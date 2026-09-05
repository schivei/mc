// sandbox_box.mc — the box (M43 step B, docs/specs/M43.md § 1, § 3, § 4).
//
// This file is the two processes that live inside the sandbox. src/sandbox.mc
// is P, the supervisor on the host; this is:
//
//   I  the box       a child of P. It unshares the six namespaces, waits for P
//                    to write its uid/gid maps, builds the mount tree of § 3
//                    and pivot_roots into it.
//   J  the steps      the first child of I, and therefore pid 1 of the new pid
//                    namespace. It runs one child per STEP and reports each one
//                    over the status pipe. It is what P kills for the wall
//                    clock: SIGKILL to the init of a pid namespace takes every
//                    process in it (§ 1, § Risks 6).
//   C  a step        a child of J. It closes every inherited descriptor, asks
//                    for no_new_privs, reads one sync byte, sets the caps that
//                    only make sense on the process about to run, and execve's.
//
// Everything it knows lives in the record src/sandbox.mc defines, which the
// fork gave it a private copy of; every system call goes through the same
// sb_sys() shim, and it names no number.
//
// Step C -- Landlock and the seccomp filter with SECCOMP_RET_USER_NOTIF, which
// is what turns a kill into `refused: open /etc/shadow` -- goes in ONE place,
// marked below in sb_step_child between no_new_privs and the sync read. Nothing
// else in this file has to move for it.

// Why there are FOUR processes and not the three § 1 draws, measured rather
// than chosen: a pid namespace dies with its init, so the compile step cannot
// BE pid 1 -- once it exits the kernel refuses to put the run step in the same
// namespace. The obvious repair, one fresh pid namespace per step, is not
// available either: `unshare(CLONE_NEWPID)` a second time answers EINVAL,
// because copy_pid_ns() refuses when the caller's ACTIVE pid namespace is no
// longer the one its children would be put in (kernel/pid_namespace.c), which
// is exactly the state the first unshare leaves. So one child of I, J, is pid 1
// for the whole box and runs the steps as its own children -- and it is J, not
// a step, that P kills.

// ---- talking to P ----
void sb_say_box(uptr line) {
    sb_sys(SN_WRITE, sb_spw(), line, cstrlen(line), 0, 0, 0);
}

// the site of a setup failure and the errno the kernel gave, as one line; the
// sentence is P's (sb_site_msg), because P is the process that owns the report.
void sb_die_box(i64 site, i64 rc) {
    i64 e = 0 - rc;
    if (e < 0) e = 0;
    sb_say_box(tm_cat("E ", tm_cat(tm_num_str(site), tm_cat(" ", tm_cat(tm_num_str(e), "\n")))));
    sb_sys(SN_EXIT_GROUP, SB_EXIT_SETUP, 0, 0, 0, 0, 0);
}

// ---- the mount tree (§ 3) ----
i64 sb_mkdir(uptr p) { return sb_sys(SN_MKDIRAT, SB_AT_FDCWD, p, SB_MODE_755, 0, 0, 0); }

// every directory of the box, with the kernel's own errno kept: a `cannot
// create a directory in the box: EACCES` that invented its errno would be
// worse than no line at all
void sb_mkdir_or_die(uptr p) {
    i64 rc = sb_mkdir(p);
    if (rc < 0) sb_die_box(SBE_MKDIR, rc);
}

i64 sb_mount(uptr src, uptr tgt, uptr fs, i64 flags, uptr data) {
    return sb_sys(SN_MOUNT, src, tgt, fs, flags, data, 0);
}

// A bind is two calls: the first one attaches the tree, the second one turns it
// read-only. The kernel ignores every flag but MS_REC on the first, which is
// why MS_RDONLY cannot be asked for in one go.
i64 sb_bind_ro(uptr src, uptr tgt) {
    i64 rc = sb_mount(src, tgt, 0, SB_MS_BIND | SB_MS_REC, 0);
    if (rc < 0) return rc;
    return sb_mount(0, tgt, 0,
                    SB_MS_BIND | SB_MS_REMOUNT | SB_MS_RDONLY | SB_MS_REC | SB_MS_NOSUID | SB_MS_NODEV, 0);
}

// a path inside the box directory, before the pivot
uptr sb_bp(uptr rel) { return tm_cat(tm_cat(sb_boxdir(), "/"), rel); }

// /mc is a FILE, so its mount point is an empty file and not a directory.
void sb_bind_compiler() {
    i64 fd = sb_sys(SN_OPENAT, SB_AT_FDCWD, sb_bp("mc"), SB_O_WRONLY | SB_O_CREAT, SB_MODE_600, 0, 0);
    if (fd < 0) sb_die_box(SBE_BIND_MC, fd);
    sb_sys(SN_CLOSE, fd, 0, 0, 0, 0, 0);
    i64 rc = sb_bind_ro(sb_self(), sb_bp("mc"));
    if (rc < 0) sb_die_box(SBE_BIND_MC, rc);
}

// /src: an overlay whose lower is the host's directory and whose upper and work
// are on the box tmpfs -- so the program writes, and the host tree is untouched
// by construction (§ 3, decision 6).
//
// `userxattr` is not decoration: an overlay mounted from a user namespace
// cannot set `trusted.overlay.*` xattrs (that needs CAP_SYS_ADMIN in the INIT
// namespace, which nobody here has, root included -- unshare(CLONE_NEWUSER)
// drops it), so the kernel wants to be told to use the `user.overlay.*` names
// instead. Kernels that predate it answer EINVAL, and the option is dropped and
// tried again.
//
// § Risks 3 priced a fallback for a lower filesystem that refuses an overlay
// (virtiofs was the suspect); it is built: a read-only bind of the source at
// /src plus a writable /out on the tmpfs, with the compiler writing there. P is
// told with an `O` line, so the report and the paths agree.
i64 sb_mount_src() {
    uptr common = tm_cat("lowerdir=", tm_cat(sb_srcdir(),
                  tm_cat(",upperdir=", tm_cat(sb_bp("upper"),
                  tm_cat(",workdir=", sb_bp("work"))))));
    i64 rc = sb_mount("overlay", sb_bp("src"), "overlay", 0, tm_cat(common, ",userxattr"));
    if (rc >= 0) return 0;
    rc = sb_mount("overlay", sb_bp("src"), "overlay", 0, common);
    if (rc >= 0) return 0;
    // the fallback road
    if (sb_entry() == 0) sb_die_box(SBE_PROJECT, rc);
    rc = sb_bind_ro(sb_srcdir(), sb_bp("src"));
    if (rc < 0) sb_die_box(SBE_SRC, rc);
    set_sb_outdir("/out");
    sb_say_box("O\n");
    return 1;
}

// /lib, /lib64 and /usr/lib, when the host has them: an M42 dynamic binary
// names its loader by path and finds its libc next to it, and the compiler
// itself is one of those binaries.
void sb_bind_libs() {
    if (sb_is_dir("/lib")) {
        sb_mkdir_or_die(sb_bp("lib"));
        i64 rc = sb_bind_ro("/lib", sb_bp("lib"));
        if (rc < 0) sb_die_box(SBE_LIB, rc);
    }
    if (sb_is_dir("/lib64")) {
        sb_mkdir_or_die(sb_bp("lib64"));
        i64 rc = sb_bind_ro("/lib64", sb_bp("lib64"));
        if (rc < 0) sb_die_box(SBE_LIB, rc);
    }
    if (sb_is_dir("/usr/lib")) {
        sb_mkdir(sb_bp("usr"));
        sb_mkdir_or_die(sb_bp("usr/lib"));
        i64 rc = sb_bind_ro("/usr/lib", sb_bp("usr/lib"));
        if (rc < 0) sb_die_box(SBE_LIB, rc);
    }
}

// --ro DIR, repeatable: each one is bound read-only at /ro0, /ro1, ... in the
// order it was given. The numbering is the interface -- a program that has to
// read a tree next to its own source is told where it is, and the box never
// reproduces a host path (§ 6: no host path in the report, and none in the
// box either).
void sb_bind_ro_dirs() {
    i64 i = 0;
    while (i < sb_nro()) {
        uptr at = tm_cat("ro", tm_num_str(i));
        sb_mkdir_or_die(sb_bp(at));
        i64 rc = sb_bind_ro(sb_abs(sb_ro_at(i)), sb_bp(at));
        if (rc < 0) sb_die_box(SBE_RO, rc);
        i = i + 1;
    }
}

void sb_build_tree() {
    i64 rc = sb_mount(0, "/", 0, SB_MS_PRIVATE_REC, 0);
    if (rc < 0) sb_die_box(SBE_MOUNT_ROOT, rc);

    // The box is a directory on the host that exists only while the box does.
    // It is made under /tmp rather than by shadowing an existing directory,
    // because the source tree the overlay reads may itself be under /tmp and a
    // tmpfs over it would hide the very files being compiled. P removes it
    // after the box is gone (sb_cleanup); it is the only thing the sandbox
    // writes outside the box, and it is empty.
    rc = sb_mkdir(sb_boxdir());
    if (rc < 0 && rc != 0 - 17) sb_die_box(SBE_MKDIR, rc);       // EEXIST is fine

    rc = sb_mount("tmpfs", sb_boxdir(), "tmpfs", SB_MS_NOSUID | SB_MS_NODEV,
                  tm_cat("size=", tm_cat(tm_num_str(sb_out()), "m,mode=755")));
    if (rc < 0) sb_die_box(SBE_TMPFS, rc);

    sb_mkdir_or_die(sb_bp("src"));
    sb_mkdir_or_die(sb_bp("upper"));
    sb_mkdir_or_die(sb_bp("work"));
    sb_mkdir_or_die(sb_bp("out"));
    sb_mkdir_or_die(sb_bp(".old"));

    sb_bind_compiler();
    sb_mount_src();
    sb_bind_ro_dirs();
    sb_bind_libs();

    // pivot_root(".", ".old") from inside the new root is the documented
    // recipe: put_old has to be under new_root, and new_root has to be a mount
    // point whose parent is not shared -- which is what the MS_PRIVATE|MS_REC
    // above bought.
    rc = sb_sys(SN_CHDIR, sb_boxdir(), 0, 0, 0, 0, 0);
    if (rc < 0) sb_die_box(SBE_CHDIR, rc);
    rc = sb_sys(SN_PIVOT_ROOT, ".", ".old", 0, 0, 0, 0);
    if (rc < 0) sb_die_box(SBE_PIVOT, rc);
    rc = sb_sys(SN_CHDIR, "/", 0, 0, 0, 0, 0);
    if (rc < 0) sb_die_box(SBE_CHDIR, rc);
    rc = sb_sys(SN_UMOUNT2, "/.old", SB_MNT_DETACH, 0, 0, 0, 0);
    if (rc < 0) sb_die_box(SBE_UMOUNT, rc);

    rc = sb_sys(SN_SETHOSTNAME, "sandbox", 7, 0, 0, 0, 0);
    if (rc < 0) sb_die_box(SBE_HOSTNAME, rc);

    // where the steps start: /src, or --cwd. A --cwd that starts with a slash
    // is a path in the box (/ro0 is how a program reads a tree beside its own
    // source); anything else is relative to /src.
    uptr cw = "/src";
    if (sb_cwd()) {
        cw = sb_cwd();
        if (ld8(cw) != '/') cw = tm_cat("/src/", cw);
    }
    rc = sb_sys(SN_CHDIR, cw, 0, 0, 0, 0, 0);
    if (rc < 0) sb_die_box(SBE_CHDIR, rc);
}

// ---- the caps (§ 4) ----
// § 4 has I set every limit and every step inherit it. Two of them cannot be
// set there, and the reason is measured rather than stylistic:
//
//   RLIMIT_AS     applies to the process that sets it, and I is a fork of `mc`
//                 carrying its own arena -- capping it at --mem would make the
//                 BOX die of the program's limit;
//   RLIMIT_NPROC  is checked by fork, and I still has to fork the steps: a 0
//                 there would refuse the compile step before it started.
//
// So I sets the three that are safe to inherit and can be REPORTED when they
// fail, and C sets the three that only make sense on the process about to
// execve. Each step gets its own of all six, which is what "inherited by every
// step" meant.
i64 sb_rlimit(i64 res, i64 v) {
    st64(sb_rlim(), v);
    st64(sb_rlim() + 8, v);
    return sb_sys(SN_PRLIMIT64, 0, res, sb_rlim(), 0, 0, 0);
}

void sb_caps_box() {
    i64 rc = sb_rlimit(SB_RLIMIT_CPU, sb_time());
    if (rc < 0) sb_die_box(SBE_RLIMIT, rc);
    rc = sb_rlimit(SB_RLIMIT_FSIZE, sb_out() * 1048576);
    if (rc < 0) sb_die_box(SBE_RLIMIT, rc);
    rc = sb_rlimit(SB_RLIMIT_CORE, 0);
    if (rc < 0) sb_die_box(SBE_RLIMIT, rc);
    rc = sb_rlimit(SB_RLIMIT_NOFILE, SB_NOFILE);
    if (rc < 0) sb_die_box(SBE_RLIMIT, rc);
}

// C is past close_range by the time it runs this, so it has no way to reach P
// with a diagnostic; none of the three can fail for a value chosen here, and a
// failure would surface as the program running without that one cap rather than
// as silence -- `mc sandbox check` and the isolation cases are what keep them
// honest.
void sb_caps_step(i64 step) {
    sb_rlimit(SB_RLIMIT_AS, sb_mem() * 1048576);
    sb_rlimit(SB_RLIMIT_STACK, SB_STACK_MIB * 1048576);
    // RLIMIT_NPROC is a REAL wall here, and it was measured: at 0 the kernel
    // refuses the first clone with EAGAIN, for a plain fork and for the
    // clone3(CLONE_VM|CLONE_VFORK) behind posix_spawn alike -- the box's uid 0
    // holds CAP_SYS_RESOURCE in its own user namespace, and copy_process asks
    // capable(), which is a question about the INIT namespace. So a fork bomb
    // stops at its first fork without any filter (§ Risks 5 expected the
    // opposite).
    //
    // The compile step is the exception, and it is not a loophole: `mc build`
    // WRITES a compiler and then runs it (drv_teach spawns it with
    // --entry-only, § 5), so a project needs a handful of processes to build at
    // all. Sixteen is more than the three execs a taught build takes and far
    // less than a bomb.
    i64 np = 0;
    if (step == SB_STEP_COMPILE) np = SB_NPROC_COMPILE;
    if (sb_threads()) np = SB_NPROC_THREADS;
    sb_rlimit(SB_RLIMIT_NPROC, np);
}

// ---- C: one step ----
// `sr` is the sync pipe's read end and `ew` the write end of the pipe that
// carries an execve failure back to I. Both are inherited descriptors with
// numbers I did not choose, so instead of moving them to fixed slots the close
// sweeps AROUND them -- three ranges, no dup3 dance, and nothing but 0, 1, 2
// and those two survives into the program.
void sb_step_child(i64 step, i64 sr, i64 ew) {
    if (sb_infd() >= 0 && sb_infd() != 0) sb_sys(SN_DUP3, sb_infd(), 0, 0, 0, 0, 0);

    i64 lo = sr;
    i64 hi = ew;
    if (ew < sr) { lo = ew; hi = sr; }
    if (lo > 3) sb_sys(SN_CLOSE_RANGE, 3, lo - 1, SB_CLOSE_RANGE_UNSHARE, 0, 0, 0);
    if (hi > lo + 1) sb_sys(SN_CLOSE_RANGE, lo + 1, hi - 1, SB_CLOSE_RANGE_UNSHARE, 0, 0, 0);
    sb_sys(SN_CLOSE_RANGE, hi + 1, SB_FD_MAX, SB_CLOSE_RANGE_UNSHARE, 0, 0, 0);

    sb_sys(SN_PRCTL, SB_PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0, 0);

    // ---- STEP C GOES HERE ----------------------------------------------
    // Landlock (a ruleset over /src, /out, /mc, /lib, /lib64, /usr/lib and the
    // --ro roots) and then seccomp(SECCOMP_SET_MODE_FILTER,
    // SECCOMP_FILTER_FLAG_NEW_LISTENER, &prog), whose result is the listener
    // fd P fetches with pidfd_open + pidfd_getfd. Both must be installed by the
    // process that execve's, both are irrevocable, and both must come AFTER
    // no_new_privs and BEFORE the sync read -- the byte below is what tells C
    // that P already holds the listener. Nothing above or below has to change.
    // --------------------------------------------------------------------

    st8(sb_word(), 0);
    sb_sys(SN_READ, sr, sb_word(), 1, 0, 0, 0);
    sb_sys(SN_CLOSE, sr, 0, 0, 0, 0, 0);

    sb_caps_step(step);

    uptr bin = sb_bin0();
    uptr av = sb_av0();
    if (step == SB_STEP_RUN) { bin = sb_bin1(); av = sb_av1(); }
    i64 rc = sb_sys(SN_EXECVE, bin, av, sb_env(), 0, 0, 0);

    // only reachable when execve failed: the errno goes back to I over the
    // CLOEXEC pipe, which a successful execve would have closed for us.
    st64(sb_word(), 0 - rc);
    sb_sys(SN_WRITE, ew, sb_word(), 8, 0, 0, 0);
    sb_sys(SN_EXIT_GROUP, 127, 0, 0, 0, 0, 0);
}

// ---- J: run one step and report it ----
// Returns 1 when the box should stop (the step failed, or it was the last one).
i64 sb_run_step(i64 step) {
    // P has to know which step is running before it starts: the wall clock
    // kills J, and a dead J cannot report anything, so the line P prints then
    // is one it composes itself and it needs the step for the `compile: `
    // prefix.
    sb_say_box(tm_cat("B ", tm_cat(tm_num_str(step), "\n")));
    if (sb_sys(SN_PIPE2, sb_word(), 0, 0, 0, 0, 0) < 0) sb_die_box(SBE_PIPE, 0 - E_NOMEM);
    i64 sr = ld32(sb_word());
    i64 sw = ld32(sb_word() + 4);
    if (sb_sys(SN_PIPE2, sb_word(), SB_O_CLOEXEC, 0, 0, 0, 0) < 0) sb_die_box(SBE_PIPE, 0 - E_NOMEM);
    i64 er = ld32(sb_word());
    i64 ew = ld32(sb_word() + 4);

    i64 pid = sb_sys(SN_CLONE, SB_SIGCHLD, 0, 0, 0, 0, 0);
    if (pid < 0) sb_die_box(SBE_FORK, pid);
    if (pid == 0) {
        sb_sys(SN_CLOSE, sw, 0, 0, 0, 0, 0);
        sb_sys(SN_CLOSE, er, 0, 0, 0, 0, 0);
        sb_step_child(step, sr, ew);             // never returns
    }
    sb_sys(SN_CLOSE, sr, 0, 0, 0, 0, 0);
    sb_sys(SN_CLOSE, ew, 0, 0, 0, 0, 0);
    // Step C fetches the seccomp listener out of C here, with pidfd_open on
    // this pid and pidfd_getfd, before the sync byte lets C go on to execve.
    sb_sys(SN_WRITE, sw, "1", 1, 0, 0, 0);       // C may go
    sb_sys(SN_CLOSE, sw, 0, 0, 0, 0, 0);

    st64(sb_word(), 0);
    mem_zero(sb_ru(), 144);
    sb_sys(SN_WAIT4, pid, sb_word(), 0, sb_ru(), 0, 0);
    i64 st = ld32(sb_word());

    // did execve itself fail? The pipe holds eight bytes only in that case.
    st64(sb_word() + 8, 0);
    i64 n = sb_sys(SN_READ, er, sb_word() + 8, 8, 0, 0, 0);
    sb_sys(SN_CLOSE, er, 0, 0, 0, 0, 0);
    if (n == 8) { sb_die_box(SBE_EXEC, 0 - ld64(sb_word() + 8)); }

    if (st & 0x7f) {
        // the cpu decision is made HERE, where the rusage of this step alone is
        // in hand: P's own wait4 would see the sum of every step, and a
        // compile that took a second would then make a segfaulting program look
        // like a cpu cap.
        //
        // Two measured details. SIGXCPU is the signal the kernel sends at the
        // SOFT limit and it means nothing else, so it is proof on its own -- but
        // with soft = hard the kernel adds SIGKILL and that is the one that
        // arrives (measured: forever.mc dies of 9, not of 24). And the recorded
        // time is a shade UNDER the limit when it does: a 2 s cap came back as
        // 1.997 s of rusage, because the accounting tick that triggered the
        // kill is not in the total. A tenth of a second of slack is what makes
        // the comparison mean "it spent its whole budget".
        i64 sig = st & 0x7f;
        i64 us = ld64(sb_ru()) * 1000000 + ld64(sb_ru() + 8)
               + ld64(sb_ru() + 16) * 1000000 + ld64(sb_ru() + 24);
        i64 cpu = 0;
        if (sig == SB_SIGXCPU) cpu = 1;
        if (us + 100000 >= sb_time() * 1000000) cpu = 1;
        sb_say_box(tm_cat("S ", tm_cat(tm_num_str(step), tm_cat(" ",
                   tm_cat(tm_num_str(sig), tm_cat(" ",
                   tm_cat(tm_num_str(cpu), "\n")))))));
        return 1;
    }
    i64 code = (st >> 8) & 0xff;
    sb_say_box(tm_cat("X ", tm_cat(tm_num_str(step), tm_cat(" ",
               tm_cat(tm_num_str(code), "\n")))));
    if (code != 0) return 1;
    return 0;
}

// ---- J: the steps, from inside the pid namespace ----
void sb_steps_main() {
    i64 step = SB_STEP_COMPILE;
    if (!sb_is_run()) step = SB_STEP_RUN;        // `exec`: there is nothing to compile
    loop {
        if (sb_run_step(step)) break;
        if (step == SB_STEP_RUN) break;
        if (sb_dump()) break;                    // the dump IS the output (§ 5)
        if (!str_eq(sb_kind(), "exe")) break;    // a project that builds an object
        step = SB_STEP_RUN;
    }
    sb_sys(SN_EXIT_GROUP, 0, 0, 0, 0, 0, 0);
}

// ---- I: the box ----
void sb_box_main() {
    i64 rc = sb_sys(SN_UNSHARE, SB_CLONE_BOX, 0, 0, 0, 0, 0);
    if (rc < 0) sb_die_box(SBE_UNSHARE, rc);

    // P is the only process that may write the maps (§ 1): unprivileged, a
    // process cannot map even its own uid from inside the namespace it just
    // created. So the box asks, and blocks until the byte comes back.
    // the box directory, named after I's own pid so that two sandboxes never
    // collide. P computes the same name from the pid clone() gave it, and
    // removes the empty directory once the box is gone.
    set_sb_boxdir(tm_cat("/tmp/.mc-box", tm_num_str(sb_sys(SN_GETPID, 0, 0, 0, 0, 0, 0))));

    sb_say_box("U\n");
    st8(sb_word(), 0);
    sb_sys(SN_READ, sb_mpr(), sb_word(), 1, 0, 0, 0);
    sb_sys(SN_CLOSE, sb_mpr(), 0, 0, 0, 0, 0);

    // No setuid is needed here and that is a property of the maps, not an
    // omission: both of them put THE CALLER at the inner uid 0 (sb_map_text),
    // so the box is already the identity it is going to keep.

    sb_build_tree();
    sb_caps_box();
    sb_argv_build();

    // J: the first child of a process that unshared CLONE_NEWPID is pid 1 of
    // the new namespace, and everything the box runs is under it.
    i64 jpid = sb_sys(SN_CLONE, SB_SIGCHLD, 0, 0, 0, 0, 0);
    if (jpid < 0) sb_die_box(SBE_FORK, jpid);
    if (jpid == 0) sb_steps_main();              // never returns
    sb_say_box(tm_cat("P ", tm_cat(tm_num_str(jpid), "\n")));
    st64(sb_word(), 0);
    sb_sys(SN_WAIT4, jpid, sb_word(), 0, 0, 0, 0);
    sb_sys(SN_EXIT_GROUP, 0, 0, 0, 0, 0, 0);
}

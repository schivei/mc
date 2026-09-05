// seccomp.mc — the two walls (M43 step C, docs/specs/M43.md § 3 and § 4,
// docs/reference/sandbox.md § The two walls).
//
// The box of step B is a tree and a set of namespaces: a program in it cannot
// SEE the host, and that is enforced by what exists. This file is the other
// half -- what the program may DO -- and it is two independent walls:
//
//   Landlock    a filesystem policy attached to the process itself, so a path
//               outside the four roots answers EACCES even if a mount were
//               ever wrong. It is the second wall, not the first.
//   seccomp     an allowlist of system-call NUMBERS. Everything outside it
//               reaches the supervisor as a SECCOMP_RET_USER_NOTIF
//               notification, which is what turns a kill into a sentence:
//               `refused: syscall 198 (socket)`, `refused: open /etc/shadow`.
//
// Both are installed by C, the process that execve's, in the marked place in
// src/sandbox_box.mc: they are inherited, cumulative and irrevocable, so they
// cannot live in I (which still has to fork) and they must come after
// PR_SET_NO_NEW_PRIVS and before the sync byte -- the byte is what tells C that
// P is already holding the listener.
//
// The three primitives at the bottom (recv, send, the remote read) are P's,
// not C's: the answer to a notification is a POLICY decision and it belongs
// with the report, in src/sandbox.mc. This file is the ABI.

// ---- classic BPF, the four opcodes a seccomp filter needs ----
// (linux/filter.h: the class in bits 0..2, the size in 3..4, the mode in 5..7
// for a load; the op in 4..7 and the source in bit 3 for a jump.)
#define BPF_LD_W_ABS   0x20              // BPF_LD | BPF_W | BPF_ABS
#define BPF_JEQ_K      0x15              // BPF_JMP | BPF_JEQ | BPF_K
#define BPF_JGE_K      0x35              // BPF_JMP | BPF_JGE | BPF_K
#define BPF_JSET_K     0x45              // BPF_JMP | BPF_JSET | BPF_K
#define BPF_RET_K      0x06              // BPF_RET | BPF_K

// struct seccomp_data, the record the filter reads: int nr, __u32 arch,
// __u64 instruction_pointer, __u64 args[6].
#define SD_NR                 0
#define SD_ARCH               4
#define SD_ARG0              16

#define SECCOMP_RET_KILL_PROCESS 0x80000000
#define SECCOMP_RET_ALLOW        0x7FFF0000
#define SECCOMP_SET_MODE_FILTER  1
#define SECCOMP_NEW_LISTENER     8       // SECCOMP_FILTER_FLAG_NEW_LISTENER

// On x86-64 a system call whose number carries 0x40000000 is the x32 ABI: a
// DIFFERENT numbering over the same entry point, so an allowlist written for
// the 64-bit table would be answering questions it was never asked. There is
// no such bit on AArch64 and no number that high, so the test is free there.
#define SB_X32_BIT            0x40000000

// clone(2) flags. The filter allows a clone only when it is a THREAD of the
// process that asked -- CLONE_THREAD set and no CLONE_NEW* bit -- which is
// what `--allow=threads` means and what a fork bomb is not.
#define SB_CLONE_THREAD       0x00010000
#define SB_CLONE_NEWANY       0x7E020000  // NEWNS|NEWCGROUP|NEWUTS|NEWIPC|NEWUSER|NEWPID|NEWNET

// how the filter treats clone(2), decided per step
#define SB_CLONE_PROF    0               // whatever the profile says (compile)
#define SB_CLONE_THREADS 1               // the flag test above (--allow=threads)

// ---- Landlock (§ 3) ----
// The access bits of each ABI level. A bit the running kernel does not know is
// EINVAL from landlock_create_ruleset, so the mask is built UP from the ABI it
// reports -- `landlock: abi 8` on the baseline, floor 4 (§ 0).
#define LL_FS_BASE       0x1fff          // ABI 1: the thirteen original rights
#define LL_FS_REFER      0x2000          // ABI 2
#define LL_FS_TRUNCATE   0x4000          // ABI 3
#define LL_FS_IOCTL_DEV  0x8000          // ABI 5
#define LL_NET_ALL            3          // ABI 4: bind TCP | connect TCP
#define LL_SCOPE_ALL          3          // ABI 6: abstract unix sockets | signals
#define LL_RULE_PATH_BENEATH  1
#define LL_READ_EXEC         13          // EXECUTE | READ_FILE | READ_DIR
// /mc is a FILE, not a directory, and a rule on a file may not carry a
// directory right: READ_DIR on it is EINVAL from landlock_add_rule, which is
// how the first version of this file failed (`cannot install the Landlock
// ruleset: EINVAL`, measured on kernel 7.0.0-30).
#define LL_FILE_EXEC          5          // EXECUTE | READ_FILE
#define LL_READ_ONLY         12          // READ_FILE | READ_DIR
#define LL_READ_FILE          4          // one file, read only
#define SB_O_PATH        0x200000

// the message C sends J over the error pipe when the walls are up; the site
// numbers of src/sandbox.mc start at 1, so 0 cannot collide with a failure
#define SBM_READY 0

uptr sb_notifp();                        // src/sandbox.mc: the record's buffers
uptr sb_respp();
uptr sb_iovp();
uptr sb_llattr();
uptr sb_pbattr();
uptr sb_fprogp();
uptr sb_bpfp();
uptr sb_profp();
uptr sb_rpath();

// ---- the profile: SN_* indices in, kernel numbers out ----
// A profile is written in SN_* terms (src/sysno.mc) and resolved here, once,
// against the table of the architecture that is running. An entry this
// architecture does not have -- `access` and `arch_prctl` on AArch64, `openat`
// where glibc issues `open` -- answers -1 from host_sysno() and is dropped:
// the same profile compiles and means the right thing on both machines.
i64 sb_prof_has(i64 nr) {
    i64 i = 0;
    while (i < sb_nprof()) {
        if (ld64(sb_profp() + i * 8) == nr) return 1;
        i = i + 1;
    }
    return 0;
}

// The five calls the supervisor always wants to SEE, even though every profile
// contains them: they are what the table of § 4 decides on, and a decision
// needs the call to arrive. They are allowed in the end -- P answers CONTINUE
// -- but through P, which is what makes `refused: open /etc/shadow` and
// `refused: mmap N bytes over the cap` possible at all. The cost is a round
// trip per call and it is the overhead docs/reference/sandbox.md reports.
//
// clone and clone3 are NOT here: the compile step has to fork (`mc build`
// writes a compiler and runs it), so when they are in a profile they are
// plainly allowed, and when they are not -- every run step without
// --allow=threads -- they fall through to the notification anyway.
i64 sb_notified(i64 nr) {
    if (nr == host_sysno(SN_OPENAT)) return 1;
    if (nr == host_sysno(SN_OPEN)) return 1;
    if (nr == host_sysno(SN_MMAP)) return 1;
    if (nr == host_sysno(SN_MUNMAP)) return 1;
    if (nr == host_sysno(SN_EXECVE)) return 1;
    return 0;
}

void sb_prof_one(i64 sn) {
    i64 nr = host_sysno(sn);
    if (nr >= 0 && !sb_notified(nr) && !sb_prof_has(nr) && sb_nprof() < SB_MAXPROF) {
        st64(sb_profp() + sb_nprof() * 8, nr);
        set_sb_nprof(sb_nprof() + 1);
    }
}

void sb_prof_add(uptr list) {
    i64 i = 0;
    loop {
        i64 sn = ld64(list + i * 8);
        if (sn < 0) break;
        sb_prof_one(sn);
        i = i + 1;
    }
}

// one 8-byte struct sock_filter: u16 code, u8 jt, u8 jf, u32 k
i64 sb_bpf_at(i64 i, i64 code, i64 jt, i64 jf, i64 k) {
    uptr p = sb_bpfp() + i * 8;
    st16(p, code);
    st8(p + 2, jt);
    st8(p + 3, jf);
    st32(p + 4, k);
    return i + 1;
}

// The whole program, laid out so that every jump is forward and every offset
// is a subtraction that can be read off the picture:
//
//   0            ld  [arch]
//   1            jeq AUDIT_ARCH_*      jf -> KILL
//   2            ld  [nr]
//   3            jge 0x40000000        jt -> KILL          (the x32 ABI)
//   4 .. 4+m-1   jeq <allowed number>  jt -> ALLOW
//   [clone block, four instructions, only with --allow=threads]
//   d            ret USER_NOTIF        <- the fall-through: ask the supervisor
//   d+1          ret ALLOW
//   d+2          ret KILL_PROCESS
//
// A jump offset is one unsigned byte, counted from the instruction AFTER the
// jump, so d + 2 has to stay under 255: sb_filter_apply refuses a longer
// profile rather than emitting a filter that jumps to the wrong place.
i64 sb_filter_build(i64 mode) {
    i64 m = sb_nprof();
    i64 c = 0;
    if (mode == SB_CLONE_THREADS) c = 4;
    i64 d = 4 + m + c;

    i64 i = 0;
    i = sb_bpf_at(i, BPF_LD_W_ABS, 0, 0, SD_ARCH);
    i = sb_bpf_at(i, BPF_JEQ_K, 0, d, host_audit_arch());
    i = sb_bpf_at(i, BPF_LD_W_ABS, 0, 0, SD_NR);
    i = sb_bpf_at(i, BPF_JGE_K, d - 2, 0, SB_X32_BIT);

    i64 j = 0;
    while (j < m) {
        i = sb_bpf_at(i, BPF_JEQ_K, m + c - j, 0, ld64(sb_profp() + j * 8));
        j = j + 1;
    }

    if (c) {
        // clone is the one row whose ARGUMENT decides. clone3 is not here and
        // cannot be: its flags live in a struct in the caller's memory, which
        // BPF cannot read -- it stays a notification, and P counts it.
        i = sb_bpf_at(i, BPF_JEQ_K, 0, 3, host_sysno(SN_CLONE));
        i = sb_bpf_at(i, BPF_LD_W_ABS, 0, 0, SD_ARG0);
        i = sb_bpf_at(i, BPF_JSET_K, 0, 1, SB_CLONE_THREAD);   // no THREAD -> notify
        i = sb_bpf_at(i, BPF_JSET_K, 0, 1, SB_CLONE_NEWANY);   // a NEW* -> notify
    }

    i = sb_bpf_at(i, BPF_RET_K, 0, 0, SB_RET_USER_NOTIF);
    i = sb_bpf_at(i, BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW);
    i = sb_bpf_at(i, BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS);
    return i;
}

// Build the profile for this step and install it. The result is the LISTENER
// fd (SECCOMP_FILTER_FLAG_NEW_LISTENER), which is the whole point: without it
// a refused call is a dead process with no explanation.
i64 sb_filter_apply(i64 step) {
    set_sb_nprof(0);
    // The two calls C itself makes AFTER the filter is in and before the
    // program exists: the read that waits for P's sync byte, and the close of
    // its own copy of the listener. They are in no profile by right -- the
    // profiles measure the PROGRAM -- and they cannot be moved earlier: the
    // listener does not exist until the filter is installed, and P must hold
    // it before the program runs. Measured, without this: `refused: syscall 0
    // (read)` for every musl run step, because musl's programs in the corpus
    // never read (its stdio uses readv) while glibc's do, so the aarch64
    // profile hid the bug and the x86-64 one did not.
    sb_prof_one(SN_READ);
    sb_prof_one(SN_CLOSE);

    i64 gnu = str_eq(sb_libc(), "gnu");
    if (step == SB_STEP_COMPILE) {
        sb_prof_add(sbp_compile());
        if (gnu) sb_prof_add(sbp_gnu_compile());
    } else {
        sb_prof_add(sbp_program());
        if (gnu) sb_prof_add(sbp_gnu_program());
    }
    i64 mode = SB_CLONE_PROF;
    if (sb_threads()) {
        sb_prof_add(sbp_threads);
        mode = SB_CLONE_THREADS;
    }
    if (sb_nprof() + 11 > 250) return 0 - E_NOMEM;   // the u8 jump offset
    i64 count = sb_filter_build(mode);
    st16(sb_fprogp(), count);
    st64(sb_fprogp() + 8, sb_bpfp());
    return sb_sys(SN_SECCOMP, SECCOMP_SET_MODE_FILTER, SECCOMP_NEW_LISTENER,
                  sb_fprogp(), 0, 0, 0);
}

// ---- Landlock (§ 3) ----
// One rule per root. The attribute is a PACKED 12-byte record -- u64
// allowed_access then s32 parent_fd -- so it is written byte by byte like
// every other record this project hands to a kernel, and the fd is opened
// O_PATH because a rule needs a name for a directory, not a way to read it.
i64 sb_ll_rule(i64 rs, uptr path, i64 access) {
    i64 fd = sb_sys(SN_OPENAT, SB_AT_FDCWD, path, SB_O_PATH | SB_O_CLOEXEC, 0, 0, 0);
    if (fd < 0) return 0;                        // absent in this box: nothing to grant
    st64(sb_pbattr(), access);
    st32(sb_pbattr() + 8, fd);
    i64 rc = sb_sys(SN_LANDLOCK_ADD_RULE, rs, LL_RULE_PATH_BENEATH, sb_pbattr(), 0, 0, 0);
    sb_sys(SN_CLOSE, fd, 0, 0, 0, 0, 0);
    return rc;
}

// The ruleset covers every access this kernel knows about; what a path is not
// granted, it does not get. /src and /out are the writable pair (the overlay
// upper and the tmpfs) and get everything; the rest is read and execute, which
// is what a loader needs of /lib and what execve needs of /mc.
//
// With ABI >= 4 the ruleset also handles the network and grants nothing, so a
// TCP bind or connect is refused by the policy as well as by the empty network
// namespace; with ABI >= 6 it scopes abstract unix sockets and signals to the
// domain, so the box cannot signal a process outside it even if one were
// visible.
i64 sb_landlock_apply() {
    i64 abi = sb_sys(SN_LANDLOCK_CREATE_RULESET, 0, 0, SB_LANDLOCK_ABI_VERSION, 0, 0, 0);
    if (abi < 0) return abi;
    if (abi < SB_LANDLOCK_ABI_MIN) return 0 - E_NOSYS;

    i64 fs = LL_FS_BASE;
    if (abi >= 2) fs = fs | LL_FS_REFER;
    if (abi >= 3) fs = fs | LL_FS_TRUNCATE;
    if (abi >= 5) fs = fs | LL_FS_IOCTL_DEV;
    mem_zero(sb_llattr(), 24);
    st64(sb_llattr(), fs);
    i64 sz = 8;
    if (abi >= 4) { st64(sb_llattr() + 8, LL_NET_ALL); sz = 16; }
    if (abi >= 6) { st64(sb_llattr() + 16, LL_SCOPE_ALL); sz = 24; }

    i64 rs = sb_sys(SN_LANDLOCK_CREATE_RULESET, sb_llattr(), sz, 0, 0, 0, 0);
    if (rs < 0) return rs;

    i64 rc = sb_ll_rule(rs, "/src", fs);
    if (rc >= 0) rc = sb_ll_rule(rs, "/out", fs);
    if (rc >= 0) rc = sb_ll_rule(rs, "/mc", LL_FILE_EXEC);
    if (rc >= 0) rc = sb_ll_rule(rs, "/lib", LL_READ_EXEC);
    if (rc >= 0) rc = sb_ll_rule(rs, "/lib64", LL_READ_EXEC);
    if (rc >= 0) rc = sb_ll_rule(rs, "/usr/lib", LL_READ_EXEC);
    // The one file of /etc the box has (src/sandbox_box.mc, sb_bind_ldcache).
    // Without this rule the mount is there and Landlock refuses it, and the
    // difference is not academic: glibc's loader then falls back to searching
    // the default directories, which on x86-64 means probing
    // /lib/x86_64-linux-gnu/glibc-hwcaps/x86-64-v4/ with newfstatat -- a call
    // no profile has, so EVERY dynamic program died with `refused: syscall 262
    // (newfstatat)`. Measured on the VPS; AArch64's loader hid it, because its
    // fallback finds libc in the first default directory it tries.
    if (rc >= 0) rc = sb_ll_rule(rs, "/etc/ld.so.cache", LL_READ_FILE);
    i64 i = 0;
    while (i < sb_nro() && rc >= 0) {
        rc = sb_ll_rule(rs, tm_cat("/ro", tm_num_str(i)), LL_READ_ONLY);
        i = i + 1;
    }
    if (rc < 0) { sb_sys(SN_CLOSE, rs, 0, 0, 0, 0, 0); return rc; }

    rc = sb_sys(SN_LANDLOCK_RESTRICT_SELF, rs, 0, 0, 0, 0, 0);
    sb_sys(SN_CLOSE, rs, 0, 0, 0, 0, 0);
    return rc;
}

// ---- the notification channel, P's side ----
// The three ioctls of the seccomp user-notification ABI. Their numbers are
// _IOWR('!', 0|1|2, sizeof(struct)) fully expanded, which is why the size of
// each record is visible in the constant: 0x50 is the 80-byte seccomp_notif,
// 0x18 the 24-byte seccomp_notif_resp, 0x08 the bare u64 of ID_VALID.
#define SB_IOCTL_NOTIF_RECV     0xC0502100
#define SB_IOCTL_NOTIF_SEND     0xC0182101
#define SB_IOCTL_NOTIF_ID_VALID 0x40082102

// struct seccomp_notif: u64 id, u32 pid, u32 flags, then the seccomp_data --
// so nr is at 16, arch at 20, the instruction pointer at 24 and args[0] at 32.
#define SB_NF_ID    0
#define SB_NF_PID   8
#define SB_NF_NR   16
#define SB_NF_ARG0 32

// struct seccomp_notif_resp: u64 id, s64 val, s32 error, u32 flags.
#define SB_NR_ID    0
#define SB_NR_VAL   8
#define SB_NR_ERROR 16
#define SB_NR_FLAGS 20
#define SB_NOTIF_CONTINUE 1              // SECCOMP_USER_NOTIF_FLAG_CONTINUE

i64 sb_notif_recv() {
    mem_zero(sb_notifp(), 80);           // the kernel refuses a dirty record
    return sb_sys(SN_IOCTL, sb_lfd(), SB_IOCTL_NOTIF_RECV, sb_notifp(), 0, 0, 0);
}

// Is the notification we are holding still the live one? A target that died
// between the RECV and the answer frees its id, and the kernel may hand the
// same number to another call; asking before a CONTINUE is what the manual
// recommends and it costs one ioctl.
i64 sb_notif_valid() {
    st64(sb_word(), ld64(sb_notifp() + SB_NF_ID));
    return sb_sys(SN_IOCTL, sb_lfd(), SB_IOCTL_NOTIF_ID_VALID, sb_word(), 0, 0, 0);
}

// err is 0 with SB_NOTIF_CONTINUE ("let the kernel run it after all") or a
// NEGATIVE errno with flags 0 ("answer the program this, and never run it").
i64 sb_notif_send(i64 err, i64 flags) {
    mem_zero(sb_respp(), 24);
    st64(sb_respp() + SB_NR_ID, ld64(sb_notifp() + SB_NF_ID));
    st64(sb_respp() + SB_NR_VAL, 0);
    st32(sb_respp() + SB_NR_ERROR, err);
    st32(sb_respp() + SB_NR_FLAGS, flags);
    return sb_sys(SN_IOCTL, sb_lfd(), SB_IOCTL_NOTIF_SEND, sb_respp(), 0, 0, 0);
}

// A NUL-terminated string out of the step's own address space, for the one
// thing a number cannot say: WHICH path was opened. It is read a page at a
// time, because a string that ends just before an unmapped page would make a
// single long read answer EFAULT and lose a name that is perfectly readable.
//
// This is a DIAGNOSTIC read and nothing depends on it: the mount tree and
// Landlock are what refuse, and with --allow=threads another thread may write
// the buffer between this read and the kernel's own (docs/reference/sandbox.md
// § What is not isolated).
uptr sb_vm_read(i64 pid, i64 addr) {
    i64 got = 0;
    loop {
        i64 want = 4096 - ((addr + got) & 4095);
        if (got + want > 4096) want = 4096 - got;
        if (want <= 0) break;
        st64(sb_iovp(), sb_rpath() + got);       // local iovec
        st64(sb_iovp() + 8, want);
        st64(sb_iovp() + 16, addr + got);        // remote iovec
        st64(sb_iovp() + 24, want);
        i64 n = sb_sys(SN_PROCESS_VM_READV, pid, sb_iovp(), 1, sb_iovp() + 16, 1, 0);
        if (n <= 0) break;
        i64 i = 0;
        while (i < n) {
            if (ld8(sb_rpath() + got + i) == 0) { return sb_rpath(); }
            i = i + 1;
        }
        got = got + n;
        if (got >= 4096) break;
    }
    st8(sb_rpath() + got, 0);
    return sb_rpath();
}

// ---- the explain channel, P's policy (§ 4) ---------------------------------
// One table, and it is the whole difference between step B and step C: a
// program that reaches outside the box is not killed by a number any more, it
// is REFUSED BY NAME, and `mc sandbox` exits 125.
//
//   anything not below   refused: syscall N (name)      -EPERM
//   openat / open        under a root -> let it run; otherwise
//                        refused: open PATH             -EACCES
//   mmap / munmap        a running total against --mem;
//                        refused: mmap N bytes over the cap (M)   -ENOMEM
//   clone / clone3       counted, with --allow=threads;
//                        refused: process limit (64)    -EAGAIN
//   execve               counted per step;  refused: execve       -EPERM
//
// Everything here is a DIAGNOSIS. The enforcement is elsewhere and does not
// depend on it: the mount tree is what makes /etc absent, Landlock is what
// makes a path outside the roots EACCES, RLIMIT_AS is what makes a huge
// mapping fail, the empty network namespace is what makes a connect
// unreachable. What this adds is the sentence.

// The name of a system call NUMBER on the running architecture, walked out of
// the one table that carries both columns (src/sysno.mc): the SN_* index names
// the row, host_sysno() gives its number here, sn_names[] its name. An index
// this architecture does not have has no number and can never be matched.
uptr sb_sysname(i64 nr) {
    i64 i = 0;
    while (i < SN_COUNT) {
        if (host_sysno(i) == nr) return ld64(sn_names + i * 8);
        i = i + 1;
    }
    return 0;
}

// `refused: syscall 198 (socket)`, or just the number when the table has no
// name for it -- a kernel is allowed to have calls this compiler never heard of.
uptr sb_callname(i64 nr) {
    uptr nm = sb_sysname(nr);
    if (nm == 0) return tm_cat("syscall ", tm_num_str(nr));
    return tm_cat("syscall ", tm_cat(tm_num_str(nr), tm_cat(" (", tm_cat(nm, ")"))));
}

// is `p` the root itself, or something under it?
i64 sb_under(uptr p, uptr root) {
    i64 n = cstrlen(root);
    if (!mem_eq(p, root, n)) return 0;
    i64 c = ld8(p + n);
    return c == 0 || c == '/';
}

// The roots a step may name. A relative path is always allowed: it resolves
// against the step's own working directory, which is inside the box by
// construction, and the mount tree is what says whether it exists.
i64 sb_path_ok(uptr p) {
    if (ld8(p) != '/') return 1;
    if (sb_under(p, "/src")) return 1;
    if (sb_under(p, "/out")) return 1;
    if (sb_under(p, "/mc")) return 1;
    if (sb_under(p, "/lib")) return 1;
    if (sb_under(p, "/lib64")) return 1;
    if (sb_under(p, "/usr")) return 1;
    i64 i = 0;
    while (i < sb_nro()) {
        if (sb_under(p, tm_cat("/ro", tm_num_str(i)))) return 1;
        i = i + 1;
    }
    // The dynamic loader's own configuration files. They do not exist in the
    // box -- there is no /etc -- and the loader opens them before a single
    // instruction of the program runs, so refusing them would refuse every
    // dynamic program instead of naming anything. Measured: glibc's ld.so
    // opens /etc/ld.so.preload and /etc/ld.so.cache at every start, musl's
    // /etc/ld-musl-<arch>.path when a library is not where it expected it.
    // They are let through and answered ENOENT by the kernel, which is what
    // the absence of /etc means. /etc/shadow is not on this list.
    if (str_eq(p, "/etc/ld.so.cache")) return 1;
    if (str_eq(p, "/etc/ld.so.preload")) return 1;
    if (mem_eq(p, "/etc/ld-musl-", 13)) return 1;
    return 0;
}

// The end of the box, by refusal. The notification is answered first -- the
// step is sitting in a system call and would otherwise stay there -- then the
// line is written, then J dies and takes the pid namespace with it.
// The end of the box, by refusal.
//
// The notification is NOT answered, and that is a deviation from § 4's table
// (which has P answer -EPERM or -EACCES and then kill). It was measured:
// answering wakes the step inside its system call, and it then runs for as
// long as the SIGKILL takes to travel -- tests/sandbox/shadow.mc printed
// `shadow errno=13` and tests/sandbox/connect.mc `socket refused` before dying,
// on some runs and not on others. Left unanswered, the refused call never
// returns and the step's output ends exactly where the refusal happened, which
// is what makes a `.expect` file possible at all. The errno column of § 4 is
// what the program WOULD be told if the box were the kind that continues; this
// one stops, and says so in one line and one exit code.
//
// `err` is kept in the signature for that table, and for the one thing that
// could still want it: a future --keep-going mode would answer it here.
void sb_refuse(uptr text, i64 err) {
    if (!sb_done()) {
        sb_say(tm_cat("refused: ", text));
        set_sb_rc(SB_EXIT_REFUSED);
        set_sb_done(1);
    }
    sb_kill_box();
}

// let the kernel run the call after all
void sb_allow() {
    sb_notif_send(0, SB_NOTIF_CONTINUE);
}

// the same, for the one decision that was made by READING the caller's memory:
// SECCOMP_IOCTL_NOTIF_ID_VALID says the notification is still the live one, so
// the path just read belongs to the call about to run and not to a dead
// process whose id the kernel has since reused.
void sb_allow_checked() {
    if (sb_notif_valid() < 0) return;
    sb_notif_send(0, SB_NOTIF_CONTINUE);
}

// one notification, decided by the table above
void sb_notif_decide() {
    i64 nr = ld32(sb_notifp() + SB_NF_NR);
    i64 pid = ld32(sb_notifp() + SB_NF_PID);
    i64 a0 = ld64(sb_notifp() + SB_NF_ARG0);
    i64 a1 = ld64(sb_notifp() + SB_NF_ARG0 + 8);

    if (nr == host_sysno(SN_OPENAT) || nr == host_sysno(SN_OPEN)) {
        // openat(dirfd, path, ...) and open(path, ...) differ by one argument
        i64 pp = a1;
        if (nr == host_sysno(SN_OPEN)) pp = a0;
        uptr path = sb_vm_read(pid, pp);
        if (sb_path_ok(path)) { sb_allow_checked(); return; }
        sb_refuse(tm_cat("open ", xstrdup(path, cstrlen(path))), 0 - E_ACCES);
        return;
    }
    if (nr == host_sysno(SN_MMAP)) {
        set_sb_mmtot(sb_mmtot() + a1);
        if (sb_mmtot() > sb_mem() * 1048576) {
            sb_refuse(tm_cat("mmap ", tm_cat(tm_num_str(a1),
                      tm_cat(" bytes over the cap (",
                      tm_cat(tm_num_str(sb_mem() * 1048576), ")")))), 0 - E_NOMEM);
            return;
        }
        sb_allow();
        return;
    }
    if (nr == host_sysno(SN_MUNMAP)) {
        i64 t = sb_mmtot() - a1;
        if (t < 0) t = 0;
        set_sb_mmtot(t);
        sb_allow();
        return;
    }
    // Every way this kernel has of making a process. `fork` and `vfork` are
    // x86-64's own and are what musl uses; glibc goes through clone on both
    // architectures, and clone3 is what a modern posix_spawn uses. All four
    // count against the same cap, because the cap is about processes and not
    // about which entry point asked for one.
    if (nr == host_sysno(SN_CLONE) || nr == host_sysno(SN_CLONE3)
        || nr == host_sysno(SN_FORK) || nr == host_sysno(SN_VFORK)) {
        // Without --allow=threads neither is in the profile and neither is
        // counted: a fork bomb stops at its FIRST fork, named. With the flag,
        // a real thread never gets here (the filter's own flag test allows
        // it) and what does get here is a new PROCESS, which is what the cap
        // is about.
        if (!sb_threads()) { sb_refuse(sb_callname(nr), 0 - E_PERM); return; }
        set_sb_nclone(sb_nclone() + 1);
        if (sb_nclone() > SB_NPROC_THREADS) {
            sb_refuse(tm_cat("process limit (", tm_cat(tm_num_str(SB_NPROC_THREADS), ")")),
                      0 - E_AGAIN);
            return;
        }
        sb_allow();
        return;
    }
    if (nr == host_sysno(SN_EXECVE)) {
        set_sb_nexec(sb_nexec() + 1);
        if (sb_nexec() > sb_execmax()) { sb_refuse("execve", 0 - E_PERM); return; }
        sb_allow();
        return;
    }
    sb_refuse(sb_callname(nr), 0 - E_PERM);
}

// One notification per readable listener. The descriptor is BLOCKING, so it is
// only ever read when ppoll said there is something on it (§ 4).
void sb_notif_pump() {
    if (sb_lfd() < 0) return;
    i64 rc = sb_notif_recv();
    if (rc < 0) {
        // ENOENT is a target that died between the poll and the read, which is
        // ordinary at the end of a step; anything else means the listener
        // itself is finished.
        if (rc != 0 - E_NOENT) {
            sb_sys(SN_CLOSE, sb_lfd(), 0, 0, 0, 0, 0);
            set_sb_lfd(-1);
        }
        return;
    }
    sb_notif_decide();
}

// host_linux.mc — the Linux half of the host layer (M37), shared by both
// architectures. It carries everything that depends on the OPERATING SYSTEM;
// the two files that include it, src/host_linux_aarch64.mc and
// src/host_linux_x86_64.mc, add the three answers that depend on the
// ARCHITECTURE (host_arch, host_machine, host_include).
//
// See src/host_macos.mc for what a host file is and who includes one.
//
// Every routine below is in musl exactly as it is in libSystem, under the same
// name and with the same signature, so the compiler's own code does not change
// shape between the two hosts -- only these declarations do.

// asm-generic/fcntl.h: NOT the macOS values (0x200 / 0x400 there).
#define O_CREAT 0x40
#define O_TRUNC 0x200

// M45: every one of these returns a C `int` (`waitpid` a `pid_t`, which is an
// `int` too), so bits 63..32 of the result are unspecified. The declarations
// stay `i64` for the reason src/arena.mc gives -- this file is in the seed set
// and a narrow declaration would move its codegen away from the frozen seed's
// -- and src/driver.mc reads `waitpid`, the one that can be negative, through
// c_int(). posix_spawnp's result is an errno compared against 0 and ENOENT,
// which is right on a zero-extended value either way.
extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 posix_spawn_file_actions_init(uptr fa);
extern i64 posix_spawn_file_actions_addopen(uptr fa, i64 fd, uptr path, i64 flags, i64 mode);
extern i64 posix_spawn_file_actions_destroy(uptr fa);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern i64 mkdir(uptr path, i64 mode);
extern i64 unlink(uptr path);

// There is no `_NSGetEnviron` here, and linking against musl's `environ` global
// would need a data relocation to an imported symbol that the ELF writer does
// not emit. The environment arrives the way the C runtime has always passed it:
// musl's crt1.o calls `main(argc, argv, envp)`, so x2 already holds it and
// src/main.mc hands it straight over.
uptr host_envp = 0;

void host_init(uptr envp) { host_envp = envp; }

uptr host_environ() { return host_envp; }

uptr host_os()  { return "linux"; }
uptr host_sys() { return "sys_linux"; }

// `xcrun` is a macOS program: a Linux mc.toml that writes `{sdk}` is an error,
// not a spawn that fails with "cannot run xcrun" (src/driver.mc, drv_sdk).
i64 host_has_sdk() { return 0; }

// M38: what this host appends to the name of an executable it is about to write
// and then run -- nothing here, ".exe" on Windows (src/host_windows.mc).
uptr host_exe_suffix() { return ""; }

// M25: the user's home directory, where the sysroot cache lives
// (`~/.mc/sysroots/<os>-<arch>`, docs/reference/sysroot.md). Same shape as the
// macOS host: there is no `getenv` here either, only the `KEY=VALUE` array
// musl's crt1.o passed to main().
uptr host_home() {
    uptr e = host_environ();
    if (e == 0) return 0;
    i64 i = 0;
    loop {
        uptr s = ld64(e + i * 8);
        if (s == 0) return 0;
        if (mem_eq(s, "HOME=", 5)) return s + 5;
        i = i + 1;
    }
}

// M25: the downloader `mc sysroot fetch` spawns, and its fallback. A
// distribution ships one of the two; the CI runners have both.
uptr host_downloader()     { return "curl"; }
uptr host_downloader_alt() { return "wget"; }

// M43: the raw system-call shim. Every system call the sandbox issues goes
// through here, because `prctl`, `syscall` and `clone` are VARIADIC in musl and
// this project refuses a variadic extern (M5.6), and because `seccomp`,
// `landlock_*`, `pidfd_*` and `close_range` have no musl wrapper at all. The
// implementation is `sys6` in the architecture file this host includes
// (src/sysno_linux_aarch64.mc / src/sysno_linux_x86_64.mc), which also carries
// the number table host_sysno() reads. The result is the kernel's own: -errno
// on failure, exactly as lib/sys_linux.mc documents.
i64 host_syscall6(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
    return sys6(n, a, b, c, d, e, f);
}

// 1 when `mc sandbox run|exec|check` can do anything at all on this host. It is
// not "the box will work" -- that is what `mc sandbox check` measures against
// the running kernel -- only "this operating system is the one the sandbox was
// written for". macOS and Windows answer 0 and print the command to run instead.
i64 host_sandbox_supported() { return 1; }

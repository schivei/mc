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

// host_macos.mc — the macOS host layer (M37, docs/guide/90-linux-host.md).
//
// Everything the COMPILER needs from the operating system it is RUNNING ON, and
// nothing else. `src/core.mc` is host-neutral: it is this file (or its Linux
// sibling) that says how to spawn a tool, where the environment lives, what the
// O_* flags of this kernel are, and which (os, arch) pair the binary is itself.
//
// One host file is included by every compiler entry point, BEFORE the core:
//
//   src/mc.mc              host_macos.mc          + core.mc + user.mc
//   src/mc_linux.mc        host_linux_aarch64.mc  + core.mc + user.mc
//   src/mc_linux_x86_64.mc host_linux_x86_64.mc   + core.mc + user.mc
//
// A taught compiler gets the same thing from the bundle: `mc build` writes
// `#include <mc/host>` above `#include <mc/core>`, and `<mc/host>` is the host
// file of the compiler that is running (src/main.mc, host_bundle_open).
//
// Only the compiler needs a host file. src/arena.mc, src/lex.mc and every tool
// built on them (tools/bundle.mc, src/lexdump.mc, src/tomldump.mc,
// site/gen/main.mc) are portable as they stand: open/read/write/close/creat/
// _exit/mmap exist under the same names in libSystem and in musl, and the one
// value that differed -- the anonymous-mapping flag -- is written as a single
// number valid on both kernels (see src/arena.mc).

// macOS values (sys/fcntl.h). O_RDONLY and O_WRONLY are 0 and 1 everywhere and
// stay in arena.mc; these two are the ones that differ from Linux (0x40/0x200).
#define O_CREAT 0x200
#define O_TRUNC 0x400

// libSystem, for spawning tools. There is no equivalent in lib/sys_svc.mc: the
// syscall path exists to prove the core does not need libc for I/O, and
// posix_spawn is not a syscall -- it is a libSystem routine over
// __posix_spawn(2) with a struct layout this language cannot lay out. See
// docs/build.md, section "Spawning tools".
extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 posix_spawn_file_actions_init(uptr fa);
extern i64 posix_spawn_file_actions_addopen(uptr fa, i64 fd, uptr path, i64 flags, i64 mode);
extern i64 posix_spawn_file_actions_destroy(uptr fa);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern i64 mkdir(uptr path, i64 mode);
extern i64 unlink(uptr path);

// On macOS the environment is not a global a program may link against: dyld
// keeps it and `_NSGetEnviron()` returns the address of the pointer to it.
extern uptr _NSGetEnviron();

// main() hands its third argument here at startup. macOS passes envp too, but
// libSystem's own copy is the one dyld keeps up to date, so this host ignores
// it; the Linux host has no other source and keeps it.
void host_init(uptr envp) { }

uptr host_environ() { return ld64(_NSGetEnviron()); }

uptr host_os()   { return "macos"; }
uptr host_arch() { return "aarch64"; }

// the machine the walker drives for this host, by the name src/hooks.mc knows
// it under (`machine("arm64", ...)`); the dump modes need one before any
// backend has been chosen
uptr host_machine() { return "arm64"; }

// the bundled system layer a program on this host includes for its I/O:
// `#include <sys>` here, `#include <sys_linux>` on Linux
uptr host_sys() { return "sys"; }

// the bundle name `<mc/host>` resolves to when this compiler writes a taught
// compiler's source
uptr host_include() { return "mc/host_macos"; }

// 1 when `xcrun --show-sdk-path` exists, which is what the `{sdk}` placeholder
// of [linker].args runs (src/driver.mc)
i64 host_has_sdk() { return 1; }

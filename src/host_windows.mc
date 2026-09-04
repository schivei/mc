// host_windows.mc — the Windows half of the host layer (M38), shared by both
// architectures. It carries everything that depends on the OPERATING SYSTEM;
// the two files that include it, src/host_windows_aarch64.mc and
// src/host_windows_x86_64.mc, add the three answers that depend on the
// ARCHITECTURE (host_arch, host_machine, host_include).
//
// See src/host_macos.mc for what a host file is and who includes one.
//
// The difference from src/host_linux.mc is where the routines below COME FROM.
// On Linux every one of them is in musl under the same name; on Windows none of
// them exists at all -- the documented boundary is kernel32.dll, which has no
// POSIX interface. So they are shims, written in mc over kernel32 and compiled
// once into build/mcrt-windows-<arch>.obj (lib/sys_windows_host.mc), linked next
// to the compiler by scripts/link-windows.sh. This file only DECLARES them, and
// its declarations are the same ones the macOS and Linux hosts make, because the
// compiler's own code must not change shape between hosts.

// The values lib/sys_windows.mc publishes (M19). They are not a kernel's
// numbers -- Windows takes the disposition as a separate argument to
// CreateFileA -- but they are part of the interface every system layer of this
// project publishes, and a program that writes O_CREAT | O_TRUNC has to get a
// value from somewhere.
#define O_CREAT 0x100
#define O_TRUNC 0x200

// Resolved from build/mcrt-windows-<arch>.obj, not from a libc.
extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 posix_spawn_file_actions_init(uptr fa);
extern i64 posix_spawn_file_actions_addopen(uptr fa, i64 fd, uptr path, i64 flags, i64 mode);
extern i64 posix_spawn_file_actions_destroy(uptr fa);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern i64 mkdir(uptr path, i64 mode);
extern i64 unlink(uptr path);

// The entry point (lib/sys_windows_start.mc) has no envp to pass -- Windows has
// no third argument to main -- and hands over 0. Nothing reads it: the child of
// a spawn inherits this process's environment when CreateProcessA is given a
// null lpEnvironment, which is what host_environ() returning 0 means here
// (Decision 5).
void host_init(uptr envp) { }

uptr host_environ() { return 0; }

uptr host_os()  { return "windows"; }

// the bundled system layer a program on this host includes for its I/O
uptr host_sys() { return "sys_windows"; }

// `xcrun` is a macOS program: a Windows mc.toml that writes `{sdk}` is a config
// error, not a spawn that fails halfway through a build (src/driver.mc, drv_sdk).
i64 host_has_sdk() { return 0; }

// M38: what this host appends to the name of an executable it is about to
// write and then run. `mc build` is the one caller -- [compiler].out names a
// taught compiler that the driver links and immediately spawns, and on Windows
// a file without the suffix is not a program (src/driver.mc, drv_teach).
uptr host_exe_suffix() { return ".exe"; }

// M25: the user's home directory, where the sysroot cache lives
// (`~/.mc/sysroots/<os>-<arch>`, docs/reference/sysroot.md). This host cannot
// do what the other two do -- host_environ() is 0 here (Decision 5 of M38), so
// there is no array to walk -- and asks kernel32 for USERPROFILE instead. The
// name has to be in scripts/sysroot-windows.sh's kernel32.def, like every other
// import this layer declares.
extern i64 GetEnvironmentVariableA(uptr name, uptr buf, i64 size);

u8 hw_home[512];

uptr host_home() {
    i64 n = GetEnvironmentVariableA("USERPROFILE", hw_home, 512);
    if (n <= 0) return 0;                 // absent, or the buffer is too small
    if (n >= 512) return 0;
    return hw_home;
}

// M25: `curl.exe` ships in System32 since Windows 10 1803 and is on PATH under
// Git Bash. There is no second one to try.
uptr host_downloader()     { return "curl.exe"; }
uptr host_downloader_alt() { return 0; }

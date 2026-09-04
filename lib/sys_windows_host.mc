// sys_windows_host.mc — the POSIX-shaped shims the COMPILER's own `extern`s
// need, over kernel32 (M38, docs/guide/95-windows-host.md).
//
// It is lib/sys_windows.mc's second half, and a file of its own for the reason
// Decision 2 gives: lib/sys_windows.mc is the SYSTEM LAYER a Windows program
// includes for its I/O, and is compiled into `winrt.obj` next to every test.
// What is here is not part of that interface -- `posix_spawnp`, `waitpid`,
// `mmap`, `mkdir`, `unlink`, `chmod`, `_exit` -- it is the set of names
// src/arena.mc, src/backend_exe.mc and src/host_windows.mc declare `extern` and
// that a Windows host has to resolve at link time. Fifteen symbols in all,
// counting the six this file inherits by including lib/sys_windows.mc.
//
// The compiler cannot define them itself: src/arena.mc declares `open`, `read`,
// `write`, `close`, `_exit`, `creat` and `mmap` extern and `func_add` refuses a
// second definition (`function declared twice`). So they come from an ordinary
// object linked NEXT TO the compiler, exactly as `winrt.obj` is linked next to
// every test:
//
//   mc build src --config src/mc.windows-aarch64-obj.toml   -> mc-windows-arm64.obj
//   mc lib/sys_windows_host.mc                              -> mcrt-windows-aarch64.obj
//   lld-link -machine:arm64 -subsystem:console -entry:mc_start -nodefaultlib \
//            -out:mc.exe mc-windows-arm64.obj winstart.obj \
//            mcrt-windows-aarch64.obj kernel32.lib
//
// (scripts/link-windows.sh writes that line.) It is architecture-neutral: not
// one instruction is written by hand, the whole file is ordinary mc code over
// kernel32 `extern`s, and the same source is compiled once per architecture.
//
// What it deliberately does NOT do: no wide-character paths (the *A entry
// points and the ANSI code page), no child stdout capture (§ 5 of the spec: the
// only child whose stdout `mc` reads is `xcrun`, which does not exist here), no
// signals (Windows has none, which is what makes the exit status below exact).

#include "sys_windows.mc"

// ---- kernel32, the second set ----
extern i64  CreateProcessA(uptr appname, uptr cmdline, uptr procattr, uptr thrattr,
                           i64 inherit, i64 flags, uptr env, uptr cwd,
                           uptr si, uptr pi);
extern i64  WaitForSingleObject(uptr h, i64 ms);
extern i64  GetExitCodeProcess(uptr h, uptr code);
extern i64  CreateDirectoryA(uptr path, uptr sa);
extern i64  DeleteFileA(uptr path);
extern uptr VirtualAlloc(uptr addr, i64 size, i64 type, i64 protect);

#define INFINITE       0xffffffff
#define WAIT_OBJECT_0  0
#define MEM_COMMIT     0x1000
#define MEM_RESERVE    0x2000
#define PAGE_READWRITE 0x04
#define BSLASH         92                 // there is no \\ escape worth reading here

// ---- STARTUPINFOA and PROCESS_INFORMATION, laid out by hand ----
// This language has no struct, and that is on purpose (docs/plan.md): a record
// the OPERATING SYSTEM defines is a byte layout, and writing it as offsets into
// a u8 array is the same shape every file format in this compiler is written
// with. The offsets below are the x64 and ARM64 layouts, which are identical --
// every field is naturally aligned and every pointer is eight bytes.
//
//   STARTUPINFOA: cb 0, lpReserved 8, lpDesktop 16, lpTitle 24, dwX 32, dwY 36,
//   dwXSize 40, dwYSize 44, dwXCountChars 48, dwYCountChars 52,
//   dwFillAttribute 56, dwFlags 60, wShowWindow 64, cbReserved2 66,
//   lpReserved2 72, hStdInput 80, hStdOutput 88, hStdError 96  -> 104 bytes
//
//   PROCESS_INFORMATION: hProcess 0, hThread 8, dwProcessId 16, dwThreadId 20
//   -> 24 bytes
//
// Only `cb` is set: dwFlags stays 0, so the child inherits this process's
// console and its three standard handles, which is what makes a spawned
// `lld-link`'s diagnostics reach the user unchanged (src/driver.mc, drv_spawn).
#define SI_CB       0
#define SI_SIZE     104
#define PI_HPROCESS 0
#define PI_HTHREAD  8
#define PI_SIZE     24

#define WH_CMDMAX 8192                    // the command line handed to CreateProcessA

u8 wh_si[SI_SIZE];
u8 wh_pi[PI_SIZE];
u8 wh_cmd[WH_CMDMAX];
u8 wh_code[8];                            // the DWORD out-parameter of GetExitCodeProcess

i64 wh_o    = 0;                          // how much of wh_cmd is written
i64 wh_over = 0;                          // 1 once the ceiling was reached

void wh_zero(uptr p, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(p + i, 0);
        i = i + 1;
    }
}

// One byte of the command line. Truncating it silently would run the WRONG
// command, so the overflow is remembered and posix_spawnp fails with -1, which
// src/driver.mc reports as `cannot run <tool>`.
void wh_byte(i64 c) {
    if (wh_o >= WH_CMDMAX - 1) { wh_over = 1; return; }
    st8(wh_cmd + wh_o, c);
    wh_o = wh_o + 1;
}

void wh_bslash(i64 n) {
    i64 k = 0;
    loop {
        if (k >= n) break;
        wh_byte(BSLASH);
        k = k + 1;
    }
}

// ---- MSVCRT quoting ----
// Windows has no argument vector: a process receives ONE string and splits it
// itself. There is no single official rule, but every C runtime and every
// linker built with one -- lld-link included -- uses the MSVCRT convention, so
// that is the one written here:
//
//   * an argument with a space, a tab, a quote, or no characters at all is
//     wrapped in double quotes;
//   * a run of N backslashes before a quote becomes 2N+1 backslashes and \";
//   * a run of N backslashes at the end of a QUOTED argument becomes 2N, so the
//     closing quote is not escaped by the last one;
//   * a backslash anywhere else is itself.
//
// A path like C:/x/y needs none of it (this compiler's paths are `/`-only,
// docs/guide/95-windows-host.md § Paths), which is why the common case comes
// out as the plain text it went in as.
i64 wh_need_quote(uptr s) {
    if (ld8(s) == 0) return 1;
    i64 i = 0;
    loop {
        i64 c = ld8(s + i);
        if (c == 0) break;
        if (c == ' ' || c == 9 || c == '"') return 1;
        i = i + 1;
    }
    return 0;
}

void wh_arg(uptr s) {
    i64 q = wh_need_quote(s);
    if (q) wh_byte('"');
    i64 i = 0;
    loop {
        i64 nb = 0;
        loop {
            if (ld8(s + i) != BSLASH) break;
            nb = nb + 1;
            i = i + 1;
        }
        i64 c = ld8(s + i);
        if (c == 0) {
            if (q) wh_bslash(nb * 2); else wh_bslash(nb);
            break;
        }
        if (c == '"') {
            wh_bslash(nb * 2 + 1);
            wh_byte('"');
        } else {
            wh_bslash(nb);
            wh_byte(c);
        }
        i = i + 1;
    }
    if (q) wh_byte('"');
}

// ---- the shims ----
// `file` is ignored on purpose: CreateProcessA with lpApplicationName = 0 takes
// the program from the command line and searches PATH for it, appending `.exe`
// by itself -- which is exactly what posix_spawnp's PATH search does, and what
// makes `cmd = "lld-link"` in an mc.toml work with no suffix written anywhere.
// `envp` goes straight through: 0 (what src/host_windows.mc's host_environ
// returns) means "inherit this process's environment".
i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp) {
    wh_o = 0;
    wh_over = 0;
    i64 i = 0;
    loop {
        uptr a = ld64(av + i * 8);
        if (a == 0) break;
        if (i) wh_byte(' ');
        wh_arg(a);
        i = i + 1;
    }
    st8(wh_cmd + wh_o, 0);
    if (wh_over) return 0 - 1;
    wh_zero(wh_si, SI_SIZE);
    wh_zero(wh_pi, PI_SIZE);
    st32(wh_si + SI_CB, SI_SIZE);
    if ((CreateProcessA(0, wh_cmd, 0, 0, 1, 0, envp, 0, wh_si, wh_pi) & BOOL_MASK) == 0)
        return 0 - 1;
    st64(pid, ld64(wh_pi + PI_HPROCESS));
    CloseHandle(ld64(wh_pi + PI_HTHREAD));
    return 0;
}

// `pid` is the process HANDLE posix_spawnp stored above -- Windows has process
// ids too, but a handle is what one waits on. The status is written in the shape
// src/driver.mc reads: it takes the code from bits 8..15 and treats the low
// seven as a signal number. Windows has no signals, so those seven stay 0 and
// `(code & 255) << 8` is exact; the mask is what keeps a DWORD exit code such as
// 0x100 from arriving as 0.
i64 waitpid(i64 pid, uptr status, i64 options) {
    if ((WaitForSingleObject(pid, INFINITE) & BOOL_MASK) != WAIT_OBJECT_0) return 0 - 1;
    st64(wh_code, 0);
    if ((GetExitCodeProcess(pid, wh_code) & BOOL_MASK) == 0) {
        CloseHandle(pid);
        return 0 - 1;
    }
    i64 code = ld32(wh_code);
    CloseHandle(pid);
    st64(status, (code & 255) << 8);
    return pid;
}

// The three file actions exist for ONE caller, drv_sdk, and it never reaches
// them here: `mc` asks host_has_sdk() first, and src/host_windows.mc answers 0,
// which turns `{sdk}` in an mc.toml into a config error (src/driver.mc). They
// are declared by the host layer, so they have to link; -1 is what a caller that
// found a way here would see.
i64 posix_spawn_file_actions_init(uptr fa) { return 0 - 1; }
i64 posix_spawn_file_actions_addopen(uptr fa, i64 fd, uptr path, i64 flags, i64 mode) { return 0 - 1; }
i64 posix_spawn_file_actions_destroy(uptr fa) { return 0 - 1; }

// src/arena.mc grows the arena by mapping one more chunk; VirtualAlloc is the
// call that does that here. `addr`, `prot`, `flags`, `fd` and `off` are ignored
// -- the arena only ever asks for an anonymous read/write mapping at any address
// -- and arena_map already rounds the size up to 64 KiB, which is exactly
// VirtualAlloc's allocation granularity, and already treats both 0 and -1 as a
// refusal. src/arena.mc itself does not change (Decision 3).
uptr mmap(uptr addr, i64 len, i64 prot, i64 flags, i64 fd, i64 off) {
    return VirtualAlloc(0, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
}

// NTFS has no mode bits and there is no execute permission to grant: an .exe is
// executable because of its name and its PE header. src/backend_exe.mc is the
// only caller and it is the Mach-O direct-executable backend, which a Windows
// host never selects -- but the symbol still has to link (Decision 10).
i64 chmod(uptr path, i64 mode) { return 0; }

i64 mkdir(uptr path, i64 mode) {
    if ((CreateDirectoryA(path, 0) & BOOL_MASK) == 0) return 0 - 1;
    return 0;
}

i64 unlink(uptr path) {
    if ((DeleteFileA(path) & BOOL_MASK) == 0) return 0 - 1;
    return 0;
}

void _exit(i64 code) { ExitProcess(code); }

// sys_windows.mc — the same interface as sys.mc, on Windows on ARM and with no
// C runtime at all: every call is a kernel32 entry point. It is lib/sys_svc.mc's
// and lib/sys_linux.mc's sibling — same five functions, another system
// (M19, docs/build.md § Windows targets).
//
// Unlike the other two there is no syscall instruction here: Windows has no
// stable system-call numbers, and the documented boundary is kernel32.dll. So
// this file is ordinary mc code over eight `extern`s, and the link needs an
// import library (`kernel32.lib`, built by scripts/sysroot-windows.sh with
// `llvm-dlltool`).
//
// Link with:
//
//   lld-link /machine:arm64 /subsystem:console /entry:mc_start /nodefaultlib \
//            /out:prog.exe prog.obj <sysroot>/kernel32.lib
//
// `mc_start` is the entry point this file provides, so a program needs no crt
// object of any kind.
//
// It does NOT include io.mc, and that is the one place where it differs from
// lib/sys_linux.mc. On Linux the wrappers come out of libc.a, an archive the
// linker takes members from; here they come out of an ordinary object that is
// linked NEXT TO the program (scripts/test-windows.sh builds it once as
// winrt.obj), and an object carries everything it holds. If this file also
// carried strlen/puts/putnum, every program that already has them -- anything
// that includes lib/sys.mc, which ends in io.mc -- would fail the link with a
// duplicate symbol. A program that includes this file directly and wants those
// utilities adds `#include <io>` after it, and then links alone.
//
// Handles, not descriptors: `open`/`creat` hand back the HANDLE CreateFileA
// returned and `read`/`write`/`close` take it back unchanged. The three standard
// descriptors keep their Unix numbers -- 0, 1 and 2 are translated through
// GetStdHandle -- which is safe because a real Windows handle is never one of
// those three values.

// ---- kernel32 ----
// All non-variadic. A DWORD parameter travels in the low half of its register,
// which is what AAPCS64 does with a 32-bit argument anyway, so an i64 is the
// right shape for every one of them.
extern uptr GetStdHandle(i64 nStdHandle);
extern i64 WriteFile(uptr hFile, uptr buf, i64 n, uptr written, uptr overlapped);
extern i64 ReadFile(uptr hFile, uptr buf, i64 n, uptr got, uptr overlapped);
extern uptr CreateFileA(uptr name, i64 access, i64 share, uptr sa,
                        i64 disposition, i64 flags, uptr template);
extern i64 CloseHandle(uptr h);
extern void ExitProcess(i64 code);
extern uptr GetCommandLineA();

#define STD_INPUT_HANDLE  0 - 10
#define STD_OUTPUT_HANDLE 0 - 11
#define STD_ERROR_HANDLE  0 - 12

#define GENERIC_READ          0x80000000
#define GENERIC_WRITE         0x40000000
#define FILE_SHARE_READ       1
#define CREATE_ALWAYS         2
#define OPEN_EXISTING         3
#define FILE_ATTRIBUTE_NORMAL 0x80
#define INVALID_HANDLE        0 - 1

// The flags an mc program passes to open(); Windows does not take them (the
// disposition is a separate argument), but they exist because they are part of
// the interface every system layer publishes -- and their values, like the Linux
// and macOS ones, belong to the system and not to lib/io.mc.
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT  0x100
#define O_TRUNC  0x200

// A BOOL is 32 bits and the high half of the register comes back unspecified,
// so it is masked before it is compared.
#define BOOL_MASK 0xffffffff

u8 win_nio[8];                        // the DWORD out-parameter of Read/WriteFile

uptr win_handle(i64 fd) {
    if (fd == 0) return GetStdHandle(STD_INPUT_HANDLE);
    if (fd == 1) return GetStdHandle(STD_OUTPUT_HANDLE);
    if (fd == 2) return GetStdHandle(STD_ERROR_HANDLE);
    return fd;
}

i64 write(i64 fd, uptr buf, i64 n) {
    st64(win_nio, 0);
    if ((WriteFile(win_handle(fd), buf, n, win_nio, 0) & BOOL_MASK) == 0) return 0 - 1;
    return ld32(win_nio);
}

i64 read(i64 fd, uptr buf, i64 n) {
    st64(win_nio, 0);
    if ((ReadFile(win_handle(fd), buf, n, win_nio, 0) & BOOL_MASK) == 0) return 0 - 1;
    return ld32(win_nio);
}

// The flags are ignored: this open is the read-only one lib/io.mc's users ask
// for, and `creat` below is the writing half, exactly as on macOS -- where open
// is variadic and creat is the one the core can call.
i64 open(uptr path, i64 flags, i64 mode) {
    uptr h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE) return 0 - 1;
    return h;
}

i64 creat(uptr path, i64 mode) {
    uptr h = CreateFileA(path, GENERIC_WRITE, 0, 0, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE) return 0 - 1;
    return h;
}

// 0, 1 and 2 are the standard descriptors, not handles: closing them would
// close the console the program is writing to.
i64 close(i64 fd) {
    if (fd >= 0 && fd <= 2) return 0;
    if ((CloseHandle(fd) & BOOL_MASK) == 0) return 0 - 1;
    return 0;
}

void exit(i64 code) {
    ExitProcess(code);
}

// ---- entry point ----
// The loader enters mc_start with no arguments: on Windows the command line is
// one string the program asks for and splits itself. `win_split` is the
// minimum that behaves like a shell for the cases a test needs -- runs of
// spaces or tabs separate arguments, and a double quote toggles a region in
// which they do not. It copies into win_cmd rather than writing through the
// pointer kernel32 handed back, which belongs to the process parameters.
#define WIN_MAXARG 32
#define WIN_CMDMAX 2048

u8 win_cmd[WIN_CMDMAX];
u8 win_args[WIN_MAXARG * 8 + 8];

i64 win_split(uptr cl) {
    i64 n = 0;
    i64 i = 0;
    i64 o = 0;
    loop {
        loop {
            i64 c = ld8(cl + i);
            if (c != ' ' && c != 9) break;
            i = i + 1;
        }
        if (ld8(cl + i) == 0) break;
        if (n >= WIN_MAXARG) break;
        st64(win_args + n * 8, win_cmd + o);
        n = n + 1;
        i64 q = 0;
        loop {
            i64 c = ld8(cl + i);
            if (c == 0) break;
            if (c == '"') {
                q = 1 - q;
                i = i + 1;
                continue;
            }
            if (q == 0 && (c == ' ' || c == 9)) break;
            if (o < WIN_CMDMAX - 1) {
                st8(win_cmd + o, c);
                o = o + 1;
            }
            i = i + 1;
        }
        if (o < WIN_CMDMAX) {
            st8(win_cmd + o, 0);
            o = o + 1;
        }
    }
    st64(win_args + n * 8, 0);
    return n;
}

// `main` is called through a raw `bl`, the way lib/sys_linux.mc calls it, and
// not through an `extern` declaration: a program that includes this file
// defines `main` itself, and a file cannot both declare a function extern and
// define it. The two parameters are already in x0 and x1 when the body starts
// -- the prologue does not touch them (docs/reference/objects.md § 4) -- and the
// epilogue does not touch x0, so the result comes straight back.
i64 win_call_main(i64 argc, uptr argv) {
    reloc(BRANCH26, "_main");
    emit(0x94000000);                 // bl main
}

i64 mc_start() {
    i64 argc = win_split(GetCommandLineA());
    ExitProcess(win_call_main(argc, win_args));
}

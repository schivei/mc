// sys_windows_start.mc — the Windows entry point, on its own and architecture-
// neutral (M20, docs/specs/M20.md).
//
// It is a file of its own for one reason: `main`. lib/sys_windows.mc is included
// INTO a program that defines `main` (tests/windows/070-kernel32.mc is the
// case), and a file cannot both declare a function `extern` and define it. M19
// worked around that by calling main through a raw word --
// `reloc(BRANCH26, "_main"); emit(0x94000000);` -- which is an AArch64 `bl` and
// a Mach-O relocation kind, the only architecture-specific line in the layer.
//
// It cannot simply be re-encoded for x86-64: `emit()` writes exactly four bytes,
// a pending `reloc()` is pinned to the START of that word, and `gen_word` only
// accepts the four Mach-O kinds. An x86 `call rel32` is five bytes with its
// field one byte in. So the raw words are DELETED rather than doubled: this file
// is not included by anything, it is compiled on its own into `winstart.obj` and
// linked next to every Windows program, and from here `main` is an ordinary
// `extern` reached through the ordinary MTASK_CALL path -- BRANCH26 on arm64,
// R_X86_PLT32 -> IMAGE_REL_AMD64_REL32 on x64, both already correct.
//
// `lld-link -entry:mc_start` calls the entry point normally, so rsp is 8 mod 16
// at its first instruction (arm64: sp 16-aligned, lr set) -- the same invariant
// every mc function is compiled against. The entry receives no arguments, which
// is why the command line is fetched from kernel32 rather than read off the
// stack: win_setup() does the GetCommandLineA + split and returns argc, and
// win_argv() hands back the vector it filled (lib/sys_windows.mc).
//
// Link with:
//
//   lld-link -machine:<arm64|x64> -subsystem:console -entry:mc_start \
//            -nodefaultlib -out:prog.exe prog.obj [winrt.obj] winstart.obj \
//            <sysroot>/kernel32.lib

extern i64  main(i64 argc, uptr argv);
extern i64  win_setup();
extern uptr win_argv();
extern void ExitProcess(i64 code);

i64 mc_start() {
    i64 argc = win_setup();
    ExitProcess(main(argc, win_argv()));
}

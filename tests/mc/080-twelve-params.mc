// 080-twelve-params.mc — M38: parameters 9..12 travel on the STACK.
//
// MAXPARAMS went from 8 to 12 in src/ so that a Windows-hosted compiler can
// declare CreateProcessA, which takes ten (docs/specs/M38.md § 1). The frozen C
// seed keeps 8, which is why this test lives in tests/mc/ and not in tests/:
// build/mc0 refuses it with `at most 8 parameters`, and the four cross-checks
// that compare mc0 against mc1 over tests/*.mc would report that as a failure.
//
// It is portable to every target the project has: the only thing outside the
// language is `write`, and this file does not even use it. It runs on macOS
// (scripts/check-mc.sh, both through .o + ld and through --exe), on
// linux/aarch64 and linux/x86_64 (scripts/test-linux.sh) and on windows/arm64
// and windows/x86_64 (scripts/test-windows.sh) -- five ABIs, three machines,
// three ways of putting an argument past the register table on the stack.
//
// Note on depths: gen_walk lowers argument i at depth d+i, and only depths 0..6
// live in registers on arm64 (0..3 on x86-64), so arguments 8 and up are ALWAYS
// read out of a spill slot here. The register path and the spilled path are both
// exercised by every call below.
// expect-exit: 42

// the plain case: twelve parameters, all of them added up
i64 sum12(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f,
          i64 g, i64 h, i64 i, i64 j, i64 k, i64 l) {
    return a + b + c + d + e + f + g + h + i + j + k + l;
}

// the same twelve, but only the four that came off the stack, each weighted, so
// a swapped pair or an off-by-one offset cannot pass
i64 pick12(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f,
           i64 g, i64 h, i64 i, i64 j, i64 k, i64 l) {
    return i * 1000 + j * 100 + k * 10 + l;
}

// eleven, for callp: the pointer counts towards the twelve
i64 sum11(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f,
          i64 g, i64 h, i64 i, i64 j, i64 k) {
    return a + b + c + d + e + f + g + h + i + j + k;
}

i64 pick11(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f,
           i64 g, i64 h, i64 i, i64 j, i64 k) {
    return i * 100 + j * 10 + k;
}

// ten, called with two CALLS in the stack positions: the argument values are all
// lowered before the outgoing area is written, so an inner call cannot step on
// the outer one's stack arguments
i64 sum10(i64 a, i64 b, i64 c, i64 d, i64 e,
          i64 f, i64 g, i64 h, i64 i, i64 j) {
    return a + b + c + d + e + f + g + h + i + j;
}

// the narrow types on the stack path: the caller stores eight bytes and the
// CALLEE truncates when it puts the parameter in its slot, exactly as it does
// for a register parameter
i64 wide12(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h,
           u8 i, u16 j, u32 k, i64 l) {
    return i + j + k + l;
}

i64 id(i64 x) { return x; }
i64 twice(i64 x) { return x + x; }

i64 main() {
    i64 bad = 0;
    if (sum12(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) != 78)      bad = bad + 1;
    if (pick12(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) != 10122)  bad = bad + 2;
    if (callp(&sum11, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11) != 66)  bad = bad + 4;
    if (callp(&pick11, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11) != 1011) bad = bad + 8;
    if (sum10(1, 2, 3, 4, 5, 6, 7, 8, id(9), twice(5)) != 55)    bad = bad + 16;
    // 300 & 255 = 44, 70000 & 0xffff = 4464, 4294967303 & 0xffffffff = 7
    if (wide12(1, 2, 3, 4, 5, 6, 7, 8, 300, 70000, 4294967303, 12) != 4527) bad = bad + 32;
    // a nested call in a stack position, inside another call's arguments
    if (sum12(1, 2, 3, 4, 5, 6, 7, 8, sum10(1, 1, 1, 1, 1, 1, 1, 1, 1, 0), 10, 11, 12) != 78)
        bad = bad + 64;
    if (bad != 0) return bad;
    return 42;
}

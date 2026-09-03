// rt.mc — minimal runtime for the examples/api programs: static arena, string
// utilities, an output buffer (strbuf) and integer <-> text conversion.
//
// Written using only the language's core plus lib/prelude.mc (`while`, `for`,
// `++`, `+=`). Nothing here depends on M12's hooks: it is program code, not
// compiler code.
//
// The arena is FIXED: RT_HEAP_SIZE bytes reserved in __bss and a pointer that
// only moves forward. There is no rt_free — a program that allocates in an
// infinite loop overruns the arena and dies in rt_panic. The real heap is
// M13's business.
//
//   #include "lib/rt.mc"

#include "../../../lib/prelude.mc"
#include "../../../lib/sys.mc"

#define RT_HEAP_SIZE 4194304          // 4 MiB
#define RT_ALIGN 16                   // every block comes out aligned to 16

u8  rt_heap[RT_HEAP_SIZE];
i64 rt_hp = 0;

// ---- arena ----

// aborts the program with a message to stderr; no recovery
void rt_panic(uptr msg) {
    write(2, "rt: ", 4);
    write(2, msg, str_len(msg));
    write(2, "\n", 1);
    exit(70);
}

// returns `n` zeroed bytes aligned to 16; never returns 0
uptr rt_alloc(i64 n) {
    if (n < 0) rt_panic("rt_alloc: negative size");
    i64 sz = (n + (RT_ALIGN - 1)) & ~(RT_ALIGN - 1);
    if (sz == 0) sz = RT_ALIGN;
    if (rt_hp + sz > RT_HEAP_SIZE) rt_panic("rt_alloc: arena full");
    uptr p = rt_heap + rt_hp;
    rt_hp = rt_hp + sz;
    mem_zero(p, sz);
    return p;
}

// bytes already handed out by the arena (useful for tests and diagnostics)
i64 rt_used() { return rt_hp; }

// ---- memory ----

void mem_copy(uptr d, uptr s, i64 n) {
    i64 i = 0;
    while (i < n) {
        st8(d + i, ld8(s + i));
        i++;
    }
}

void mem_zero(uptr p, i64 n) {
    i64 i = 0;
    while (i < n) {
        st8(p + i, 0);
        i++;
    }
}

// ---- NUL-terminated strings ----

i64 str_len(uptr s) {
    i64 n = 0;
    while (ld8(s + n) != 0) {
        n++;
    }
    return n;
}

// compares up to `n` bytes; 0 if equal, otherwise the difference of the first differing byte
i64 str_ncmp(uptr a, uptr b, i64 n) {
    i64 i = 0;
    while (i < n) {
        i64 ca = ld8(a + i);
        i64 cb = ld8(b + i);
        if (ca != cb) return ca - cb;
        if (ca == 0) return 0;
        i++;
    }
    return 0;
}

// 1 if the two strings are identical, 0 otherwise
i64 str_eq(uptr a, uptr b) {
    i64 i = 0;
    i64 ca = 0;
    i64 cb = 0;
    loop {
        ca = ld8(a + i);
        cb = ld8(b + i);
        if (ca != cb) break;
        if (ca == 0) return 1;
        i++;
    }
    return 0;
}

// index of the first occurrence of `n` in `h`, or -1; an empty needle matches at 0
i64 str_find(uptr h, uptr n) {
    i64 ln = str_len(n);
    i64 lh = str_len(h);
    if (ln == 0) return 0;
    i64 i = 0;
    while (i + ln <= lh) {
        if (str_ncmp(h + i, n, ln) == 0) return i;
        i++;
    }
    return 0 - 1;
}

// copies `s` with the NUL to `d`; returns the length without the NUL
i64 str_cpy(uptr d, uptr s) {
    i64 n = str_len(s);
    mem_copy(d, s, n + 1);
    return n;
}

// copies `s` into the arena
uptr str_dup(uptr s) {
    return str_ndup(s, str_len(s));
}

// copies the first `n` bytes of `s` into the arena and closes with a NUL
uptr str_ndup(uptr s, i64 n) {
    uptr p = rt_alloc(n + 1);
    mem_copy(p, s, n);
    st8(p + n, 0);
    return p;
}

// ---- integer <-> text ----

// writes `v` in decimal (signed) and NUL-terminated into `buf`; returns the length.
// `buf` needs 21 bytes. i64's minimum is not representable via negation and is not
// handled: no value in this example reaches it.
i64 itoa(i64 v, uptr buf) {
    u8 tmp[24];
    i64 neg = 0;
    i64 i = 24;
    if (v < 0) {
        neg = 1;
        v = 0 - v;
    }
    loop {
        i--;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    i64 n = 0;
    if (neg) {
        st8(buf, '-');
        n = 1;
    }
    while (i < 24) {
        st8(buf + n, ld8(tmp + i));
        n++;
        i++;
    }
    st8(buf + n, 0);
    return n;
}

// reads a signed decimal from the start of `s`; stops at the first non-digit byte
i64 atoi(uptr s) {
    i64 i = 0;
    i64 sig = 1;
    i64 v = 0;
    if (ld8(s) == '-') {
        sig = 0 - 1;
        i = 1;
    }
    while (ld8(s + i) >= '0' && ld8(s + i) <= '9') {
        v = v * 10 + (ld8(s + i) - '0');
        i++;
    }
    return v * sig;
}

// ---- strbuf: text buffer that grows in the arena ----
// Flat 24-byte structure, in the project's mandatory style: offset #define
// plus accessors. The buffer always reserves one extra byte for sb_str's NUL.

#define SB_BUF  0                     // uptr: bytes
#define SB_LEN  8                     // i64:  used, without the NUL
#define SB_CAP  16                    // i64:  buffer capacity, with the NUL
#define SB_SIZE 24

uptr sb_buf(uptr b)             { return ld64(b + SB_BUF); }
void set_sb_buf(uptr b, uptr v) { st64(b + SB_BUF, v); }
i64  sb_len(uptr b)             { return ld64(b + SB_LEN); }
void set_sb_len(uptr b, i64 v)  { st64(b + SB_LEN, v); }
i64  sb_cap(uptr b)             { return ld64(b + SB_CAP); }
void set_sb_cap(uptr b, i64 v)  { st64(b + SB_CAP, v); }

uptr sb_new(i64 cap) {
    if (cap < 64) cap = 64;
    uptr b = rt_alloc(SB_SIZE);
    set_sb_buf(b, rt_alloc(cap));
    set_sb_len(b, 0);
    set_sb_cap(b, cap);
    return b;
}

// ensures room for `n` more bytes besides the final NUL; reallocates by doubling
void sb_grow(uptr b, i64 n) {
    i64 need = sb_len(b) + n + 1;
    if (need <= sb_cap(b)) return;
    i64 cap = sb_cap(b);
    while (cap < need) {
        cap = cap * 2;
    }
    uptr grown = rt_alloc(cap);
    mem_copy(grown, sb_buf(b), sb_len(b));
    set_sb_buf(b, grown);
    set_sb_cap(b, cap);
}

void sb_put(uptr b, i64 c) {
    sb_grow(b, 1);
    st8(sb_buf(b) + sb_len(b), c);
    set_sb_len(b, sb_len(b) + 1);
}

// appends `n` raw bytes (may contain any byte except whatever the caller does not want)
void sb_putmem(uptr b, uptr s, i64 n) {
    sb_grow(b, n);
    mem_copy(sb_buf(b) + sb_len(b), s, n);
    set_sb_len(b, sb_len(b) + n);
}

void sb_puts(uptr b, uptr s) {
    sb_putmem(b, s, str_len(s));
}

void sb_putnum(uptr b, i64 v) {
    u8 tmp[24];
    i64 n = itoa(v, tmp);
    sb_putmem(b, tmp, n);
}

// closes the buffer with a NUL and returns the bytes; the pointer is valid until the next sb_put*
uptr sb_str(uptr b) {
    st8(sb_buf(b) + sb_len(b), 0);
    return sb_buf(b);
}

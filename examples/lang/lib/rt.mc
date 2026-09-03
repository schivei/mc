// rt.mc — the runtime of the `lx` language: a fixed 4 MiB arena, free lists by
// size class, reference counting and the print helpers.
//
// This file is PROGRAM code, not compiler code: it is compiled by the taught
// compiler together with the `.lx` source, and every name in it is what the
// generated code calls. It uses only the CORE language -- no `while`, no `for`,
// no `#rule` prelude -- so the default `mc` compiles it unchanged, and the first
// thing the default compiler trips on in an `.lx` program is the language
// itself and not the runtime.
//
// Object layout produced by lang.mc (see README.md § Layout):
//
//     +0   vtable pointer   (word 0)
//     +8   reference count  (word 1)
//     +16  fields, the base class's first
//
// Vtable layout:
//
//     +0   &Class_release
//     +8   Class_itab, or 0 when the class implements no interface
//     +16  virtual slot 0, +24 slot 1, ...
//
// That is why rc_dec can free an object it knows nothing about: slot 0 of the
// vtable is always the class's release function.

#include "../../../lib/sys.mc"

#define RT_ARENA   4194304            // 4 MiB, in __bss
#define RT_ALIGN   16
#define RT_NCLASS  16                 // free lists: 16, 32, ... 256 bytes
#define RT_MAXSMALL 256

u8   rt_heap[RT_ARENA];
i64  rt_hp = 0;
uptr rt_fl[RT_NCLASS];                // head of each size class's free list
i64  rt_nlive = 0;                    // objects handed out and not yet freed
i64  rt_npeak = 0;                    // high-water mark of rt_hp

uptr rt_fl_at(i64 i)          { return ld64(rt_fl + i * 8); }
void set_rt_fl_at(i64 i, uptr v) { st64(rt_fl + i * 8, v); }

// aborts with a message on stderr; there is no recovery
void rt_panic(uptr msg) {
    write(2, "lx: ", 4);
    write(2, msg, strlen(msg));
    write(2, "\n", 1);
    exit(70);
}

void rt_zero(uptr p, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(p + i, 0);
        i = i + 1;
    }
}

// size class of a block of `sz` bytes (sz already a multiple of 16), or -1 when
// the block is too big to be recycled
i64 rt_class(i64 sz) {
    if (sz > RT_MAXSMALL) return 0 - 1;
    return sz / RT_ALIGN - 1;
}

// `n` zeroed bytes, aligned to 16. Recycles from the free list of its size
// class first; only then does the bump pointer move. Never returns 0.
uptr rt_alloc(i64 n) {
    if (n < 0) rt_panic("rt_alloc: negative size");
    i64 sz = (n + (RT_ALIGN - 1)) & ~(RT_ALIGN - 1);
    if (sz == 0) sz = RT_ALIGN;
    i64 c = rt_class(sz);
    if (c >= 0) {
        uptr h = rt_fl_at(c);
        if (h != 0) {
            set_rt_fl_at(c, ld64(h));            // word 0 of a free block is the link
            rt_zero(h, sz);
            rt_nlive = rt_nlive + 1;
            return h;
        }
    }
    if (rt_hp + sz > RT_ARENA) rt_panic("rt_alloc: arena full");
    uptr p = rt_heap + rt_hp;
    rt_hp = rt_hp + sz;
    if (rt_hp > rt_npeak) rt_npeak = rt_hp;
    rt_zero(p, sz);
    rt_nlive = rt_nlive + 1;
    return p;
}

// gives `n` bytes at `p` back to its size class. A block bigger than
// RT_MAXSMALL is dropped: the arena never reuses it (documented in README).
void rt_free(uptr p, i64 n) {
    if (p == 0) return;
    rt_nlive = rt_nlive - 1;
    i64 sz = (n + (RT_ALIGN - 1)) & ~(RT_ALIGN - 1);
    if (sz == 0) sz = RT_ALIGN;
    i64 c = rt_class(sz);
    if (c < 0) return;
    st64(p, rt_fl_at(c));
    set_rt_fl_at(c, p);
}

i64 rt_used()  { return rt_hp; }
i64 rt_live()  { return rt_nlive; }
i64 rt_peak()  { return rt_npeak; }

// ---- reference counting ----

void rc_inc(uptr p) {
    if (p == 0) return;
    st64(p + 8, ld64(p + 8) + 1);
}

// at zero, calls the class's release through slot 0 of the vtable; that
// function runs `dispose`, releases the class-typed fields and calls rt_free
void rc_dec(uptr p) {
    if (p == 0) return;
    i64 n = ld64(p + 8) - 1;
    st64(p + 8, n);
    if (n > 0) return;
    if (n < 0) rt_panic("rc_dec: reference count below zero");
    callp(ld64(ld64(p)), p);
}

// borrow -> owned: used when a borrowed value initializes an owning slot
uptr rt_own(uptr p) {
    rc_inc(p);
    return p;
}

// *slot = v, with the counts kept straight. The increment comes first so that
// `x = x` cannot free the object between the two steps.
void rt_store(uptr slot, uptr v) {
    rc_inc(v);
    uptr old = ld64(slot);
    st64(slot, v);
    rc_dec(old);
}

// the same store when `v` is already owned (it came from `new` or from a
// function that returned a reference): no increment, the reference moves in
void rt_store_own(uptr slot, uptr v) {
    uptr old = ld64(slot);
    st64(slot, v);
    rc_dec(old);
}

// releases `n` object slots starting at `base`: an array field of class type
void rt_release_array(uptr base, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        rc_dec(ld64(base + i * 8));
        st64(base + i * 8, 0);
        i = i + 1;
    }
}

// method table of interface `id` inside the class whose vtable is `vt`.
// The interface table is { count, (id, methods)* }, in declaration order.
uptr rt_itab(uptr vt, i64 id) {
    uptr t = ld64(vt + 8);
    if (t == 0) rt_panic("interface dispatch on a class with no interface table");
    i64 n = ld64(t);
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld64(t + 8 + i * 16) == id) return ld64(t + 16 + i * 16);
        i = i + 1;
    }
    rt_panic("interface not implemented by this class");
    return 0;
}

// ---- output ----

void rt_print_str(uptr s) {
    write(1, s, strlen(s));
    write(1, "\n", 1);
}

void rt_write_str(uptr s) {
    write(1, s, strlen(s));
}

void rt_print_i64(i64 v) {
    u8 tmp[24];
    i64 neg = 0;
    i64 i = 24;
    if (v < 0) {
        neg = 1;
        v = 0 - v;
    }
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    if (neg) write(1, "-", 1);
    write(1, tmp + i, 24 - i);
    write(1, "\n", 1);
}

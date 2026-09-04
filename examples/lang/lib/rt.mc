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

// ---- dynamic dispatch: the receiver, evaluated once ----
//
// A dynamic call needs the receiver TWICE -- once to reach the method pointer
// through the vtable, and once as the `self` argument -- and the module cannot
// write it twice. An AST node is a node in ONE tree: `list_append` links by
// mutating `nd_next`, so the same node placed in two argument lists splices the
// two lists together (the vtable `ld64` then ends up with the method's own
// arguments as well, `wrong arity in intrinsic`), and a node reachable from two
// places is walked twice, which evaluates the receiver EXPRESSION twice --
// `new C().m()` allocating two objects, `pick(s).m()` calling `pick` twice.
//
// So the receiver is bound to a name instead, and the cheapest name in a
// language with no block expression is a PARAMETER: `obj` below is written once
// by the caller, at the call site's own position in the evaluation order, and
// read twice inside. One wrapper per arity because `callp` takes a fixed number
// of arguments at each call site; `lg_call_method`/`lg_call_iface` pick the one
// that matches (examples/lang/lang_expr.mc). The arity ceiling is unchanged:
// with `obj` and one packed integer ahead of them, a method may still take the
// ten arguments `na + 2 > MAXPARAMS` has always allowed.
uptr rt_vslot(uptr obj, i64 off) { return ld64(ld64(obj) + off); }

// `code` packs the interface index and the method's index within it, so that an
// interface call spends exactly as many parameters as a virtual one. Both are
// indices into the compiler's own tables, one per declaration in the program;
// lang_expr.mc refuses to pack anything at or above 65536.
uptr rt_islot(uptr obj, i64 code) {
    return ld64(rt_itab(ld64(obj), code / 65536) + (code % 65536) * 8);
}

i64 rt_vcall0(uptr obj, i64 off) { return callp(rt_vslot(obj, off), obj); }
i64 rt_vcall1(uptr obj, i64 off, i64 a1) { return callp(rt_vslot(obj, off), obj, a1); }
i64 rt_vcall2(uptr obj, i64 off, i64 a1, i64 a2) { return callp(rt_vslot(obj, off), obj, a1, a2); }
i64 rt_vcall3(uptr obj, i64 off, i64 a1, i64 a2, i64 a3) { return callp(rt_vslot(obj, off), obj, a1, a2, a3); }
i64 rt_vcall4(uptr obj, i64 off, i64 a1, i64 a2, i64 a3, i64 a4) { return callp(rt_vslot(obj, off), obj, a1, a2, a3, a4); }
i64 rt_vcall5(uptr obj, i64 off, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5) { return callp(rt_vslot(obj, off), obj, a1, a2, a3, a4, a5); }
i64 rt_vcall6(uptr obj, i64 off, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6) { return callp(rt_vslot(obj, off), obj, a1, a2, a3, a4, a5, a6); }
i64 rt_vcall7(uptr obj, i64 off, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7) { return callp(rt_vslot(obj, off), obj, a1, a2, a3, a4, a5, a6, a7); }
i64 rt_vcall8(uptr obj, i64 off, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7, i64 a8) { return callp(rt_vslot(obj, off), obj, a1, a2, a3, a4, a5, a6, a7, a8); }
i64 rt_vcall9(uptr obj, i64 off, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7, i64 a8, i64 a9) { return callp(rt_vslot(obj, off), obj, a1, a2, a3, a4, a5, a6, a7, a8, a9); }
i64 rt_vcall10(uptr obj, i64 off, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7, i64 a8, i64 a9, i64 a10) { return callp(rt_vslot(obj, off), obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10); }

i64 rt_icall0(uptr obj, i64 code) { return callp(rt_islot(obj, code), obj); }
i64 rt_icall1(uptr obj, i64 code, i64 a1) { return callp(rt_islot(obj, code), obj, a1); }
i64 rt_icall2(uptr obj, i64 code, i64 a1, i64 a2) { return callp(rt_islot(obj, code), obj, a1, a2); }
i64 rt_icall3(uptr obj, i64 code, i64 a1, i64 a2, i64 a3) { return callp(rt_islot(obj, code), obj, a1, a2, a3); }
i64 rt_icall4(uptr obj, i64 code, i64 a1, i64 a2, i64 a3, i64 a4) { return callp(rt_islot(obj, code), obj, a1, a2, a3, a4); }
i64 rt_icall5(uptr obj, i64 code, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5) { return callp(rt_islot(obj, code), obj, a1, a2, a3, a4, a5); }
i64 rt_icall6(uptr obj, i64 code, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6) { return callp(rt_islot(obj, code), obj, a1, a2, a3, a4, a5, a6); }
i64 rt_icall7(uptr obj, i64 code, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7) { return callp(rt_islot(obj, code), obj, a1, a2, a3, a4, a5, a6, a7); }
i64 rt_icall8(uptr obj, i64 code, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7, i64 a8) { return callp(rt_islot(obj, code), obj, a1, a2, a3, a4, a5, a6, a7, a8); }
i64 rt_icall9(uptr obj, i64 code, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7, i64 a8, i64 a9) { return callp(rt_islot(obj, code), obj, a1, a2, a3, a4, a5, a6, a7, a8, a9); }
i64 rt_icall10(uptr obj, i64 code, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, i64 a7, i64 a8, i64 a9, i64 a10) { return callp(rt_islot(obj, code), obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10); }

// ---- compound assignment on a field: the receiver, evaluated once ----
//
// `p.f += e` needs the field's ADDRESS twice -- to load the current value and
// to store the new one -- and that address is `receiver + offset`. Building it
// twice puts the receiver EXPRESSION under two nodes, and a node reachable from
// two places is walked twice: `pick(s).k += 1` called `pick` twice
// (examples/lang/tests/93-dup-field.lx), the same defect the dispatch wrappers
// above fixed for `o.m()`. The answer is the same one: the address is bound to
// a PARAMETER, written once by the caller at its own position in the evaluation
// order and read twice inside. One pair per width, because the field's width is
// what picks the ldW/stW intrinsic (lang_util.mc, lg_fopn).
//
// Two consequences, both deliberate. The field is read AFTER `e` has been
// evaluated, so `p.f += g()` sees whatever `g` left in it -- before, the load
// came first, but only because the receiver was being evaluated a second time.
// And the value of the whole expression is the field's new value read back from
// memory, so for a u8/u16/u32 field it is the narrowed one.
i64 rt_fadd8(uptr p, i64 v)   { st8(p, ld8(p) + v);    return ld8(p); }
i64 rt_fadd16(uptr p, i64 v)  { st16(p, ld16(p) + v);  return ld16(p); }
i64 rt_fadd32(uptr p, i64 v)  { st32(p, ld32(p) + v);  return ld32(p); }
i64 rt_fadd64(uptr p, i64 v)  { st64(p, ld64(p) + v);  return ld64(p); }
i64 rt_fsub8(uptr p, i64 v)   { st8(p, ld8(p) - v);    return ld8(p); }
i64 rt_fsub16(uptr p, i64 v)  { st16(p, ld16(p) - v);  return ld16(p); }
i64 rt_fsub32(uptr p, i64 v)  { st32(p, ld32(p) - v);  return ld32(p); }
i64 rt_fsub64(uptr p, i64 v)  { st64(p, ld64(p) - v);  return ld64(p); }

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

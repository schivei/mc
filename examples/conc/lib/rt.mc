// rt.mc -- the runtime of the `lx` programs in this directory: the same arena,
// free lists, reference counting and print helpers as examples/lang/lib/rt.mc,
// made safe for several threads. It is PROGRAM code, not compiler code, and it
// is written in the CORE language only, so the plain `mc` compiles it unchanged
// (examples/conc/test.sh proves that).
//
// Three differences from the single-threaded original, and no others:
//
//   1. rc_inc / rc_dec go through a_add (LDADDAL). The -AL variants carry the
//      acquire/release pair, so the counts need no separate fence. Four threads
//      x 200 000 increments give exactly 800 000 where ld64/st64 lose ~570 000.
//   2. rt_alloc / rt_free run under one global mutex. Two threads walking an
//      unsynchronised free list corrupt it, and reference counting is only half
//      the problem: the allocator is the other half. One lock is a convoy;
//      per-thread arenas need an owning-arena header and are a later milestone
//      (docs/specs/M31.md section 8, question 5).
//   3. rt_nlive / rt_npeak move atomically, so live() is a number and not a
//      race -- though it is still only meaningful at a quiescence point, which
//      is why the prelude exports quiesce().
//
// rt_store / rt_store_own are NOT locked: a slot -- a local, a field, an array
// element -- has one owner thread by the language's own convention. Two threads
// writing the same field race, exactly as they would in C, and for a
// CLASS-TYPED field that race is a hard abort rather than a wrong value: see
// rt_store below, and README.md, "The one slot two threads may not share".
//
// Object layout produced by lang.mc (examples/lang/README.md section Layout):
//
//     +0   vtable pointer     +8   reference count     +16  fields
//
// and slot 0 of a vtable is always the class's release function, which is what
// lets rc_dec free an object whose class it knows nothing about -- and what
// lets the intent of conc.mc be an ordinary counted object with a vtable the
// runtime writes itself (see conc_rt.mc, it_new).

#include "../../../lib/sys.mc"
#include "atomic.mc"
#include "thread.mc"

#define RT_ARENA    4194304           // 4 MiB, in __bss
#define RT_ALIGN    16
#define RT_NCLASS   16                // free lists: 16, 32, ... 256 bytes
#define RT_MAXSMALL 256

u8   rt_heap[RT_ARENA];
i64  rt_hp = 0;
uptr rt_fl[RT_NCLASS];                // head of each size class's free list
i64  rt_nlive = 0;                    // objects handed out and not yet freed
i64  rt_npeak = 0;                    // high-water mark of rt_hp

// PTHREAD_MUTEX_INITIALIZER: a global with the signature word set is a usable
// mutex before main() runs, so nothing here needs a boot step
u64 rt_mtx[8] = { PT_MUTEX_SIG, 0, 0, 0, 0, 0, 0, 0 };

uptr rt_fl_at(i64 i)             { return ld64(rt_fl + i * 8); }
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

// `n` zeroed bytes, aligned to 16, taken from the free list of its size class
// first and only then from the bump pointer. Never returns 0.
uptr rt_alloc(i64 n) {
    if (n < 0) rt_panic("rt_alloc: negative size");
    i64 sz = (n + (RT_ALIGN - 1)) & ~(RT_ALIGN - 1);
    if (sz == 0) sz = RT_ALIGN;
    i64 c = rt_class(sz);
    pthread_mutex_lock(rt_mtx);
    if (c >= 0) {
        uptr h = rt_fl_at(c);
        if (h != 0) {
            set_rt_fl_at(c, ld64(h));            // word 0 of a free block is the link
            pthread_mutex_unlock(rt_mtx);
            rt_zero(h, sz);
            a_add(&rt_nlive, 1);
            return h;
        }
    }
    if (rt_hp + sz > RT_ARENA) {
        pthread_mutex_unlock(rt_mtx);
        rt_panic("rt_alloc: arena full");
    }
    uptr p = rt_heap + rt_hp;
    rt_hp = rt_hp + sz;
    if (rt_hp > rt_npeak) rt_npeak = rt_hp;
    pthread_mutex_unlock(rt_mtx);
    rt_zero(p, sz);
    a_add(&rt_nlive, 1);
    return p;
}

// gives `n` bytes at `p` back to its size class. A block bigger than
// RT_MAXSMALL is dropped: the arena never reuses it (documented in README).
void rt_free(uptr p, i64 n) {
    if (p == 0) return;
    a_add(&rt_nlive, 0 - 1);
    i64 sz = (n + (RT_ALIGN - 1)) & ~(RT_ALIGN - 1);
    if (sz == 0) sz = RT_ALIGN;
    i64 c = rt_class(sz);
    if (c < 0) return;
    pthread_mutex_lock(rt_mtx);
    st64(p, rt_fl_at(c));
    set_rt_fl_at(c, p);
    pthread_mutex_unlock(rt_mtx);
}

i64 rt_used() { return rt_hp; }
i64 rt_live() { return rt_nlive; }
i64 rt_peak() { return rt_npeak; }

// ---- reference counting, atomic ----

void rc_inc(uptr p) {
    if (p == 0) return;
    a_add(p + 8, 1);
}

// at zero, calls the class's release through slot 0 of the vtable; that
// function runs `dispose`, releases the class-typed fields and calls rt_free.
// The thread that brings the count to zero is the one that disposes -- the
// Arc/Drop rule, and the reason `dispose` may run on any thread.
void rc_dec(uptr p) {
    if (p == 0) return;
    i64 n = a_add(p + 8, 0 - 1) - 1;
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
//
// FOUR steps, and no lock: two threads storing into the SAME class-typed slot
// read the same `old` and both release it, and the second rc_dec aborts the
// process with `rc_dec: reference count below zero` -- a crash, not a wrong
// value (measured: 3 of 40 runs of two threads hammering one field). A shared
// mutable field belongs to one thread, or inside a `lock`. README.md, "The one
// slot two threads may not share".
void rt_store(uptr slot, uptr v) {
    rc_inc(v);
    uptr old = ld64(slot);
    st64(slot, v);
    rc_dec(old);
}

// the same store when `v` is already owned: no increment, the reference moves in
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
// One write() per line, so two threads printing interleave whole lines and
// never half a number. A test that must be reproducible prints from one thread.

void rt_print_str(uptr s) {
    write(1, s, strlen(s));
    write(1, "\n", 1);
}

void rt_write_str(uptr s) {
    write(1, s, strlen(s));
}

i64 rt_fmt_i64(uptr buf, i64 v) {
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
    i64 n = 0;
    if (neg) {
        st8(buf, '-');
        n = 1;
    }
    loop {
        if (i >= 24) break;
        st8(buf + n, ld8(tmp + i));
        n = n + 1;
        i = i + 1;
    }
    return n;
}

void rt_print_i64(i64 v) {
    u8 buf[32];
    i64 n = rt_fmt_i64(buf, v);
    st8(buf + n, '\n');
    write(1, buf, n + 1);
}

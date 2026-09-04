// arena.mc — transliteration of stage0/arena.c: static arena in bss, buffers
// little-endian and I/O by fd. Same functions, same order, same I/O shape.
// No struct: Buf is a flat 24-byte record (BUF_* + accessors).

extern i64 open(uptr path, i64 flags, i64 mode);
extern i64 read(i64 fd, uptr buf, i64 n);
extern i64 write(i64 fd, uptr buf, i64 n);
extern i64 close(i64 fd);
extern void _exit(i64 code);
// NOTE (M5.6): libSystem's `open` is variadic — `int open(const char *, int, ...)`
// — and on Apple's arm64 ABI every variadic argument goes on the STACK, not into
// x2. The core only knows how to pass arguments in x0..x7, so the mode sent by
// `open(path, flags, MODE_644)` would be ignored and the file would come out with
// garbage permissions (measured: `-r--------`). That is why file creation goes
// through `creat`, which is not variadic; `stage0/arena.c` uses the same call, and
// both versions of write_file have exactly the same I/O shape.
extern i64 creat(uptr path, i64 mode);
// M23: the arena grows by mapping one more chunk instead of dying. mmap is a
// libSystem routine, like every other extern above; lib/sys.mc declares the same
// prototype so a program can do it too (docs/build.md § limits).
extern uptr mmap(uptr addr, i64 len, i64 prot, i64 flags, i64 fd, i64 off);

// macOS values (sys/fcntl.h)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0x200
#define O_TRUNC 0x400
#define MODE_644 420                  // 0644 in decimal: no octal literal

// mmap: PROT_READ|PROT_WRITE and MAP_PRIVATE|MAP_ANON (sys/mman.h)
#define PROT_RW   3
#define MAP_ANONP 0x1002

// ---- limit shared by parse.mc and gen_arm64.mc (stage0's mc.h) ----
// MAXPARAMS is not a table: it is the ABI. Every other MAX* of the seed became a
// growable table at M23 -- see the registry below and docs/build.md § limits.
#define MAXPARAMS 8                   // never passes an argument on the stack

// ---- M23: the limits registry ----
// Every table of the compiler is an arena block that doubles on demand. The
// registry holds, per table, the estimate the pre-scan made, the capacity that
// was reserved from it, the high-water usage and how many times the table had to
// grow past that reserve. `mc limits` prints exactly these four numbers
// (src/limits.mc). Order is fixed by the ids below and never sorted.
#define T_TOKENS    0
#define T_INCLUDES  1
#define T_OPENS     2
#define T_INCPATH   3
#define T_NODES     4
#define T_DEFINES   5
#define T_INFIX     6
#define T_PREFIX    7
#define T_OPCODES   8
#define T_SECTIONS  9
#define T_DYLIBS   10
#define T_EXTLIB   11
#define T_EXTPAT   12
#define T_RULES    13
#define T_FUNCS    14
#define T_LOWERED  15
#define T_GLOBALS  16
#define T_STRINGS  17
#define T_LOCALS   18
#define T_LOOPS    19
#define T_PREL     20
#define T_INS      21
#define T_SYMBOLS  22
#define T_MSECS    23
#define T_XSECS    24
#define T_XSEGS    25
#define T_UNDEF    26
#define T_PASSES   27
#define T_ONSTMT   28
#define T_ONJUMP   29
#define T_BACKENDS 30
#define T_SYNTAX   31
#define T_ALIAS    32
#define T_TOMLENT  33
#define T_TOMLAOT  34
#define T_HEAP     35
#define T_COUNT    36

uptr lim_names[] = {
    "tokens", "includes", "opens", "incpath", "nodes", "defines", "infix",
    "prefix", "opcodes", "sections", "dylibs", "extlib", "extpat", "rules",
    "funcs", "lowered", "globals", "strings", "locals", "loops", "prel",
    "ins", "symbols", "msecs", "xsecs", "xsegs", "undef", "passes",
    "on_stmt", "on_jump", "backends", "syntax", "alias", "tomlent", "tomlaot",
    "heap"
};

// cold-start capacity: what a table gets when the pre-scan said nothing about
// it. Never a ceiling -- doubling takes over from here.
i64 lim_seeds[] = {
    512, 64, 16, 8, 256, 128, 64,
    32, 32, 16, 8, 32, 16, 32,
    64, 64, 32, 64, 128, 16, 64,
    256, 64, 16, 32, 8, 64, 8,
    8, 8, 8, 16, 16, 128, 8,
    0
};

i64 lim_est[T_COUNT];                 // estimate, in elements
i64 lim_res[T_COUNT];                 // estimate * (1 + tolerance)
i64 lim_used[T_COUNT];                // high-water usage
i64 lim_grew[T_COUNT];                // reallocations past the first reserve

uptr lim_name_at(i64 i) { return ld64(lim_names + i * 8); }
i64  lim_seed_at(i64 i) { return ld64(lim_seeds + i * 8); }
i64  lim_est_at(i64 i)  { return ld64(lim_est + i * 8); }
i64  lim_res_at(i64 i)  { return ld64(lim_res + i * 8); }
i64  lim_used_at(i64 i) { return ld64(lim_used + i * 8); }
i64  lim_grew_at(i64 i) { return ld64(lim_grew + i * 8); }
void set_lim_est(i64 i, i64 v)  { st64(lim_est + i * 8, v); }
void set_lim_res(i64 i, i64 v)  { st64(lim_res + i * 8, v); }
void set_lim_grew(i64 i, i64 v) { st64(lim_grew + i * 8, v); }

// records n as used by table i, keeping the maximum: tables like `locals` and
// `loops` restart at every function, so the report needs the high-water mark
void lim_note(i64 i, i64 n) {
    if (n > lim_used_at(i)) st64(lim_used + i * 8, n);
}

// capacity for the FIRST allocation of a table: the reserve the plan computed,
// never below the cold-start seed
i64 lim_reserve(i64 i) {
    i64 e = lim_res_at(i);
    if (e < lim_seed_at(i)) e = lim_seed_at(i);
    return e;
}

// ---- the arena ----
// One static chunk in bss plus, when it runs out, one mmap'd chunk per growth.
// Chunks are never moved and never freed, so every pointer handed out stays
// valid -- that is what lets the tables above be plain arena blocks.
#define HEAP_SIZE (32 << 20)
u8  heap[HEAP_SIZE];
i64 hp = 0;
uptr hbase = 0;                       // current chunk; 0 = the static heap[]
i64  hsize = HEAP_SIZE;               // its size
i64  heap_res = HEAP_SIZE;            // bytes reserved across every chunk
i64  heap_used = 0;                   // bytes handed out

// M21.5: where the parser was when the arena ran out. xalloc has no position of
// its own -- it is called from everywhere -- so parse.mc's next() leaves the
// current token's file and line here, two stores per token, and parse_unit()
// clears them again on its way out. 0 = nothing is being parsed (the pre-scan,
// or a failure in the passes, the codegen or the object writer), and the
// message then simply has no position rather than an unrelated one.
uptr ax_file = 0;
i64  ax_line = 0;

uptr arena_base() {
    if (hbase) return hbase;
    return heap;
}

// M21.5: `arena exhausted` used to be four words with no position, no sizes and
// no hint. It is the one error a taught compiler hits by growing, so it says
// what was asked, what is already reserved, what the plan had estimated, where
// the parser was, and what to change. `n` is the request that did not fit.
void arena_die(uptr what, i64 n) {
    out_str(2, "mc: ");
    out_str(2, what);
    out_str(2, " (");
    out_num(2, heap_res >> 20);
    out_str(2, " MiB reserved, ");
    out_num(2, lim_est_at(T_HEAP) >> 20);
    out_str(2, " MiB estimated, asked ");
    out_num(2, n);
    out_str(2, " bytes)");
    if (ax_file != 0) {
        out_str(2, " while parsing ");
        out_str(2, ax_file);
        out_str(2, ":");
        out_num(2, ax_line);
    }
    out_str(2, " -- raise [limits].tolerance or HEAP_SIZE\n");
    _exit(1);
}

// maps a chunk of exactly n bytes (rounded up to 64 KiB) and makes it current;
// 0 = the kernel refused. What is left of the previous chunk is abandoned, never
// freed, so every pointer already handed out stays valid.
i64 arena_map(i64 n) {
    i64 sz = (n + 0xffff) & ~0xffff;
    uptr p = mmap(0, sz, PROT_RW, MAP_ANONP, 0 - 1, 0);
    if (p == 0 || p == 0 - 1) return 0;
    hbase = p;
    hsize = sz;
    hp = 0;
    heap_res = heap_res + sz;
    return 1;
}

// organic growth: double, or take what was asked if that is bigger
i64 arena_chunk(i64 n) {
    i64 sz = hsize * 2;
    if (sz < n) sz = n;
    return arena_map(sz);
}

// reserves n bytes for the arena up front, and exactly n: the plan already knows
// how much it wants. Only maps when what is left of the static heap cannot hold
// them -- bss is already there, and mapping next to it would waste the pages
// nobody asked for.
void arena_reserve(i64 n) {
    if (n <= hsize - hp) return;
    if (arena_map(n)) return;
    arena_die("cannot reserve the arena", n);
}

uptr xalloc(i64 n) {
    n = (n + 15) & ~15;
    if (hp + n > hsize) {
        if (!arena_chunk(n)) arena_die("arena exhausted", n);
        set_lim_grew(T_HEAP, lim_grew_at(T_HEAP) + 1);
    }
    uptr p = arena_base() + hp;
    hp = hp + n;
    heap_used = heap_used + n;
    lim_note(T_HEAP, heap_used);
    return p;
}

// ---- the one growth helper (M23) ----
// grow(id, p, n, &cap, elem) is called at every append site, right where the
// `if (n == MAX) die(...)` used to be. The block doubles, the elements already
// there are copied in the same order, and the registry records the append.
uptr grow(i64 id, uptr p, i64 n, uptr pcap, i64 esz) {
    lim_note(id, n + 1);
    i64 cap = ld64(pcap);
    if (n < cap) return p;
    i64 nc = lim_reserve(id);
    if (cap != 0) {
        nc = cap * 2;
        set_lim_grew(id, lim_grew_at(id) + 1);
    }
    if (nc <= n) nc = n + 1;
    uptr np = xalloc(nc * esz);
    mem_copy(np, p, n * esz);
    st64(pcap, nc);
    return np;
}

// the parallel arrays that share one counter with a table grow() has just
// resized: same new capacity, same copy, no second accounting
uptr grow_to(uptr p, i64 n, i64 cap, i64 esz) {
    uptr np = xalloc(cap * esz);
    mem_copy(np, p, n * esz);
    return np;
}

i64 cstrlen(uptr s) {
    i64 n = 0;
    loop {
        if (ld8(s + n) == 0) break;
        n = n + 1;
    }
    return n;
}

i64 str_eq(uptr a, uptr b) {
    loop {
        if (ld8(a) == 0) break;
        if (ld8(a) != ld8(b)) break;
        a = a + 1;
        b = b + 1;
    }
    return ld8(a) == ld8(b);
}

i64 mem_eq(uptr a, uptr b, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(a + i) != ld8(b + i)) return 0;
        i = i + 1;
    }
    return 1;
}

uptr xstrdup(uptr s, i64 n) {
    uptr d = xalloc(n + 1);
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(d + i, ld8(s + i));
        i = i + 1;
    }
    return d;
}

// ---- Buf: flat record { p, len, cap } ----
#define BUF_P    0
#define BUF_LEN  8
#define BUF_CAP  16
#define BUF_SIZE 24

uptr buf_p(uptr b)   { return ld64(b + BUF_P); }
i64  buf_len(uptr b) { return ld64(b + BUF_LEN); }
i64  buf_cap(uptr b) { return ld64(b + BUF_CAP); }
void set_buf_p(uptr b, uptr v)  { st64(b + BUF_P, v); }
void set_buf_len(uptr b, i64 v) { st64(b + BUF_LEN, v); }
void set_buf_cap(uptr b, i64 v) { st64(b + BUF_CAP, v); }

// equivalent to C's `Buf b = {0}`: locals do not come zeroed
void buf_init(uptr b) {
    set_buf_p(b, 0);
    set_buf_len(b, 0);
    set_buf_cap(b, 0);
}

void buf_grow(uptr b, i64 need) {
    if (buf_len(b) + need <= buf_cap(b)) return;
    i64 cap = buf_cap(b);
    if (cap == 0) cap = 64;
    loop {
        if (cap >= buf_len(b) + need) break;
        cap = cap * 2;
    }
    uptr np = xalloc(cap);
    i64 i = 0;
    loop {
        if (i >= buf_len(b)) break;
        st8(np + i, ld8(buf_p(b) + i));
        i = i + 1;
    }
    set_buf_p(b, np);
    set_buf_cap(b, cap);
}

void buf_put(uptr b, uptr src, i64 n) {
    buf_grow(b, n);
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(buf_p(b) + buf_len(b) + i, ld8(src + i));
        i = i + 1;
    }
    set_buf_len(b, buf_len(b) + n);
}

void buf_u8(uptr b, i64 v) {
    buf_grow(b, 1);
    st8(buf_p(b) + buf_len(b), v);
    set_buf_len(b, buf_len(b) + 1);
}

void buf_u16(uptr b, i64 v) { buf_u8(b, v & 0xff); buf_u8(b, (v >> 8) & 0xff); }
void buf_u32(uptr b, i64 v) { buf_u16(b, v & 0xffff); buf_u16(b, (v >> 16) & 0xffff); }
void buf_u64(uptr b, i64 v) { buf_u32(b, v & 0xffffffff); buf_u32(b, (v >> 32) & 0xffffffff); }

void buf_pad(uptr b, i64 align) {
    loop {
        if (buf_len(b) % align == 0) break;
        buf_u8(b, 0);
    }
}

void buf_patch32(uptr b, i64 off, i64 v) {
    i64 i = 0;
    loop {
        if (i >= 4) break;
        st8(buf_p(b) + off + i, (v >> (8 * i)) & 0xff);
        i = i + 1;
    }
}

i64 buf_get32(uptr b, i64 off) {
    i64 v = 0;
    i64 i = 0;
    loop {
        if (i >= 4) break;
        v = v | (ld8(buf_p(b) + off + i) << (8 * i));
        i = i + 1;
    }
    return v;
}

// ---- output ----
void io_write(i64 fd, uptr p, i64 n) {
    loop {
        if (n == 0) break;
        i64 w = write(fd, p, n);
        if (w <= 0) _exit(2);
        p = p + w;
        n = n - w;
    }
}

void out_str(i64 fd, uptr s)            { io_write(fd, s, cstrlen(s)); }
void out_bytes(i64 fd, uptr p, i64 n)   { io_write(fd, p, n); }

// NOTE M3: stage0's codegen always emits `sdiv`, even for u64. So `u / 10`
// here is signed division: the only value that would diverge from C is v == -2^63.
void out_num(i64 fd, i64 v) {
    u8 tmp[24];
    i64 i = 24;
    i64 neg = v < 0;
    u64 u = v;
    if (neg) u = 0 - v;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + u % 10);
        u = u / 10;
        if (u == 0) break;
    }
    if (neg) {
        i = i - 1;
        st8(tmp + i, '-');
    }
    io_write(fd, tmp + i, 24 - i);
}

void out_hex(i64 fd, u64 v) {
    u8 tmp[18];
    i64 i = 18;
    loop {
        i = i - 1;
        st8(tmp + i, ld8("0123456789abcdef" + (v & 15)));
        v = v >> 4;                            // v is u64: `>>` is logical (lsr)
        if (v == 0) break;
    }
    i = i - 1; st8(tmp + i, 'x');
    i = i - 1; st8(tmp + i, '0');
    io_write(fd, tmp + i, 18 - i);
}

void die(uptr msg) {
    out_str(2, "mc: "); out_str(2, msg); out_str(2, "\n");
    _exit(1);
}

void die2(uptr msg, uptr detail) {
    out_str(2, "mc: "); out_str(2, msg); out_str(2, ": "); out_str(2, detail); out_str(2, "\n");
    _exit(1);
}

// file:line: msg — the file always comes from the token/node that gave the line. The
// compiler's only form of positioned error: the lexer passes lex_file() or the token's
// file, the parser the current token's, the codegen the node's (err_node).
void err_at(uptr file, i64 line, uptr msg) {
    if (file) out_str(2, file);
    else      out_str(2, "?");
    out_str(2, ":");
    out_num(2, line);
    out_str(2, ": ");
    out_str(2, msg);
    out_str(2, "\n");
    _exit(1);
}

// same thing with one extra detail at the end: the lexeme the rule expected, for example
void err_at2(uptr file, i64 line, uptr msg, uptr detail) {
    if (file) out_str(2, file);
    else      out_str(2, "?");
    out_str(2, ":");
    out_num(2, line);
    out_str(2, ": ");
    out_str(2, msg);
    out_str(2, ": ");
    out_str(2, detail);
    out_str(2, "\n");
    _exit(1);
}

#define RF_CHUNK 65536                // the C uses `u8 tmp[65536]` on the frame; here it comes from the arena

uptr read_file(uptr path, uptr plen) {
    i64 fd = open(path, O_RDONLY, 0);
    if (fd < 0) die2("cannot open", path);
    u8 b[BUF_SIZE];
    buf_init(b);
    uptr tmp = xalloc(RF_CHUNK);
    loop {
        i64 r = read(fd, tmp, RF_CHUNK);
        if (r < 0) die2("read error", path);
        if (r == 0) break;
        buf_put(b, tmp, r);
    }
    close(fd);
    buf_u8(b, 0);
    st64(plen, buf_len(b) - 1);
    return buf_p(b);
}

void write_file(uptr path, uptr b) {
    i64 fd = creat(path, MODE_644);       // see the NOTE about variadic open above
    if (fd < 0) die2("cannot create", path);
    io_write(fd, buf_p(b), buf_len(b));
    close(fd);
}

// ---- copy/zero bytes (the C uses struct assignment; here it's byte by byte) ----
void mem_copy(uptr d, uptr s, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(d + i, ld8(s + i));
        i = i + 1;
    }
}

void mem_zero(uptr p, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(p + i, 0);
        i = i + 1;
    }
}

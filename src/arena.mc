// arena.mc — transliteracao de stage0/arena.c: arena estatica em bss, buffers
// little-endian e I/O por fd. Mesmas funcoes, mesma ordem, mesma forma de I/O.
// Sem struct: Buf e um registro plano de 24 bytes (BUF_* + acessoras).

extern i64 open(uptr path, i64 flags, i64 mode);
extern i64 read(i64 fd, uptr buf, i64 n);
extern i64 write(i64 fd, uptr buf, i64 n);
extern i64 close(i64 fd);
extern void _exit(i64 code);

// valores do macOS (sys/fcntl.h)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0x200
#define O_TRUNC 0x400
#define MODE_644 420                  // 0644 em decimal: nao ha literal octal

#define HEAP_SIZE (256 << 20)
u8  heap[HEAP_SIZE];
i64 hp = 0;

uptr xalloc(i64 n) {
    n = (n + 15) & ~15;
    if (hp + n > HEAP_SIZE) die("arena exhausted");
    uptr p = heap + hp;
    hp = hp + n;
    return p;
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

// ---- Buf: registro plano { p, len, cap } ----
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

// equivale a `Buf b = {0}` do C: locais nao vem zerados
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

// ---- saida ----
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

// NOTA M3: o codegen do stage0 emite sempre `sdiv`, mesmo para u64. Logo `u / 10`
// aqui e divisao com sinal: o unico valor que divergiria do C e v == -2^63.
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
        v = v >> 4;                            // v e u64: `>>` e logico (lsr)
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

uptr src_name;                        // main/lex_push definem antes de qualquer erro

void err_at(i64 line, uptr msg) {
    out_str(2, src_name); out_str(2, ":"); out_num(2, line);
    out_str(2, ": "); out_str(2, msg); out_str(2, "\n");
    _exit(1);
}

#define RF_CHUNK 65536                // o C usa `u8 tmp[65536]` no frame; aqui vem da arena

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
    i64 fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, MODE_644);
    if (fd < 0) die2("cannot create", path);
    io_write(fd, buf_p(b), buf_len(b));
    close(fd);
}

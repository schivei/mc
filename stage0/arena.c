/* arena.c — arena estatica em bss, buffers little-endian e I/O por fd.
 * Mesma forma que a versao em .mc: so open/read/write/close/exit. */
#include "mc.h"
#include <unistd.h>
#include <fcntl.h>

#define HEAP_SIZE (256u << 20)
static u8 heap[HEAP_SIZE];
static size_t hp;

void *xalloc(size_t n) {
    n = (n + 15) & ~(size_t)15;
    if (hp + n > HEAP_SIZE) die("arena exhausted");
    void *p = heap + hp;
    hp += n;
    return p;
}

size_t cstrlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
bool str_eq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}
bool mem_eq(const void *a, const void *b, size_t n) {
    const u8 *x = a, *y = b;
    for (size_t i = 0; i < n; i++) if (x[i] != y[i]) return false;
    return true;
}
char *xstrdup(const char *s, size_t n) {
    char *d = xalloc(n + 1);
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return d;
}

static void buf_grow(Buf *b, size_t need) {
    if (b->len + need <= b->cap) return;
    size_t cap = b->cap ? b->cap : 64;
    while (cap < b->len + need) cap *= 2;
    u8 *np = xalloc(cap);
    for (size_t i = 0; i < b->len; i++) np[i] = b->p[i];
    b->p = np; b->cap = cap;
}
void buf_put(Buf *b, const void *src, size_t n) {
    buf_grow(b, n);
    const u8 *s = src;
    for (size_t i = 0; i < n; i++) b->p[b->len + i] = s[i];
    b->len += n;
}
void buf_u8(Buf *b, u8 v)   { buf_grow(b, 1); b->p[b->len++] = v; }
void buf_u16(Buf *b, u16 v) { buf_u8(b, v & 0xff); buf_u8(b, v >> 8); }
void buf_u32(Buf *b, u32 v) { buf_u16(b, v & 0xffff); buf_u16(b, v >> 16); }
void buf_u64(Buf *b, u64 v) { buf_u32(b, (u32)v); buf_u32(b, (u32)(v >> 32)); }
void buf_pad(Buf *b, size_t align) { while (b->len % align) buf_u8(b, 0); }
void buf_patch32(Buf *b, size_t off, u32 v) {
    for (int i = 0; i < 4; i++) b->p[off + i] = (u8)(v >> (8 * i));
}
u32 buf_get32(Buf *b, size_t off) {
    u32 v = 0;
    for (int i = 0; i < 4; i++) v |= (u32)b->p[off + i] << (8 * i);
    return v;
}

static void io_write(int fd, const void *p, size_t n) {
    const u8 *s = p;
    while (n) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) _exit(2);
        s += w; n -= (size_t)w;
    }
}
void out_str(int fd, const char *s) { io_write(fd, s, cstrlen(s)); }
void out_bytes(int fd, const void *p, size_t n) { io_write(fd, p, n); }
void out_num(int fd, i64 v) {
    char tmp[24]; int i = 24; bool neg = v < 0;
    u64 u = neg ? 0 - (u64)v : (u64)v;
    do { tmp[--i] = (char)('0' + u % 10); u /= 10; } while (u);
    if (neg) tmp[--i] = '-';
    io_write(fd, tmp + i, (size_t)(24 - i));
}
void out_hex(int fd, u64 v) {
    char tmp[18]; int i = 18;
    do { tmp[--i] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
    tmp[--i] = 'x'; tmp[--i] = '0';
    io_write(fd, tmp + i, (size_t)(18 - i));
}
void die(const char *msg) { out_str(2, "mc: "); out_str(2, msg); out_str(2, "\n"); _exit(1); }
void die2(const char *msg, const char *detail) {
    out_str(2, "mc: "); out_str(2, msg); out_str(2, ": "); out_str(2, detail); out_str(2, "\n"); _exit(1);
}
void err_at(const char *file, int line, const char *msg) {
    out_str(2, file ? file : "?"); out_str(2, ":"); out_num(2, line);
    out_str(2, ": "); out_str(2, msg); out_str(2, "\n"); _exit(1);
}

u8 *read_file(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) die2("cannot open", path);
    Buf b = {0};
    u8 tmp[65536];
    for (;;) {
        ssize_t r = read(fd, tmp, sizeof tmp);
        if (r < 0) die2("read error", path);
        if (r == 0) break;
        buf_put(&b, tmp, (size_t)r);
    }
    close(fd);
    buf_u8(&b, 0);
    *len = b.len - 1;
    return b.p;
}
void write_file(const char *path, Buf *b) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) die2("cannot create", path);
    io_write(fd, b->p, b->len);
    close(fd);
}

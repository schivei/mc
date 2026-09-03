// lz.mc — LZ77 in both directions, deterministic, written in the language
// itself (M15, docs/specs/M15.md).
//
// The stream is a sequence of tokens, each introduced by one control byte:
//
//   0xxxxxxx            literal run of (xxxxxxx + 1) bytes, 1..128
//                       followed by exactly that many raw bytes
//   1xxxxxxx dd dd      match of (xxxxxxx + 3) bytes, 3..130, copied from
//                       `dd dd` bytes back (little-endian distance, 1..65535)
//
// There is no entropy coder and no header: the caller always knows the
// uncompressed size (it is stored next to the stream, in bundle_rsize[] or in
// `#define name_raw`), so `lz_inflate` never has to guess.
//
// Determinism: the match finder is a hash chain (head + prev, both in bss and
// reset at the start of every `lz_deflate`), walked newest-first with a fixed
// bound of LZ_CHAIN candidates, and the first longest match wins. Nothing here
// depends on an address, on the arena's state, or on how many times the
// function was called before — the same input always produces the same bytes.
// That is what makes `make bundle` reproducible.
//
// This file has NO dependencies at all — not even on arena.mc — so `#include
// <lz>` is enough for a program that only wants to decompress an `#embed ... lz`
// (tests/mc/071-embed-lz.mc). It never allocates either: `lz_deflate` writes
// into the buffer the caller sizes with `lz_bound(n)`, and `lz_inflate` into a
// buffer of `rsize` bytes. A corrupt stream is not a fatal error here: inflate
// stops and returns how many bytes it produced, and it is the caller who
// decides — src/bundle.mc dies, a program can do something else.

#define LZ_HBITS  15
#define LZ_HSIZE  32768               // 1 << LZ_HBITS
#define LZ_HMASK  32767
#define LZ_WIN    65536               // window: the distance field is 16 bits
#define LZ_WMASK  65535
#define LZ_MINM   3                   // shorter than this a match does not pay
#define LZ_MAXM   130                 // 127 + LZ_MINM: the length field is 7 bits
#define LZ_MAXLIT 128                 // 127 + 1: the run field is 7 bits
#define LZ_CHAIN  32                  // candidates examined per position
#define LZ_NIL    0xffffffff          // "empty" in the chain

u32 lz_head[LZ_HSIZE];                // last position seen with each hash
u32 lz_prev[LZ_WIN];                  // previous position with the same hash

// hash of the 3 bytes at p — only has to be stable, not good
i64 lz_hash(uptr p) {
    return ((ld8(p) << 10) ^ (ld8(p + 1) << 5) ^ ld8(p + 2)) & LZ_HMASK;
}

// how many bytes are equal at a and b, up to max
i64 lz_mlen(uptr a, uptr b, i64 max) {
    i64 l = 0;
    loop {
        if (l >= max) break;
        if (ld8(a + l) != ld8(b + l)) break;
        l = l + 1;
    }
    return l;
}

// records position p in the chain of its hash
void lz_insert(uptr src, i64 p) {
    i64 h = lz_hash(src + p);
    st32(lz_prev + (p & LZ_WMASK) * 4, ld32(lz_head + h * 4));
    st32(lz_head + h * 4, p);
}

// upper bound on the output: every byte a literal, plus one control byte per
// run of 128, plus slack. The caller allocates this much before deflating.
i64 lz_bound(i64 n) { return n + n / LZ_MAXLIT + 8; }

// writes the pending literals src[lit..end) as runs and returns the new cursor
i64 lz_flush(uptr src, i64 lit, i64 end, uptr dst, i64 w) {
    loop {
        if (lit >= end) break;
        i64 k = end - lit;
        if (k > LZ_MAXLIT) k = LZ_MAXLIT;
        st8(dst + w, k - 1);                    // high bit clear: literal run
        w = w + 1;
        i64 j = 0;
        loop {
            if (j >= k) break;
            st8(dst + w + j, ld8(src + lit + j));
            j = j + 1;
        }
        w = w + k;
        lit = lit + k;
    }
    return w;
}

// longest match for position p, or 0 in blen. The distance comes back in pdist.
i64 lz_match(uptr src, i64 n, i64 p, uptr pdist) {
    st64(pdist, 0);
    if (p + LZ_MINM > n) return 0;
    i64 max = n - p;
    if (max > LZ_MAXM) max = LZ_MAXM;
    i64 cand = ld32(lz_head + lz_hash(src + p) * 4);
    i64 tries = 0;
    i64 blen = 0;
    loop {
        if (cand == LZ_NIL) break;
        if (tries >= LZ_CHAIN) break;
        i64 d = p - cand;
        if (d <= 0 || d > LZ_WMASK) break;
        i64 l = lz_mlen(src + cand, src + p, max);
        if (l > blen) {
            blen = l;
            st64(pdist, d);
            if (l == max) break;
        }
        cand = ld32(lz_prev + (cand & LZ_WMASK) * 4);
        tries = tries + 1;
    }
    if (blen < LZ_MINM) { st64(pdist, 0); return 0; }
    return blen;
}

// compresses src[0..n) into dst and returns the number of bytes written
i64 lz_deflate(uptr src, i64 n, uptr dst) {
    i64 i = 0;
    loop {
        if (i >= LZ_HSIZE) break;
        st32(lz_head + i * 4, LZ_NIL);
        i = i + 1;
    }
    i64 w = 0;
    i64 lit = 0;
    i64 p = 0;
    loop {
        if (p >= n) break;
        i64 dist = 0;
        i64 blen = lz_match(src, n, p, &dist);
        // A match of exactly LZ_MINM costs 3 bytes for 3 bytes: it only pays
        // when there is no pending literal run, because otherwise it also
        // forces an extra control byte for the run it interrupts. Refusing it
        // is what keeps lz_bound() true: every (literal run + match) pair then
        // has non-positive overhead, and the only cost left is one control
        // byte per 128 literals.
        if (blen == LZ_MINM && lit != p) blen = 0;
        if (blen == 0) {
            if (p + LZ_MINM <= n) lz_insert(src, p);
            p = p + 1;
            continue;
        }
        w = lz_flush(src, lit, p, dst, w);
        st8(dst + w, 128 | (blen - LZ_MINM));
        st8(dst + w + 1, dist & 255);
        st8(dst + w + 2, (dist >> 8) & 255);
        w = w + 3;
        i64 q = 0;
        loop {                                  // every covered position enters the chain
            if (q >= blen) break;
            if (p + q + LZ_MINM <= n) lz_insert(src, p + q);
            q = q + 1;
        }
        p = p + blen;
        lit = p;
    }
    return lz_flush(src, lit, n, dst, w);
}

// expands src[0..n) into dst, which has room for rsize bytes; returns how many
// were written. A stream that does not fit, or that points outside what has
// already been produced, is refused — an inflate never writes past rsize.
i64 lz_inflate(uptr src, i64 n, uptr dst, i64 rsize) {
    i64 i = 0;
    i64 o = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(src + i);
        i = i + 1;
        if (c < 128) {
            i64 k = c + 1;
            if (i + k > n || o + k > rsize) return o;      // corrupt: stop here
            i64 j = 0;
            loop {
                if (j >= k) break;
                st8(dst + o + j, ld8(src + i + j));
                j = j + 1;
            }
            i = i + k;
            o = o + k;
            continue;
        }
        i64 l = (c & 127) + LZ_MINM;
        if (i + 2 > n) return o;
        i64 d = ld8(src + i) | (ld8(src + i + 1) << 8);
        i = i + 2;
        if (d == 0 || d > o || o + l > rsize) return o;
        i64 j = 0;
        loop {                                  // forward copy: overlap is intentional
            if (j >= l) break;
            st8(dst + o + j, ld8(dst + o - d + j));
            j = j + 1;
        }
        o = o + l;
    }
    return o;
}

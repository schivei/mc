// sha256.mc — SHA-256 (FIPS 180-4) escrito na propria linguagem.
//
// Existe por causa do M11: a assinatura ad-hoc de um Mach-O executavel e uma
// arvore de hashes SHA-256 (uma por pagina de 4 KiB do arquivo) e o LC_UUID que
// o backend grava e derivado do hash do conteudo — sem um SHA-256 proprio nao ha
// como assinar sem chamar `codesign`.
//
// Sem u32 de verdade nas contas: todo valor intermediario mora num i64 e e
// mascarado com SHA_M32 a cada passo. Isso torna `>>` aritmetico e `>>` logico
// indistinguiveis (o valor nunca passa de 2^32 - 1 nem fica negativo), entao o
// codigo nao depende da regra de sinal do nucleo (docs/core-language.md
// § Divisao e modulo sem sinal).
//
// Estado e escalonamento moram em globais (__bss/__data), nao no frame: o frame
// de uma funcao do nucleo e limitado a 4095 bytes e `u32 w[64]` sozinho ja seria
// 256 deles.
//
// Depende so do nucleo mais o prelude (while/+=). Nenhum extern.
//
// Conferido contra `shasum -a 256` em sete vetores (string vazia, "abc", o vetor
// de 56 bytes do FIPS, 1000 bytes, e os limites de padding 55/56/64 — os tres
// casos em que o bloco final vira dois). A regressao permanente e indireta e mais
// forte: `scripts/test-exe.sh` roda `codesign --verify` em cada um dos 32
// binarios da suite, e o `codesign` recalcula todos os hashes de pagina por conta
// propria — um erro aqui reprovaria os 32 na hora.

#include "../lib/prelude.mc"

#define SHA_M32 0xffffffff

// constantes de round (FIPS 180-4, 4.2.2): primeiros 32 bits das partes
// fracionarias das raizes cubicas dos 64 primeiros primos
u32 sha_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

u32 sha_st[8];                          // h0..h7
u32 sha_w[64];                          // escalonamento da mensagem

i64  sha_k_at(i64 i)             { return ld32(sha_k + i * 4); }
i64  sha_w_at(i64 i)             { return ld32(sha_w + i * 4); }
void set_sha_w_at(i64 i, i64 v)  { st32(sha_w + i * 4, v); }
i64  sha_st_at(i64 i)            { return ld32(sha_st + i * 4); }
void set_sha_st_at(i64 i, i64 v) { st32(sha_st + i * 4, v); }

// rotacao a direita em 32 bits; x sempre chega mascarado
i64 rotr32(i64 x, i64 n) {
    return ((x >> n) | (x << (32 - n))) & SHA_M32;
}

// le 4 bytes big-endian (a ordem de todo campo de SHA-256)
i64 sha_be32(uptr p) {
    return (ld8(p) << 24) | (ld8(p + 1) << 16) | (ld8(p + 2) << 8) | ld8(p + 3);
}

// escreve 4 bytes big-endian
void sha_put_be32(uptr p, i64 v) {
    st8(p,     (v >> 24) & 0xff);
    st8(p + 1, (v >> 16) & 0xff);
    st8(p + 2, (v >> 8) & 0xff);
    st8(p + 3, v & 0xff);
}

// comprime um bloco de 64 bytes sobre sha_st
void sha_block(uptr p) {
    i64 i = 0;
    while (i < 16) {
        set_sha_w_at(i, sha_be32(p + i * 4));
        i++;
    }
    while (i < 64) {
        i64 x = sha_w_at(i - 15);
        i64 y = sha_w_at(i - 2);
        i64 s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3);
        i64 s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >> 10);
        set_sha_w_at(i, (sha_w_at(i - 16) + s0 + sha_w_at(i - 7) + s1) & SHA_M32);
        i++;
    }
    i64 a = sha_st_at(0);
    i64 b = sha_st_at(1);
    i64 c = sha_st_at(2);
    i64 d = sha_st_at(3);
    i64 e = sha_st_at(4);
    i64 f = sha_st_at(5);
    i64 g = sha_st_at(6);
    i64 h = sha_st_at(7);
    i = 0;
    while (i < 64) {
        i64 be = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        i64 ch = (e & f) ^ ((~e) & g);
        i64 t1 = (h + be + ch + sha_k_at(i) + sha_w_at(i)) & SHA_M32;
        i64 ba = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        i64 mj = (a & b) ^ (a & c) ^ (b & c);
        i64 t2 = (ba + mj) & SHA_M32;
        h = g;
        g = f;
        f = e;
        e = (d + t1) & SHA_M32;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & SHA_M32;
        i++;
    }
    set_sha_st_at(0, (sha_st_at(0) + a) & SHA_M32);
    set_sha_st_at(1, (sha_st_at(1) + b) & SHA_M32);
    set_sha_st_at(2, (sha_st_at(2) + c) & SHA_M32);
    set_sha_st_at(3, (sha_st_at(3) + d) & SHA_M32);
    set_sha_st_at(4, (sha_st_at(4) + e) & SHA_M32);
    set_sha_st_at(5, (sha_st_at(5) + f) & SHA_M32);
    set_sha_st_at(6, (sha_st_at(6) + g) & SHA_M32);
    set_sha_st_at(7, (sha_st_at(7) + h) & SHA_M32);
}

// sha256(p, n, out): 32 bytes de digest em `out`. Uma passada so, sem estado
// persistente entre chamadas — o padding do bloco final cabe em 128 bytes.
void sha256(uptr p, i64 n, uptr out) {
    set_sha_st_at(0, 0x6a09e667);
    set_sha_st_at(1, 0xbb67ae85);
    set_sha_st_at(2, 0x3c6ef372);
    set_sha_st_at(3, 0xa54ff53a);
    set_sha_st_at(4, 0x510e527f);
    set_sha_st_at(5, 0x9b05688c);
    set_sha_st_at(6, 0x1f83d9ab);
    set_sha_st_at(7, 0x5be0cd19);

    i64 i = 0;
    while (n - i >= 64) {
        sha_block(p + i);
        i += 64;
    }

    u8 tail[128];                       // resto + 0x80 + zeros + 8 bytes de tamanho
    i64 rem = n - i;
    i64 tl = 64;
    if (rem >= 56) tl = 128;
    i64 j = 0;
    while (j < rem) {
        st8(tail + j, ld8(p + i + j));
        j++;
    }
    st8(tail + rem, 0x80);
    j = rem + 1;
    while (j < tl) {
        st8(tail + j, 0);
        j++;
    }
    u64 bits = n * 8;                   // comprimento em bits, big-endian, nos 8 ultimos
    j = 0;
    while (j < 8) {
        st8(tail + tl - 1 - j, (bits >> (8 * j)) & 0xff);
        j++;
    }
    sha_block(tail);
    if (tl == 128) sha_block(tail + 64);

    j = 0;
    while (j < 8) {
        sha_put_be32(out + j * 4, sha_st_at(j));
        j++;
    }
}

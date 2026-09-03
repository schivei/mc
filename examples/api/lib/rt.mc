// rt.mc — runtime minimo dos programas de examples/api: arena estatica, utilitarios
// de string, buffer de saida (strbuf) e conversao inteiro <-> texto.
//
// Escrito so com o nucleo da linguagem mais lib/prelude.mc (`while`, `for`, `++`,
// `+=`). Nada aqui depende dos hooks do M12: e codigo de programa, nao de compilador.
//
// A arena e FIXA: RT_HEAP_SIZE bytes reservados em __bss e um ponteiro que so anda
// para frente. Nao existe rt_free — um programa que aloca em laco infinito estoura a
// arena e morre em rt_panic. O heap de verdade e assunto do M13.
//
//   #include "lib/rt.mc"

#include "../../../lib/prelude.mc"
#include "../../../lib/sys.mc"

#define RT_HEAP_SIZE 4194304          // 4 MiB
#define RT_ALIGN 16                   // todo bloco sai alinhado a 16

u8  rt_heap[RT_HEAP_SIZE];
i64 rt_hp = 0;

// ---- arena ----

// aborta o programa com uma mensagem em stderr; sem recuperacao
void rt_panic(uptr msg) {
    write(2, "rt: ", 4);
    write(2, msg, str_len(msg));
    write(2, "\n", 1);
    exit(70);
}

// devolve `n` bytes zerados e alinhados a 16; nunca devolve 0
uptr rt_alloc(i64 n) {
    if (n < 0) rt_panic("rt_alloc: tamanho negativo");
    i64 sz = (n + (RT_ALIGN - 1)) & ~(RT_ALIGN - 1);
    if (sz == 0) sz = RT_ALIGN;
    if (rt_hp + sz > RT_HEAP_SIZE) rt_panic("rt_alloc: arena cheia");
    uptr p = rt_heap + rt_hp;
    rt_hp = rt_hp + sz;
    mem_zero(p, sz);
    return p;
}

// bytes ja entregues pela arena (util em teste e diagnostico)
i64 rt_used() { return rt_hp; }

// ---- memoria ----

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

// ---- strings NUL-terminadas ----

i64 str_len(uptr s) {
    i64 n = 0;
    while (ld8(s + n) != 0) {
        n++;
    }
    return n;
}

// compara ate `n` bytes; 0 se iguais, senao a diferenca do primeiro byte diferente
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

// 1 se as duas strings sao identicas, 0 caso contrario
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

// indice da primeira ocorrencia de `n` em `h`, ou -1; agulha vazia casa em 0
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

// copia `s` com o NUL para `d`; devolve o comprimento sem o NUL
i64 str_cpy(uptr d, uptr s) {
    i64 n = str_len(s);
    mem_copy(d, s, n + 1);
    return n;
}

// copia `s` para a arena
uptr str_dup(uptr s) {
    return str_ndup(s, str_len(s));
}

// copia os primeiros `n` bytes de `s` para a arena e fecha com NUL
uptr str_ndup(uptr s, i64 n) {
    uptr p = rt_alloc(n + 1);
    mem_copy(p, s, n);
    st8(p + n, 0);
    return p;
}

// ---- inteiro <-> texto ----

// escreve `v` em decimal (com sinal) e NUL-terminado em `buf`; devolve o comprimento.
// `buf` precisa de 21 bytes. O minimo de i64 nao e representavel pela negacao e nao e
// tratado: nenhum valor deste exemplo chega la.
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

// le um decimal com sinal do inicio de `s`; para no primeiro byte nao-digito
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

// ---- strbuf: buffer de texto que cresce na arena ----
// Estrutura plana de 24 bytes, no estilo obrigatorio do projeto: #define do offset
// mais acessoras. O buffer sempre reserva um byte a mais para o NUL de sb_str.

#define SB_BUF  0                     // uptr: bytes
#define SB_LEN  8                     // i64:  usados, sem o NUL
#define SB_CAP  16                    // i64:  capacidade do buffer, com o NUL
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

// garante espaco para mais `n` bytes alem do NUL final; realoca dobrando
void sb_grow(uptr b, i64 n) {
    i64 need = sb_len(b) + n + 1;
    if (need <= sb_cap(b)) return;
    i64 cap = sb_cap(b);
    while (cap < need) {
        cap = cap * 2;
    }
    uptr novo = rt_alloc(cap);
    mem_copy(novo, sb_buf(b), sb_len(b));
    set_sb_buf(b, novo);
    set_sb_cap(b, cap);
}

void sb_put(uptr b, i64 c) {
    sb_grow(b, 1);
    st8(sb_buf(b) + sb_len(b), c);
    set_sb_len(b, sb_len(b) + 1);
}

// anexa `n` bytes crus (pode conter qualquer byte menos o que o chamador nao quiser)
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

// fecha o buffer com NUL e devolve os bytes; o ponteiro vale ate o proximo sb_put*
uptr sb_str(uptr b) {
    st8(sb_buf(b) + sb_len(b), 0);
    return sb_buf(b);
}

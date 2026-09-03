// backend_arm64.mc — backend `arm64-surface`: a prova do Tier 2.
//
// Este modulo NAO faz parte do compilador. Ele entra pelo `#include` de
// src/user.mc e registra um backend novo em `user_init`. O que ele faz e a
// segunda metade do gen: chama `gen_lower(root)` — que baixa a AST para os
// buffers `Ins` de cada funcao e ja criou secoes, globais, strings e simbolos —
// e depois **reencoda tudo do zero**, com tabelas de opcode proprias, usando so
// a API publica:
//
//   gen_lower/gen_func_count/gen_ins_count/gen_ins_at + ins_op/ins_rd/...
//   gen_func_sec/gen_func_sym/gen_func_labels/gen_prel_*      (gen_arm64.mc)
//   sec_at/sec_data/buf_pad/buf_len/buf_u32/reloc_add/
//   sym_set_value/macho_write                                 (macho.mc)
//
// As formulas de encoding sao as mesmas de `encode` (copiadas de proposito: o
// ponto e que um backend externo consegue chega-las com o que a superficie
// exporta, nao que sejam diferentes). Tudo aqui leva o prefixo `sur_` porque em
// .mc nao ha escopo de arquivo: todo nome e global.
//
// Criterio de aceite: para todo tests/*.mc,
//   build/mc1 --backend=arm64-surface X -o a.o   ==   build/mc1 X -o b.o

// ---- tabelas de opcode, escritas de novo ----
i64 sur_rrr_ins[]  = { I_ADD, I_SUB, I_MUL, I_SDIV, I_UDIV, I_AND, I_ORR, I_EOR,
                       I_LSLV, I_LSRV, I_ASRV, 0 };
u32 sur_rrr_base[] = { 0x8B000000, 0xCB000000, 0x9B007C00, 0x9AC00C00, 0x9AC00800,
                       0x8A000000, 0xAA000000, 0xCA000000,
                       0x9AC02000, 0x9AC02400, 0x9AC02800 };
i64 sur_mem_ins[]  = { I_LDR, I_STR, I_LDRW, I_STRW, I_LDRH, I_STRH, I_LDRB, I_STRB, 0 };
u32 sur_mem_base[] = { 0xF9400000, 0xF9000000, 0xB9400000, 0xB9000000,
                       0x79400000, 0x79000000, 0x39400000, 0x39000000 };
i64 sur_mem_scale[] = { 8, 8, 4, 4, 2, 2, 1, 1 };

i64 sur_rrr_ins_at(i64 i)   { return ld64(sur_rrr_ins + i * 8); }
i64 sur_rrr_base_at(i64 i)  { return ld32(sur_rrr_base + i * 4); }
i64 sur_mem_ins_at(i64 i)   { return ld64(sur_mem_ins + i * 8); }
i64 sur_mem_base_at(i64 i)  { return ld32(sur_mem_base + i * 4); }
i64 sur_mem_scale_at(i64 i) { return ld64(sur_mem_scale + i * 8); }

i64 sur_mem_slot(i64 op) {                    // -1 se nao e acesso a memoria
    i64 i = 0;
    loop {
        if (sur_mem_ins_at(i) == 0) break;
        if (op == sur_mem_ins_at(i)) return i;
        i = i + 1;
    }
    return -1;
}

// vetores de i64 na arena (offsets e labels desta funcao)
i64  sur_vec_at(uptr v, i64 i)          { return ld64(v + i * 8); }
void sur_set_vec_at(uptr v, i64 i, i64 x) { st64(v + i * 8, x); }

// alcance conservador de 19 bits (o menor dos tres desvios)
i64 sur_br_off(i64 target, i64 pc) {
    i64 d = (target - pc) / 4;
    if (d > 0x1ffff || d < 0 - 0x20000) die("desvio longe demais");
    return (u32) d;
}

// ldr/str com deslocamento escalado sem sinal (0..4095 * largura)
i64 sur_enc_mem(uptr e, i64 i) {
    i64 scale = sur_mem_scale_at(i);
    i64 off = ins_imm(e);
    if (off < 0 || off % scale != 0 || off / scale > 4095)
        die("deslocamento de memoria fora de alcance");
    return sur_mem_base_at(i) | ((off / scale) << 10) | (ins_rn(e) << 5) | ins_rd(e);
}

i64 sur_encode(uptr e, i64 pc, uptr lab) {
    i64 op = ins_op(e);
    i64 rd = ins_rd(e);
    i64 rn = ins_rn(e);
    i64 rm = ins_rm(e);
    i64 im = (u32) ins_imm(e);
    i64 i = 0;
    loop {                                    // os 11 de tres operandos rd, rn, rm
        if (sur_rrr_ins_at(i) == 0) break;
        if (op == sur_rrr_ins_at(i)) return sur_rrr_base_at(i) | (rm << 16) | (rn << 5) | rd;
        i = i + 1;
    }
    i64 mi = sur_mem_slot(op);
    if (mi >= 0) return sur_enc_mem(e, mi);
    if (op == I_MOVZ) return 0xD2800000 | (rn << 21) | ((im & 0xffff) << 5) | rd;
    if (op == I_MOVK) return 0xF2800000 | (rn << 21) | ((im & 0xffff) << 5) | rd;
    if (op == I_MOV)  return 0xAA0003E0 | (rn << 16) | rd;      // orr rd, xzr, rn
    if (op == I_MOVW) return 0x2A0003E0 | (rn << 16) | rd;      // orr wd, wzr, wn
    if (op == I_MSUB) return 0x9B008000 | (rm << 16) | ((im & 0x1f) << 10) | (rn << 5) | rd;
    if (op == I_MVN)  return 0xAA2003E0 | (rn << 16) | rd;
    if (op == I_NEG)  return 0xCB0003E0 | (rn << 16) | rd;
    if (op == I_CMP)  return 0xEB00001F | (rm << 16) | (rn << 5);
    if (op == I_CMPI) {
        if (ins_imm(e) < 0 || ins_imm(e) > 4095) die("imediato de cmp fora de 12 bits");
        return 0xF100001F | ((im & 0xfff) << 10) | (rn << 5);
    }
    if (op == I_CSET) return 0x9A9F07E0 | (((ins_imm(e) ^ 1) & 0xf) << 12) | rd;
    if (op == I_ANDI) {                       // mascara 2^k-1: N=1, immr=0, imms=k-1
        u64 m = ins_imm(e);
        i64 k = 0;
        loop {
            if (k >= 64) break;
            if (((m >> k) & 1) == 0) break;
            k = k + 1;
        }
        if (k == 0 || k == 64 || (m >> k) != 0) die("mascara de and imediato nao suportada");
        return 0x92400000 | ((k - 1) << 10) | (rn << 5) | rd;
    }
    if (op == I_ADDI || op == I_SUBI) {
        if (ins_imm(e) < 0 || ins_imm(e) > 4095) die("imediato de add/sub fora de 12 bits");
        i64 base = 0xD1000000;
        if (op == I_ADDI) base = 0x91000000;
        return base | ((im & 0xfff) << 10) | (rn << 5) | rd;
    }
    if (op == I_STP_PRE)  return 0xA9800000 | (((ins_imm(e) / 8) & 0x7f) << 15)
                                 | (rm << 10) | (rn << 5) | rd;
    if (op == I_LDP_POST) return 0xA8C00000 | (((ins_imm(e) / 8) & 0x7f) << 15)
                                 | (rm << 10) | (rn << 5) | rd;
    if (op == I_RET)   return 0xD65F03C0;
    if (op == I_B)     return 0x14000000 | (sur_br_off(sur_vec_at(lab, ins_label(e)), pc) & 0x3ffffff);
    if (op == I_BCOND) return 0x54000000
                              | ((sur_br_off(sur_vec_at(lab, ins_label(e)), pc) & 0x7ffff) << 5)
                              | (im & 0xf);
    if (op == I_CBZ || op == I_CBNZ) {         // bit 24 distingue cbz de cbnz
        i64 base = 0xB5000000;
        if (op == I_CBZ) base = 0xB4000000;
        return base | ((sur_br_off(sur_vec_at(lab, ins_label(e)), pc) & 0x7ffff) << 5) | rd;
    }
    // o deslocamento destes tres vem da relocacao registrada abaixo
    if (op == I_BL)    return 0x94000000;
    if (op == I_ADRP)  return 0x90000000 | rd;
    if (op == I_ADDLO) return 0x91000000 | (rn << 5) | rd;
    if (op == I_EMIT)  return im;
    if (op == I_BLR)   return 0xD63F0000 | (rd << 5);
    die("instrucao sem encoder (backend arm64-surface)");
    return 0;
}

i64 sur_rel_pcrel(i64 t) { return t == R_BRANCH26 || t == R_PAGE21; }
i64 sur_rel_len(i64 t)   { if (t == R_UNSIGNED) return 3; return 2; }

// encoda a funcao f exatamente como gen_encode_one faria, so que daqui de fora
void sur_encode_one(i64 f) {
    i64 n = gen_ins_count(f);
    i64 text = gen_func_sec(f);
    uptr sec = sec_data(sec_at(text));
    uptr off = xalloc(8 * (n + 1));
    uptr lab = xalloc(8 * (gen_func_labels(f) + 2));
    buf_pad(sec, 4);                                // cada funcao alinhada a 4
    i64 base = buf_len(sec);
    sym_set_value(gen_func_sym(f), base);
    i64 pc = 0;
    i64 i = 0;
    loop {                                          // passada 1: offsets e labels
        if (i >= n) break;
        uptr e = gen_ins_at(f, i);
        sur_set_vec_at(off, i, pc);
        if (ins_op(e) == I_LABEL) sur_set_vec_at(lab, ins_label(e), pc);
        else if (ins_op(e) != I_NOP) pc = pc + 4;
        i = i + 1;
    }
    i = 0;
    loop {                                          // passada 2: palavras e relocacoes
        if (i >= n) break;
        uptr e = gen_ins_at(f, i);
        if (ins_op(e) != I_LABEL && ins_op(e) != I_NOP) {
            i64 at = (u32) (base + sur_vec_at(off, i));
            if (ins_op(e) == I_BL)         reloc_add(text, at, ins_sym(e), R_BRANCH26, 1, 2);
            else if (ins_op(e) == I_ADRP)  reloc_add(text, at, ins_sym(e), R_PAGE21, 1, 2);
            else if (ins_op(e) == I_ADDLO) reloc_add(text, at, ins_sym(e), R_PAGEOFF12, 0, 2);
            i64 k = 0;
            loop {                                  // as que reloc() pendurou aqui
                if (k >= gen_prel_count(f)) break;
                if (gen_prel_ins(f, k) == i) {
                    i64 t = gen_prel_type(f, k);
                    reloc_add(text, at, gen_prel_sym(f, k), t, sur_rel_pcrel(t), sur_rel_len(t));
                }
                k = k + 1;
            }
            buf_u32(sec, sur_encode(e, sur_vec_at(off, i), lab));
        }
        i = i + 1;
    }
}

// o backend em si: baixa a AST com o nucleo, encoda aqui, escreve o objeto
void sur_backend(i64 root, uptr out) {
    gen_lower(root);
    i64 f = 0;
    loop {
        if (f >= gen_func_count()) break;
        sur_encode_one(f);
        f = f + 1;
    }
    macho_write(out);
}

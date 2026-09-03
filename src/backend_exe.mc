// backend_exe.mc — backend `macho-exe`: escreve um MH_EXECUTE arm64 direto, sem
// `ld`. `--exe` no driver e apelido de `--backend=macho-exe`.
//
// O caminho comum ate aqui e o mesmo do backend `macho`: gen_lower baixa a AST e
// gen_encode_all encoda as palavras e registra as relocacoes nas secoes. A
// diferenca comeca depois: em vez de gravar um MH_OBJECT com a tabela de
// relocacoes para o `ld` resolver, este backend
//
//   1. escolhe os enderecos finais (um LC_SEGMENT_64 por nome de segmento, cada
//      um alinhado a 16 KiB, que e o vm_page_size do arm64);
//   2. resolve ele mesmo cada relocacao (BRANCH26, PAGE21, PAGEOFF12, UNSIGNED);
//   3. para cada simbolo indefinido cria um stub em __TEXT,__stubs e um slot em
//      __DATA,__got, e manda o dyld preencher o slot com bind opcodes;
//   4. UNSIGNED em secao gravavel vira ponteiro absoluto + entrada de rebase (o
//      binario e PIE: sem rebase o ASLR quebraria o ponteiro);
//   5. assina ad-hoc (CS_SuperBlob + CS_CodeDirectory v0x20400, SHA-256 por
//      pagina de 4 KiB) — sem assinatura o kernel mata o processo.
//
// O layout de enderecos segue a mesma regra do `ld` (conferida com `otool -l`
// num executavel de referencia, ver docs/macho-notes.md): __PAGEZERO ocupa os
// primeiros 4 GiB, __TEXT comeca em 0x100000000 com o header e as load commands
// dentro dele, e cada segmento seguinte comeca na proxima pagina de 16 KiB tanto
// em VM quanto em arquivo (VM e arquivo andam separados porque zerofill ocupa VM
// e nao ocupa arquivo).
//
// Depende de arena.mc (buf_*, xalloc, die, io_write), de macho.mc (secoes,
// simbolos, relocacoes, sym_order), de gen_arm64.mc (gen_lower/gen_encode_all e
// ivec_at/set_ivec_at) e de sha256.mc.

#include "../lib/prelude.mc"

// muda o modo de um arquivo que ja existe: `creat` so aplica o modo quando cria,
// entao regravar um -o que ja estava la manteria a permissao antiga
extern i64 chmod(uptr path, i64 mode);

#define MODE_755 493                       // 0755 em decimal: nao ha literal octal

// ---- constantes de Mach-O que o MH_OBJECT nao usa ----
#define MH_EXECUTE   2
#define MH_NOUNDEFS  0x1
#define MH_DYLDLINK  0x4
#define MH_TWOLEVEL  0x80
#define MH_PIE       0x200000
#define EXE_FLAGS (MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE)

#define LC_REQ_DYLD       0x80000000
#define LC_DYLD_INFO_ONLY 0x80000022
#define LC_LOAD_DYLINKER  0xe
#define LC_UUID           0x1b
#define LC_MAIN           0x80000028
#define LC_LOAD_DYLIB     0xc
#define LC_CODE_SIGNATURE 0x1d

#define S_NON_LAZY_SYMBOL_POINTERS 6
#define S_SYMBOL_STUBS             8
#define STUB_FLAGS (S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)

#define EXE_BASE  0x100000000              // topo do __PAGEZERO
#define EXE_PAGE  16384                    // vm_page_size do arm64
#define CS_PAGE   4096                     // pagina de hash da assinatura
#define STUB_SIZE 12                        // adrp + ldr + br

#define N_DESC_ORD1 0x100                  // ordinal 1 (libSystem) em n_desc
#define DYLIB_HDR   24                     // bytes de LC_LOAD_DYLIB antes do nome

// opcodes de rebase/bind (mach-o/loader.h)
#define REBASE_SET_TYPE_IMM      0x10
#define REBASE_SET_SEG_ULEB      0x20
#define REBASE_DO_IMM_TIMES      0x50
#define BIND_SET_DYLIB_ORD_IMM   0x10
#define BIND_SET_SYMBOL_FLAGS    0x40
#define BIND_SET_TYPE_IMM        0x50
#define BIND_SET_SEG_ULEB        0x70
#define BIND_DO_BIND             0x90
#define TYPE_POINTER             1

// ---- assinatura ad-hoc ----
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_CODEDIRECTORY      0xfade0c02
#define CS_ADHOC                   0x2
#define CS_EXECSEG_MAIN_BINARY     0x1
#define CD_VERSION                 0x20400
#define CD_HEADER                  88       // bytes antes do identificador
#define CD_HASHTYPE_SHA256         2
#define CD_HASHSIZE                32

#define MAXXSEC  64                        // secoes do executavel (4 + #section + 2)
#define MAXXSEG  16                        // nomes de segmento distintos
#define MAXUNDEF 256                       // simbolos importados

// ---- tabela de secoes do executavel (ordem final = ordem no arquivo) ----
i64 xs_src[MAXXSEC];                       // indice em sections[]; -1 se sintetica
i64 xs_kind[MAXXSEC];                      // 0 = do modulo, 1 = __stubs, 2 = __got
i64 xs_addr[MAXXSEC];
i64 xs_off[MAXXSEC];
i64 xs_size[MAXXSEC];
i64 xs_seg[MAXXSEC];
i64 nxsec = 0;
i64 sec2x[MAXXSEC];                        // secao do modulo -> indice em xs_*

// ---- tabela de segmentos ----
uptr xg_name[MAXXSEG];
i64  xg_addr[MAXXSEG];
i64  xg_vmsize[MAXXSEG];
i64  xg_off[MAXXSEG];
i64  xg_fsize[MAXXSEG];
i64  nxseg = 0;

uptr xg_name_at(i64 i)            { return ld64(xg_name + i * 8); }
void set_xg_name_at(i64 i, uptr v) { st64(xg_name + i * 8, v); }

// ---- simbolos importados, na ordem de criacao ----
i64 undef_sym[MAXUNDEF];
i64 nundef = 0;

// ---- __LINKEDIT ----
u8  lk_rebase[BUF_SIZE];
u8  lk_bind[BUF_SIZE];
u8  lk_str[BUF_SIZE];
i64 rb_open = 0;                           // ja emitiu o SET_TYPE do rebase?
i64 bd_open = 0;                           // ja emitiu ordinal e tipo do bind?
i64 bd_ord = 0;                            // ordinal de dylib em vigor nos binds
i64 lk_off = 0;
i64 lk_addr = 0;
i64 stubs_addr = 0;
i64 got_addr = 0;
i64 got_seg = 0;

// ---- utilitarios ----
i64 exe_up(i64 v, i64 a) { return (v + a - 1) & ~(a - 1); }

// 16 bytes de nome de seg/secao preenchidos com zero
void exe_put_name(uptr o, uptr s) {
    i64 i = 0;
    while (i < 16) {
        if (i < cstrlen(s)) buf_u8(o, ld8(s + i));
        else                buf_u8(o, 0);
        i++;
    }
}

// campos da assinatura sao big-endian, ao contrario de todo o resto do Mach-O
void buf_be32(uptr b, i64 v) {
    buf_u8(b, (v >> 24) & 0xff);
    buf_u8(b, (v >> 16) & 0xff);
    buf_u8(b, (v >> 8) & 0xff);
    buf_u8(b, v & 0xff);
}

void buf_be64(uptr b, i64 v) {
    buf_be32(b, (v >> 32) & 0xffffffff);
    buf_be32(b, v & 0xffffffff);
}

// inteiro variavel little-endian de 7 bits por byte (formato dos opcodes do dyld)
void exe_uleb(uptr b, i64 v) {
    loop {
        i64 c = v & 0x7f;
        v = v >> 7;
        if (v == 0) {
            buf_u8(b, c);
            break;
        }
        buf_u8(b, c | 0x80);
    }
}

// os 16 bytes do segname de uma Section como string NUL-terminada
uptr exe_segname(uptr p16) {
    uptr s = xalloc(17);
    i64 i = 0;
    while (i < 16) {
        st8(s + i, ld8(p16 + i));
        i++;
    }
    st8(s + 16, 0);
    return s;
}

// ---- simbolos importados ----
void exe_collect_undef() {
    nundef = 0;
    i64 i = 0;
    while (i < nsymbols) {
        if (sym_sect(sym_at(i)) == 0) {
            if (nundef == MAXUNDEF) die("simbolos importados demais");
            set_ivec_at(undef_sym, nundef, i);
            nundef = nundef + 1;
        }
        i++;
    }
}

i64 exe_undef_index(i64 sym) {
    i64 i = 0;
    while (i < nundef) {
        if (ivec_at(undef_sym, i) == sym) return i;
        i++;
    }
    return -1;
}

// ---- segmentos e secoes ----
i64 exe_seg_find(uptr nm) {
    i64 i = 0;
    while (i < nxseg) {
        if (str_eq(xg_name_at(i), nm)) return i;
        i++;
    }
    return -1;
}

void exe_seg_add(uptr nm) {
    if (nxseg == MAXXSEG) die("segmentos demais no executavel");
    set_xg_name_at(nxseg, nm);
    nxseg = nxseg + 1;
}

void exe_add_sec(i64 src, i64 kind, i64 seg) {
    if (nxsec == MAXXSEC) die("secoes demais no executavel");
    set_ivec_at(xs_src, nxsec, src);
    set_ivec_at(xs_kind, nxsec, kind);
    set_ivec_at(xs_seg, nxsec, seg);
    if (src >= 0) set_ivec_at(sec2x, src, nxsec);
    nxsec = nxsec + 1;
}

i64 exe_sec_zf(i64 x) {
    i64 src = ivec_at(xs_src, x);
    if (src < 0) return 0;                        // as sinteticas sao sempre regulares
    return (sec_flags(sec_at(src)) & 0xff) == S_ZEROFILL;
}

i64 exe_sec_align(i64 x) {
    i64 k = ivec_at(xs_kind, x);
    if (k == 1) return 2;                         // instrucoes
    if (k == 2) return 3;                         // ponteiros de 8 bytes
    return sec_align(sec_at(ivec_at(xs_src, x)));
}

i64 exe_sec_size(i64 x) {
    i64 k = ivec_at(xs_kind, x);
    if (k == 1) return STUB_SIZE * nundef;
    if (k == 2) return 8 * nundef;
    uptr s = sec_at(ivec_at(xs_src, x));
    if ((sec_flags(s) & 0xff) == S_ZEROFILL) return sec_zsize(s);
    return buf_len(sec_data(s));
}

i64 exe_sec_flags(i64 x) {
    i64 k = ivec_at(xs_kind, x);
    if (k == 1) return STUB_FLAGS;
    if (k == 2) return S_NON_LAZY_SYMBOL_POINTERS;
    return sec_flags(sec_at(ivec_at(xs_src, x)));
}

i64 exe_seg_nsec(i64 g) {
    i64 n = 0;
    i64 x = 0;
    while (x < nxsec) {
        if (ivec_at(xs_seg, x) == g) n = n + 1;
        x++;
    }
    return n;
}

// Um segmento por nome de segname distinto, na ordem de primeira aparicao — como
// __TEXT,__text e sempre a primeira secao criada por gen_sections, __TEXT sai
// sempre no indice 0, que e o que o header exige. Dentro de cada segmento as
// regulares vem na ordem de criacao e as zerofill no fim, a mesma regra de
// macho_write. As duas sinteticas entram no fim das regulares do seu segmento.
void exe_plan_sections() {
    nxseg = 0;
    nxsec = 0;
    i64 i = 0;
    while (i < nsections) {
        uptr nm = exe_segname(sec_seg(sec_at(i)));
        if (exe_seg_find(nm) < 0) exe_seg_add(nm);
        i++;
    }
    if (nundef > 0 && exe_seg_find("__DATA") < 0) exe_seg_add("__DATA");
    i64 g = 0;
    while (g < nxseg) {
        uptr nm = xg_name_at(g);
        i64 pass = 0;
        while (pass < 2) {
            i = 0;
            while (i < nsections) {
                uptr s = sec_at(i);
                i64 zf = (sec_flags(s) & 0xff) == S_ZEROFILL;
                if (zf == pass && str_eq(exe_segname(sec_seg(s)), nm)) exe_add_sec(i, 0, g);
                i++;
            }
            if (pass == 0 && nundef > 0) {
                if (str_eq(nm, "__TEXT")) exe_add_sec(0 - 1, 1, g);
                if (str_eq(nm, "__DATA")) exe_add_sec(0 - 1, 2, g);
            }
            pass++;
        }
        g++;
    }
}

// LC_LOAD_DYLIB: cabecalho fixo + caminho com NUL, arredondado para 8
i64 exe_dylib_size(uptr path) { return exe_up(DYLIB_HDR + cstrlen(path) + 1, 8); }

// tamanho de todas as load commands: sabido antes do layout porque so depende do
// numero de segmentos, de secoes e de dylibs
i64 exe_sizeofcmds() {
    i64 n = 72;                                   // __PAGEZERO
    i64 g = 0;
    while (g < nxseg) {
        n = n + 72 + 80 * exe_seg_nsec(g);
        g++;
    }
    n = n + 72;                                   // __LINKEDIT
    n = n + 48;                                   // LC_DYLD_INFO_ONLY
    n = n + 24;                                   // LC_SYMTAB
    n = n + 80;                                   // LC_DYSYMTAB
    n = n + 32;                                   // LC_LOAD_DYLINKER
    n = n + 24;                                   // LC_UUID
    n = n + 24;                                   // LC_BUILD_VERSION
    n = n + 24;                                   // LC_MAIN
    n = n + exe_dylib_size("/usr/lib/libSystem.B.dylib");
    i64 dl = 0;                                   // uma LC_LOAD_DYLIB por #dylib
    while (dl < dylib_count()) {
        n = n + exe_dylib_size(dylib_path(dl));
        dl++;
    }
    n = n + 16;                                   // LC_CODE_SIGNATURE
    return n;
}

// enderecos finais: cada segmento comeca numa pagina de 16 KiB, em VM e em
// arquivo; dentro dele o cursor e o mesmo para os dois (por isso o offset de uma
// secao e sempre segoff + (addr - segvm)).
void exe_layout(i64 sizeofcmds) {
    i64 vm = EXE_BASE;
    i64 fo = 0;
    i64 g = 0;
    while (g < nxseg) {
        i64 segvm = vm;
        i64 segoff = fo;
        i64 cur = 0;
        if (g == 0) cur = 32 + sizeofcmds;        // o header mora dentro do __TEXT
        i64 fsz = 0;
        i64 pass = 0;
        while (pass < 2) {
            i64 x = 0;
            while (x < nxsec) {
                if (ivec_at(xs_seg, x) == g && exe_sec_zf(x) == pass) {
                    cur = exe_up(cur, 1 << exe_sec_align(x));
                    set_ivec_at(xs_addr, x, segvm + cur);
                    if (pass) set_ivec_at(xs_off, x, 0);
                    else      set_ivec_at(xs_off, x, segoff + cur);
                    set_ivec_at(xs_size, x, exe_sec_size(x));
                    cur = cur + exe_sec_size(x);
                }
                x++;
            }
            if (pass == 0) fsz = cur;
            pass++;
        }
        set_ivec_at(xg_addr, g, segvm);
        set_ivec_at(xg_off, g, segoff);
        set_ivec_at(xg_fsize, g, exe_up(fsz, EXE_PAGE));
        set_ivec_at(xg_vmsize, g, exe_up(cur, EXE_PAGE));
        vm = segvm + exe_up(cur, EXE_PAGE);
        fo = segoff + exe_up(fsz, EXE_PAGE);
        g++;
    }
    lk_off = fo;
    lk_addr = vm;
    stubs_addr = 0;
    got_addr = 0;
    i64 x = 0;
    while (x < nxsec) {
        if (ivec_at(xs_kind, x) == 1) stubs_addr = ivec_at(xs_addr, x);
        if (ivec_at(xs_kind, x) == 2) {
            got_addr = ivec_at(xs_addr, x);
            got_seg  = ivec_at(xs_seg, x);
        }
        x++;
    }
}

// ---- rebase e bind ----
void exe_rebase_add(i64 seg, i64 off) {
    if (seg > 15) die("segmentos demais para o opcode de rebase");
    if (!rb_open) {
        buf_u8(lk_rebase, REBASE_SET_TYPE_IMM | TYPE_POINTER);
        rb_open = 1;
    }
    buf_u8(lk_rebase, REBASE_SET_SEG_ULEB | seg);
    exe_uleb(lk_rebase, off);
    buf_u8(lk_rebase, REBASE_DO_IMM_TIMES | 1);
}

// ordinal da dylib de um simbolo importado: o nome do simbolo tem o `_` que o
// compilador poe, a tabela de #dylib e indexada pelo nome do fonte
i64 exe_sym_ord(uptr symname) { return extern_lib_find(symname + 1); }

void exe_bind_add(i64 seg, i64 off, uptr name, i64 ord) {
    if (seg > 15) die("segmentos demais para o opcode de bind");
    if (ord > 15) die("dylibs demais para o opcode de bind");
    if (!bd_open) {
        buf_u8(lk_bind, BIND_SET_DYLIB_ORD_IMM | ord);
        buf_u8(lk_bind, BIND_SET_TYPE_IMM | TYPE_POINTER);
        bd_open = 1;
        bd_ord = ord;
    } else if (ord != bd_ord) {
        buf_u8(lk_bind, BIND_SET_DYLIB_ORD_IMM | ord);    // trocou de dylib
        bd_ord = ord;
    }
    buf_u8(lk_bind, BIND_SET_SYMBOL_FLAGS);
    buf_put(lk_bind, name, cstrlen(name) + 1);
    buf_u8(lk_bind, BIND_SET_SEG_ULEB | seg);
    exe_uleb(lk_bind, off);
    buf_u8(lk_bind, BIND_DO_BIND);
}

// ---- relocacoes ----
// endereco final de um simbolo; um importado nao tem endereco proprio, entao vale
// o do seu stub — e assim que `&write` passa a funcionar no executavel direto
i64 exe_sym_addr(i64 sym) {
    uptr s = sym_at(sym);
    if (sym_sect(s) == 0) return stubs_addr + exe_undef_index(sym) * STUB_SIZE;
    return ivec_at(xs_addr, ivec_at(sec2x, sym_sect(s) - 1)) + sym_value(s);
}

void exe_fix_branch26(uptr p, i64 at, i64 pc, i64 target) {
    i64 d = target - pc;
    if (d % 4 != 0) die("destino de bl desalinhado");
    if (d >= 128 * 1024 * 1024 || d < 0 - 128 * 1024 * 1024) die("bl longe demais");
    st32(p + at, (ld32(p + at) & ~0x3ffffff) | ((d / 4) & 0x3ffffff));
}

void exe_fix_page21(uptr p, i64 at, i64 pc, i64 target) {
    i64 im = ((target & ~4095) - (pc & ~4095)) / 4096;
    i64 w = ld32(p + at) & ~((3 << 29) | (0x7ffff << 5));
    st32(p + at, w | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5));
}

// o imediato de 12 bits do `add` e o proprio deslocamento; o de um ldr/str com
// deslocamento sem sinal e escalado pela largura do acesso (bits 31:30)
void exe_fix_pageoff12(uptr p, i64 at, i64 target) {
    i64 w = ld32(p + at);
    i64 sc = 0;
    if ((w & 0x3b000000) == 0x39000000) sc = (w >> 30) & 3;
    i64 lo = target & 4095;
    if (lo % (1 << sc) != 0) die("pageoff12 desalinhado para a largura do acesso");
    st32(p + at, (w & ~(0xfff << 10)) | (((lo >> sc) & 0xfff) << 10));
}

void exe_fix_unsigned(i64 x, uptr p, uptr r) {
    i64 seg = ivec_at(xs_seg, x);
    i64 at = rel_off(r);
    i64 off = ivec_at(xs_addr, x) - ivec_at(xg_addr, seg) + at;
    i64 sym = rel_sym(r);
    if (rel_len(r) != 3) die("UNSIGNED que nao ocupa 8 bytes");
    if (str_eq(xg_name_at(seg), "__TEXT"))
        die("ponteiro relocado em __TEXT: o segmento e r-x e o dyld nao o rebasa");
    if (sym_sect(sym_at(sym)) == 0) {
        st64(p + at, 0);                            // o dyld escreve o endereco importado
        uptr nm = sym_name(sym_at(sym));
        exe_bind_add(seg + 1, off, nm, exe_sym_ord(nm));
    } else {
        st64(p + at, exe_sym_addr(sym));            // endereco sem o slide do ASLR
        exe_rebase_add(seg + 1, off);               // ... que o dyld soma no rebase
    }
}

void exe_patch_relocs() {
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if ((sec_flags(s) & 0xff) != S_ZEROFILL) {
            i64 x = ivec_at(sec2x, i);
            uptr p = buf_p(sec_data(s));
            i64 j = 0;
            while (j < sec_nrel(s)) {
                uptr r = rel_at(sec_rel(s), j);
                i64 t = rel_type(r);
                i64 pc = ivec_at(xs_addr, x) + rel_off(r);
                if (t == R_BRANCH26)        exe_fix_branch26(p, rel_off(r), pc, exe_sym_addr(rel_sym(r)));
                else if (t == R_PAGE21)     exe_fix_page21(p, rel_off(r), pc, exe_sym_addr(rel_sym(r)));
                else if (t == R_PAGEOFF12)  exe_fix_pageoff12(p, rel_off(r), exe_sym_addr(rel_sym(r)));
                else if (t == R_UNSIGNED)   exe_fix_unsigned(x, p, r);
                else die("relocacao sem suporte no executavel direto");
                j++;
            }
        }
        i++;
    }
}

// ---- conteudo sintetico ----
// stub k: adrp x16, pagina do slot; ldr x16, [x16, #off]; br x16
void exe_put_stubs(uptr o) {
    i64 k = 0;
    while (k < nundef) {
        i64 pc = stubs_addr + k * STUB_SIZE;
        i64 slot = got_addr + k * 8;
        i64 im = ((slot & ~4095) - (pc & ~4095)) / 4096;
        buf_u32(o, 0x90000010 | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5));
        buf_u32(o, 0xF9400210 | (((slot & 4095) / 8) << 10));
        buf_u32(o, 0xD61F0200);
        k++;
    }
}

// os slots do __got saem zerados: quem os preenche e o dyld, pelos bind opcodes
void exe_put_got(uptr o) {
    i64 k = 0;
    while (k < nundef) {
        buf_u64(o, 0);
        k++;
    }
}

// um bind por slot do __got, na ordem dos simbolos importados
void exe_bind_got() {
    i64 k = 0;
    while (k < nundef) {
        i64 off = got_addr + k * 8 - ivec_at(xg_addr, got_seg);
        uptr nm = sym_name(sym_at(ivec_at(undef_sym, k)));
        exe_bind_add(got_seg + 1, off, nm, exe_sym_ord(nm));
        k++;
    }
}

// ---- load commands ----
void exe_seg_cmd(uptr o, uptr nm, i64 vmaddr, i64 vmsize, i64 fileoff, i64 filesize,
                 i64 prot, i64 nsects) {
    buf_u32(o, LC_SEGMENT_64);
    buf_u32(o, 72 + 80 * nsects);
    exe_put_name(o, nm);
    buf_u64(o, vmaddr);
    buf_u64(o, vmsize);
    buf_u64(o, fileoff);
    buf_u64(o, filesize);
    buf_u32(o, prot);
    buf_u32(o, prot);
    buf_u32(o, nsects);
    buf_u32(o, 0);
}

void exe_sec_hdr(uptr o, i64 x) {
    i64 src = ivec_at(xs_src, x);
    i64 kind = ivec_at(xs_kind, x);
    if (src >= 0) {
        buf_put(o, sec_sect(sec_at(src)), 16);
        buf_put(o, sec_seg(sec_at(src)), 16);
    } else if (kind == 1) {
        exe_put_name(o, "__stubs");
        exe_put_name(o, "__TEXT");
    } else {
        exe_put_name(o, "__got");
        exe_put_name(o, "__DATA");
    }
    buf_u64(o, ivec_at(xs_addr, x));
    buf_u64(o, ivec_at(xs_size, x));
    buf_u32(o, ivec_at(xs_off, x));
    buf_u32(o, exe_sec_align(x));
    buf_u32(o, 0);                                  // reloff: nao ha, ja foram resolvidas
    buf_u32(o, 0);                                  // nreloc
    buf_u32(o, exe_sec_flags(x));
    // reserved1 e o indice na tabela de simbolos indiretos; reserved2 o tamanho
    // do stub. A tabela tem os importados duas vezes: primeiro para __stubs,
    // depois para __got, na mesma ordem em que saem no arquivo.
    if (kind == 1)      { buf_u32(o, 0);      buf_u32(o, STUB_SIZE); }
    else if (kind == 2) { buf_u32(o, nundef); buf_u32(o, 0); }
    else                { buf_u32(o, 0);      buf_u32(o, 0); }
    buf_u32(o, 0);
}

void exe_dylinker(uptr o) {
    buf_u32(o, LC_LOAD_DYLINKER);
    buf_u32(o, 32);
    buf_u32(o, 12);                                 // offset do nome
    buf_put(o, "/usr/lib/dyld", 14);
    buf_pad(o, 8);
}

void exe_dylib_one(uptr o, uptr path) {
    buf_u32(o, LC_LOAD_DYLIB);
    buf_u32(o, exe_dylib_size(path));
    buf_u32(o, DYLIB_HDR);                          // offset do nome
    buf_u32(o, 2);                                  // timestamp fixo (determinismo)
    buf_u32(o, 0x054C0000);                         // current 1356.0.0
    buf_u32(o, 0x00010000);                         // compatibility 1.0.0
    buf_put(o, path, cstrlen(path) + 1);
    buf_pad(o, 8);
}

// a libSystem e sempre a primeira (ordinal 1); depois as de #dylib, na ordem de
// registro — e a ordem que define o ordinal que n_desc e os binds citam
void exe_dylib(uptr o) {
    exe_dylib_one(o, "/usr/lib/libSystem.B.dylib");
    i64 i = 0;
    while (i < dylib_count()) {
        exe_dylib_one(o, dylib_path(i));
        i++;
    }
}

// ---- symtab ----
// numero da secao (1-based na ordem final) e endereco absoluto de um simbolo
void exe_symtab(uptr o, uptr order, uptr strx) {
    i64 k = 0;
    while (k < nsymbols) {
        i64 oi = ivec_at(order, k);
        uptr s = sym_at(oi);
        buf_u32(o, ivec_at(strx, oi));
        if (sym_sect(s) == 0) {
            buf_u8(o, N_UNDF | N_EXT);
            buf_u8(o, 0);
            buf_u16(o, N_DESC_ORD1 * exe_sym_ord(sym_name(s)));  // two-level: ordinal
            buf_u64(o, 0);
        } else {
            i64 x = ivec_at(sec2x, sym_sect(s) - 1);
            if (sym_global(s)) buf_u8(o, N_SECT | N_EXT);
            else               buf_u8(o, N_SECT);
            buf_u8(o, x + 1);
            buf_u16(o, 0);
            buf_u64(o, ivec_at(xs_addr, x) + sym_value(s));
        }
        k++;
    }
}

void exe_indirect(uptr o, uptr pos) {
    i64 pass = 0;
    while (pass < 2) {                              // __stubs e depois __got
        i64 k = 0;
        while (k < nundef) {
            buf_u32(o, ivec_at(pos, ivec_at(undef_sym, k)));
            k++;
        }
        pass++;
    }
}

// ---- assinatura ad-hoc ----
// nome do arquivo de saida sem diretorio: e o identificador que `codesign -dvvv`
// mostra e o unico texto livre da assinatura
uptr exe_ident(uptr path) {
    i64 last = 0;
    i64 i = 0;
    while (ld8(path + i)) {
        if (ld8(path + i) == '/') last = i + 1;
        i++;
    }
    return path + last;
}

// CS_SuperBlob com um unico CS_CodeDirectory; tudo big-endian
void exe_sig(uptr o, uptr ident, i64 codelimit, i64 nslots, i64 texts, i64 textlim, uptr hashes) {
    i64 idlen = cstrlen(ident) + 1;
    i64 cdlen = CD_HEADER + idlen + CD_HASHSIZE * nslots;
    buf_be32(o, CSMAGIC_EMBEDDED_SIGNATURE);
    buf_be32(o, 20 + cdlen);
    buf_be32(o, 1);                                 // um blob
    buf_be32(o, 0);                                 // CSSLOT_CODEDIRECTORY
    buf_be32(o, 20);                                // offset do blob
    buf_be32(o, CSMAGIC_CODEDIRECTORY);
    buf_be32(o, cdlen);
    buf_be32(o, CD_VERSION);
    buf_be32(o, CS_ADHOC);
    buf_be32(o, CD_HEADER + idlen);                 // hashOffset
    buf_be32(o, CD_HEADER);                         // identOffset
    buf_be32(o, 0);                                 // nSpecialSlots
    buf_be32(o, nslots);
    buf_be32(o, codelimit);
    buf_u8(o, CD_HASHSIZE);
    buf_u8(o, CD_HASHTYPE_SHA256);
    buf_u8(o, 0);                                   // platform
    buf_u8(o, 12);                                  // pageSize: 1 << 12 = 4 KiB
    buf_be32(o, 0);                                 // spare2
    buf_be32(o, 0);                                 // scatterOffset
    buf_be32(o, 0);                                 // teamOffset
    buf_be32(o, 0);                                 // spare3
    buf_be64(o, 0);                                 // codeLimit64
    buf_be64(o, texts);                             // execSegBase
    buf_be64(o, textlim);                           // execSegLimit
    buf_be64(o, CS_EXECSEG_MAIN_BINARY);            // execSegFlags
    buf_put(o, ident, idlen);
    buf_put(o, hashes, CD_HASHSIZE * nslots);
}

// ---- escrita ----
void exe_write_file(uptr path, uptr b) {
    i64 fd = creat(path, MODE_755);
    if (fd < 0) die2("cannot create", path);
    io_write(fd, buf_p(b), buf_len(b));
    close(fd);
    chmod(path, MODE_755);                          // creat so aplica o modo ao criar
}

void exe_write(uptr path) {
    exe_collect_undef();
    exe_plan_sections();
    i64 sizeofcmds = exe_sizeofcmds();
    exe_layout(sizeofcmds);

    buf_init(lk_rebase);
    buf_init(lk_bind);
    buf_init(lk_str);
    rb_open = 0;
    bd_open = 0;
    exe_bind_got();
    exe_patch_relocs();
    if (rb_open) buf_u8(lk_rebase, 0);              // REBASE_OPCODE_DONE
    if (bd_open) buf_u8(lk_bind, 0);                // BIND_OPCODE_DONE

    uptr order = xalloc(8 * (nsymbols + 1));
    uptr pos   = xalloc(8 * (nsymbols + 1));
    u8   count[24];
    sym_order(order, pos, count);
    uptr strx = xalloc(8 * (nsymbols + 1));
    buf_u8(lk_str, 0);
    i64 k = 0;
    while (k < nsymbols) {
        set_ivec_at(strx, k, buf_len(lk_str));
        buf_put(lk_str, sym_name(sym_at(k)), cstrlen(sym_name(sym_at(k))) + 1);
        k++;
    }
    buf_pad(lk_str, 8);

    i64 rebase_off = lk_off;
    i64 bind_off   = exe_up(rebase_off + buf_len(lk_rebase), 8);
    i64 symoff     = exe_up(bind_off + buf_len(lk_bind), 8);
    i64 indoff     = symoff + 16 * nsymbols;
    i64 stroff     = indoff + 4 * 2 * nundef;
    i64 sigoff     = exe_up(stroff + buf_len(lk_str), 16);
    i64 nslots     = (sigoff + CS_PAGE - 1) / CS_PAGE;
    uptr ident     = exe_ident(path);
    i64 siglen     = 20 + CD_HEADER + cstrlen(ident) + 1 + CD_HASHSIZE * nslots;

    i64 msym = sym_find("_main");
    if (msym < 0 || sym_sect(sym_at(msym)) == 0) die("sem _main: nao da para gerar executavel");

    u8 o[BUF_SIZE];
    buf_init(o);
    buf_u32(o, MH_MAGIC_64);
    buf_u32(o, CPU_TYPE_ARM64);
    buf_u32(o, 0);
    buf_u32(o, MH_EXECUTE);
    buf_u32(o, nxseg + 11 + dylib_count());
    buf_u32(o, sizeofcmds);
    buf_u32(o, EXE_FLAGS);
    buf_u32(o, 0);

    exe_seg_cmd(o, "__PAGEZERO", 0, EXE_BASE, 0, 0, 0, 0);
    i64 g = 0;
    while (g < nxseg) {
        i64 prot = 3;                               // rw-
        if (str_eq(xg_name_at(g), "__TEXT")) prot = 5;
        exe_seg_cmd(o, xg_name_at(g), ivec_at(xg_addr, g), ivec_at(xg_vmsize, g),
                    ivec_at(xg_off, g), ivec_at(xg_fsize, g), prot, exe_seg_nsec(g));
        i64 x = 0;
        while (x < nxsec) {
            if (ivec_at(xs_seg, x) == g) exe_sec_hdr(o, x);
            x++;
        }
        g++;
    }
    exe_seg_cmd(o, "__LINKEDIT", lk_addr, exe_up(sigoff + siglen - lk_off, EXE_PAGE),
                lk_off, sigoff + siglen - lk_off, 1, 0);

    buf_u32(o, LC_DYLD_INFO_ONLY);
    buf_u32(o, 48);
    buf_u32(o, rebase_off);
    buf_u32(o, buf_len(lk_rebase));
    buf_u32(o, bind_off);
    buf_u32(o, buf_len(lk_bind));
    buf_u32(o, 0); buf_u32(o, 0);                   // weak bind
    buf_u32(o, 0); buf_u32(o, 0);                   // lazy bind: tudo e bind imediato
    buf_u32(o, 0); buf_u32(o, 0);                   // export trie: executavel nao exporta

    buf_u32(o, LC_SYMTAB);
    buf_u32(o, 24);
    buf_u32(o, symoff);
    buf_u32(o, nsymbols);
    buf_u32(o, stroff);
    buf_u32(o, buf_len(lk_str));

    buf_u32(o, LC_DYSYMTAB);
    buf_u32(o, 80);
    buf_u32(o, 0);                buf_u32(o, ivec_at(count, 0));
    buf_u32(o, ivec_at(count, 0)); buf_u32(o, ivec_at(count, 1));
    buf_u32(o, ivec_at(count, 0) + ivec_at(count, 1)); buf_u32(o, ivec_at(count, 2));
    buf_u32(o, 0); buf_u32(o, 0);                   // toc
    buf_u32(o, 0); buf_u32(o, 0);                   // modtab
    buf_u32(o, 0); buf_u32(o, 0);                   // extrefsyms
    buf_u32(o, indoff); buf_u32(o, 2 * nundef);
    buf_u32(o, 0); buf_u32(o, 0);                   // extrel
    buf_u32(o, 0); buf_u32(o, 0);                   // locrel

    exe_dylinker(o);
    buf_u32(o, LC_UUID);
    buf_u32(o, 24);
    i64 uuid_off = buf_len(o);                      // preenchido depois: e hash do arquivo
    i64 i = 0;
    while (i < 16) {
        buf_u8(o, 0);
        i++;
    }
    buf_u32(o, LC_BUILD_VERSION);
    buf_u32(o, 24);
    buf_u32(o, 1);                                  // platform macOS
    buf_u32(o, 0x000D0000);                         // minos 13.0.0
    buf_u32(o, 0x000D0000);                         // sdk 13.0.0
    buf_u32(o, 0);                                  // ntools
    buf_u32(o, LC_MAIN);
    buf_u32(o, 24);
    buf_u64(o, exe_sym_addr(msym) - EXE_BASE);      // entryoff: dyld chama _main
    buf_u64(o, 0);                                  // stacksize: default
    exe_dylib(o);
    buf_u32(o, LC_CODE_SIGNATURE);
    buf_u32(o, 16);
    buf_u32(o, sigoff);
    buf_u32(o, siglen);

    i64 x = 0;                                      // dados das secoes
    while (x < nxsec) {
        if (!exe_sec_zf(x)) {
            while (buf_len(o) < ivec_at(xs_off, x)) {
                buf_u8(o, 0);
            }
            i64 kind = ivec_at(xs_kind, x);
            if (kind == 1)      exe_put_stubs(o);
            else if (kind == 2) exe_put_got(o);
            else {
                uptr s = sec_at(ivec_at(xs_src, x));
                buf_put(o, buf_p(sec_data(s)), buf_len(sec_data(s)));
            }
        }
        x++;
    }
    while (buf_len(o) < rebase_off) {
        buf_u8(o, 0);
    }
    buf_put(o, buf_p(lk_rebase), buf_len(lk_rebase));
    while (buf_len(o) < bind_off) {
        buf_u8(o, 0);
    }
    buf_put(o, buf_p(lk_bind), buf_len(lk_bind));
    while (buf_len(o) < symoff) {
        buf_u8(o, 0);
    }
    exe_symtab(o, order, strx);
    exe_indirect(o, pos);
    buf_put(o, buf_p(lk_str), buf_len(lk_str));
    while (buf_len(o) < sigoff) {
        buf_u8(o, 0);
    }

    // o UUID e o SHA-256 do arquivo inteiro sem ele: deterministico e sem data
    u8 dig[32];
    sha256(buf_p(o), sigoff, dig);
    i = 0;
    while (i < 16) {
        st8(buf_p(o) + uuid_off + i, ld8(dig + i));
        i++;
    }
    st8(buf_p(o) + uuid_off + 6, (ld8(dig + 6) & 0x0f) | 0x50);   // versao 5
    st8(buf_p(o) + uuid_off + 8, (ld8(dig + 8) & 0x3f) | 0x80);   // variante RFC 4122

    // hashes de todas as paginas antes de escrever qualquer byte da assinatura:
    // buf_put pode realocar o buffer e mover buf_p(o)
    uptr hashes = xalloc(CD_HASHSIZE * nslots + CD_HASHSIZE);
    i = 0;
    while (i < nslots) {
        i64 n = CS_PAGE;
        if (i * CS_PAGE + n > sigoff) n = sigoff - i * CS_PAGE;
        sha256(buf_p(o) + i * CS_PAGE, n, hashes + i * CD_HASHSIZE);
        i++;
    }
    exe_sig(o, ident, sigoff, nslots, ivec_at(xg_off, 0), ivec_at(xg_fsize, 0), hashes);
    exe_write_file(path, o);
}

// o backend em si: a mesma baixada e o mesmo encoder do backend `macho`, so a
// escrita e outra
void backend_exe(i64 root, uptr out) {
    gen_lower(root);
    gen_encode_all();
    exe_write(out);
}

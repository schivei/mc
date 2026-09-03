/* macho.c — modelo de objeto (secoes, simbolos, relocacoes) e escrita de MH_OBJECT arm64.
 * Todo campo e escrito byte a byte em little-endian; nada de fwrite(&struct). */
#include "mc.h"

Section *sections; int nsections; static int seccap;
Symbol  *symbols;  int nsymbols;  static int symcap;

static void name16(char *dst, const char *s) {
    int i = 0;
    for (; i < 16 && s[i]; i++) dst[i] = s[i];
    for (; i < 16; i++) dst[i] = 0;
}

int sec_new(const char *seg, const char *sect, u32 flags, u32 align) {
    int i = sec_find(seg, sect);
    if (i >= 0) return i;
    if (nsections == seccap) {
        seccap = seccap ? seccap * 2 : 8;
        Section *n = xalloc(sizeof(Section) * (size_t)seccap);
        for (int k = 0; k < nsections; k++) n[k] = sections[k];
        sections = n;
    }
    Section *s = &sections[nsections];
    *s = (Section){0};
    name16(s->seg, seg); name16(s->sect, sect);
    s->flags = flags; s->align = align;
    return nsections++;
}
int sec_find(const char *seg, const char *sect) {
    char a[16], b[16];
    name16(a, seg); name16(b, sect);
    for (int i = 0; i < nsections; i++) {
        bool eq = true;
        for (int k = 0; k < 16; k++)
            if (sections[i].seg[k] != a[k] || sections[i].sect[k] != b[k]) { eq = false; break; }
        if (eq) return i;
    }
    return -1;
}

int sym_find(const char *name) {
    for (int i = 0; i < nsymbols; i++)
        if (str_eq(symbols[i].name, name)) return i;
    return -1;
}
int sym_new(const char *name, int sect, u64 value, bool global) {
    int i = sym_find(name);
    if (i >= 0) {
        if (symbols[i].sect != 0 && sect != 0) die2("duplicate symbol", name);
        if (sect != 0) { symbols[i].sect = sect; symbols[i].value = value; symbols[i].global = global; }
        return i;
    }
    if (nsymbols == symcap) {
        symcap = symcap ? symcap * 2 : 64;
        Symbol *n = xalloc(sizeof(Symbol) * (size_t)symcap);
        for (int k = 0; k < nsymbols; k++) n[k] = symbols[k];
        symbols = n;
    }
    symbols[nsymbols] = (Symbol){ name, sect, value, global };
    return nsymbols++;
}
int sym_ref(const char *name) {
    int i = sym_find(name);
    return i >= 0 ? i : sym_new(name, 0, 0, true);
}

/* o endereco de uma funcao so existe depois de encodar: gen_lower cria o
 * simbolo (fixando a ordem da symtab) e gen_encode_all preenche o valor */
void sym_set_value(int sym, u64 value) { symbols[sym].value = value; }

void reloc_add(int sec, u32 off, int sym, int type, int pcrel, int len) {
    Section *s = &sections[sec];
    if (s->nrel == s->relcap) {
        s->relcap = s->relcap ? s->relcap * 2 : 16;
        Reloc *n = xalloc(sizeof(Reloc) * (size_t)s->relcap);
        for (int k = 0; k < s->nrel; k++) n[k] = s->rel[k];
        s->rel = n;
    }
    s->rel[s->nrel++] = (Reloc){ off, sym, (u8)type, (u8)pcrel, (u8)len };
}

/* ---- escrita ---- */
#define MH_MAGIC_64      0xfeedfacfu
#define CPU_TYPE_ARM64   0x0100000Cu
#define MH_OBJECT        1
#define MH_SUBSECTIONS_VIA_SYMBOLS 0x2000u
#define LC_SEGMENT_64    0x19
#define LC_SYMTAB        0x2
#define LC_DYSYMTAB      0xb
#define LC_BUILD_VERSION 0x32
#define N_EXT  0x01
#define N_UNDF 0x00
#define N_SECT 0x0e

static int sym_class(const Symbol *s) { return s->sect == 0 ? 2 : (s->global ? 1 : 0); }

/* ordem final da symtab: locais, externos definidos, indefinidos (particao estavel) */
void sym_order(int *order, int *pos, int *count) {
    int n = 0;
    count[0] = 0; count[1] = 0; count[2] = 0;
    for (int c = 0; c < 3; c++)
        for (int i = 0; i < nsymbols; i++)
            if (sym_class(&symbols[i]) == c) { pos[i] = n; order[n++] = i; count[c]++; }
}

/* nomes de seg/sect ocupam 16 bytes preenchidos com zero e podem nao ter NUL */
static void out_name16(const char *p) {
    int n = 0;
    while (n < 16 && p[n]) n++;
    out_bytes(1, p, (size_t)n);
}

/* --dump-syms: as secoes na ordem de criacao e os simbolos na ordem final da symtab */
void dump_syms(void) {
    for (int i = 0; i < nsections; i++) {
        Section *s = &sections[i];
        bool zf = (s->flags & 0xff) == S_ZEROFILL;
        out_str(1, "section "); out_name16(s->seg); out_str(1, ","); out_name16(s->sect);
        out_str(1, " flags="); out_hex(1, s->flags);
        out_str(1, " align="); out_num(1, s->align);
        out_str(1, " size="); out_num(1, (i64)(zf ? s->zsize : s->data.len));
        out_str(1, " nreloc="); out_num(1, s->nrel);
        out_str(1, "\n");
    }
    int *order = xalloc(sizeof(int) * (size_t)(nsymbols + 1));
    int *pos   = xalloc(sizeof(int) * (size_t)(nsymbols + 1));
    int count[3];
    sym_order(order, pos, count);
    for (int k = 0; k < nsymbols; k++) {
        Symbol *s = &symbols[order[k]];
        out_str(1, "sym "); out_num(1, k); out_str(1, " ");
        out_str(1, s->sect == 0 ? "undef" : (s->global ? "extern" : "local"));
        out_str(1, " sect="); out_num(1, s->sect);
        out_str(1, " value="); out_num(1, (i64)s->value);
        out_str(1, " "); out_str(1, s->name); out_str(1, "\n");
    }
}

void macho_write(const char *path) {
    int *order = xalloc(sizeof(int) * (size_t)(nsymbols + 1));
    int *pos   = xalloc(sizeof(int) * (size_t)(nsymbols + 1));
    int count[3];
    sym_order(order, pos, count);

    /* layout de enderecos: secoes regulares primeiro, zerofill por ultimo */
    u64 *addr = xalloc(sizeof(u64) * (size_t)(nsections + 1));
    u64 vm = 0, filesz = 0;
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < nsections; i++) {
            Section *s = &sections[i];
            bool zf = (s->flags & 0xff) == S_ZEROFILL;
            if (zf != (pass == 1)) continue;
            u64 al = 1ull << s->align;
            vm = (vm + al - 1) & ~(al - 1);
            addr[i] = vm;
            vm += zf ? s->zsize : s->data.len;
            if (!zf) filesz = vm;
        }

    u32 ncmds = 4;
    u32 sizeofcmds = 72 + 80 * (u32)nsections + 24 + 24 + 80;
    u32 dataoff = 32 + sizeofcmds;
    u32 reloff = dataoff + (u32)filesz;
    reloff = (reloff + 7) & ~7u;
    u32 nreloc_total = 0;
    for (int i = 0; i < nsections; i++) nreloc_total += (u32)sections[i].nrel;
    u32 symoff = reloff + 8 * nreloc_total;
    u32 stroff = symoff + 16 * (u32)nsymbols;

    /* string table */
    Buf str = {0};
    buf_u8(&str, 0);
    u32 *strx = xalloc(sizeof(u32) * (size_t)(nsymbols + 1));
    for (int k = 0; k < nsymbols; k++) {
        strx[k] = (u32)str.len;
        buf_put(&str, symbols[k].name, cstrlen(symbols[k].name) + 1);
    }
    buf_pad(&str, 8);

    Buf o = {0};
    buf_u32(&o, MH_MAGIC_64); buf_u32(&o, CPU_TYPE_ARM64); buf_u32(&o, 0);
    buf_u32(&o, MH_OBJECT); buf_u32(&o, ncmds); buf_u32(&o, sizeofcmds);
    buf_u32(&o, MH_SUBSECTIONS_VIA_SYMBOLS); buf_u32(&o, 0);

    buf_u32(&o, LC_SEGMENT_64); buf_u32(&o, 72 + 80 * (u32)nsections);
    buf_put(&o, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0", 16);
    buf_u64(&o, 0); buf_u64(&o, vm); buf_u64(&o, dataoff); buf_u64(&o, filesz);
    buf_u32(&o, 7); buf_u32(&o, 7); buf_u32(&o, (u32)nsections); buf_u32(&o, 0);
    u32 roff = reloff;
    for (int i = 0; i < nsections; i++) {
        Section *s = &sections[i];
        bool zf = (s->flags & 0xff) == S_ZEROFILL;
        buf_put(&o, s->sect, 16); buf_put(&o, s->seg, 16);
        buf_u64(&o, addr[i]); buf_u64(&o, zf ? s->zsize : s->data.len);
        buf_u32(&o, zf ? 0 : dataoff + (u32)addr[i]); buf_u32(&o, s->align);
        buf_u32(&o, s->nrel ? roff : 0); buf_u32(&o, (u32)s->nrel); buf_u32(&o, s->flags);
        buf_u32(&o, 0); buf_u32(&o, 0); buf_u32(&o, 0);
        roff += 8 * (u32)s->nrel;
    }
    buf_u32(&o, LC_BUILD_VERSION); buf_u32(&o, 24);
    buf_u32(&o, 1); buf_u32(&o, 0x000D0000); buf_u32(&o, 0x000D0000); buf_u32(&o, 0);
    buf_u32(&o, LC_SYMTAB); buf_u32(&o, 24);
    buf_u32(&o, symoff); buf_u32(&o, (u32)nsymbols); buf_u32(&o, stroff); buf_u32(&o, (u32)str.len);
    buf_u32(&o, LC_DYSYMTAB); buf_u32(&o, 80);
    buf_u32(&o, 0); buf_u32(&o, (u32)count[0]);
    buf_u32(&o, (u32)count[0]); buf_u32(&o, (u32)count[1]);
    buf_u32(&o, (u32)(count[0] + count[1])); buf_u32(&o, (u32)count[2]);
    for (int k = 0; k < 12; k++) buf_u32(&o, 0);

    /* dados das secoes */
    for (int i = 0; i < nsections; i++) {
        Section *s = &sections[i];
        if ((s->flags & 0xff) == S_ZEROFILL) continue;
        while (o.len < dataoff + addr[i]) buf_u8(&o, 0);
        buf_put(&o, s->data.p, s->data.len);
    }
    while (o.len < reloff) buf_u8(&o, 0);
    /* relocacoes: ordem decrescente de endereco, como o clang faz */
    for (int i = 0; i < nsections; i++) {
        Section *s = &sections[i];
        for (int k = s->nrel - 1; k >= 0; k--) {
            Reloc *r = &s->rel[k];
            u32 symnum = r->type == R_ADDEND ? (u32)r->sym : (u32)pos[r->sym];
            u32 ext    = r->type == R_ADDEND ? 0 : 1;
            buf_u32(&o, r->off);
            buf_u32(&o, (symnum & 0xffffff) | ((u32)r->pcrel << 24) | ((u32)r->len << 25)
                        | (ext << 27) | ((u32)r->type << 28));
        }
    }
    /* symtab */
    for (int k = 0; k < nsymbols; k++) {
        Symbol *s = &symbols[order[k]];
        buf_u32(&o, strx[order[k]]);
        buf_u8(&o, s->sect == 0 ? (N_UNDF | N_EXT) : (u8)(N_SECT | (s->global ? N_EXT : 0)));
        buf_u8(&o, (u8)s->sect);
        buf_u16(&o, 0);
        buf_u64(&o, s->sect == 0 ? 0 : addr[s->sect - 1] + s->value);
    }
    buf_put(&o, str.p, str.len);
    write_file(path, &o);
}

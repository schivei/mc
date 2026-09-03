// expect-exit: 42
// #section escolhe a secao das funcoes e globais seguintes. __DATA,__tbl nao e
// zerofill: o array ocupa bytes de verdade no arquivo. __DATA,__zt e zerofill
// (flags & 0xff == 1): so conta zsize. #section sem argumentos volta ao default.

#section __DATA __tbl 0 3
u64 tbl[4];

#section __DATA __zt 1 4
u64 zt[2];

#section __TEXT __hot 0x80000400 2
i64 hot(i64 x) {
    return x + 2;
}

#section
i64 base = 30;                          // volta ao default: __DATA,__data

i64 main() {
    if (ld64(zt) != 0) return 1;        // zerofill chega zerado
    if (ld64(tbl + 8) != 0) return 2;   // secao custom regular tambem chega zerada
    st64(zt, 4);
    st64(tbl, base + ld64(zt));         // 34
    return hot(ld64(tbl) + 6);          // 34 + 6 + 2
}

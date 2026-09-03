// 056-gensym-nocapture.mc — o gensym de #rule nao pode capturar nome do usuario.
// A regra declara `$$t` no MESMO bloco de quem a chamou (o template nao abre
// `{ }`), entao o local escondido convive com os locais de main. Antes do M10 o
// gensym se chamava `__g1` e a expansao roubava o `__g1` do usuario, fazendo
// este teste devolver 1; hoje ele se chama `$g1` e a colisao e impossivel
// (o lexer nunca forma um identificador com `$`).
// expect-exit: 42

#rule stmt: mk ( expr $v ) ;
    => i64 $$t = $v;

i64 main() {
    i64 __g1 = 42;
    mk(1);                 // declara um local escondido, sem bloco proprio
    return __g1;           // tem de continuar 42
}

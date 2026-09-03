// expect-exit: 42
// expect-stdout: 10,7,8,7,
// Compostos do prelude: `+=`, `-=`, `++`, `--`. Sao quatro #rule com padrao
// `ident $x OP ... ;` — o nome ja foi lido como expressao quando o token
// composto aparece, entao o despacho continua sendo por token literal.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

i64 g = 0;                            // global: += tambem vale para ela

i64 main() {
    i64 x = 4;
    x += 6;
    putnum(x);  write(1, ",", 1);     // 10
    x -= 3;
    putnum(x);  write(1, ",", 1);     // 7
    x++;
    putnum(x);  write(1, ",", 1);     // 8
    x--;
    putnum(x);  write(1, ",", 1);     // 7

    g += 5;
    g++;
    // += com expressao inteira do lado direito, nao so uma constante
    i64 y = 0;
    y += x * 5 - 1;                   // 34
    return y + g + 2;                 // 34 + 6 + 2 = 42
}

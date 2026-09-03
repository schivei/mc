// prelude.mc — a superficie de ensino que o nucleo nao tem: `while`, `for` e os
// compostos `+=`, `-=`, `++`, `--`. Nada aqui e sintaxe embutida: sao seis
// `#rule stmt:` sobre o `loop {}` / `if` / `break` do nucleo, mais os quatro
// `#token` que criam os lexemas compostos. Incluir este arquivo e opcional e
// versionado — o nucleo continua compilando sem ele.
//
//   #include "../lib/prelude.mc"
//
// Palavras-chave criadas: `while` e `for` deixam de poder ser nomes de variavel
// ou de funcao a partir do #include (o primeiro item de uma regra vira palavra
// reservada via tok_add).
//
// `continue` dentro de um `for` pula o passo, exatamente como pularia dentro do
// `loop` que a regra gera: `continue` volta para o topo do `loop`, e o passo
// esta no fim do corpo. Quem precisa do passo escreve-o antes do `continue`.

#token "+="
#token "-="
#token "++"
#token "--"

// while (c) { ... }  ->  loop { if (!c) break; ... }
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }

// for (init; cond; x = passo) { ... }
// O passo e `ident $x = expr $step` e nao `expr $step`: no nucleo a atribuicao e
// um statement, nao um operador, entao um `expr` sozinho no passo so poderia ser
// uma chamada — inutil para um contador. Ver docs/core-language.md.
#rule stmt: for ( stmt $init expr $cond ; ident $x = expr $step ) block $b
    => { $init loop { if (!$cond) break; $b $x = $step; } }

#rule stmt: ident $x += expr $e ;   => $x = $x + $e;
#rule stmt: ident $x -= expr $e ;   => $x = $x - $e;
#rule stmt: ident $x ++ ;           => $x = $x + 1;
#rule stmt: ident $x -- ;           => $x = $x - 1;

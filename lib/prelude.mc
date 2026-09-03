// prelude.mc — the teaching surface that the core does not have: `while`, `for`
// and the compound `+=`, `-=`, `++`, `--`. Nothing here is builtin syntax: it is
// six `#rule stmt:` over the core's `loop {}` / `if` / `break`, plus the four
// `#token` that create the compound lexemes. Including this file is optional
// and versioned — the core keeps compiling without it.
//
//   #include "../lib/prelude.mc"
//
// Keywords created: `while` and `for` can no longer be variable or function
// names once #include'd (the first item of a rule becomes a reserved word via
// tok_add).
//
// `continue` inside a `for` skips the step, exactly as it would inside the
// `loop` the rule generates: `continue` goes back to the top of the `loop`,
// and the step is at the end of the body. Whoever needs the step writes it
// before the `continue`.

#token "+="
#token "-="
#token "++"
#token "--"

// while (c) { ... }  ->  loop { if (!c) break; ... }
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }

// for (init; cond; x = step) { ... }
// The step is `ident $x = expr $step` and not `expr $step`: in the core,
// assignment is a statement, not an operator, so an `expr` alone in the step
// could only be a call — useless for a counter. See docs/core-language.md.
#rule stmt: for ( stmt $init expr $cond ; ident $x = expr $step ) block $b
    => { $init loop { if (!$cond) break; $b $x = $step; } }

#rule stmt: ident $x += expr $e ;   => $x = $x + $e;
#rule stmt: ident $x -= expr $e ;   => $x = $x - $e;
#rule stmt: ident $x ++ ;           => $x = $x + 1;
#rule stmt: ident $x -- ;           => $x = $x - 1;

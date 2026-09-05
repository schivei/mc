# Every message the compiler emits

Every diagnostic `mc` can print, with what causes it and what to do about it. The list is
extracted from the `die`/`die2`/`err_at`/`err_at2`/`err_node`/`expect`/`toml_err*` call sites in
`src/*.mc`; nothing here is invented, and `scripts/check-docs.sh` compiles a sample for the ones
marked with an example.

Every diagnostic exits **1**. There are no warnings: the compiler either produces the artifact or
says why it did not.

## The four shapes

| shape | who | example |
|---|---|---|
| `mc: MESSAGE` | `die` — no position available | `mc: arena exhausted` |
| `mc: MESSAGE: DETAIL` | `die2` | `mc: cannot open: sys.mc` |
| `FILE:LINE: MESSAGE` | `err_at` / `err_node` — the position of the token or node at fault | `prog.mc:7: type expected` |
| `FILE:LINE: MESSAGE: DETAIL` | `err_at2` | `prog.mc:3: the rule expected: )` |
| `FILE:LINE:COL: MESSAGE[: KEY]` | `toml_err*` | `mc.toml:6:6: only macos, linux and windows (see docs/build.md): target.os` |

`FILE` is whatever the token's source is called: a real path, or a **bundled name** when the code
came from inside the binary (`syntax_demo_test:10: type expected at top level`). A missing file is
printed as `?`.

```mc
// expect-error: type expected at top level
notatype main() { return 0; }
```

---

## 1. Lexer

| message | cause | fix |
|---|---|---|
| `unexpected character` | a byte that starts no token and no lexeme in the table | remove it; if it is meant to be an operator, register it with `#token` first |
| `unterminated comment` | a `/*` with no `*/` before end of file | close it — block comments do not nest |
| `unterminated string` | a `"` with no closing `"` on the same source | close it, or split with two literals |
| `unterminated char literal` | a `'` with no closing `'` | close it |
| `unterminated literal` | a literal that ends at end of file | the file is truncated |
| `unterminated escape` | a `\` at the very end of a literal | complete the escape |
| `unknown escape` | an escape that is not `\n \t \r \0 \\ \' \"` | use one of those, or write the byte with a char literal and `st8` |
| `\0 not allowed in string` | an explicit NUL inside a string literal | `__cstring` is `S_CSTRING_LITERALS` and the linker merges literals at the first NUL, so `"a\0b"` and `"a"` would share an address. Build the bytes into a `u8` array instead |
| `invalid hexadecimal` | `0x` with no hex digit after it | write at least one digit |
| `empty lexeme` | `#token ""` | give the lexeme at least one byte |
| `unknown directive` | a `#name` that is not one of the ten | check the spelling; the list is in [directives.md](directives.md). `#include <name>` and `#embed` do not exist in the C seed |
| `invalid hole` | a `$` that is not followed by a hole name | `$name` and `$$name` are only meaningful inside a `#rule` template |
| `unknown bundled include` | `#include <name>` with a name the bundle does not carry | the catalogue is [bundle.md](bundle.md). There is no filesystem fallback for `<...>` |
| `path with too many segments` | a path with more than 64 components after normalisation | shorten it, or add an `[include].paths` root and include by a short name |
| `too many substitutions` | more than 16 `p_subst_*` entries pending for one pushed source | a module bug: batch fewer substitutions per push |

## 2. Directives

| message | cause | fix |
|---|---|---|
| `#include expects a string` | `#include` without `"path"` or `<name>` | quote the path. In the C seed, `<name>` itself produces this message |
| `unterminated #include <name>` | a `<` with no `>` before end of file | close the bracket |
| `directive expects a string` | `#token`/`#infix`/`#prefix` given something that is not a string | quote the lexeme |
| `directive not yet supported` | a directive the parser recognises but does not handle | none: this is reachable only from a partially added directive |
| `#define expects a name` | `#define` followed by something that is not an identifier | give it a name |
| `#define expects a constant expression` | the value does not fold to a constant | `#define` is a folded constant, not a textual macro; it cannot mention a variable |
| `duplicate #define` | the same name defined twice | rename one, or delete the second |
| `name already defined by #define` | a local, parameter, global or function declared with a name a `#define` owns | rename either, in whichever order they appear |
| `#token expects a string` | `#token` without a quoted lexeme | quote it |
| `#infix expects the precedence` | `#infix "op"` with no integer after the lexeme | add a precedence, 1..100 |
| `#infix expects left or right` | the associativity word missing or misspelled | write `left` or `right` |
| `precedence out of 1..100` | the precedence is outside the range (from `#infix` or `syntax_infix`) | pick a value in 1..100; the core uses 1..10 |
| `#dylib expects a string` | `#dylib` without a quoted path | quote the path, or write `#dylib ""` to return to libSystem |
| `#embed expects NAME "path" [lz]` | the name or the quoted path is missing | write `#embed name "file"`, optionally followed by `lz` |
| `#embed file is empty or over 16 MiB` | the file is 0 bytes or exceeds the declared ceiling | every byte costs an AST node, so the arena is the real bound long before 16 MiB |
| `#section expects the section name` | `#section` with a segment but no section name | give both, or write `#section` alone to return to the defaults |
| `#section expects constant flags` | the flags argument does not fold | use a literal or a `#define` |
| `#section expects constant alignment` | the alignment argument does not fold | same |
| `section flags out of 32 bits` | the flags value does not fit in `u32` | it is the Mach-O flags word: `0x80000400`, `1`, `0`, … |
| `alignment out of 0..15` | the alignment is not a log2 in 0..15 | write `3` for 8 bytes, `4` for 16 |
| `#opcode expects a name` | `#opcode` not followed by an identifier | name the instruction |
| `expected ( in #opcode` | no parameter list | write `name(a, b)` even when empty: `name()` |
| `parameter name expected in #opcode` | a non-identifier in the parameter list | parameters are plain names |
| `at most 12 parameters in #opcode` | more than 12 parameters | split the encoding into two opcodes |
| `expected ) in #opcode` | the parameter list is not closed | close it |
| `duplicate #opcode` | two `#opcode`s with the same name | rename one |

## 3. `#rule`

| message | cause | fix |
|---|---|---|
| `#rule expects category stmt` | no category word after `#rule` | write `#rule stmt:` |
| `#rule expr: reserved, not yet supported` | the category `expr` | reserved. Use `#infix`/`#prefix`, or `syntax_expr` from a module |
| `#rule only knows category stmt` | any other category | only `stmt` exists |
| `expected : after the #rule category` | the colon is missing | write `#rule stmt: …` |
| `empty #rule pattern` | nothing between the colon and `=>` | a pattern needs at least one item |
| `the #rule pattern must open with a literal token` | the first item is `expr`/`stmt`/`block` | dispatch is by the opening token. Only a leading `ident $x` may precede the literal |
| `cannot redefine core keyword` | the dispatch literal is a type word or a control word | `if`, `loop`, `return`, `i64`, … are refused because a rule opened by them would hijack the core's parser. Punctuation and new `#token`s are free |
| `expected $name in the pattern` | an `nt` with no `$name` after it | write `expr $c`, `block $b`, `ident $x` |
| `duplicate hole in #rule` | the same `$name` twice in one pattern | rename one |
| `too many holes in #rule` | more holes than one rule may carry | split the rule |
| `too many name holes in #rule` | more `ident $x`/`$$t` names than one rule may carry | split the rule |
| `too many items in the #rule pattern` | the pattern is longer than one rule record allows | split the rule |
| ``nt `type` is out of scope for M9`` | `type $t` in a pattern | not implemented; it is what a real `struct` would need. Use `#define` offsets and accessors |
| `#rule without =>` | the arrow is missing | `PATTERN => TEMPLATE` |
| `hole $name has no rule binding it` | a `$name` in the template that the pattern never bound | check the spelling, or add the item to the pattern |
| `hole out of range in template` | an expansion referenced a hole index the rule does not have | an internal inconsistency; reduce the rule and re-add items |
| `$$name only works in a #rule template` | a gensym outside a template | `$$t` is only meaningful on the right of `=>` |
| `the rule expected` | the matched rule wanted a literal that is not there — the detail is the lexeme | once a rule is chosen there is no backtracking; write what the pattern says |
| `the rule expected a name` | the rule wanted an `ident $x` and got something else | supply a plain identifier |
| `the rule expected a name on the left` | a compound rule (`ident $x += …`) whose left side is not a plain name | `a.b += 1` cannot match; assign explicitly |
| `too many nested rules` | more than 64 levels of rule-inside-rule at definition time | flatten the templates |

## 4. Parser — expressions and statements

| message | cause | fix |
|---|---|---|
| `expression expected` | a primary was required and none was there | often the real cause is a missing `#token`: without it a compound operator is lexed as two tokens and the Pratt loop stops far from the mistake |
| `expected ) after expression` | an unbalanced `(` in an expression | close it |
| `expected ) in cast` | `(type` without the closing `)` | write `(u32) x` |
| `cast to void` | `(void) x` | there is no value of type `void`; drop the cast |
| `expected ) in call` | an argument list is not closed | close it |
| `call by name only` | calling something that is not a plain name | for an indirect call use `callp(p, …)` |
| `& expects a name` | `&` applied to an expression | `&` takes a local, a global or a function |
| `name expected` | `p_ident()` required an identifier | supply a name |
| `name expected here` / `variable name expected` / `parameter name expected` / `name expected at top level` | a declaration name is missing | supply it. If the token is a taught word, the message is the next one instead |
| `name reserved by a syntax/type_alias registration` | the name is a word some Tier 3 registration claimed — the detail is the word. Since M41.5 that word may be a core operator, if a module taught `+` with `syntax_infix`; since M45 it may be `i32`, which the core registers for itself | a registration reserves the word for the whole program. Rename the identifier, or choose a different word in the module |
| `type expected` | `p_type()` required a type word | one of the seven core types, or a `type_alias` |
| `type expected at top level` | a top-level declaration that starts with neither a type nor a taught word | this is what the default compiler says about a source written for a taught one |
| `type expected in parameter` | a parameter with no type | write `i64 x`, never a bare `x` |
| `type expected in extern` | `extern` with no return type | `extern i64 name(...)` |
| `name expected in extern` | `extern` with a type but no name | add the name |
| `parameter of type void` | a parameter declared `void` | drop it |
| `local of type void` | a local declared `void` | there is no value of that type |
| `global of type void` | a global declared `void` | same |
| `at most 12 parameters` | more than 12 parameters | the ABI limit (8 in registers, 4 on the stack): pass a pointer to a struct-like block instead |
| `expected ( in the parameter list` / `expected ) in the parameter list` | the parentheses of a declaration | close them |
| `expected ( after if` / `expected ) after condition` | `if` without its parenthesised condition | write `if (c) …` |
| `expected {` | a block was required | `loop`, a function body and a `block $b` hole all need braces |
| `unterminated block` | a `{` with no `}` before end of file | close it |
| `expected ; after declaration` | a local declaration without its semicolon | add it |
| `expected ; after assignment` | an assignment statement without its semicolon | add it |
| `expected ; after expression` | an expression statement without its semicolon | add it |
| `expected ; after return` | `return` without its semicolon | add it |
| `expected ; after break` | `break` or `break N` without its semicolon | add it |
| `expected ; after continue` | `continue` or `continue N` without its semicolon | add it |
| `expected ; after extern` | an `extern` declaration without its semicolon | add it |
| `expected ; after the global` | a global declaration without its semicolon | add it |
| `left side of assignment must be a name` | assigning to something that is not a plain name | use `st8`/`st64` for memory, or a taught `syntax_infix` for members |
| `break expects a positive level` | `break 0;` or a negative level | `break;` is `break 1;` |
| `continue expects a positive level` | `continue 0;` or a negative level | `continue;` is `continue 1;` |
| `expected ] in the array size` | an array declaration's bracket | close it |
| `array size must be a positive constant` | `N` in `type x[N]` does not fold to a positive integer | use a literal or a `#define` |
| `expected { in the array initializer` / `expected } in the array initializer` | the braces of `= { … }` | close them |
| `empty array initializer` | `= { }` | give at least one element, or drop the initializer |
| `initializer must be constant` | an element that does not fold | initializers are constants |
| `initializer with too many elements` | more elements than the declared `N` | raise `N`, or write `type x[] = { … }` and let it be inferred |
| `a string only initializes uptr` | a string element in an array that is not `uptr` | a string element becomes a relocated pointer; the element type must be `uptr` |
| `global initializer must be constant` | a global's scalar initializer does not fold | same rule |
| `global array too large` | the declared array exceeds the addressable size | reduce it |
| `division by zero` | `x / 0` or `x % 0` with both sides constant | folding happens at compile time |
| `operator without constant folding` | an operator used where a constant is required and the folder has no rule for it | use a simpler constant expression |

## 5. Tier 3 handler contract

| message | cause | fix |
|---|---|---|
| `syntax handler consumed no tokens: <word>` | a `syntax` handler returned without calling `p_next` — the detail is the word it was registered for | the handler must consume at least that word; the guard exists to stop an infinite loop |
| `syntax_stmt handler consumed no tokens: <word>` | the same at the statement position | same |
| `syntax_expr handler consumed no tokens: <word>` | the same at the expression position | same |
| `syntax_expr handler produced no expression: <word>` | the handler returned 0 | an expression position has no empty node to fall back on; return a node |
| `syntax_param handler consumed no tokens: <word>` | M41.5: a `syntax_param` handler returned a node without advancing | a handler that claims the parameter has to read it; return 0 to leave it to the core |
| `syntax_param handler consumed tokens and returned 0: <word>` | M41.5 (review): the handler read part of the parameter and then declined. `parse_params` would read what was left as a whole parameter — an arity change with no diagnostic | 0 means "I read nothing"; either claim the parameter and return an `N_PARAM`, or decline before consuming anything |
| `syntax_param handler did not return a parameter` | M41.5: what the handler returned is not an `N_PARAM` | build it with `param_new(ty, name)`; the node goes straight into a list `gen_lower` walks by `nd_type`/`nd_name` |
| `syntax_type handler consumed tokens and returned 0: <word>` | a `syntax_type` handler read a suffix and then declined; the core would read the rest of the declaration from the middle of a type. The detail is the type word the handler was given | 0 means "I read nothing"; either claim the suffix and return a type id, or decline before consuming anything |
| `syntax_type handler consumed no tokens: <word>` | a type came back with the cursor unmoved — there is no suffix, so the answer cannot be about this position | return 0 to leave the core's type alone |
| `syntax_type handler returned an invalid type: <word>` | the id is negative or at or past `type_count()`. It goes straight into `type_width`/`type_align`/`type_kind` | answer 0, a core `TY_*`, or an id a `type_new` returned |
| `syntax_lit handler consumed tokens and returned 0: <literal>` | M41.5 (review): the same rule at M24's literal position — the handler moved the cursor with `p_take_lit` and then declined, and the core would build an `N_INT` out of a token whose span no longer covers what was read | decline before calling `p_take_lit`, or return the node |
| `syntax_infix handler produced no expression: <operator>` | the same for an operator handler | return the resulting node |
| `operator already taught` | a second `syntax_infix` on the same token, a core one (`+`) included since M41.5 — the FIRST registration on a core operator is allowed, because it carries no handler to override | a second registration is a mistake, not an override. A later `#infix` on the token *is* allowed: it clears the handler and the template wins |
| `cannot redefine core keyword` | `syntax`/`syntax_stmt`/`syntax_expr`/`syntax_infix`/`type_alias` on a core word | choose another word |
| `type_alias with invalid type` | the base is not a type id that exists — one of `TY_VOID..TY_UPTR`, or one a `type_new` returned | use a core type constant, or the id `type_new` gave you |
| `type_new with a width below 1` | M24: a registered type has to occupy at least one byte | the detail is the type's name |
| `type_new with an alignment below 1` | the same for the alignment | |
| `type_new with an unknown kind` | the kind is not `TK_INT`, `TK_FLOAT`, `TK_WIDE`, `TK_OPAQUE` or `TK_SINT` (M45) | |
| `type_set_width only declares the width of uptr` | M41: `type_set_width` with any `ty` but `TY_UPTR` | `i64` folds in 64 bits at parse time and u8/u16/u32/u64 are their own names; register a new primitive with `type_new()` instead |
| `uptr width must be 1, 2, 4 or 8` | M41: `type_set_width(TY_UPTR, w)` with any other `w` | a word the relocation length can be the log2 of |
| `type_disable with an unknown type` | M41: the id is negative or past `type_count()` | pass a `TY_*` constant, or an id `type_new` returned |
| `type_disable beyond the mask` | M41: a type id above 62 — the disable set is one `i64` of bits | disable it before registering 60 other types, or leave the word in |
| `too many intrinsic_disable` | M41: more than 32 `intrinsic_disable()` names | the ceiling is fixed on purpose, like the subcommand table |
| `too many subcommands` | M41: more than 16 `subcommand()` registrations | the ceiling is fixed on purpose: the number of subcommands is a property of the compiler |
| `too many on_plan hooks` | M41: more than 8 `on_plan()` registrations | same |
| `p_skip_balanced expects the opening token` | the parse was not sitting on the opening token | position the handler on the `{`/`<`/`(` before calling |
| `unterminated region` | `p_skip_balanced` reached end of file — reported at the **opening** token | close the region; the position points at what never closed |
| `region crosses a file boundary` | the OPENING delimiter of a recorded region was read in one `#include` frame and the CLOSING one in another — a `{` in an include and its `}` in the includer, or the reverse. Reported at the opening token. A region that merely ENDS on the last token of an included file is not this: it is a slice of one buffer and is accepted (M45) | a span is a slice of one buffer; keep both delimiters of a recorded region inside one file |
| `p_take_lit outside the source token` | M24: a `syntax_lit` handler said its literal ends before the cursor, past the end of the source, or on a token that was not just lexed from the source being read | same rule as `p_resplit_punct`: never a string, never a substituted identifier |
| `p_resplit_punct expects a longer punctuation token` | the current token is not a punctuation token longer than `n`, freshly lexed from the source | it works only on a token just read from the source being lexed — never a string, never a substituted identifier |
| `p_resplit_punct: unknown punctuation` | the first `n` bytes are not a registered lexeme | split at a boundary that is a real token, as `>>` → `>` |

## 6. Codegen

| message | cause | fix |
|---|---|---|
| `unknown name` | an identifier that is no local, global, function or `extern` | declare it, or check the spelling. Codegen looks for a local, then a global, then a signature |
| `call to unknown function` | a call to a name with no signature | declare a prototype or an `extern` before the call |
| `wrong number of arguments` | the call's arity does not match the declaration | fix one of the two |
| `wrong arity in intrinsic` | `ld*`, `st*`, `emit`, `reloc` with the wrong count | `ld*` takes 1, `st*` takes 2 |
| `callp expects 1 to 12 arguments` | `callp()` empty, or with more than 11 arguments after the pointer | the pointer counts towards the twelve |
| `function declared twice` | two definitions of one name | delete one |
| `declaration does not match prototype` | the definition's return type or arity differs from the prototype | make them agree |
| `prototype with no definition` | a prototype nobody defines and no `extern` | define it, or declare it `extern` |
| `global name declared twice` | two globals with one name | rename one |
| `value of type void` | a `void` call used where a value is needed | `void` produces no value |
| `assignment to array` | assigning to an array name | an array name is an address; write through `st*` |
| `break out of range` | `break N;` with N greater than the enclosing loop depth | count the loops again |
| `continue out of range` | `continue N;` with N greater than the enclosing loop depth | count the loops again |
| `continue outside loop` | `continue;` with no enclosing `loop` | remove it, or add the loop |
| `expression too deep` | more than 64 levels of expression nesting | split into statements |
| `frame too large` | locals + spill area exceed 4095 bytes | `sub sp, sp, #imm` carries only 12 bits; move data into a global |
| `local array too large` | one local array exceeds 4095 bytes | make it a global |
| `unary operator with no codegen` / `binary operator with no codegen` / `expression with no codegen` / `statement with no codegen` | a node kind the generator has no rule for | reachable when a module builds a node the core does not lower; check the node kind the handler produced |
| `instruction with no encoder` / `instruction with no dump` | an `I_*` opcode the encoder or the dumper does not handle | the same, one layer down: a backend produced an instruction the core cannot encode |
| `x86 instruction with no encoder` / `x86 instruction with no dump` | the same two, from the x86-64 machine and its `X_*` opcodes. There is no third: `MTASK_INS_SIZE` is the encoder over a scratch buffer, so an opcode with no encoder has no size either | see [machine.md](machine.md) |
| `no machine registered` | the walker was asked to lower with no machine table in effect. Since M41 `mc_main` says it before `gen_lower` as well, so a compiler that registered none fails at a defined point instead of mid-lowering | `main()` registers both and `mc_main` makes the host's current; a recreated compiler registers its own from `user_init()` |
| `<word>: removed by this compiler` | M41: a type word `type_disable()` removed, at the token that used it, or an intrinsic name `intrinsic_disable()` removed, at the call. The detail is the word. `i32: removed by this compiler` is the M45 case a machine with no sign-fill produces (`examples/avr`) | this dialect does not have it. `type_disable` removes the WORD, not the type: `ld32()` still yields `TY_U32` internally |
| `cannot shadow a core intrinsic` | M24: `intrinsic()` was given the name of a built-in one (`ld64`, `st64`, `emit`, `reloc`, `callp`, …), which the dispatch would never reach | pick another name; the detail is the one asked for |
| `intrinsic with an impossible arity` | the arity is negative or above `MAXPARAMS` | |
| `intrinsic with an unknown result type` | the result type is not a type id that exists | register the type first |
| `machine_slot outside the task table` | M24: the task index handed to `machine_slot` is not in `0 .. MTASK_COUNT - 1` | the slot list is [machine.md](machine.md) § 2 |
| `unknown machine` | `--machine=NAME`, or a backend's `machine_use`, named something not registered | `arm64` and `x86_64` are built in; the detail is the name |
| `add/sub immediate out of 12 bits` / `cmp immediate out of 12 bits` | a folded immediate does not fit the instruction | materialise it into a variable first |
| `immediate and mask not supported` | an `and` with an immediate the bitmask encoding cannot express | put the mask in a variable |
| `memory offset out of range` | a frame offset outside the scaled `ldr`/`str` range | the frame is too large or too fragmented; reduce the locals |
| `branch too far` | a branch beyond the 19-bit range the encoder checks uniformly (±1 MiB) | split the function |
| `function in a zerofill section` | a function defined while a `#section … 1` (`S_ZEROFILL`) is in effect | zerofill sections have no file bytes; switch sections before the function |
| `global with initializer in a zerofill section` | an initialised global in a zerofill section | same: an initialiser needs file bytes |

## 7. `emit()`, `reloc()` and `#opcode`

| message | cause | fix |
|---|---|---|
| `emit expects an argument` / `emit expects a constant` | `emit()` empty, or with a non-constant | it writes one folded 32-bit word |
| `emitted word does not fit in 32 bits` | the folded word exceeds `0xffffffff` | mask it |
| `#opcode argument not constant` | an argument of a `#opcode` call does not fold | `#opcode` is an encoder, not a function: everything must be known at compile time |
| `wrong number of arguments in #opcode` | the call's arity does not match the declaration | fix one of the two |
| `reloc expects two arguments` | `reloc()` with a different count | `reloc(TYPE, "symbol")` |
| `relocation type must be constant` | the first argument does not fold | use `BRANCH26`, `PAGE21`, `PAGEOFF12` or `UNSIGNED` |
| `reloc expects the symbol in quotes` | the second argument is not a string | quote the symbol name, with its leading `_` |
| `unknown relocation type` | a value that is not one of the four | see [objects.md](objects.md) |
| `two relocations for the same word` | two `reloc()` calls with no `emit()` between them | one relocation per word |
| `reloc without an immediately following emit` | a `reloc()` with no word after it before the next label or the end of the function | put the `emit()`/`#opcode` call right after it |
| `reloc UNSIGNED requires 8 bytes: use a global array initializer` | `reloc(UNSIGNED, …)` before a 4-byte word | it is an 8-byte relocation and would overrun the next instruction. Write the address as a global array initializer instead |

## 8. Object writers

| message | cause | fix |
|---|---|---|
| `duplicate symbol` | two definitions of one symbol name | rename one; the detail is the symbol |
| `no _main: cannot generate an executable` | `--exe` on a unit with no `main` | add `i64 main()`, or produce an object instead |
| `UNSIGNED that does not occupy 8 bytes` | an `UNSIGNED` relocation of the wrong length reached a backend | the same cause as the `reloc UNSIGNED` message, seen at write time |
| `relocation not supported in the direct executable` | a relocation kind `macho-exe` cannot resolve itself | use the `.o` + `ld` path for that construct |
| `relocation not supported in the ELF object` / `relocation not supported in the x86-64 ELF object` | a relocation kind the ELF writer has no mapping for on that architecture | same, for Linux targets. An AArch64 `reloc(BRANCH26, …)` compiled for `arch = "x86_64"` lands here |
| `relocated pointer in __TEXT: the segment is r-x and dyld will not rebase it` | a global with a relocated pointer placed in a `__TEXT` section | put the data in `__DATA` |
| `pageoff12 misaligned for the access width` | a `PAGEOFF12` target not aligned for the load/store width it patches | the address must be aligned to the access width |
| `misaligned bl target` / `bl too far` | a call target not 4-byte aligned, or beyond ±128 MiB | the program is too large for one `__text`; split it |
| `too many segments for the rebase opcode` / `too many segments for the bind opcode` | more distinct segments than a `dyld` opcode can index | reduce the number of distinct `#section` segment names |
| `too many dylibs for the bind opcode` | more `#dylib`/`[libs]` entries than the ordinal encoding allows | link fewer libraries, or use `[linker]` |

## 9. Command line and driver

| message | cause | fix |
|---|---|---|
| `unknown option` | a flag starting with `-` that is not recognised | the list is [cli.md](cli.md). `--exe` and `--backend=` other than `macho` do not exist in the C seed |
| `-o requires an argument` | `-o` at the end of the command line | give it a path |
| `duplicate entry` | two source files on one command line | `mc` compiles one file at a time; use `mc build` for a project |
| `--config requires an argument` | `--config` at the end of the command line | give it a path |
| `duplicate directory` | two directories after `mc build` / `mc limits` | pass one |
| `--entry-only and --compiler-only are exclusive` | both halves of a taught build asked for at once | `--compiler-only` builds the compiler and stops; `--entry-only` compiles the entry with the running binary. Pick one |
| `unknown backend: NAME` (then `registered: …`) | `--backend=` naming something not registered | the message lists what exists |
| `no backend: use --backend=NAME` | M41: no `--backend=`, no `--exe`, no `target()` registered for this host and no `backend_default()` — a recreated compiler that registered a writer and forgot to name it | call `backend_default("name")` from `user_init()`, or pass `--backend=` |
| `<os> requires a linker: there is no direct executable` | post-M41 review: `--exe` on a host whose `target()` registration has 0 in the exe slot — `windows` today, and any pair a module registers that way. `linux` was on this list until M42 gave ELF a direct executable | compile to an object (`mc x.mc -o x.o`) and link it, or use `mc build` with a `[linker]` section. This is the single-file CLI's wording of the driver's `<os> requires [linker]: there is no direct executable` (§ 10): same registration, same refusal, and `[linker]` is a TOML section a command line does not have |
| `<os>/<arch> has no object backend: use --exe` | post-M41 review: the object backend was left to the host and that pair's `target()` registration has 0 in the object slot. Only a module can write that 0 — `target(os, arch, 0, exe)` is what a board whose flat image is the whole artefact registers (`examples/kernel`) — and it is reached by a plain `mc x.mc -o x.o` on such a compiler. It used to be handed to `backend_find()`, whose `str_eq` dereferenced it: SIGSEGV, exit 139, no message | ask for the executable instead (`mc --exe x.mc -o x`), which is what that registration says the target has. This is the single-file CLI's wording of the driver's `<os>/<arch> has no object backend: use kind = "exe"` (§ 10): same registration, same refusal, and `kind` is a TOML key a command line does not have |
| `the host is not a registered target` | the backend was left to the host and the `target()` registry has no entry for `host_os()`/`host_arch()`: with no `--backend=` when some target is registered but not this one, and always with `--exe`, which means "a direct executable for the host" | register the pair from `user_init()`, or name the writer with `--backend=` (or `backend_default()`) |
| `cannot run` | `posix_spawnp` could not start the linker or the taught compiler | check the `cmd` in `[linker]`, and that a relative compiler path starts with `./` |
| `cannot spawn: <tool> (error N)` | a tool `mc` may legitimately find missing — `curl`, `wget`, `tar`, `llvm-dlltool` — is there and could not be started anyway. `N` is the number `posix_spawnp` returned: 13 `EACCES` (not executable), 8 `ENOEXEC` (not a program), 7 `E2BIG` (on a Windows host, a command line past `WH_CMDMAX`). Only `ENOENT` (2) is silent, and means "not on `PATH`" | fix the permissions on the tool, or take the broken copy off the `PATH` |
| `waitpid failed` | the spawned process could not be waited for | a system-level failure |
| `posix_spawn_file_actions_init failed` | the spawn could not be set up | same |
| `xcrun --show-sdk-path failed` | `{sdk}` was used and `xcrun` failed | install the command line tools, or write the SDK path literally |
| `too many arguments in [linker].args` | more than 64 arguments after `{libs}` expansion | shorten the list |
| `--libc must be gnu or musl: <value>` | post-M42 patch: `--libc=` with anything else. `libc` names a **family**, not a soname | `gnu` or `musl` ([cli.md](cli.md)) |
| `--link must be dynamic or static: <value>` | post-M42 patch: `--link=` with anything else | those are the two values |
| `--libc applies to an executable: use --exe` (also `--interp`, `--link`) | post-M42 review: one of the three Linux flags on a run that writes an **object** — a plain `mc x.mc -o x.o`, or a `--backend=` the target registry names in an object slot. Only the executable writer reads them (`PT_INTERP` and `DT_NEEDED` are program-header fields; an object has neither), so before this the flag was accepted and did nothing | ask for the executable: `mc --exe --libc=gnu prog.mc -o prog` on a Linux host, or `mc --backend=elf-exe --libc=gnu prog.mc -o prog` from any host. What counts as an executable writer is the exe slot of a `target()` registration, so a target a module registered answers for its own writer |
| `--libc applies to an executable: a --dump-* mode writes none` (also `--interp`, `--link`) | post-M42 review: one of the three flags together with `--dump-tokens`/`--dump-ast`/`--dump-asm`/`--dump-syms`/`--dump-rules`/`--dump-machine`. A dump returns before any backend is reached, so the flag can affect nothing — including with `--exe`, which the dump overrides | drop the flag, or drop the dump |
| `--libc applies to a linux target` (also `--interp`, `--link`) | post-M42 patch: one of the three Linux flags asking for the HOST's executable (`--exe`) on a host that is not Linux — so the flag would describe an image this command is not going to write. Ignored would be worse than refused | drop the flag, or name the writer: `mc --backend=elf-exe --libc=gnu prog.mc -o prog` cross-builds from any host |
| `static link with imports needs [linker]: see docs/build.md -- static linking (M46)` | post-M42 patch: `--link=static` (or `[target].link = "static"`, § 10) on a program that imports anything -- a libc symbol or a `#dylib` one, the import count does not distinguish. `mc` has no archive linker; the static image it writes is the one for a program that imports **nothing** | either drop the imports (`<sys_linux>` is raw syscalls and imports nothing), or take the `[linker]` road with `ld.lld` and a sysroot ([../build.md](../build.md#the-matrix-libc-x-link)). M46 is the milestone that would remove the need for it |

## 10. `mc.toml`

All of these carry `file:line:col`.

| message | cause | fix |
|---|---|---|
| `key expected` | a line that starts with neither a key nor `[` | check for a stray character |
| `expected = after the key` | a key with no `=` | add it |
| `value expected` | nothing, or something unrecognised, after `=` | strings need quotes: `entry = main.mc` is this error, and the column points at the bare word |
| `unexpected text after the value` | trailing content on the line | one key per line; comments start with `#` |
| `unterminated string` | a string with no closing quote | close it |
| `unknown escape` | an escape other than `\" \\ \n \t \r` | use one of those |
| `expected ] in the table header` | `[table` with no `]` (or `[[table]` for an array of tables) | close the header |
| `quoted key must not contain .` | a quoted key containing `.` | the table is flat and paths join with `.`, so `"b.c"` under `[a]` and `c` under `[a.b]` would collide. Rename, or use a real sub-table |
| `unterminated array` | a `[` value with no `]` | close it; arrays may span lines and allow a trailing comma |
| `expected , or ] in the array` | two values with no comma | add it |
| `digit expected after .` | a float ending in `.` | write `0.25`, never `0.` |
| `float with more than 4 fraction digits` | more precision than basis points can hold | the only float key is `[limits].tolerance`, kept as basis points: at most four digits |

Driver-level key errors, reported at the key's position when it exists and at the file when it
does not:

| message | key | fix |
|---|---|---|
| `missing key` | `project.entry`, `project.out`, `compiler.modules`, `compiler.out` | add it. `compiler.out` is only required when there is no `project.name` to default from. `sysroot.path` is **not** on this list since M25: an absent `[sysroot]` is not an error, it is step 1 of the chain of § 11 falling through to the next step |
| `must be exe or obj` | `project.kind` | those are the two values |
| `only macos, linux and windows (see docs/build.md)` | `target.os` | the list is built from the `target()` registry, so a target a module registers appears in it |
| `only aarch64 and x86_64 (see docs/build.md)` | `target.arch` | the architectures that operating system was registered with (macOS and Windows have only `aarch64`) |
| `<os> requires [linker]: there is no direct executable` | `target.os` | the pair is registered and its **executable** slot is 0, which is a registration saying this target has no direct executable at all. Today that is `windows/aarch64` and `windows/x86_64` — there is no PE writer — and any pair a module registers with `target(os, arch, obj, 0)`. It was `linux` until M42 gave ELF one (`elf-exe`). Add a `[linker]` section, or `kind = "obj"` and link the object yourself |
| `<os>/<arch> has no object backend: use kind = "exe"` | `target.os` | the mirror of the row above: the pair is registered, its **object** slot is 0. Only a module can register that — `target(os, arch, 0, exe)` is what a board whose flat image is the whole artefact writes — so it is reached by asking such a target for `kind = "obj"`, or for an `exe` through a `[linker]` (which goes through the object step). Drop the `[linker]` and use `kind = "exe"` |
| `libc must be gnu or musl (a soname is not a value: gnu is libc.so.6, musl is libc.so)` | `target.libc` | post-M42 patch: the key names a **family**. `libc = "libc.so.6"` was the M42 spelling and the message carries the migration |
| `link must be dynamic or static` | `target.link` | those are the two values |
| `libc applies to a linux target` (also `interp`, `link`) | `target.libc`, `target.interp`, `target.link` | post-M42 patch: the three keys describe a Linux dynamic image, which no other target has. Delete the key, or set `os = "linux"` |
| `static link with imports needs [linker]: see docs/build.md -- static linking (M46)` | `target.link` | post-M42 patch: `link = "static"` on a program that imports any symbol. Raised by the executable **writer**, which counts imports, and reported at the key's own position through the reporter the driver installs (`dyn_die`, `src/objmodel.mc`). Add a `[linker]` — with one present the driver writes the object and hands it over, and the key never reaches the writer |

| `must be a relative path` | `compiler.out` | the generated compiler source lives next to it and includes by relative path |
| `must not contain ..` | `compiler.out` | same reason; the `..` check runs on the string as written |
| `library not declared in [libs]` | an `[externs]` value | the value must name a `[libs]` key |
| `tolerance must be between 0 and 1` | `limits.tolerance` | a float in `[0, 1]`, at most four fraction digits |

Since M39.5 the four `target.*` rows are raised **after** `user_init()` has run and after the
entry source has been opened and lexed — that is what lets a taught compiler register its own
`(os, arch)` pair and be driven by `mc build` (`docs/build.md` § M39 / M39.5). They therefore come
out *after* the `compile x -> y` step line, and after nothing else: the resolution happens before
the unit is parsed, so an unknown target is still reported ahead of any error in the program
itself. The message, its file, its line and its column are what they always were.

The three `--libc`/`--interp`/`--link` rows of § 9 are raised at the same point and for the same
reason (post-M42 review): whether the run writes an executable is a question for the `target()`
registry, and a module may register a target from `user_init()`. So a command line whose entry
file does not exist reports `cannot open` first, and the flag refusal only after — the resolution
still happens before the unit is parsed, and before every dump.

`mc sysroot stub` ([sysroot.md](sysroot.md) § 7) runs the same resolution at the same point, so
the first two rows come out of it byte for byte as they come out of a build. It asks for no
backend at all, which is why the two rows about a missing slot cannot be reached from it.

## 11. The sysroot, and exit code 2

One message, printed by `sysroot_missing()` (`src/sysroot.mc`) and shared by `mc build` and by
`mc sysroot`. It is the only thing that exits **2** — "the environment is not ready", as opposed
to 1 (a diagnostic) and 3 (the limits verdict), [cli.md](cli.md) § Exit codes.

```
mc: no sysroot for linux-aarch64
  tried: build/sysroot/linux-aarch64 (no crt1.o)
         /Users/me/.mc/sysroots/linux-aarch64 (no crt1.o)
  run:   sh scripts/sysroot-linux.sh --arch aarch64
```

| line | what it says |
|---|---|
| `no sysroot for <os>-<arch>` | the target whose `{sysroot}` could not be resolved |
| `tried:` | one line per candidate the chain looked at, with the reason it was refused: `no <marker>`, the first of that target's marker files ([sysroot.md](sysroot.md) § 2) that the directory does not hold. A directory that does not exist at all is refused with the same words, and deliberately — the chain probes the marker FILES and never the directory, because `open` on a directory is not portable to a Windows host |
| `run:` | the command that would produce one, per operating system |

It is the one diagnostic in this compiler with **no `file:line:col`**, on purpose: the chain runs
lazily, the first time an `[linker].args` value asks for `{sysroot}`, so there is no single key to
blame — and `mc sysroot path <target>` prints the same text with no config open at all. Every
`tried:` line names an absolute directory instead. `docs/specs/M25.md` § Deviations records it.

`mc sysroot fetch` fails through the same `run:`/`or:` block and the same exit 2, under its own
first line:

| message | cause |
|---|---|
| `mc: no downloader on this PATH (tried curl)` | neither `host_downloader()` nor its alternative is on the `PATH` — `ENOENT` from both spawns, and nothing else: a downloader that is there and refuses to start is the `cannot spawn` of § 9 instead |
| `mc: the download failed (exit N)` | the downloader ran and returned non-zero. `curl` exit 1 here is the `--proto '=https'` guard refusing a redirect to plaintext |
| `mc: checksum mismatch for <file>` | the bytes are not the pinned row's. Both digests are printed |
| `mc: wrong size for <file>` | the length is not the pinned row's |
| `mc: tar could not extract <file>` | the `tar` spawn returned non-zero; its own diagnostic came out on stderr just above |
| `mc: the archive did not carry <name>` | `tar` returned 0 but a member of the row, or a marker, is not there. The download and the directory's marker files are removed, so the partial directory cannot be mistaken for a sysroot later |

Causes, in the order the chain runs them ([sysroot.md](sysroot.md) § 1):

| cause | fix |
|---|---|
| `[sysroot].path` names a directory that is not a sysroot | fix the path, or populate the directory. An explicit path stops the chain: nothing else is tried after it |
| the host is not the target, and nothing is cached | `mc sysroot fetch <os>-<arch> --yes`, or `sh scripts/sysroot-linux.sh --arch <arch>`, or point `--sysroot-dir` at a directory you already have |
| the host *is* the target but the system has no musl | on Debian/Ubuntu `apt-get install musl-dev`, on Alpine `apk add musl-dev` |
| no `HOME`, no `[sysroot].cache` and no `--sysroot-dir` | the `tried:` line says exactly that; give the chain one of the three |

The stub writers (`{stubs}`, `mc sysroot stub`, [sysroot.md](sysroot.md) § 9) have three of their
own, all exit 1:

| message | cause | fix |
|---|---|---|
| `mc: no stub writer for: linux: a static libc is code, not a name list` | `{stubs}` or `mc sysroot stub` on a Linux target | a `libc.a` cannot be synthesized from a name list; `mc sysroot fetch linux-<arch> --yes` |
| `mc: cannot run llvm-dlltool for: PATH` | the Windows stub writer could not start `llvm-dlltool` | put it on `PATH` (Homebrew keeps it in `opt/llvm/bin`) |
| `mc: llvm-dlltool failed for: PATH` | it started and returned non-zero | its own diagnostic came out on stderr just above; the `.def` it was given is the named file |

## 11b. `mc sandbox`

Its exit codes are its own — **124** a cap, **125** a refusal, **126** the box could not be set
up ([cli.md](cli.md) § 3c) — and 2 stays the option errors' code, as everywhere else.

| message | cause | fix |
|---|---|---|
| `mc: the sandbox is a Linux feature; on this Mac: limactl shell mc-k7 build/mc-linux-arm64 sandbox run PATH (docs/build.md § Lima)` | any `mc sandbox` verb on macOS. Exit 126 | run the command it prints. There is no macOS sandbox and there will not be one ([sandbox.md](sandbox.md) § Hosts) |
| `mc: the sandbox is a Linux feature; this host is: windows` | any `mc sandbox` verb on Windows. Exit 126 | the same: it is a Linux feature |
| `mc: unknown sandbox subcommand: WORD` | the verb is not `run`, `exec` or `check`. Exit 2, and the usage follows | one of the three |
| `mc: unknown sandbox option: --x` | an option `mc sandbox` does not take. Exit 2 | the list is in [cli.md](cli.md) § 3c |
| `mc: option requires an argument: --time` | `--time`, `--wall`, `--mem`, `--out`, `--stdin`, `--ro`, `--cwd`, `--root`, `--config` or `--report` was last on the line. Exit 2 | give it its value |
| `mc: not a number: abc` | a non-decimal value for `--time`/`--wall`/`--mem`/`--out`. Exit 2 | a non-negative decimal |
| `mc: --mem: number too large` | the value has more digits than any cap can have (the accumulation stops at 10^12). Exit 2 | a real number: the maxima are in [cli.md](cli.md) § 3c |
| `mc: --mem: at most 1048576` | past the option's maximum — 86400 for `--time` and `--wall`, 1048576 MiB for `--mem`, 65536 MiB for `--out`. Exit 2 | a value inside the range |
| `mc: --time: must be at least 1` | zero, for any of the four caps. Exit 2 | one or more. A cap of zero is a box that cannot start |
| `mc: unknown --allow value: X` | only `threads` exists today. Exit 2 | `--allow=threads` |
| `mc: unknown --libc value: X` | `--libc` takes `musl` or `gnu`. Exit 2 | one of the two, or leave it out and let `PT_INTERP` decide |
| `mc: too many --ro directories` | more than 16. Exit 2 | the box mounts one bind per `--ro`; group them under a common parent |
| `mc: sandbox run needs a source path` / `mc: sandbox exec needs a program` | the verb had options and nothing else. Exit 2 | give it the path |
| `mc: sandbox run: not in this step` / `mc: sandbox exec: not in this step` | a compiler built before M43 step B, where only `mc sandbox check` existed. Exit 126 | gone since step B: `run` and `exec` build the box ([sandbox.md](sandbox.md)) |
| `sandbox: cannot install the Landlock ruleset: ERRNO` / `cannot install the seccomp filter: ERRNO` / `cannot fetch the seccomp listener: ERRNO` | the three step-C ways the box can fail to be built, reported like every other `cannot` site. Exit 126 | `mc sandbox check` first: a kernel below Landlock ABI 4, or without `SECCOMP_RET_USER_NOTIF`, cannot run this box |

The report is not a diagnostic table either: it is a fixed vocabulary written to stderr (and to
`--report FILE`) after the box is gone, and [sandbox.md](sandbox.md) § The report is where it is
defined. The five lines that end a box with **125** are the ones a person is most likely to have
to read, so they are here too:

| line | cause | fix |
|---|---|---|
| `sandbox: refused: syscall N (name)` | the step made a call that is in no profile for its step, architecture and C library. The number is this architecture's | if the call is legitimate for the corpus, re-measure: `make sandbox-trace` ([sandbox.md](sandbox.md) § The profiles). `socket`, `connect` and `bind` are refused on purpose; `clone`, `clone3`, `fork` and `vfork` never reach this row at all -- they have two of their own below |
| `sandbox: refused: open PATH` | an `openat`/`open` of a path under none of the box's roots (`/src`, `/out`, `/mc`, `/lib`, `/lib64`, `/usr/lib`, `/roN`) | `--ro DIR` puts one more tree in the box, at `/ro0`, `/ro1`, … A program that probes for a file it does not expect to find is stopped just the same: the box does not answer ENOENT for a path it will not look at |
| `sandbox: refused: mmap N bytes over the cap (M)` | the running total of what the step has mapped went past `--mem` | raise `--mem`; `RLIMIT_AS` is the same number and the kernel's own wall behind it |
| `sandbox: refused: process limit (N)` | the step created one process more than it may: **16** in a compile step, **0** in a run step, **64** with `--allow=threads`. Every `clone`, `clone3`, `fork` and `vfork` is counted — no profile allows one | with `--allow=threads` a real *thread* is free and never counted. A compile that legitimately needs more processes than sixteen is a project this box will not build |
| `sandbox: refused: clone with namespace flags` | a `clone` or `clone3` whose flags carry a `CLONE_NEW*` bit: a program in the box asking for a namespace of its own | there is no option for it. The box is a set of namespaces and one made inside it is where an unprivileged process starts collecting capabilities |
| `sandbox: refused: clone3 with unreadable arguments` | a `clone3` whose `struct clone_args` could not be read out of the step with `process_vm_readv` (the flags live there and BPF cannot follow a pointer) | a process-creating call whose flags cannot be inspected is not one to let through |
| `sandbox: refused: execve` | a step exec'd more times than its budget — three for a compile step, one for a run step | a program that re-execs itself is out of scope for the box |

`mc sandbox check` is not a diagnostic: it writes its six lines to **stdout** and exits 1 when a
capability is missing. The one line most likely to need reading is
`userns: restricted (apparmor)` — [sandbox.md](sandbox.md) § The AppArmor restriction says what
it means and what the two ways out are.

## 12. Runtime and I/O

| message | cause | fix |
|---|---|---|
| `mc: cannot open: PATH` | a source, include or config that cannot be read | check the path. For `#include "x"` the search is the includer's directory, then each `[include].paths` root |
| `mc: cannot create: PATH` | the output could not be created | check the directory and its permissions; `mc build` creates parent directories, the single-file CLI does not |
| `mc: read error: PATH` | a short or failed read | the file changed under the compiler, or the medium failed |
| `mc: arena exhausted (R MiB reserved, E MiB estimated, asked N bytes) while parsing FILE:LINE -- raise [limits].tolerance or HEAP_SIZE` | the compiler's arena could not grow | the arena starts at a static 32 MiB and grows by `mmap`; this means the kernel refused. The numbers say what was already reserved, what the plan had estimated and what did not fit; `while parsing` is where the parser was, and appears only while it is parsing: the pre-scan, the passes, the codegen and the object writer report no position rather than the last line the lexer happened to reach. Raise `[limits].tolerance` so the estimate reserves more up front, or split the translation unit |
| `mc: cannot reserve the arena (…) -- raise [limits].tolerance or HEAP_SIZE` | the initial reservation failed | same message, same numbers, at the first `mmap` |

## 13. Packages

Everything here comes from `src/deps.mc` and `src/lex.mc`; the model behind them is
[packages.md](packages.md). Five of the messages are exit **2** -- "the environment is not ready",
the same code and the same `run:` block as § 11 -- and four are exit 1, because they are about the
source or about the config.

| message | exit | cause | fix |
|---|---|---|---|
| `mc: geo 1.2.0: vec.mc does not match mc.lock` | 2 | the bytes of a file inside a locked package are not the ones the lock pins. The FILE is named when the installation carries a cache manifest (`<libs>/<pack>/v<version>.toml`) to attribute it to | `mc pkg verify`; if the change was yours, re-sync so the lock records it |
| `mc: geo 1.2.0: mc.toml does not match mc.lock` | 2 | every file line still matches, so what moved is the package's own manifest -- its `[package].files` list | the same |
| `mc: geo 1.2.0: the tree does not match mc.lock` | 2 | the same disagreement in a VENDORED tree, which has no manifest to attribute it to | the same |
| `mc: mc.lock is stale: geo` | 2 | `[deps]` names a package the lock lacks, or asks a minimum above the version the lock pins. With no name after the colon, the lock file itself is missing | `mc pkg sync --yes` |
| `mc: geo 1.2.0 is not fetched` | 2 | the lock names a version that is neither vendored in `deps/geo/` nor installed under `<libs>/geo/v1.2.0/` with its manifest | `mc pkg sync --yes`, or vendor it, or point `--libs-dir` at an installation that has it |
| `mc: geo 1.2.0: no mc.toml in the package tree` | 2 | the tree was found but carries no manifest at all | the directory is not a package; re-fetch it |
| `mc: a file the package lists is missing: PATH` | 2 | `[package].files` names a file the tree does not hold, so the hash cannot be computed | the tree is incomplete; re-fetch it |
| `geo/vec.mc:3: package geo reaches outside its tree: PATH` | 1 | a file under a package root tried to `#include` or `#embed` something that is not its own tree, not a library this binary ships and not a declared dependency ([packages.md](packages.md) § 5) | the package's bug: it must declare what it reads in its own `[deps]` |
| `geo/extra.mc:1: not declared in geo's [package].files` | 1 | the build read a file inside a package that the package did not list | the package's bug, unless the file was planted: `files` is the boundary |
| `mc.toml:8:6: reserved package name: deps.mc` | 1 | `mc`, `deps` or `build` in `[deps]` or `[replace]`. `mc` is the compiler's own package and can never be pinned | pick another name |
| `mc.toml:8:7: invalid package name: deps.Geo` | 1 | the name is not `[a-z][a-z0-9_]*` of at most 32 bytes | lower case, digits and `_` |
| `prog.mc:1: unknown bundled include: geo/geo` | 1 | none of the three resolution steps had the name. In the single-file CLI there is no lock and therefore no step 1 at all | `mc build` with a `[deps]` entry, or `--include=DIR` and a quote include |
| `mc: --libs-dir requires an argument` | 1 | the flag was last on the command line | give it a directory |

Note the shape of the first three: `<name> <version>: <what> does not match mc.lock`. The middle
field is a file inside the package, `mc.toml` when the manifest itself moved, and `the tree` when
there is nothing to attribute it to.

---

## Reproducing them

Each of these is a real, compiled sample:

```mc
// expect-error: cannot redefine core keyword
#rule stmt: if ( expr $c ) block $b => loop { $b }
i64 main() { return 0; }
```

```mc
// expect-error: reloc UNSIGNED requires 8 bytes
i64 main() {
    reloc(UNSIGNED, "_main");
    emit(0x00000000);
}
```

```mc
// expect-error: name already defined by #define
#define LIMIT 10
i64 LIMIT = 5;
i64 main() { return 0; }
```

```mc
// expect-error: \0 not allowed in string
#include <sys>
i64 main() { write(1, "a\0b", 3); return 0; }
```

```mc
// expect-error: at most 12 parameters
i64 f(i64 a, i64 b, i64 c, i64 d, i64 e, i64 g, i64 h, i64 i,
      i64 j, i64 k, i64 l, i64 m, i64 n) { return a; }
i64 main() { return 0; }
```

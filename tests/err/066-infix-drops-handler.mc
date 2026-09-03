// M21: a `#infix` on a token taught by syntax_infix DROPS the handler —
// infix_set rewrites the whole entry, INF_FN included, so the template wins and
// the operator goes back to being an ordinary binary one. `~>` then stops
// resolving the name on its right in the module's field table, and `len`
// becomes an ordinary name that does not exist. Expected:
//
//   tests/err/066-infix-drops-handler.mc:12: unknown name
#infix "~>" 12 left $1 + $2

i64 main() {
    uptr p = 0;
    return p ~> len;
}

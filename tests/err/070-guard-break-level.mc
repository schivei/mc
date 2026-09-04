// M31 (2.2): the on_jump handler sees the node KIND and the node itself, so it
// can tell a `break 2` -- which provably leaves more than the guard body -- from
// a `break` that does not. The demo's guard refuses the first. Expected:
//
//   tests/err/070-guard-break-level.mc:12: guard: break N leaves more than the guard body
i64 g_n = 0;
i64 bump() { g_n = g_n + 1; return 0; }

i64 main() {
    loop {
        loop {
            guard bump() { break 2; }
        }
    }
    return g_n;
}

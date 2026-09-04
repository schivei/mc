// user_core_min.mc — the user_init of the smallest compiler that exists:
// <mc/core_min> alone, plus one machine and one writer, both stubs (M41,
// Acceptance 4 of docs/specs/M41.md).
//
// It is deliberately not a compiler that produces code: the machine's slots do
// nothing and the backend writes no file. It exists so scripts/check-parts.sh
// can BUILD a core_min-only binary and measure it -- what a compiler costs
// before any target is in it, and which symbols are provably absent -- without
// having to invent a real machine first. The real one is examples/kernel's
// (M39) and M40's AVR.
//
// Two slots, not thirty-one: a machine table is MTASK_COUNT entries of `&fn`,
// the walker only reaches a slot when it lowers something, and this compiler is
// never asked to. machine_slot bounds-checks the index, so the table is honest
// about what it fills; the rest stay 0 and `mc --dump-machine` reports them as
// taught, which they are.
uptr m_probe[MTASK_COUNT];

void probe_nop() { }

// a writer that writes nothing. backend_default() names it, which is what gives
// `mc x.mc -o x.o` an answer in a compiler with no target registry at all.
void backend_null(i64 unit, uptr out) { }

void user_init() {
    machine_slot(m_probe, MTASK_PROLOGUE, &probe_nop);
    machine_slot(m_probe, MTASK_EPILOGUE, &probe_nop);
    machine("probe", m_probe);
    backend("null", &backend_null);
    backend_default("null");
}

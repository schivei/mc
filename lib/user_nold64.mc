// user_nold64.mc — a compiler with no `ld64` (M41, Acceptance 5).
//
// intrinsic_disable removes the NAME, not the width: st64 still exists, and so
// does the TY_U64 the intrinsic used to yield. This is M40 § 2B's mitigation in
// its smallest form -- on a two-byte word the wide pair is silently wrong, so a
// dialect for such a target makes it unreachable and offers its own ldw/stw.
void user_init() { intrinsic_disable("ld64"); }

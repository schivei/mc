// lang_solo.mc — `lx` with no module stacked on top of it.
//
// lang.mc ends its `user_init` with `lg_more()`, the chain point a SECOND
// module registers from (a compiler may hold only one `user_init`, and it is
// lang.mc's). This file is the empty default: it is the last entry of this
// project's `[compiler].modules`, and a project that stacks a module — as
// examples/conc does, with `["../lang/lang.mc", "conc.mc"]` — leaves it out and
// defines `lg_more` itself.

void lg_more() { }

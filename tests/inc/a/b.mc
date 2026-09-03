// b.mc — inclui o irmao do diretorio de cima; path_join normaliza o .. antes
// do once-only, entao c.mc entra uma vez so.
#include "../c.mc"

i64 pelo_b() { return comum() + 2; }

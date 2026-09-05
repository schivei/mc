// def.mc -- `mc` itself, spelled with library names only. Compiled by the
// bundle-less probe compiler (tests/pkg/nobundle.mc) it is the proof that step 3
// of the resolution order works: every one of these names is served from
// <libs>/mc/v<version>/ and the object comes out equal to build/mc2.o.
#include <mc/host>
#include <mc/core>
#include <user_default>

// lang_tab.mc — every table the `lx` module keeps, as flat records with
// accessors, in the project's mandatory style (docs/determinism.md, rule 1: a
// linear array in registration order, no hashing, nothing iterated for output).
//
// Nothing here knows the core: it is the module's own bookkeeping. The core
// hands out positions, spans and a second source; naming, layout, typing and
// ownership are all decided in these tables.

#include "../../lib/prelude.mc"

#define LG_MAXCLASS  96
#define LG_MAXFIELD  512
#define LG_MAXMETH   512
#define LG_MAXVSLOT  512
#define LG_MAXCI     128              // (class, interface) pairs
#define LG_MAXIFACE  16
#define LG_MAXIMETH  64
#define LG_MAXLOCAL  128
#define LG_MAXLOOP   16
#define LG_MAXNS     16
#define LG_MAXUSING  16
#define LG_MAXGEN    32
#define LG_MAXGP     4                // generic parameters of one generic
#define LG_MAXINST   96
#define LG_MAXXT     2048
#define LG_MAXDONE   512
#define LG_MAXFN     256
#define LG_MAXREG    256

#define LG_HEADER    16               // vtable word + reference count
#define LG_VT_FIXED  2                // vtable words before the virtual slots

// One writer for every table. Each record is a flat block in a global array and
// each field is a `#define` offset, so a single store covers all of them; the
// named GETTERS below are what carries the documentation. Sixty-five one-line
// setters is what this file had first, and the compiler's arena is tight enough
// that they were worth collapsing into these two -- lang_main.mc's header has
// the measurement.
void lg_put(uptr rec, i64 field, i64 v)   { st64(rec + field, v); }
void lg_puta(uptr arr, i64 i, i64 v)      { st64(arr + i * 8, v); }

// ---- class ----
#define CL_NAME  0                    // mangled name: Circle, geo__Circle, Box__Circle__4
#define CL_BASE  8                    // base class index, -1
#define CL_SZ    16                   // object size in bytes, header included
#define CL_V0    24                   // first virtual slot in the vs_ table
#define CL_NV    32
#define CL_REC   40

u8   lg_cls[LG_MAXCLASS * CL_REC];
i64  lg_ncls = 0;

uptr cl_at(i64 i)    { return lg_cls + i * CL_REC; }
uptr cl_name(uptr c) { return ld64(c + CL_NAME); }
i64  cl_base(uptr c) { return ld64(c + CL_BASE); }
i64  cl_sz(uptr c)   { return ld64(c + CL_SZ); }
i64  cl_v0(uptr c)   { return ld64(c + CL_V0); }
i64  cl_nv(uptr c)   { return ld64(c + CL_NV); }

// ---- field ----
#define FD_NAME 0
#define FD_OWN  8                     // class that declares the field
#define FD_TY   16                    // TY_*
#define FD_CLS  24                    // class index of the field's type, -1
#define FD_IF   32                    // interface index, -1
#define FD_OFF  40
#define FD_NEL  48                    // 0 = scalar, N = inline array of N elements
#define FD_REC  56

u8  lg_fld[LG_MAXFIELD * FD_REC];
i64 lg_nfld = 0;

uptr fd_at(i64 i)    { return lg_fld + i * FD_REC; }
uptr fd_name(uptr f) { return ld64(f + FD_NAME); }
i64  fd_own(uptr f)  { return ld64(f + FD_OWN); }
i64  fd_ty(uptr f)   { return ld64(f + FD_TY); }
i64  fd_cls(uptr f)  { return ld64(f + FD_CLS); }
i64  fd_if(uptr f)   { return ld64(f + FD_IF); }
i64  fd_off(uptr f)  { return ld64(f + FD_OFF); }
i64  fd_nel(uptr f)  { return ld64(f + FD_NEL); }

// ---- method ----
#define MT_NAME 0                     // as written: area, push, show
#define MT_FN   8                     // generated function: Circle_area
#define MT_CLS  16                    // owner class index
#define MT_RET  24                    // TY_*
#define MT_RCLS 32
#define MT_RIF  40
#define MT_SLOT 48                    // virtual slot, -1 when not virtual
#define MT_NP   56                    // parameters besides self
#define MT_KIND 64                    // 0 plain, 1 virtual, 2 override
#define MT_PARAMS 72                  // the N_PARAM list, self included
#define MT_REC  80

u8  lg_mth[LG_MAXMETH * MT_REC];
i64 lg_nmth = 0;

uptr mt_at(i64 i)    { return lg_mth + i * MT_REC; }
uptr mt_name(uptr m) { return ld64(m + MT_NAME); }
uptr mt_fn(uptr m)   { return ld64(m + MT_FN); }
i64  mt_cls(uptr m)  { return ld64(m + MT_CLS); }
i64  mt_ret(uptr m)  { return ld64(m + MT_RET); }
i64  mt_rcls(uptr m) { return ld64(m + MT_RCLS); }
i64  mt_rif(uptr m)  { return ld64(m + MT_RIF); }
i64  mt_slot(uptr m) { return ld64(m + MT_SLOT); }
i64  mt_np(uptr m)   { return ld64(m + MT_NP); }
i64  mt_kind(uptr m) { return ld64(m + MT_KIND); }
i64  mt_params(uptr m) { return ld64(m + MT_PARAMS); }

// ---- virtual slot: the resolved table of one class ----
#define VS_M   0                      // method name the slot stands for
#define VS_FN  8                      // function that implements it in this class
#define VS_REC 16

u8  lg_vs[LG_MAXVSLOT * VS_REC];
i64 lg_nvs = 0;

uptr vs_at(i64 i)    { return lg_vs + i * VS_REC; }
uptr vs_m(uptr v)    { return ld64(v + VS_M); }
uptr vs_fn(uptr v)   { return ld64(v + VS_FN); }

// ---- interfaces implemented by a class: (owner class, interface) pairs ----
#define CI_OWN 0
#define CI_IF  8
#define CI_REC 16

u8  lg_ci[LG_MAXCI * CI_REC];
i64 lg_nci = 0;

uptr ci_at(i64 i)   { return lg_ci + i * CI_REC; }
i64  ci_own(uptr e) { return ld64(e + CI_OWN); }
i64  ci_if(uptr e)  { return ld64(e + CI_IF); }

// ---- interface ----
#define IF_NAME  0
#define IF_NM    8
#define IF_REC   16

u8  lg_ifc[LG_MAXIFACE * IF_REC];
i64 lg_nifc = 0;

uptr if_at(i64 i)     { return lg_ifc + i * IF_REC; }
uptr if_name(uptr f)  { return ld64(f + IF_NAME); }
i64  if_nm(uptr f)    { return ld64(f + IF_NM); }

// ---- interface method ----
#define IM_NAME 0
#define IM_OWN  8                     // interface that declares the method
#define IM_RET  16
#define IM_RCLS 24
#define IM_RIF  32
#define IM_NP   40
#define IM_REC  48

u8  lg_imth[LG_MAXIMETH * IM_REC];
i64 lg_nimth = 0;

uptr im_at(i64 i)    { return lg_imth + i * IM_REC; }
uptr im_name(uptr m) { return ld64(m + IM_NAME); }
i64  im_own(uptr m)  { return ld64(m + IM_OWN); }
i64  im_ret(uptr m)  { return ld64(m + IM_RET); }
i64  im_rcls(uptr m) { return ld64(m + IM_RCLS); }
i64  im_rif(uptr m)  { return ld64(m + IM_RIF); }
i64  im_np(uptr m)   { return ld64(m + IM_NP); }

// ---- local / parameter of the function being parsed ----
#define LV_NAME  0
#define LV_CLS   8
#define LV_IF    16
#define LV_REF   24                   // 1 = `ref` parameter (a uptr holding an address)
#define LV_RW    32                   // width the ref parameter loads and stores
#define LV_PARAM 40                   // 1 = parameter (borrowed: no rc traffic)
#define LV_REC   48

u8  lg_lv[LG_MAXLOCAL * LV_REC];
i64 lg_nlv = 0;

uptr lv_at(i64 i)     { return lg_lv + i * LV_REC; }
uptr lv_name(uptr l)  { return ld64(l + LV_NAME); }
i64  lv_cls(uptr l)   { return ld64(l + LV_CLS); }
i64  lv_if(uptr l)    { return ld64(l + LV_IF); }
i64  lv_ref(uptr l)   { return ld64(l + LV_REF); }
i64  lv_rw(uptr l)    { return ld64(l + LV_RW); }
i64  lv_param(uptr l) { return ld64(l + LV_PARAM); }

// ---- loop marks: a plain stack of `lg_nlv` values, one per while/for ----
i64 lg_lp[LG_MAXLOOP];
i64 lg_nlp = 0;

i64  lp_at(i64 i)          { return ld64(lg_lp + i * 8); }

// ---- plain functions the module declared, so a call site knows its type ----
#define FN_NAME 0
#define FN_RCLS 8
#define FN_RIF  16
#define FN_REC  24

u8  lg_fns[LG_MAXFN * FN_REC];
i64 lg_nfns = 0;

uptr fn_at(i64 i)     { return lg_fns + i * FN_REC; }
uptr fnr_name(uptr f) { return ld64(f + FN_NAME); }
i64  fnr_rcls(uptr f) { return ld64(f + FN_RCLS); }
i64  fnr_rif(uptr f)  { return ld64(f + FN_RIF); }

// ---- names this module has already reserved in the lexer ----
uptr lg_reg[LG_MAXREG];
i64  lg_nreg = 0;

uptr reg_at(i64 i)          { return ld64(lg_reg + i * 8); }

// ---- namespaces and `using` ----
uptr lg_ns[LG_MAXNS];
i64  lg_nns = 0;
uptr lg_us[LG_MAXUSING];
i64  lg_nus = 0;

uptr ns_at(i64 i)          { return ld64(lg_ns + i * 8); }
uptr us_at(i64 i)          { return ld64(lg_us + i * 8); }

// ---- generic declaration: the recorded body plus its parameters ----
#define GN_NAME  0                    // mangled name of the generic itself
#define GN_NS    8
#define GN_KIND  16                   // 0 = class, 1 = fn
#define GN_NP    24
#define GN_BODY  32                   // the recorded span
#define GN_BLEN  40
#define GN_P0    48                   // parameter names, 4 slots
#define GN_K0    80                   // parameter kinds, 4 slots (0 = type, 1 = const)
#define GN_REC   112

u8  lg_gen[LG_MAXGEN * GN_REC];
i64 lg_ngen = 0;

uptr gn_at(i64 i)     { return lg_gen + i * GN_REC; }
uptr gn_name(uptr g)  { return ld64(g + GN_NAME); }
uptr gn_ns(uptr g)    { return ld64(g + GN_NS); }
i64  gn_kind(uptr g)  { return ld64(g + GN_KIND); }
i64  gn_np(uptr g)    { return ld64(g + GN_NP); }
uptr gn_body(uptr g)  { return ld64(g + GN_BODY); }
i64  gn_blen(uptr g)  { return ld64(g + GN_BLEN); }
uptr gn_p(uptr g, i64 i)  { return ld64(g + GN_P0 + i * 8); }
i64  gn_k(uptr g, i64 i)  { return ld64(g + GN_K0 + i * 8); }

void set_gn_p(uptr g, i64 i, uptr v) { st64(g + GN_P0 + i * 8, v); }
void set_gn_k(uptr g, i64 i, i64 v)  { st64(g + GN_K0 + i * 8, v); }

// ---- instantiations already generated, by mangled name and in first-use order ----
uptr lg_inst[LG_MAXINST];
i64  lg_ninst = 0;

uptr inst_at(i64 i)          { return ld64(lg_inst + i * 8); }

// ---- static type of an expression the module built ----
// Keyed by node index, deliberately OUTSIDE the node: docs/surface.md warns
// that a side table must never live in nd_c/nd_d, because dump_node walks
// those as node indices.
#define XT_N   0
#define XT_CLS 8
#define XT_IF  16
#define XT_OWN 24                     // 1 = the value carries a reference of its own
#define XT_ETY 32                     // element type when the node is an array base, -1 otherwise
#define XT_REC 40

u8  lg_xt[LG_MAXXT * XT_REC];
i64 lg_nxt = 0;

uptr xt_at(i64 i)   { return lg_xt + i * XT_REC; }
i64  xt_n(uptr x)   { return ld64(x + XT_N); }
i64  xt_cls(uptr x) { return ld64(x + XT_CLS); }
i64  xt_if(uptr x)  { return ld64(x + XT_IF); }
i64  xt_own(uptr x) { return ld64(x + XT_OWN); }
i64  xt_ety(uptr x) { return ld64(x + XT_ETY); }

// ---- nodes the module has already lowered (the return it generated itself) ----
i64 lg_done[LG_MAXDONE];
i64 lg_ndone = 0;

i64  done_at(i64 i)          { return ld64(lg_done + i * 8); }

// ---- the state of the declaration being read ----
uptr lg_cur_ns  = 0;                  // namespace prefix in effect; user_init sets it to ""
i64  lg_cur_cls = -1;                 // class whose body is open, -1
i64  lg_in_fn   = 0;                  // 1 while an `lx` fn body is being parsed
i64  lg_lv_floor = 0;                 // first local visible from the current fn
i64  lg_fn_lv0  = 0;                  // first local of the current fn (the params come before)
i64  lg_fn_ret  = 0;                  // TY_* the current fn returns
i64  lg_fn_rcls = -1;
i64  lg_fn_rif  = -1;
i64  lg_line    = 0;                  // position used on generated nodes
uptr lg_file    = 0;
i64  lg_tok_dot = 0;                  // token ids the module registers
i64  lg_tok_arrow = 0;
i64  lg_tok_addassign = 0;
i64  lg_tok_subassign = 0;
i64  lg_tok_fn = 0;
i64  lg_tok_ref = 0;

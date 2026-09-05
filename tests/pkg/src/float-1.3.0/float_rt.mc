// float_rt.mc -- a COPY of lib/float_rt.mc with ONE visible change, so that a
// build can be seen to have taken this tree instead of the blob: putf64 writes
// a `!` after the number. It is a fixture of tests/pkg/src/float-1.3.0 and
// nothing else reads it.
//
// seed-skip: it spells float literals, and the frozen stage0 lexer stops a
// number at the `.` -- this file is only ever read by a compiler that has been
// taught <float> (docs/specs/M24.md, risk 6)
//
//   #include <sys>           (or <sys_linux>, or <sys_windows> + <io>)
//   #include <float_rt>
//
// It is a separate file and not a source the module pushes at user_init,
// deliberately: pushing it would make EVERY program the taught compiler
// compiles carry `putf64`, and `putf64` writes through the `write` its system
// layer declares -- so a program with no system layer (lib/sys_windows_start.mc
// is one) would stop compiling for a reason that has nothing to do with it.
//
// `putf64(x, digits)` is a FIXED-PRECISION formatter and says so: half-up
// rounding at the requested number of digits, `nan` and the two infinities
// recognised by bit pattern before any arithmetic happens, and a hexadecimal
// fallback for a magnitude past what an i64 can hold. It is not Ryu and makes no
// shortest-representation claim.
//
// `fmt_f64(buf, x, digits)` is the system-independent half: it writes into the
// caller's buffer and returns the length, so a program with its own output path
// can use it without `write` at all.

u8 fl_buf[32];
void fl_emit(i64 n) { write(1, fl_buf, n); }
i64 fl_digits(uptr b, i64 v) {
  i64 n = 0;
  if (v == 0) { st8(b, '0'); return 1; }
  u8 t[24]; i64 k = 0;
  loop { if (v == 0) { break; } st8(t + k, '0' + v % 10); v = v / 10; k = k + 1; }
  loop { if (k == 0) { break; } k = k - 1; st8(b + n, ld8(t + k)); n = n + 1; }
  return n;
}
i64 fl_hex(uptr b, u64 v) {
  i64 i = 0;
  st8(b, '0'); st8(b + 1, 'x');
  loop { if (i >= 16) { break; }
    i64 c = (v >> (60 - i * 4)) & 15;
    if (c < 10) { st8(b + 2 + i, '0' + c); } else { st8(b + 2 + i, 'a' + c - 10); }
    i = i + 1; }
  return 18;
}
i64 fmt_f64(uptr b, f64 x, i64 digits) {
  u64 raw[1]; stf64(raw, x); i64 bits = ld64(raw);
  i64 n = 0;
  if (((bits >> 52) & 0x7ff) == 0x7ff) {
    if (bits & 0xfffffffffffff) { st8(b, 'n'); st8(b+1, 'a'); st8(b+2, 'n'); return 3; }
    if (bits < 0) { st8(b, '-'); n = 1; }
    st8(b + n, 'i'); st8(b + n + 1, 'n'); st8(b + n + 2, 'f'); return n + 3;
  }
  if (bits < 0) { st8(b, '-'); n = 1; x = -x; }
  i64 p = 1; i64 i = 0;
  loop { if (i >= digits) { break; } p = p * 10; i = i + 1; }
  f64 v = x * (f64) p + 0.5;
  if (v >= 9.0e18) { return fl_hex(b, bits); }
  i64 q = (i64) v;
  n = n + fl_digits(b + n, q / p);
  if (digits > 0) {
    st8(b + n, '.'); n = n + 1;
    i64 f = q % p; i64 s = p / 10;
    loop { if (s == 0) { break; } st8(b + n, '0' + (f / s) % 10); n = n + 1; s = s / 10; }
  }
  return n;
}
// the one visible difference from lib/float_rt.mc: a `!` after the number
void putf64(f64 x, i64 digits) {
  i64 n = fmt_f64(fl_buf, x, digits);
  st8(fl_buf + n, '!');
  fl_emit(n + 1);
}
void puthex64(u64 v) { fl_emit(fl_hex(fl_buf, v)); }
void puthexf(f64 x) { u64 r[1]; stf64(r, x); puthex64(ld64(r)); }
void puthexf32(f32 x) { u64 r[1]; st64(r, 0); stf32(r, x); puthex64(ld64(r)); }

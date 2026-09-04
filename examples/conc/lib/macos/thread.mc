// thread.mc -- the platform layer: what libSystem gives this runtime, declared
// as ordinary `extern`s. One file per system, exactly as lib/sys.mc and
// lib/sys_linux.mc split the I/O; this one is macOS/arm64 and its Linux
// sibling is lib/linux/thread.mc (M37). Which of the two is compiled is
// [include].paths in mc.toml (`lib/macos`) or mc.linux.toml (`lib/linux`):
// lib/rt.mc writes `#include "thread.mc"` and its own directory no longer has
// one, so the roots decide.
//
// An mc `uptr f(uptr)` IS a C `void *(*)(void *)` -- one integer in, one out --
// so `&f` (M10) is a valid thread entry with no shim. The opaque structs are
// reserved as bytes and passed by address:
//
//     pthread_mutex_t   8 + 56 = 64 bytes   sig 0x32AAABA7 when statically initialized
//     pthread_cond_t    8 + 40 = 48 bytes   sig 0x3CB0B1BB
//     pthread_t         one word (it is a pointer)
//
// Those two signatures are what PTHREAD_MUTEX_INITIALIZER and
// PTHREAD_COND_INITIALIZER expand to, so a global
// `u64 m[8] = { PT_MUTEX_SIG, 0, 0, 0, 0, 0, 0, 0 };` is a ready-to-use mutex
// with no boot step at all -- which is how this runtime avoids the
// chicken-and-egg of "the lock that protects the lock's initialization".
//
// POSIX unnamed semaphores are stubbed out on macOS (sem_init returns ENOSYS),
// so the semaphore here is libdispatch's. DISPATCH_TIME_FOREVER is ~0, spelled
// `0 - 1` because the language has no unsigned literal that wide.
//
// None of these is variadic, which matters: the core does not lay out the stack
// portion of a variadic call (lib/sys.mc says the same about `open`).

#define PT_MUTEX_SIG 0x32AAABA7
#define PT_COND_SIG  0x3CB0B1BB
#define PT_MUTEX_SZ  64
#define PT_COND_SZ   48
#define DISPATCH_FOREVER (0 - 1)

extern i64  pthread_create(uptr th, uptr attr, uptr entry, uptr arg);
extern i64  pthread_join(uptr th, uptr ret);
extern i64  pthread_detach(uptr th);
extern uptr pthread_self();

extern i64 pthread_mutex_init(uptr m, uptr attr);
extern i64 pthread_mutex_lock(uptr m);
extern i64 pthread_mutex_unlock(uptr m);
extern i64 pthread_mutex_destroy(uptr m);

extern i64 pthread_cond_init(uptr c, uptr attr);
extern i64 pthread_cond_wait(uptr c, uptr m);
extern i64 pthread_cond_signal(uptr c);
extern i64 pthread_cond_broadcast(uptr c);

extern uptr dispatch_semaphore_create(i64 value);
extern i64  dispatch_semaphore_wait(uptr sem, i64 timeout);
extern i64  dispatch_semaphore_signal(uptr sem);

// hw.optional.arm.FEAT_LSE, read as a 32-bit int. Returns 0 on a machine that
// does not report the feature and on a machine where the name does not exist.
extern i64 sysctlbyname(uptr name, uptr oldp, uptr oldlenp, uptr newp, i64 newlen);

i64 conc_has_lse() {
    u8 val[8];
    u8 len[8];
    st64(val, 0);
    st64(len, 4);
    if (sysctlbyname("hw.optional.arm.FEAT_LSE", val, len, 0, 0) != 0) return 0;
    return ld32(val);
}

// ---- the counting semaphore ----
// POSIX unnamed semaphores are stubbed out on macOS, so this is libdispatch's.
// The three names are the whole interface lib/conc_rt.mc uses.
uptr gate_new(i64 value) {
    uptr s = dispatch_semaphore_create(value);
    if (s == 0) conc_die("dispatch_semaphore_create failed");
    return s;
}

void gate_wait(uptr s) { dispatch_semaphore_wait(s, DISPATCH_FOREVER); }
void gate_post(uptr s) { dispatch_semaphore_signal(s); }

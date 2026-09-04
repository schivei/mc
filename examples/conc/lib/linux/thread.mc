// thread.mc -- the platform layer on Linux, against musl (M37). It is
// lib/macos/thread.mc's sibling: same names, same shapes, different libc.
// [include].paths in mc.linux.toml is what picks this directory.
//
// Three things differ from macOS and only three:
//
//   * the counting semaphore. macOS stubs POSIX unnamed semaphores out and the
//     runtime uses libdispatch there; here `sem_init`/`sem_wait`/`sem_post` are
//     the real thing, and a semaphore is a 32-byte object the caller owns
//     rather than a pointer the system hands back -- so gate_new allocates it.
//   * the static initializers. PTHREAD_MUTEX_INITIALIZER and
//     PTHREAD_COND_INITIALIZER are all zeros on Linux, where macOS puts a magic
//     signature in the first word. The two PT_*_SIG below are 0 for exactly
//     that reason, and the globals in lib/conc_rt.mc need no other change.
//   * the LSE probe. There is no `sysctlbyname`; `getauxval(AT_HWCAP)` carries
//     HWCAP_ATOMICS, which is the same question asked of the kernel.
//
// The struct sizes are the maxima of musl and glibc (mutex 40 both, cond 48
// both, sem_t 32 both); the runtime reserves bytes and passes addresses, so
// reserving a little more than the libc needs is safe and reserving less is not.

#define PT_MUTEX_SIG 0
#define PT_COND_SIG  0
#define PT_MUTEX_SZ  64
#define PT_COND_SZ   48
#define PT_SEM_SZ    32

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

// sem_init(sem, pshared, value): pshared 0 = threads of this process only
extern i64 sem_init(uptr sem, i64 pshared, i64 value);
extern i64 sem_wait(uptr sem);
extern i64 sem_post(uptr sem);
extern i64 sem_destroy(uptr sem);

// getauxval(AT_HWCAP) -- 16 is AT_HWCAP, 256 is HWCAP_ATOMICS (the LSE bit).
// On x86-64 the bit is not there and the runtime takes its ldxr/stxr-free
// fallback, which is the correct answer for that machine.
extern i64 getauxval(i64 type);

#define AT_HWCAP       16
#define HWCAP_ATOMICS  256

i64 conc_has_lse() { return (getauxval(AT_HWCAP) & HWCAP_ATOMICS) != 0; }

// ---- the counting semaphore ----
uptr gate_new(i64 value) {
    uptr s = cx_alloc(PT_SEM_SZ);
    if (s == 0) conc_die("cannot allocate a semaphore");
    if (sem_init(s, 0, value) != 0) conc_die("sem_init failed");
    return s;
}

void gate_wait(uptr s) { sem_wait(s); }
void gate_post(uptr s) { sem_post(s); }

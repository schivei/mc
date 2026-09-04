// conc_rt.mc -- the concurrency runtime: mutexes, gates, channels, a worker
// pool and the intent object. Plain CORE `.mc`, like rt.mc: it is program code
// that the default `mc` compiles unchanged, and conc.mc -- the compiler module
// -- only ever generates calls into it.
//
// What the surface lowers to (docs/specs/M31.md section 4):
//
//     intent x = f(a,b)   uptr x = it_submit(it_arg(it_arg(it_new(&f,2,fl),0,a,o0),1,b,o1));
//     spawn f(a)          it_go(it_arg(it_new(&f,1,fl),0,a,o0));
//     await x;            it_drop(x);
//     await r = x;        T r = it_take(x);
//     await r = f(a)      T r = it_call(it_submit(...));
//     await f(a);         it_calld(it_submit(...));
//     lock (m) { ... }    uptr $g = m; mx_lock($g); ... mx_unlock($g);
//
// The intent is an ORDINARY reference-counted object of the host language --
// word 0 a vtable whose slot 0 is the release function, word 1 the count -- so
// every rule `lx` already has for an object (scope exit, `break N`, `return`,
// the `ref` refusal) applies to an intent local with no new code anywhere.
// it_new writes the vtable itself, exactly as a generated C_new calls C_vt_init.
//
// Dispatch: `intent x = f(a)` SUBMITS EAGERLY, at the call. Recording a thunk
// and running it at the `await` would make `await r = f()` identical to
// `r = f()` and the whole feature vacuous. Eager submission alone starves a
// fixed pool the moment a task awaits, so `await` STEALS: it CASes the intent
// from QUEUED to RUNNING and, winning, runs it inline on the awaiting thread
// while the worker that later pops it skips it. Consequences, all intended:
// back-to-back `await r = f()` degrades to a direct call plus bookkeeping,
// parallelism appears exactly when intents are left in flight, and user code
// cannot assume which thread it runs on.

#include "rt.mc"

// ---- the runtime's own arena ----
// Mutexes, channels and pool structures do NOT come from rt_alloc: they are not
// objects, they are never released, and counting them would make live() -- the
// number every ownership test asserts -- mean two different things at once.

#define CX_ARENA 262144

u8  cx_heap[CX_ARENA];
i64 cx_hp = 0;
u64 cx_mtx[8] = { PT_MUTEX_SIG, 0, 0, 0, 0, 0, 0, 0 };

void conc_die(uptr msg) {
    write(2, "conc: ", 6);
    write(2, msg, strlen(msg));
    write(2, "\n", 1);
    exit(70);
}

uptr cx_alloc(i64 n) {
    i64 sz = (n + 15) & ~15;
    pthread_mutex_lock(cx_mtx);
    if (cx_hp + sz > CX_ARENA) {
        pthread_mutex_unlock(cx_mtx);
        conc_die("runtime arena full: too many mutexes or channels");
    }
    uptr p = cx_heap + cx_hp;
    cx_hp = cx_hp + sz;
    pthread_mutex_unlock(cx_mtx);
    rt_zero(p, sz);
    return p;
}

// The one thing this runtime cannot do without. Checked once, from the top of
// main() -- conc.mc registers a pass() that puts the call there -- so a machine
// without LSE gets a sentence instead of SIGILL on the first rc_inc.
void conc_boot() {
    if (conc_has_lse()) return;
    conc_die("this runtime needs ARMv8.1 LSE atomics (ldaddal/casal), and this machine does not report hw.optional.arm.FEAT_LSE; ldaxr/stlxr sequences arrive with M24 #machine");
}

// ---- mutexes and gates ----

uptr mutex_new() {
    uptr m = cx_alloc(PT_MUTEX_SZ);
    pthread_mutex_init(m, 0);
    return m;
}

void mx_lock(uptr m) {
    if (m == 0) rt_panic("lock: the mutex is null");
    pthread_mutex_lock(m);
}

void mx_unlock(uptr m) {
    if (m == 0) rt_panic("lock: the mutex is null");
    pthread_mutex_unlock(m);
}

// The counting semaphore -- gate_new / gate_wait / gate_post -- is the one
// primitive with no portable spelling: POSIX unnamed semaphores are stubbed out
// on macOS (sem_init returns ENOSYS) and libdispatch does not exist on Linux.
// M37 moved the three of them into the platform layer, next to the pthread
// declarations they belong with: lib/macos/thread.mc has the libdispatch ones,
// lib/linux/thread.mc the sem_init/sem_wait/sem_post ones, and [include].paths
// in mc.toml (or mc.linux.toml) is what picks the file.

// ---- channel: a bounded ring, one mutex and two condition variables ----

#define CH_CAP    0
#define CH_HEAD   8
#define CH_TAIL   16
#define CH_N      24
#define CH_CLOSED 32
#define CH_MTX    48                  // 64 bytes: 48..111
#define CH_NE     112                 // not empty: 48 bytes, 112..159
#define CH_NF     160                 // not full:  48 bytes, 160..207
#define CH_BUF    208                 // cap words

uptr chan_new(i64 cap) {
    if (cap < 1) conc_die("chan_new: the capacity must be at least 1");
    uptr c = cx_alloc(CH_BUF + cap * 8);
    st64(c + CH_CAP, cap);
    pthread_mutex_init(c + CH_MTX, 0);
    pthread_cond_init(c + CH_NE, 0);
    pthread_cond_init(c + CH_NF, 0);
    return c;
}

// A channel carries OBJECTS, never scalars: the send takes a reference of its
// own and the receiver's scope drops it, so the payload's word at +8 has to be
// a live reference count. `chan` is an alias of uptr and neither the surface
// nor the host's type checker can see the difference, so the rule is enforced
// here, by bounds: every object comes from rt_alloc and therefore lives inside
// rt_heap, and 0 is what ch_recv returns for `closed and drained`. Without this
// check `chan_send(c, 1)` reached rc_inc(1), which is an atomic read-modify-
// write at address 9, and the program died of SIGBUS (exit 138) with nothing to
// read. README.md section Limits states the rule; this is where it is kept.
void chan_check(uptr v) {
    if (v == 0)
        rt_panic("chan_send: the payload must be an object; 0 is what a closed and drained channel returns");
    if (v < rt_heap)
        rt_panic("chan_send: the payload must be a reference counted object, not a scalar");
    if (v >= rt_heap + RT_ARENA)
        rt_panic("chan_send: the payload must be a reference counted object, not a scalar");
}

// The channel takes a reference OF ITS OWN, which is what makes the transfer
// safe: the sender's scope may end -- and does, in the producer/consumer test --
// before the consumer has looked at the object. Atomic counts fix the counter
// and do nothing for the transfer; this is the half that closes the race.
void chan_send(uptr c, uptr v) {
    chan_check(v);
    pthread_mutex_lock(c + CH_MTX);
    loop {
        if (ld64(c + CH_CLOSED)) break;
        if (ld64(c + CH_N) < ld64(c + CH_CAP)) break;
        pthread_cond_wait(c + CH_NF, c + CH_MTX);
    }
    if (ld64(c + CH_CLOSED)) {
        pthread_mutex_unlock(c + CH_MTX);
        rt_panic("chan_send on a closed channel");
    }
    rc_inc(v);
    i64 t = ld64(c + CH_TAIL);
    st64(c + CH_BUF + t * 8, v);
    st64(c + CH_TAIL, (t + 1) % ld64(c + CH_CAP));
    st64(c + CH_N, ld64(c + CH_N) + 1);
    pthread_cond_signal(c + CH_NE);
    pthread_mutex_unlock(c + CH_MTX);
}

// hands the channel's reference to the caller. Returns 0 once the channel is
// closed AND drained, so `loop { Item it = chan_recv(c); if (it == 0) break; }`
// terminates. The surface spells it `chan_recv`, a syntax_expr registration
// whose only job is to mark the result as already owned so the binding does not
// take a second reference (conc.mc, cc_recv).
uptr ch_recv(uptr c) {
    pthread_mutex_lock(c + CH_MTX);
    loop {
        if (ld64(c + CH_N) > 0) break;
        if (ld64(c + CH_CLOSED)) break;
        pthread_cond_wait(c + CH_NE, c + CH_MTX);
    }
    if (ld64(c + CH_N) == 0) {
        pthread_mutex_unlock(c + CH_MTX);
        return 0;
    }
    i64 h = ld64(c + CH_HEAD);
    uptr v = ld64(c + CH_BUF + h * 8);
    st64(c + CH_BUF + h * 8, 0);
    st64(c + CH_HEAD, (h + 1) % ld64(c + CH_CAP));
    st64(c + CH_N, ld64(c + CH_N) - 1);
    pthread_cond_signal(c + CH_NF);
    pthread_mutex_unlock(c + CH_MTX);
    return v;
}

void chan_close(uptr c) {
    pthread_mutex_lock(c + CH_MTX);
    st64(c + CH_CLOSED, 1);
    pthread_cond_broadcast(c + CH_NE);
    pthread_cond_broadcast(c + CH_NF);
    pthread_mutex_unlock(c + CH_MTX);
}

i64 chan_len(uptr c) {
    pthread_mutex_lock(c + CH_MTX);
    i64 n = ld64(c + CH_N);
    pthread_mutex_unlock(c + CH_MTX);
    return n;
}

// ---- the intent ----

#define IT_STATE   16
#define IT_FN      24
#define IT_NARGS   32
#define IT_FLAGS   40
#define IT_RESULT  48
#define IT_TAKEN   56
#define IT_RUNNER  64                 // slot of the thread running it, -1
#define IT_ARGS    72                 // 8 packed argument words
#define IT_OWNS    136                // 8 ownership tags
#define IT_SIZE    208                // inside the 256-byte free-list ceiling

#define IT_QUEUED  0
#define IT_RUNNING 1
#define IT_DONE    2
// written into the state word by it_release, just before the block goes back to
// the free list. `intent is never awaited in this scope` is a TEXTUAL check in
// the module, not a lifetime guarantee: copying the intent's value into an
// untyped `uptr` before the block closes escapes it (README.md section Limits),
// and the freed 208 bytes are then handed to the next intent. The poison turns
// a use of such a stale pointer into a diagnosable panic instead of two live
// intents silently sharing one block; it survives only until the block is
// reused, which is exactly the window a stale pointer is dangerous in.
#define IT_DEAD    3

#define IT_F_OWNRES 1                 // the result carries a reference
#define IT_F_VOID   2                 // the callee returns nothing

#define MAXTHREADS 16
#define QCAP       512

u64  it_vtbl[2];                      // { &it_release, 0 }: the intent's class

uptr th_id[MAXTHREADS];               // pthread_self() of the slot's owner
uptr th_wait[MAXTHREADS];             // the intent that thread is blocked on
i64  th_n = 0;

uptr pl_q[QCAP];
i64  pl_head = 0;
i64  pl_tail = 0;
i64  pl_n = 0;
i64  pl_nw = 0;                       // workers started
i64  pl_idle = 0;                     // workers parked on pl_work
// Two counters, both moved once per submitted intent and from DIFFERENT points,
// because conc_quiesce() has to outlast both windows: `pl_busy` runs from the
// submit until the worker has popped the item AND dropped the queue's reference,
// `pl_inflight` from the submit until the callee is DONE. Watching the queue
// length alone was wrong -- a worker pops (length 0) and only then starts
// running, so a quiesce in that window returned while a task was about to
// begin. Measured: 2 wrong totals in 200 runs of tests/04-parallel-sum.lx.
i64  pl_busy = 0;
i64  pl_inflight = 0;

u64 pl_mtx[8]  = { PT_MUTEX_SIG, 0, 0, 0, 0, 0, 0, 0 };
u64 pl_work[6] = { PT_COND_SIG, 0, 0, 0, 0, 0 };
u64 pl_done[6] = { PT_COND_SIG, 0, 0, 0, 0, 0 };

// the caller's slot in the thread table, claimed on first use. Called with
// pl_mtx held: the table is the deadlock detector's, and it is walked there.
i64 th_slot_locked() {
    uptr me = pthread_self();
    i64 i = 0;
    loop {
        if (i >= th_n) break;
        if (ld64(th_id + i * 8) == me) return i;
        i = i + 1;
    }
    if (th_n == MAXTHREADS) {
        pthread_mutex_unlock(pl_mtx);
        conc_die("too many threads for the wait-for table");
    }
    st64(th_id + th_n * 8, me);
    st64(th_wait + th_n * 8, 0);
    th_n = th_n + 1;
    return th_n - 1;
}

i64 th_slot() {
    pthread_mutex_lock(pl_mtx);
    i64 s = th_slot_locked();
    pthread_mutex_unlock(pl_mtx);
    return s;
}

// walks the wait-for chain from `it` and answers 1 when it comes back to `me`.
// Stealing cannot break such a cycle -- the intent is already RUNNING on the
// other thread -- so the detector is not redundant. Called with pl_mtx held.
i64 pl_cycle(i64 me, uptr it) {
    i64 steps = 0;
    loop {
        if (steps > MAXTHREADS) return 1;
        i64 r = ld64(it + IT_RUNNER);
        if (r < 0) return 0;                     // queued: nobody is blocked on it
        if (r == me) return 1;
        uptr w = ld64(th_wait + r * 8);
        if (w == 0) return 0;                    // its runner is not waiting
        it = w;
        steps = steps + 1;
    }
    return 0;
}

// one arity switch covers every callee: callp takes the pointer plus up to 7
// arguments, so no per-callee trampoline is needed (docs/specs/M31.md section 3)
i64 it_invoke(uptr f, i64 n, uptr a) {
    if (n == 0) return callp(f);
    if (n == 1) return callp(f, ld64(a));
    if (n == 2) return callp(f, ld64(a), ld64(a + 8));
    if (n == 3) return callp(f, ld64(a), ld64(a + 8), ld64(a + 16));
    if (n == 4) return callp(f, ld64(a), ld64(a + 8), ld64(a + 16), ld64(a + 24));
    if (n == 5) return callp(f, ld64(a), ld64(a + 8), ld64(a + 16), ld64(a + 24),
                             ld64(a + 32));
    if (n == 6) return callp(f, ld64(a), ld64(a + 8), ld64(a + 16), ld64(a + 24),
                             ld64(a + 32), ld64(a + 40));
    if (n == 7) return callp(f, ld64(a), ld64(a + 8), ld64(a + 16), ld64(a + 24),
                             ld64(a + 32), ld64(a + 40), ld64(a + 48));
    rt_panic("intent: at most 7 arguments");
    return 0;
}

// Exactly one it_exec runs per submitted intent -- a worker's, or the thread
// that stole it -- so this is where pl_inflight comes back down.
void it_exec(uptr it, i64 slot) {
    pthread_mutex_lock(pl_mtx);
    st64(it + IT_RUNNER, slot);
    pthread_mutex_unlock(pl_mtx);
    i64 r = it_invoke(ld64(it + IT_FN), ld64(it + IT_NARGS), it + IT_ARGS);
    pthread_mutex_lock(pl_mtx);
    st64(it + IT_RESULT, r);
    st64(it + IT_RUNNER, 0 - 1);
    st64(it + IT_STATE, IT_DONE);
    pl_inflight = pl_inflight - 1;
    pthread_cond_broadcast(pl_done);
    pthread_mutex_unlock(pl_mtx);
}

// runs `it` unless someone has already taken it: this is the worker side of
// stealing, and the only reason a worker may pop an intent and do nothing
void it_run(uptr it, i64 slot) {
    if (a_cas(IT_QUEUED, IT_RUNNING, it + IT_STATE) != IT_QUEUED) return;
    it_exec(it, slot);
}

uptr pl_worker(uptr arg) {
    pthread_mutex_lock(pl_mtx);
    i64 me = th_slot_locked();
    loop {
        loop {
            if (pl_n > 0) break;
            pl_idle = pl_idle + 1;
            pthread_cond_wait(pl_work, pl_mtx);
            pl_idle = pl_idle - 1;
        }
        uptr it = ld64(pl_q + pl_head * 8);
        pl_head = (pl_head + 1) % QCAP;
        pl_n = pl_n - 1;
        pthread_mutex_unlock(pl_mtx);
        it_run(it, me);
        rc_dec(it);                              // the queue's own reference
        pthread_mutex_lock(pl_mtx);
        // the queue is done with this item, reference included. A STOLEN intent
        // leaves the queue without ever running here, so the broadcast cannot
        // hang off it_exec alone.
        pl_busy = pl_busy - 1;
        pthread_cond_broadcast(pl_done);
    }
    return 0;
}

// pushes the intent and takes a reference for the queue. The pool GROWS when
// there is no parked worker to take the new item, capped at MAXTHREADS - 1 so
// that the main thread always has a slot in the wait-for table.
void pl_submit(uptr it) {
    pthread_mutex_lock(pl_mtx);
    if (pl_n == QCAP) {
        pthread_mutex_unlock(pl_mtx);
        rt_panic("intent queue full");
    }
    rc_inc(it);
    st64(pl_q + pl_tail * 8, it);
    pl_tail = (pl_tail + 1) % QCAP;
    pl_n = pl_n + 1;
    pl_busy = pl_busy + 1;
    pl_inflight = pl_inflight + 1;
    i64 grow = 0;
    if (pl_idle == 0) {
        if (pl_nw < MAXTHREADS - 1) {
            pl_nw = pl_nw + 1;
            grow = 1;
        }
    }
    pthread_cond_signal(pl_work);
    pthread_mutex_unlock(pl_mtx);
    if (grow) {
        u8 th[8];
        st64(th, 0);
        if (pthread_create(th, 0, &pl_worker, 0) != 0) {
            pthread_mutex_lock(pl_mtx);
            pl_nw = pl_nw - 1;
            pthread_mutex_unlock(pl_mtx);
            return;
        }
        pthread_detach(ld64(th));
    }
}

// starts workers until there are `n` of them. Growth on submit is demand
// driven and therefore timed: whether a second worker appears depends on
// whether the first one had already parked. A test that needs two tasks to be
// running AT THE SAME TIME -- the deadlock case is the only honest example --
// reserves instead of hoping.
void conc_reserve(i64 n) {
    if (n > MAXTHREADS - 1) n = MAXTHREADS - 1;
    loop {
        pthread_mutex_lock(pl_mtx);
        if (pl_nw >= n) {
            pthread_mutex_unlock(pl_mtx);
            break;
        }
        pl_nw = pl_nw + 1;
        pthread_mutex_unlock(pl_mtx);
        u8 th[8];
        st64(th, 0);
        if (pthread_create(th, 0, &pl_worker, 0) != 0) {
            pthread_mutex_lock(pl_mtx);
            pl_nw = pl_nw - 1;
            pthread_mutex_unlock(pl_mtx);
            break;
        }
        pthread_detach(ld64(th));
    }
}

uptr it_new(uptr f, i64 n, i64 flags) {
    if (n > 7) rt_panic("intent: at most 7 arguments");
    uptr it = rt_alloc(IT_SIZE);
    st64(it_vtbl, &it_release);                  // idempotent, like a C_vt_init
    st64(it_vtbl + 8, 0);
    st64(it, it_vtbl);
    st64(it + 8, 1);                             // one reference: the caller's
    st64(it + IT_STATE, IT_QUEUED);
    st64(it + IT_FN, f);
    st64(it + IT_NARGS, n);
    st64(it + IT_FLAGS, flags);
    st64(it + IT_RUNNER, 0 - 1);
    return it;
}

// own = 0 plain word, 1 a borrowed object (the intent takes a reference of its
// own), 2 an already-owned temporary (the reference moves in). A direct call
// borrows because the caller outlives the callee; an intent's callee may run
// after the caller's scope is gone, so it CAPTURES.
uptr it_arg(uptr it, i64 i, i64 v, i64 own) {
    if (own == 1) rc_inc(v);
    st64(it + IT_ARGS + i * 8, v);
    st64(it + IT_OWNS + i * 8, own);
    return it;
}

uptr it_submit(uptr it) {
    pl_submit(it);
    return it;
}

// `spawn`: submitted and never awaited, so the caller's reference goes away at
// once and the queue's is the only one left
void it_go(uptr it) {
    pl_submit(it);
    rc_dec(it);
}

void it_wait(uptr it) {
    if (it == 0) rt_panic("await of a null intent");
    if (ld64(it + IT_STATE) == IT_DEAD) rt_panic("await of a released intent");
    if (a_cas(IT_QUEUED, IT_RUNNING, it + IT_STATE) == IT_QUEUED) {
        it_exec(it, th_slot());                  // stolen: run it here
        return;
    }
    pthread_mutex_lock(pl_mtx);
    i64 me = th_slot_locked();
    loop {
        if (ld64(it + IT_STATE) == IT_DONE) break;
        if (pl_cycle(me, it)) {
            st64(th_wait + me * 8, 0);
            pthread_mutex_unlock(pl_mtx);
            rt_panic("deadlock: await cycle");
        }
        st64(th_wait + me * 8, it);
        // wake every other waiter so it re-runs the cycle walk against the edge
        // this thread has just published; without it two threads can each fall
        // asleep in the window before the other's edge existed
        pthread_cond_broadcast(pl_done);
        pthread_cond_wait(pl_done, pl_mtx);
    }
    st64(th_wait + me * 8, 0);
    pthread_mutex_unlock(pl_mtx);
}

// `await r = x;` -- the result moves out, and the intent must not release it
i64 it_take(uptr it) {
    it_wait(it);
    if (ld64(it + IT_TAKEN)) rt_panic("intent awaited twice");
    st64(it + IT_TAKEN, 1);
    return ld64(it + IT_RESULT);
}

// `await x;` -- the value is discarded, so a result that carries a reference is
// released here. Discarding it silently was a leak of one object per await.
void it_drop(uptr it) {
    it_wait(it);
    if (ld64(it + IT_TAKEN)) return;
    st64(it + IT_TAKEN, 1);
    if (ld64(it + IT_FLAGS) & IT_F_OWNRES) rc_dec(ld64(it + IT_RESULT));
}

// `await r = f(a)` and `await f(a)`: the intent is a temporary, so the caller's
// reference goes away as soon as the value is out
i64 it_call(uptr it) {
    i64 r = it_take(it);
    rc_dec(it);
    return r;
}

void it_calld(uptr it) {
    it_drop(it);
    rc_dec(it);
}

// slot 0 of the intent's vtable: what rc_dec calls at zero. The wait is the
// safety net for an intent dropped on a path the module's `never awaited in
// this scope` check cannot see -- a branch that awaits on one side only. It is
// normally a no-op: the queue holds a reference until the task is finished, so
// the count cannot reach zero while a callee is still writing.
void it_release(uptr self) {
    it_wait(self);
    if (!ld64(self + IT_TAKEN)) {
        st64(self + IT_TAKEN, 1);
        if (ld64(self + IT_FLAGS) & IT_F_OWNRES) rc_dec(ld64(self + IT_RESULT));
    }
    i64 i = 0;
    i64 n = ld64(self + IT_NARGS);
    loop {
        if (i >= n) break;
        if (ld64(self + IT_OWNS + i * 8) != 0) rc_dec(ld64(self + IT_ARGS + i * 8));
        i = i + 1;
    }
    st64(self + IT_STATE, IT_DEAD);              // see IT_DEAD: the escape hatch
    rt_free(self, IT_SIZE);
}

// the quiescence point every assertion on live() needs: returns when every
// intent submitted so far has finished AND the queue has let go of it. It says
// nothing about threads blocked inside a channel receive -- those are the
// program's own business.
void conc_quiesce() {
    pthread_mutex_lock(pl_mtx);
    loop {
        if (pl_busy == 0) {
            if (pl_inflight == 0) break;
        }
        pthread_cond_wait(pl_done, pl_mtx);
    }
    pthread_mutex_unlock(pl_mtx);
}

i64 conc_workers() { return pl_nw; }

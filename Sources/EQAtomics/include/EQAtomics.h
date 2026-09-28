#ifndef EQ_ATOMICS_H
#define EQ_ATOMICS_H

// Swift's Synchronization.Atomic needs macOS 15; eq runs on 14.4. These wrap the compiler's
// atomic builtins for plain int64_t storage the Swift side allocates and never moves.

#include <stdbool.h>
#include <stdint.h>

static inline int64_t eq_load_acquire(const int64_t *cell) { return __atomic_load_n(cell, __ATOMIC_ACQUIRE); }
static inline int64_t eq_load_relaxed(const int64_t *cell) { return __atomic_load_n(cell, __ATOMIC_RELAXED); }
static inline void eq_store_release(int64_t *cell, int64_t value) { __atomic_store_n(cell, value, __ATOMIC_RELEASE); }
static inline void eq_store_relaxed(int64_t *cell, int64_t value) { __atomic_store_n(cell, value, __ATOMIC_RELAXED); }

// A (position, host time) pair one thread publishes and another reads whole, never half old and
// half new: a sequence lock over three cells, stamp[0] odd while a write is in flight.
static inline void eq_stamp_publish(int64_t *stamp, int64_t position, int64_t host) {
    int64_t sequence = __atomic_load_n(stamp, __ATOMIC_RELAXED);
    __atomic_store_n(stamp, sequence + 1, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(stamp + 1, position, __ATOMIC_RELAXED);
    __atomic_store_n(stamp + 2, host, __ATOMIC_RELAXED);
    __atomic_store_n(stamp, sequence + 2, __ATOMIC_RELEASE);
}

/// Returns the stamp's sequence number, 0 when nothing was published yet or a write was in flight.
static inline int64_t eq_stamp_read(const int64_t *stamp, int64_t *position, int64_t *host) {
    int64_t before = __atomic_load_n(stamp, __ATOMIC_ACQUIRE);
    if (before == 0 || (before & 1)) return 0;
    int64_t p = __atomic_load_n(stamp + 1, __ATOMIC_RELAXED);
    int64_t h = __atomic_load_n(stamp + 2, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (__atomic_load_n(stamp, __ATOMIC_RELAXED) != before) return 0;
    *position = p;
    *host = h;
    return before;
}

#endif

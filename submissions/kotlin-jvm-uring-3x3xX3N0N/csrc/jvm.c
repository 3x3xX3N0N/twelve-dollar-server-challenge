/* The JVM's view of the C side: thin wrappers over uring.c and db.c whose arguments FFM passes cheaply.
 *
 * - Every function returns an int (or int64), and every buffer is a Java byte[]/int[] passed as a heap segment through
 *   a critical downcall (Linker.Option.critical(true)): the call runs with no thread-state transition and C reads
 *   and writes the array in place. A critical call must not block, so the only waiting call, kj_enter, is an
 *   ordinary downcall and the reap that follows it is critical.
 * - Offsets are explicit parameters, so Kotlin passes one cached segment per array and never makes a slice.
 * - kj_reap copies every received byte into one Java array and gives the provided buffers back to the kernel at
 *   once (jnorthrup's feed_reap idea, kotlin-trikeshed-jnorthrup #298: one crossing per pass for all completions). */
#include "kn.h"
#include <string.h>

#define KJ_MAX_EV 4096
#define KJ_BUFSZ 2048   /* uring.c BUFSZ: the largest single EV_DATA */

static kn_ev evs[KJ_MAX_EV];

int kj_enter(int wait_nr, int64_t timeout_us) {
    ur_enter(wait_nr, timeout_us);
    return 0;
}

/* Events as 5 ints each (kind, slot, gen, len, offset of the data in bytes[]). The caller's bytes[] must hold
 * max * KJ_BUFSZ. Returns the event count. */
int kj_reap(int32_t *ev, int max, uint8_t *bytes, int cap) {
    if (max > KJ_MAX_EV) max = KJ_MAX_EV;
    if (max > cap / KJ_BUFSZ) max = cap / KJ_BUFSZ;
    int n = ur_reap(evs, max), off = 0;
    for (int i = 0; i < n; i++) {
        kn_ev *e = &evs[i];
        int32_t *o = ev + 5 * i;
        o[0] = e->kind; o[1] = e->slot; o[2] = e->gen; o[3] = e->len; o[4] = off;
        if (e->kind == EV_DATA) {
            memcpy(bytes + off, e->ptr, (size_t)e->len);
            off += e->len;
        }
    }
    ur_done();   /* the bytes are copied: the buffers go back now, and receives that ran dry are re-armed */
    return n;
}

int kj_send(int slot, int gen, const uint8_t *buf, int off, int len) {
    ur_send(slot, gen, buf + off, len);
    return 0;
}

int kj_close_after(int slot, int gen) {
    ur_close_after(slot, gen);
    return 0;
}

int kj_feed(uint8_t *buf, int off, int cap) { return db_feed(buf + off, cap); }

int kj_post(int64_t id, uint8_t *buf, int off, int cap) { return db_post(id, buf + off, cap); }

int kj_add_like(int64_t uid, int64_t pid) { return db_wq_add_like(uid, pid); }

int kj_add_post(int64_t uid, const uint8_t *buf, int boff, int blen, int aoff, int alen) {
    return db_wq_add_post(uid, buf + boff, blen, buf + aoff, alen);
}

int kj_pass_end(void) {
    db_pass_end();
    return 0;
}

int kj_release(void) {
    db_wq_release();
    return 0;
}

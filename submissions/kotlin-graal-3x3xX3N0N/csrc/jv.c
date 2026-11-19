/* The FFM face of the C side for the GraalVM build: a few wide calls instead of many narrow ones.
 *
 * Every pointer argument is a Java heap array passed in place (Linker.Option.critical(true) with heap access: no
 * copy, no thread-state transition), plus an int offset, so Java never has to slice a segment (no allocation).
 *
 * One downcall per busy loop pass: jv_step() sends the responses Java staged in the previous pass (a table of
 * slot, gen, offset, length), ends the pass on the database side, waits in io_uring, and copies every completion
 * of the new pass (and the received bytes) into Java arrays, then gives the provided buffers back to the kernel.
 * Java passes timeout 0 (jv_step never sleeps: a critical call must not block, or the JVM cannot reach a safepoint);
 * only when a pass finds nothing does it sleep in jv_wait, a plain downcall, and step again.
 * One downcall per GET /feed or GET /posts/:id (the B-tree plans in btree_reads.c write the JSON into the array). */
#include "kn.h"
#include <stdint.h>
#include <string.h>
#include <time.h>

#define JV_MAX_EV 4096
static kn_ev evs[JV_MAX_EV];

/* Sends staged output: tab holds n entries of 4 ints (slot, gen, off, len); len > 0 sends buf[off, off+len),
 * len < 0 closes the connection once its queued output is gone. */
int jv_send(const int32_t *tab, int n, const uint8_t *buf) {
    for (int i = 0; i < n; i++) {
        const int32_t *t = tab + 4 * i;
        if (t[3] > 0) ur_send(t[0], t[1], buf + t[2], t[3]);
        else ur_close_after(t[0], t[1]);
    }
    return n;
}

/* One loop pass. ev receives 4 ints per event (kind, slot, gen, len); the bytes of EV_DATA events are packed one
 * after another into in[0, incap) in event order. Returns the event count. incap must be >= max * 2048. */
int jv_step(const int32_t *tab, int nsend, const uint8_t *out, int32_t *ev, uint8_t *in, int incap, int max,
            int wait_nr, int64_t timeout_us) {
    if (nsend) jv_send(tab, nsend, out);
    db_pass_end();
    if (max > JV_MAX_EV) max = JV_MAX_EV;
    if (max * 2048 > incap) max = incap / 2048;
    int n = ur_poll(evs, max, wait_nr, timeout_us);
    int at = 0;
    for (int i = 0; i < n; i++) {
        kn_ev *e = &evs[i];
        int32_t *o = ev + 4 * i;
        o[0] = e->kind; o[1] = e->slot; o[2] = e->gen; o[3] = e->len;
        if (e->kind == EV_DATA) { memcpy(in + at, e->ptr, (size_t)e->len); at += e->len; }
    }
    ur_done();
    return n;
}

/* The only blocking call; Java calls it through a NON-critical handle so the thread is "in native" meanwhile. */
int jv_wait(int wait_nr, int64_t timeout_us) { return ur_wait(wait_nr, timeout_us); }

int jv_feed(uint8_t *base, int off, int cap) { return db_feed(base + off, cap); }
int jv_post(int64_t id, uint8_t *base, int off, int cap) { return db_post(id, base + off, cap); }

int jv_wq_add_post(int64_t uid, const uint8_t *b, int boff, int blen, const uint8_t *a, int aoff, int alen) {
    return db_wq_add_post(uid, b + boff, blen, a + aoff, alen);
}

/* All results of the finished batch at once: res gets 2 ints per op (code, length); post JSON goes to out
 * one after another. Returns the op count, or -1 if the batch is not done yet. */
int jv_wq_results(int32_t *res, int maxops, uint8_t *out, int cap) {
    int n = db_wq_done();
    if (n < 0) return -1;
    int at = 0;
    for (int i = 0; i < n && i < maxops; i++) {   /* ops past maxops: Java answers them with a 500 */
        int code = -2;
        int len = db_wq_result(i, &code, out + at, cap - at);
        res[2 * i] = code;
        res[2 * i + 1] = len;
        at += len;
    }
    return n;
}

int jv_open(const uint8_t *path, const uint8_t *vfs, int btree, uint8_t *err, int errcap) {
    return db_open((const char *)path, vfs && vfs[0] ? (const char *)vfs : 0, btree, (char *)err, errcap);
}
int jv_init(const uint8_t *host, int port, int rings) { return ur_init((const char *)host, port, rings); }
int jv_health(uint8_t *err, int cap) { return db_health((char *)err, cap); }
int jv_wq_release(void) { db_wq_release(); return 0; }

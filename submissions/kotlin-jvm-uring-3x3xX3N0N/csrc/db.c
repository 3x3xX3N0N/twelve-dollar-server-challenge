/* SQLite side of the server. The stock SQLite amalgamation (sqlite3.c, unchanged, checksum-verified by build.sh) is
 * compiled into this translation unit, so the B-tree read paths (btree_reads.c, included below) can call SQLite's
 * own cursor API (sqlite3BtreeTableMoveto, sqlite3BtreeIndexMoveto, sqlite3BtreeNext, ...). They only read; nothing
 * here writes SQLite's internal state.
 *
 * Connections (all in this one process):
 *   reader  - GET /feed, GET /posts/:id, /health, and (default) the group commit too, on the loop: BEGIN IMMEDIATE
 *             without waiting (if a checkpoint holds the write lock, the batch waits for a later pass while reads go
 *             on), INSERTs, COMMIT; the loop answers only after COMMIT has returned. Its read transaction (snapshot)
 *             is kept across loop passes and ended before each commit (so every request still sees every committed
 *             write) or when the checkpointer waits for readers. Idea credit: rust-iouring-rkkautsar (snapshot reuse).
 *   writer  - only with KJ_COMMITTER=1 (the Kotlin/Native entry's design): the group commit on its own committer
 *             thread and connection (busy timeout 10 s, so it waits out a checkpoint hold).
 *   checkpointer thread - PASSIVE every 50 ms; RESTART with a bounded 250 ms hold once the WAL is long and nearly
 *             copied; nice 5. Idea credit: swift-iouring-akbashev, rust-iouring-kensac (MIT).
 * WAL + synchronous=NORMAL (rule 6), mmap off, 256 MiB reader page cache. */
#include "sqlite3.c"
#include "kn.h"
#include <pthread.h>
#include <sys/eventfd.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include <stdlib.h>

static sqlite3 *rdb, *wdb;
static sqlite3_stmt *st_rbegin, *st_rcommit, *st_health, *st_feed_sql, *st_post_sql;
static sqlite3_stmt *st_wbegin, *st_wcommit, *st_wrollback, *st_insert, *st_exists, *st_like;
static char g_path[4096];
static char g_vfs[64];
static int rd_open;                 /* reader holds a read transaction (snapshot) */
static int use_btree;
static atomic_int ckpt_want;        /* checkpointer waits for readers to leave their snapshot */
static int64_t n_bt, n_sql, n_snap;
static int keep_snapshot = 1;      /* KJ_SNAPSHOT=0: a new read transaction every loop pass (for measuring) */
/* KJ_COMMITTER=1: group commit on a committer thread with its own connection (the Kotlin/Native entry's design).
 * Default (0): the loop commits on the reader connection itself. A COMMIT by another connection makes the reader drop
 * its whole page cache at its next read transaction (SQLite's WAL "changed" check), which turned into one pread per
 * page read; committing on the same connection keeps the cache (measured in the README). */
static int committer;
static int ol_pending;              /* on-loop: a batch is staged but BEGIN IMMEDIATE was busy (checkpoint hold) */
static void ol_try(void);

static int64_t now_ns(void);

/* ------------------------------------------------------------------ helpers */
static int prep(sqlite3 *db, const char *sql, sqlite3_stmt **st, char *err, int errcap) {
    if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, st, 0) == SQLITE_OK) return 0;
    snprintf(err, errcap, "prepare %.60s: %s", sql, sqlite3_errmsg(db));
    return -1;
}

static int exec(sqlite3 *db, const char *sql, char *err, int errcap) {
    char *e = 0;
    if (sqlite3_exec(db, sql, 0, 0, &e) == SQLITE_OK) return 0;
    snprintf(err, errcap, "%s: %s", sql, e ? e : "?");
    sqlite3_free(e);
    return -1;
}

/* Steps a statement that returns no rows, then resets it. */
static int step_reset(sqlite3_stmt *st) {
    int rc = sqlite3_step(st);
    sqlite3_reset(st);
    return rc == SQLITE_DONE || rc == SQLITE_ROW ? SQLITE_OK : rc;
}

static int copy_text(sqlite3_stmt *st, int col, uint8_t *out, int cap) {
    int n = sqlite3_column_bytes(st, col);
    const unsigned char *t = sqlite3_column_text(st, col);
    if (!t || n > cap) return -1;
    memcpy(out, t, n);
    return n;
}

static int open_conn(sqlite3 **db, int busy_ms, char *err, int errcap, const char *cache) {
    if (sqlite3_open_v2(g_path, db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, g_vfs[0] ? g_vfs : 0) != SQLITE_OK) {
        snprintf(err, errcap, "open %s: %s", g_path, *db ? sqlite3_errmsg(*db) : "out of memory");
        return -1;
    }
    sqlite3_busy_timeout(*db, busy_ms);
    if (exec(*db, "PRAGMA journal_mode=WAL", err, errcap) ||
        exec(*db, "PRAGMA synchronous=NORMAL", err, errcap) ||       /* rule 6 minimum */
        exec(*db, "PRAGMA mmap_size=0", err, errcap) ||              /* pages through the page cache */
        exec(*db, cache, err, errcap) ||                             /* allocated as touched */
        exec(*db, "PRAGMA temp_store=MEMORY", err, errcap) ||
        exec(*db, "PRAGMA wal_autocheckpoint=0", err, errcap) ||     /* the checkpointer thread does it */
        exec(*db, "PRAGMA journal_size_limit=67108864", err, errcap) ||
        exec(*db, "SELECT count(*) FROM sqlite_schema", err, errcap)) return -1;
    return 0;
}

/* ------------------------------------------------------------------ reader snapshot */
#include "btree_reads.c"

static int rd_begin(void) {
    if (rd_open) return 0;
    if (step_reset(st_rbegin) != SQLITE_OK) return -1;   /* BEGIN (deferred) */
    rd_open = 1;
    n_snap++;
    if (use_btree && bt_begin(rdb) != 0) {
        /* No B-tree read transaction: SQL alone still works inside the BEGIN. */
        fprintf(stderr, "btree: begin failed, SQL only from now on\n");
        use_btree = 0;
    }
    return 0;
}

static void rd_end(void) {
    if (!rd_open) return;
    if (use_btree) bt_end();
    step_reset(st_rcommit);
    rd_open = 0;
}

void db_pass_end(void) {
    if (ol_pending) ol_try();
    if (rd_open && (!keep_snapshot || atomic_load_explicit(&ckpt_want, memory_order_relaxed))) rd_end();
}

/* ------------------------------------------------------------------ open */
#define POST_JSON \
    "json_object('id',p.id,'body',p.body,'created_at',p.created_at,'author',u.username," \
    "'like_count',(SELECT count(*) FROM likes l WHERE l.post_id=p.id))"

int db_open(const char *path, const char *vfs, int btree, char *err, int errcap) {
    snprintf(g_path, sizeof g_path, "%s", path);
    snprintf(g_vfs, sizeof g_vfs, "%s", vfs ? vfs : "");
    committer = getenv("KJ_COMMITTER") && getenv("KJ_COMMITTER")[0] == '1';
    keep_snapshot = !(getenv("KJ_SNAPSHOT") && getenv("KJ_SNAPSHOT")[0] == '0');
    /* The writer (KJ_COMMITTER=1 only) and the checkpointer touch far fewer pages (16 MiB / 2 MiB). */
    /* Reader page cache 256 MiB (KJ_CACHE_KB; the seed database is 248 MB): it is kept across transactions now that
     * only this connection writes (see committer above), so most reads stop costing a pread. KJ_MMAP: mmap_size. */
    char rcache[64];
    snprintf(rcache, sizeof rcache, "PRAGMA cache_size=-%d", getenv("KJ_CACHE_KB") ? atoi(getenv("KJ_CACHE_KB")) : 262144);
    if (open_conn(&rdb, 5000, err, errcap, rcache) ||
        /* The committer thread is off the loop, so its BEGIN can wait out a checkpoint hold that a slow disk
         * stretches (measured: 2 x 1 s was not enough at 416k users on a busy disk; 15 likes got a 500). */
        (committer && open_conn(&wdb, 10000, err, errcap, "PRAGMA cache_size=-16384"))) return -1;
    if (!committer) wdb = rdb;
    if (getenv("KJ_MMAP")) {
        char m[64];
        snprintf(m, sizeof m, "PRAGMA mmap_size=%lld", atoll(getenv("KJ_MMAP")));
        if (exec(rdb, m, err, errcap)) return -1;
    }
    if (prep(rdb, "BEGIN", &st_rbegin, err, errcap) ||
        prep(rdb, "COMMIT", &st_rcommit, err, errcap) ||
        prep(rdb, "SELECT 1", &st_health, err, errcap) ||
        prep(rdb,
             "SELECT '{\"posts\":['||coalesce(group_concat(j,',' ORDER BY ca DESC,id DESC),'')||']}' FROM ("
             "SELECT p.id id,p.created_at ca," POST_JSON " j FROM posts p JOIN users u ON u.id=p.user_id "
             "ORDER BY p.created_at DESC,p.id DESC LIMIT 20)", &st_feed_sql, err, errcap) ||
        prep(rdb, "SELECT '{\"post\":'||" POST_JSON "||'}' FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?1",
             &st_post_sql, err, errcap) ||
        prep(wdb, "BEGIN IMMEDIATE", &st_wbegin, err, errcap) ||
        prep(wdb, "COMMIT", &st_wcommit, err, errcap) ||
        prep(wdb, "ROLLBACK", &st_wrollback, err, errcap) ||
        prep(wdb, "INSERT INTO posts(user_id,body) VALUES(?1,?2) RETURNING '{\"post\":'||"
                  "json_object('id',id,'body',body,'created_at',created_at,'author',?3,'like_count',0)||'}'",
             &st_insert, err, errcap) ||
        prep(wdb, "SELECT 1 FROM posts WHERE id=?1", &st_exists, err, errcap) ||
        prep(wdb, "INSERT INTO likes(user_id,post_id) VALUES(?1,?2) ON CONFLICT(user_id,post_id) DO NOTHING",
             &st_like, err, errcap)) return -1;
    use_btree = 0;
    if (btree) {
        char why[256];
        if (bt_init(rdb, why, sizeof why) == 0) use_btree = 1;
        else fprintf(stderr, "btree reads off (SQL only): %s\n", why);
    }
    return 0;
}

/* ------------------------------------------------------------------ reads */
int db_health(char *err, int errcap) {
    if (rd_begin() != 0) { snprintf(err, errcap, "%s", sqlite3_errmsg(rdb)); return -1; }
    int rc = sqlite3_step(st_health);
    if (rc != SQLITE_ROW) {
        snprintf(err, errcap, "%s", sqlite3_errmsg(rdb));
        sqlite3_reset(st_health);
        rd_end();
        return -1;
    }
    sqlite3_reset(st_health);
    return 0;
}

static int feed_sql(uint8_t *out, int cap) {
    int n = -1;
    if (sqlite3_step(st_feed_sql) == SQLITE_ROW) n = copy_text(st_feed_sql, 0, out, cap);
    sqlite3_reset(st_feed_sql);
    return n;
}

static int post_sql(int64_t id, uint8_t *out, int cap) {
    sqlite3_bind_int64(st_post_sql, 1, id);
    int rc = sqlite3_step(st_post_sql), n;
    if (rc == SQLITE_ROW) n = copy_text(st_post_sql, 0, out, cap);
    else n = rc == SQLITE_DONE ? 0 : -1;
    sqlite3_reset(st_post_sql);
    return n;
}

int db_feed(uint8_t *out, int cap) {
    if (rd_begin() != 0) return -1;
    if (use_btree) {
        int n = bt_feed(out, cap);
        if (n > 0) { n_bt++; return n; }
    }
    n_sql++;
    return feed_sql(out, cap);
}

int db_post(int64_t id, uint8_t *out, int cap) {
    if (rd_begin() != 0) return -1;
    if (use_btree) {
        int n = bt_post(id, out, cap);
        if (n >= 0) { n_bt++; return n; }
    }
    n_sql++;
    return post_sql(id, out, cap);
}

/* ------------------------------------------------------------------ writes (group commit: on the loop or a committer thread) */
typedef struct wop {
    int kind;                 /* 0 like, 1 post */
    int64_t uid, pid;
    int boff, blen, aoff, alen;   /* body/author bytes in the batch's arena */
    int code, joff, jlen;     /* results */
} wop;

typedef struct wbatch {
    wop *ops;
    int n, cap;
    uint8_t *arena;           /* staged body/author bytes, then result JSON */
    int alen, acap;
} wbatch;

static wbatch wb[2];
static wbatch *staging = &wb[0], *inflight = 0;
static pthread_mutex_t wq_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wq_cv = PTHREAD_COND_INITIALIZER;
static int wq_state;          /* 0 idle, 1 batch handed over, 2 batch done */
static int wq_efd = -1;

static int arena_put(wbatch *b, const uint8_t *p, int n) {
    if (b->alen + n > b->acap) {
        int cap = b->acap ? b->acap : 1 << 16;
        while (cap < b->alen + n) cap *= 2;
        uint8_t *a = realloc(b->arena, (size_t)cap);
        if (!a) return -1;
        b->arena = a; b->acap = cap;
    }
    memcpy(b->arena + b->alen, p, (size_t)n);
    b->alen += n;
    return b->alen - n;
}

static wop *wq_push(void) {
    wbatch *b = staging;
    if (b->n == b->cap) {
        int cap = b->cap ? b->cap * 2 : 256;
        wop *o = realloc(b->ops, sizeof(wop) * (size_t)cap);
        if (!o) return 0;
        b->ops = o; b->cap = cap;
    }
    wop *o = &b->ops[b->n++];
    memset(o, 0, sizeof *o);
    return o;
}

int db_wq_add_like(int64_t uid, int64_t pid) {
    wop *o = wq_push();
    if (!o) return -1;
    o->kind = 0; o->uid = uid; o->pid = pid;
    return 0;
}

int db_wq_add_post(int64_t uid, const uint8_t *body, int blen, const uint8_t *author, int alen) {
    wop *o = wq_push();
    if (!o) return -1;
    o->kind = 1; o->uid = uid;
    o->boff = arena_put(staging, body, blen); o->blen = blen;
    o->aoff = arena_put(staging, author, alen); o->alen = alen;
    if (o->boff < 0 || o->aoff < 0) { staging->n--; return -1; }
    return 0;
}

int db_wq_start(void) {
    if (inflight) return 1;
    pthread_mutex_lock(&wq_mu);
    inflight = staging;
    staging = staging == &wb[0] ? &wb[1] : &wb[0];
    staging->n = 0; staging->alen = 0;
    if (!committer) {   /* on the loop: now, or at a later pass end if a checkpoint holds the write lock */
        pthread_mutex_unlock(&wq_mu);
        ol_pending = 1;
        ol_try();
        return 0;
    }
    wq_state = 1;
    pthread_cond_signal(&wq_cv);
    pthread_mutex_unlock(&wq_mu);
    return 0;
}

int db_wq_done(void) {
    if (!inflight) return -1;
    pthread_mutex_lock(&wq_mu);
    int done = wq_state == 2;
    pthread_mutex_unlock(&wq_mu);
    return done ? inflight->n : -1;
}

int db_wq_result(int i, int *code, uint8_t *out, int cap) {
    wop *o = &inflight->ops[i];
    *code = o->code;
    if (o->kind == 1 && o->code == 201) {
        if (o->jlen > cap) { *code = -2; return 0; }
        memcpy(out, inflight->arena + o->joff, (size_t)o->jlen);
        return o->jlen;
    }
    return 0;
}

void db_wq_release(void) {
    if (!inflight) return;
    pthread_mutex_lock(&wq_mu);
    wq_state = 0;
    pthread_mutex_unlock(&wq_mu);
    inflight = 0;
    rd_end();   /* the next read takes a new snapshot that includes this commit */
}

/* One batch: BEGIN IMMEDIATE (waits out a checkpoint hold here, off the loop), the statements, COMMIT. */
static void run_body(wbatch *b, int rc);

static void run_batch(wbatch *b) {
    int rc = SQLITE_BUSY;
    for (int tries = 0; tries < 2 && (rc & 0xff) == SQLITE_BUSY; tries++) rc = step_reset(st_wbegin);
    run_body(b, rc);
}

static void wq_signal(void) {
    uint64_t one = 1;
    if (write(wq_efd, &one, sizeof one) < 0) perror("committer eventfd");
}

/* On-loop group commit: BEGIN IMMEDIATE without waiting (a checkpoint RESTART can hold the write lock for a few ms;
 * then the batch stays staged and the next pass end tries again, while reads go on), the statements, COMMIT; the
 * eventfd tells the loop the results are ready, as the committer thread does. */
static void ol_try(void) {
    rd_end();   /* BEGIN IMMEDIATE needs the connection out of its read transaction */
    sqlite3_busy_timeout(rdb, 0);
    int rc = step_reset(st_wbegin);
    sqlite3_busy_timeout(rdb, 5000);
    if ((rc & 0xff) == SQLITE_BUSY) return;
    ol_pending = 0;
    run_body(inflight, rc);
    pthread_mutex_lock(&wq_mu);
    wq_state = 2;
    pthread_mutex_unlock(&wq_mu);
    wq_signal();
}

static void run_body(wbatch *b, int rc) {
    int ok = rc == SQLITE_OK;
    if (!ok) fprintf(stderr, "group commit: BEGIN: %s\n", sqlite3_errmsg(wdb));
    for (int i = 0; ok && i < b->n; i++) {
        wop *o = &b->ops[i];
        if (o->kind == 0) {
            sqlite3_bind_int64(st_exists, 1, o->pid);
            rc = sqlite3_step(st_exists);
            sqlite3_reset(st_exists);
            if (rc == SQLITE_DONE) { o->code = -1; continue; }
            if (rc != SQLITE_ROW) { o->code = -2; continue; }
            sqlite3_bind_int64(st_like, 1, o->uid);
            sqlite3_bind_int64(st_like, 2, o->pid);
            rc = sqlite3_step(st_like);
            sqlite3_reset(st_like);
            o->code = rc != SQLITE_DONE ? -2 : sqlite3_changes(wdb) > 0 ? 1 : 0;
        } else {
            sqlite3_bind_int64(st_insert, 1, o->uid);
            sqlite3_bind_text(st_insert, 2, (const char *)b->arena + o->boff, o->blen, SQLITE_TRANSIENT);
            sqlite3_bind_text(st_insert, 3, (const char *)b->arena + o->aoff, o->alen, SQLITE_TRANSIENT);
            o->code = -2;
            if (sqlite3_step(st_insert) == SQLITE_ROW) {
                int n = sqlite3_column_bytes(st_insert, 0);
                const unsigned char *t = sqlite3_column_text(st_insert, 0);
                int off = t ? arena_put(b, t, n) : -1;
                if (off >= 0) { o->joff = off; o->jlen = n; o->code = 201; }
                while (sqlite3_step(st_insert) == SQLITE_ROW) {}
            }
            sqlite3_reset(st_insert);
            sqlite3_clear_bindings(st_insert);
        }
    }
    if (ok && step_reset(st_wcommit) != SQLITE_OK) {
        fprintf(stderr, "group commit: COMMIT: %s\n", sqlite3_errmsg(wdb));
        step_reset(st_wrollback);
        ok = 0;
    }
    if (!ok) for (int i = 0; i < b->n; i++) b->ops[i].code = -2;
}

static void *wq_main(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&wq_mu);
        while (wq_state != 1) pthread_cond_wait(&wq_cv, &wq_mu);
        wbatch *b = inflight;
        pthread_mutex_unlock(&wq_mu);
        run_batch(b);
        pthread_mutex_lock(&wq_mu);
        wq_state = 2;
        pthread_mutex_unlock(&wq_mu);
        wq_signal();
    }
    return 0;
}

int db_wq_init(void) {
    wq_efd = eventfd(0, EFD_CLOEXEC);
    if (wq_efd < 0) return -1;
    if (!committer) return wq_efd;   /* commits run on the loop: no thread */
    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&a, 512 * 1024);
    return pthread_create(&t, &a, wq_main, 0) == 0 ? wq_efd : -1;
}

/* ------------------------------------------------------------------ verification */
int db_verify(void) {
    static uint8_t a[1 << 16], b[1 << 16];
    int bad = 0;
    if (!use_btree) { fprintf(stderr, "verify: btree reads are off\n"); return 1; }
    rd_end();
    if (rd_begin() != 0) return 1;
    sqlite3_stmt *mx;
    int64_t maxid = 0;
    if (sqlite3_prepare_v2(rdb, "SELECT max(id) FROM posts", -1, &mx, 0) == SQLITE_OK) {
        if (sqlite3_step(mx) == SQLITE_ROW) maxid = sqlite3_column_int64(mx, 0);
        sqlite3_finalize(mx);
    }
    int64_t checked = 0;
    for (int64_t id = 1; id <= maxid + 10; id++) {
        int n1 = bt_post(id, a, sizeof a), n2 = post_sql(id, b, sizeof b);
        checked++;
        if (n1 != n2 || (n1 > 0 && memcmp(a, b, n1) != 0)) {
            if (bad++ < 5) fprintf(stderr, "verify: post %lld: btree %d bytes, sql %d bytes\n  bt : %.*s\n  sql: %.*s\n",
                                   (long long)id, n1, n2, n1 > 0 ? n1 : 0, a, n2 > 0 ? n2 : 0, b);
        }
    }
    int n1 = bt_feed(a, sizeof a), n2 = feed_sql(b, sizeof b);
    if (n1 != n2 || n1 <= 0 || memcmp(a, b, n1) != 0) {
        bad++;
        fprintf(stderr, "verify: feed: btree %d bytes, sql %d bytes\n", n1, n2);
    }
    /* timing, same snapshot: 5,000 feeds and 5,000 random posts each way */
    int64_t t0 = now_ns();
    for (int i = 0; i < 5000; i++) bt_feed(a, sizeof a);
    int64_t t1 = now_ns();
    for (int i = 0; i < 5000; i++) feed_sql(b, sizeof b);
    int64_t t2 = now_ns();
    uint64_t x = 88172645463325252ULL;
    for (int i = 0; i < 5000; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; bt_post((int64_t)(x % (uint64_t)maxid) + 1, a, sizeof a); }
    int64_t t3 = now_ns();
    x = 88172645463325252ULL;
    for (int i = 0; i < 5000; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; post_sql((int64_t)(x % (uint64_t)maxid) + 1, b, sizeof b); }
    int64_t t4 = now_ns();
    fprintf(stderr, "verify: feed btree %.2f us, sql %.2f us; post btree %.2f us, sql %.2f us\n",
            (t1 - t0) / 5000e3, (t2 - t1) / 5000e3, (t3 - t2) / 5000e3, (t4 - t3) / 5000e3);
    rd_end();
    fprintf(stderr, "verify: %lld post ids + the feed checked, %d mismatches\n", (long long)checked, bad);
    return bad;
}

int64_t db_stat(int which) {
    switch (which) {
    case 0: return n_bt;
    case 1: return n_sql;
    case 2: return n_snap;
    default: return 0;
    }
}

/* ------------------------------------------------------------------ checkpointer */
#define CK_TICK_MS 50
#define CK_RESTART_FRAMES 4096   /* 16 MB of 4 KB pages */
#define CK_TAIL_FRAMES 128
#define CK_HOLD_MS 250

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static void *ckpt_main(void *arg) {
    (void)arg;
    /* nice 5 for this thread only: at 19 it starves under saturation, at 0 it competes with the loop as an equal. */
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 5);
    sqlite3 *c = 0;
    char err[256];
    if (open_conn(&c, CK_HOLD_MS, err, sizeof err, "PRAGMA cache_size=-2048")) { fprintf(stderr, "checkpointer: %s\n", err); return 0; }
    int logst = getenv("KJ_CKPT_LOG") && getenv("KJ_CKPT_LOG")[0] == '1';
    int64_t last = now_ns(), maxhold = 0, sumhold = 0;
    int restarts = 0, fails = 0, maxlog = 0;
    for (;;) {
        usleep(CK_TICK_MS * 1000);
        int log = 0, copied = 0;
        sqlite3_wal_checkpoint_v2(c, 0, SQLITE_CHECKPOINT_PASSIVE, &log, &copied);
        if (log > maxlog) maxlog = log;
        if (log >= CK_RESTART_FRAMES && log - copied <= CK_TAIL_FRAMES) {
            /* RESTART takes the WAL write lock (our writer's BEGIN IMMEDIATE gets SQLITE_BUSY and retries next pass),
             * copies the tail and waits for readers to leave the old frames; the next write then starts the WAL
             * from frame 1. The loop drops its kept snapshot while ckpt_want is set. */
            atomic_store(&ckpt_want, 1);
            int64_t t0 = now_ns();
            int rc = sqlite3_wal_checkpoint_v2(c, 0, SQLITE_CHECKPOINT_RESTART, 0, 0);
            int64_t dt = now_ns() - t0;
            atomic_store(&ckpt_want, 0);
            if (rc == SQLITE_OK) restarts++; else fails++;
            sumhold += dt;
            if (dt > maxhold) maxhold = dt;
        }
        if (logst && now_ns() - last > 10000000000LL) {
            fprintf(stderr, "checkpointer: restarts=%d busy=%d maxLog=%d hold avg=%lldus max=%lldus\n", restarts, fails,
                    maxlog, restarts + fails ? (long long)(sumhold / (restarts + fails) / 1000) : 0LL,
                    (long long)(maxhold / 1000));
            restarts = fails = maxlog = 0;
            maxhold = sumhold = 0;
            last = now_ns();
        }
    }
    return 0;
}

int ckpt_start(void) {
    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&a, 256 * 1024);
    return pthread_create(&t, &a, ckpt_main, 0) == 0 ? 0 : -1;
}

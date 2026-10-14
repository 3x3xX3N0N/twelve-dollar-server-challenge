package nio

import java.lang.foreign.MemorySegment
import java.lang.foreign.ValueLayout

/**
 * Two SQLite connections (FFM, no JDBC), used only by the event-loop thread, every statement prepared once.
 * - reader: feed / post / health, busy_timeout 5 s (WAL readers practically never wait).
 * - writer: the group-commit transaction, busy_timeout 0. When another worker process holds the write lock, BEGIN
 *   fails at once and the batch is retried on the next loop pass. A sleeping busy handler would freeze the whole
 *   event loop: measured at 0.5-1.4 s per stall with 2 workers at 120k users.
 * Reads are zero-copy: SQLite builds the JSON, and the caller copies it from SQLite's memory straight into the
 * socket's output buffer (row/rowLen), then calls done().
 */
class Db(path: String) {
    private val rdb = Sqlite.open(path, 5000)
    private val wdb = Sqlite.open(path, 0)

    private val health: MemorySegment
    private val feed: MemorySegment
    private val post: MemorySegment
    private val insertPost: MemorySegment
    private val postExists: MemorySegment
    private val insertLike: MemorySegment
    private val begin: MemorySegment
    private val commit: MemorySegment
    private val rollback: MemorySegment

    /** Result of the last successful read query; valid until done(). */
    var row: MemorySegment = MemorySegment.NULL; private set
    var rowLen = 0; private set
    private var open: MemorySegment? = null

    companion object {
        // Post object, exactly in the wire key order.
        private const val POST_JSON =
            "json_object('id',p.id,'body',p.body,'created_at',p.created_at,'author',u.username," +
                "'like_count',(SELECT count(*) FROM likes l WHERE l.post_id=p.id))"

        fun tune(db: MemorySegment, cacheKb: Int) {
            Sqlite.exec(db, "PRAGMA journal_mode=WAL")
            Sqlite.exec(db, "PRAGMA synchronous=NORMAL")          // rule 6 minimum: WAL + NORMAL
            Sqlite.exec(db, "PRAGMA temp_store=MEMORY")
            Sqlite.exec(db, "PRAGMA mmap_size=536870912")         // reads go through the OS page cache
            Sqlite.exec(db, "PRAGMA cache_size=-$cacheKb")
            Sqlite.exec(db, "PRAGMA wal_autocheckpoint=0")        // checkpoints run on the Checkpointer thread
            Sqlite.exec(db, "PRAGMA journal_size_limit=67108864") // truncate the WAL file back to 64 MB after a reset
        }
    }

    init {
        tune(rdb, 8000)
        tune(wdb, 2000)
        health = Sqlite.prepare(rdb, "SELECT 1")
        feed = Sqlite.prepare(rdb,
            "SELECT '{\"posts\":['||coalesce(group_concat(j,',' ORDER BY ca DESC,id DESC),'')||']}' FROM (" +
                "SELECT p.id id,p.created_at ca,$POST_JSON j FROM posts p JOIN users u ON u.id=p.user_id " +
                "ORDER BY p.created_at DESC,p.id DESC LIMIT 20)")
        post = Sqlite.prepare(rdb, "SELECT '{\"post\":'||$POST_JSON||'}' FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?")
        insertPost = Sqlite.prepare(wdb,
            "INSERT INTO posts(user_id,body) VALUES(?1,?2) RETURNING '{\"post\":'||" +
                "json_object('id',id,'body',body,'created_at',created_at,'author',?3,'like_count',0)||'}'")
        postExists = Sqlite.prepare(wdb, "SELECT 1 FROM posts WHERE id=?")
        insertLike = Sqlite.prepare(wdb, "INSERT INTO likes(user_id,post_id) VALUES(?,?) ON CONFLICT(user_id,post_id) DO NOTHING")
        begin = Sqlite.prepare(wdb, "BEGIN IMMEDIATE")
        commit = Sqlite.prepare(wdb, "COMMIT")
        rollback = Sqlite.prepare(wdb, "ROLLBACK")
    }

    private fun fail(db: MemorySegment, st: MemorySegment, rc: Int): Nothing {
        val msg = Sqlite.errmsg(db)
        Sqlite.reset(st)
        throw SqliteException(rc, msg)
    }

    /** Steps a read query; true = a row is available in row/rowLen (call done() after using it). */
    private fun query(st: MemorySegment): Boolean {
        val rc = Sqlite.step(st)
        if (rc == Sqlite.ROW) {
            rowLen = Sqlite.columnBytes(st, 0)
            row = Sqlite.columnBlob(st, 0, rowLen)
            open = st
            return true
        }
        if (rc == Sqlite.DONE) { Sqlite.reset(st); return false }
        fail(rdb, st, rc)
    }

    fun done() {
        open?.let { Sqlite.reset(it) }
        open = null; row = MemorySegment.NULL; rowLen = 0
    }

    fun ping() {
        val rc = Sqlite.step(health)
        Sqlite.reset(health)
        if (rc != Sqlite.ROW) throw SqliteException(rc, Sqlite.errmsg(rdb))
    }

    fun feed(): Boolean = query(feed)

    fun post(id: Long): Boolean { Sqlite.bindLong(post, 1, id); return query(post) }

    /** Returns the 201 body (copied out: it's sent only after COMMIT). */
    fun insertPost(userId: Long, body: String, author: String): ByteArray {
        val st = insertPost
        Sqlite.bindLong(st, 1, userId)
        Sqlite.bindText(st, 2, body.toByteArray(Charsets.UTF_8))
        Sqlite.bindText(st, 3, author.toByteArray(Charsets.UTF_8))
        val rc = Sqlite.step(st)
        if (rc != Sqlite.ROW) fail(wdb, st, rc)
        val n = Sqlite.columnBytes(st, 0)
        val out = Sqlite.columnBlob(st, 0, n).toArray(ValueLayout.JAVA_BYTE)
        Sqlite.reset(st)   // RETURNING: the insert already happened in the first step
        return out
    }

    /** -1 = no such post, 1 = newly liked, 0 = already liked. */
    fun like(userId: Long, postId: Long): Int {
        Sqlite.bindLong(postExists, 1, postId)
        val rc = Sqlite.step(postExists)
        Sqlite.reset(postExists)
        if (rc == Sqlite.DONE) return -1
        if (rc != Sqlite.ROW) throw SqliteException(rc, Sqlite.errmsg(wdb))
        Sqlite.bindLong(insertLike, 1, userId)
        Sqlite.bindLong(insertLike, 2, postId)
        val rc2 = Sqlite.step(insertLike)
        if (rc2 != Sqlite.DONE) fail(wdb, insertLike, rc2)
        Sqlite.reset(insertLike)
        return Sqlite.changes(wdb)
    }

    /** false = another process holds the write lock right now (SQLITE_BUSY); try again on the next loop pass. */
    fun tryBegin(): Boolean {
        val rc = Sqlite.step(begin)
        Sqlite.reset(begin)
        if (rc == Sqlite.DONE) return true
        if ((rc and 0xff) == Sqlite.BUSY) return false
        throw SqliteException(rc, Sqlite.errmsg(wdb))
    }

    fun commit() {
        val rc = Sqlite.step(commit)
        Sqlite.reset(commit)
        if (rc != Sqlite.DONE) throw SqliteException(rc, Sqlite.errmsg(wdb))
    }

    fun rollback() { Sqlite.step(rollback); Sqlite.reset(rollback) }
}

/** Runs WAL checkpoints off the response path, on its own connection. */
class Checkpointer(private val path: String) : Thread("checkpointer") {
    init { isDaemon = true; priority = MIN_PRIORITY }

    override fun run() {
        val db = Sqlite.open(path, 5000)
        Db.tune(db, 500)
        while (true) {
            try {
                sleep(1000)
                Sqlite.exec(db, "PRAGMA wal_checkpoint(PASSIVE)")
            } catch (e: InterruptedException) {
                return
            } catch (e: Exception) {
                System.err.println("checkpoint: $e")
            }
        }
    }
}

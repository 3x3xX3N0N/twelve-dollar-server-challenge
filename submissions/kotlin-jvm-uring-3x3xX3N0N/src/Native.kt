package app

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemorySegment
import java.lang.foreign.SymbolLookup
import java.lang.foreign.ValueLayout
import java.lang.invoke.MethodHandle
import java.nio.file.Path

/*
 * FFM downcalls into build/libkj.so (csrc/: uring.c, db.c, jvm.c). Each handle is a top-level `private val`, i.e. a
 * static final field, so C2 treats it as a constant and inlines the downcall stub at the call site. Every call is
 * `invokeExact` with the exact signature (Kotlin emits the descriptor from the argument types and the `as` cast).
 *
 * Calls that never wait are `critical(true)`: no Java -> native thread-state transition, and Java arrays are passed
 * as heap segments that C reads and writes in place (no copy, no pinning API). The one call that sleeps
 * (kj_enter: io_uring_enter) and the start-up calls are ordinary downcalls, so a safepoint never waits on them.
 */
private val LINKER: Linker = Linker.nativeLinker()
private val LIB: SymbolLookup = SymbolLookup.libraryLookup(
    Path.of(System.getProperty("kj.lib") ?: error("-Dkj.lib=<path to libkj.so> is not set")), Arena.global())

private val I = ValueLayout.JAVA_INT
private val J = ValueLayout.JAVA_LONG
private val A = ValueLayout.ADDRESS
private val CRIT = Linker.Option.critical(true)

private fun fn(name: String, critical: Boolean, ret: ValueLayout, vararg args: ValueLayout): MethodHandle {
    val addr = LIB.find(name).orElseThrow { IllegalStateException("symbol $name not in libkj.so") }
    val fd = FunctionDescriptor.of(ret, *args)
    return if (critical) LINKER.downcallHandle(addr, fd, CRIT) else LINKER.downcallHandle(addr, fd)
}

// start-up (ordinary downcalls)
private val DB_OPEN = fn("db_open", false, I, A, A, I, A, I)
private val DB_VERIFY = fn("db_verify", false, I)
private val CKPT_START = fn("ckpt_start", false, I)
private val UR_INIT = fn("ur_init", false, I, A, I, I)
private val WQ_INIT = fn("db_wq_init", false, I)
private val WATCH = fn("ur_watch_eventfd", false, I, I)
// the loop
private val ENTER = fn("kj_enter", false, I, I, J)
private val REAP = fn("kj_reap", true, I, A, I, A, I)
private val SEND = fn("kj_send", true, I, I, I, A, I, I)
private val CLOSE_AFTER = fn("kj_close_after", true, I, I, I)
private val FEED = fn("kj_feed", true, I, A, I, I)
private val POST = fn("kj_post", true, I, J, A, I, I)
private val HEALTH = fn("db_health", true, I, A, I)
private val ADD_LIKE = fn("kj_add_like", true, I, J, J)
private val ADD_POST = fn("kj_add_post", true, I, J, A, I, I, I, I)
private val WQ_START = fn("db_wq_start", true, I)
private val WQ_DONE = fn("db_wq_done", true, I)
private val WQ_RESULT = fn("db_wq_result", true, I, I, A, A, I)
private val RELEASE = fn("kj_release", true, I)
private val PASS_END = fn("kj_pass_end", true, I)
private val UR_STAT = fn("ur_stat", false, J, I)
private val DB_STAT = fn("db_stat", false, J, I)

private fun cstr(arena: Arena, s: String?): MemorySegment = if (s == null) MemorySegment.NULL else arena.allocateFrom(s)

/** Opens the database; null on success, else SQLite's message. */
fun dbOpen(path: String, vfs: String?, btree: Int): String? {
    Arena.ofConfined().use { a ->
        val err = a.allocate(512)
        val rc = DB_OPEN.invokeExact(cstr(a, path), cstr(a, vfs), btree, err, 512) as Int
        return if (rc == 0) null else err.getString(0)
    }
}

fun dbVerify(): Int = DB_VERIFY.invokeExact() as Int
fun ckptStart(): Int = CKPT_START.invokeExact() as Int
fun urInit(host: String, port: Int, rings: Int): Int =
    Arena.ofConfined().use { a -> UR_INIT.invokeExact(cstr(a, host), port, rings) as Int }
fun wqInit(): Int = WQ_INIT.invokeExact() as Int
fun watchEventfd(fd: Int): Int = WATCH.invokeExact(fd) as Int

fun kjEnter(waitNr: Int, timeoutUs: Long): Int = ENTER.invokeExact(waitNr, timeoutUs) as Int
fun kjReap(ev: MemorySegment, max: Int, bytes: MemorySegment, cap: Int): Int = REAP.invokeExact(ev, max, bytes, cap) as Int
fun kjSend(slot: Int, gen: Int, buf: MemorySegment, off: Int, len: Int): Int = SEND.invokeExact(slot, gen, buf, off, len) as Int
fun kjCloseAfter(slot: Int, gen: Int): Int = CLOSE_AFTER.invokeExact(slot, gen) as Int
fun kjFeed(buf: MemorySegment, off: Int, cap: Int): Int = FEED.invokeExact(buf, off, cap) as Int
fun kjPost(id: Long, buf: MemorySegment, off: Int, cap: Int): Int = POST.invokeExact(id, buf, off, cap) as Int
fun dbHealth(err: MemorySegment, cap: Int): Int = HEALTH.invokeExact(err, cap) as Int
fun kjAddLike(uid: Long, pid: Long): Int = ADD_LIKE.invokeExact(uid, pid) as Int
fun kjAddPost(uid: Long, buf: MemorySegment, boff: Int, blen: Int, aoff: Int, alen: Int): Int =
    ADD_POST.invokeExact(uid, buf, boff, blen, aoff, alen) as Int
fun wqStart(): Int = WQ_START.invokeExact() as Int
fun wqDone(): Int = WQ_DONE.invokeExact() as Int
fun wqResult(i: Int, code: MemorySegment, out: MemorySegment, cap: Int): Int = WQ_RESULT.invokeExact(i, code, out, cap) as Int
fun kjRelease(): Int = RELEASE.invokeExact() as Int
fun kjPassEnd(): Int = PASS_END.invokeExact() as Int
fun urStat(which: Int): Long = UR_STAT.invokeExact(which) as Long
fun dbStat(which: Int): Long = DB_STAT.invokeExact(which) as Long

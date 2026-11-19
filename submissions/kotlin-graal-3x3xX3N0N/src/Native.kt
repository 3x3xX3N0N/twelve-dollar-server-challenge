package app

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemoryLayout
import java.lang.foreign.MemorySegment
import java.lang.foreign.SymbolLookup
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.foreign.ValueLayout.JAVA_LONG
import java.lang.invoke.MethodHandle

/**
 * FFM downcall handles into build/libkn.so (csrc/). Each handle is a static final field made WITHOUT a target
 * address (the function's address is the first argument), so native-image can create every handle at image build
 * time (`--initialize-at-build-time=app.H`) and compile each call as a direct call into a pre-generated stub; a
 * handle made at run time would go through the generic method-handle path. On the JVM the same shape lets C2/Graal
 * inline the handle as a constant.
 *
 * `Linker.Option.critical(true)`: no Java->native thread-state transition, and heap arrays are passed in place
 * (MemorySegment.ofArray, made once per array), so no call copies or allocates.
 * Signatures here and in native-image's foreign metadata (build.sh writes it) must match.
 */
object H {
    private val L: Linker = Linker.nativeLinker()
    private val CRIT = Linker.Option.critical(true)
    private fun fn(ret: MemoryLayout, vararg args: MemoryLayout): MethodHandle =
        L.downcallHandle(FunctionDescriptor.of(ret, *args), CRIT)

    // int jv_wait(wait_nr, timeout_us): NOT critical (it sleeps; the thread must be "in native" for safepoints)
    @JvmField val WAIT: MethodHandle = L.downcallHandle(FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_LONG))
    // int jv_step(tab, nsend, out, ev, in, incap, max, wait_nr, timeout_us)
    @JvmField val STEP: MethodHandle = fn(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, ADDRESS, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_LONG)
    // int jv_send(tab, n, out)
    @JvmField val SEND: MethodHandle = fn(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS)
    // int jv_feed(base, off, cap)
    @JvmField val FEED: MethodHandle = fn(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT)
    // int jv_post(id, base, off, cap)
    @JvmField val POST: MethodHandle = fn(JAVA_INT, JAVA_LONG, ADDRESS, JAVA_INT, JAVA_INT)
    // int db_wq_add_like(uid, pid)
    @JvmField val ADD_LIKE: MethodHandle = fn(JAVA_INT, JAVA_LONG, JAVA_LONG)
    // int jv_wq_add_post(uid, b, boff, blen, a, aoff, alen)
    @JvmField val ADD_POST: MethodHandle = fn(JAVA_INT, JAVA_LONG, ADDRESS, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT)
    // int db_wq_start(void)
    @JvmField val WQ_START: MethodHandle = fn(JAVA_INT)
    // int jv_wq_results(res, maxops, out, cap)
    @JvmField val WQ_RESULTS: MethodHandle = fn(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT)
    // int jv_wq_release(void)
    @JvmField val WQ_RELEASE: MethodHandle = fn(JAVA_INT)
    // int jv_open(path, vfs, btree, err, errcap)
    @JvmField val OPEN: MethodHandle = fn(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT)
    // int jv_init(host, port, rings)
    @JvmField val INIT: MethodHandle = fn(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT)
    // int jv_health(err, cap)
    @JvmField val HEALTH: MethodHandle = fn(JAVA_INT, ADDRESS, JAVA_INT)
    // int f(void): db_wq_init, ckpt_start, db_verify
    @JvmField val INT0: MethodHandle = fn(JAVA_INT)
    // int ur_watch_eventfd(int)
    @JvmField val INT1: MethodHandle = fn(JAVA_INT, JAVA_INT)
    // int64 ur_stat(int), db_stat(int)
    @JvmField val STAT: MethodHandle = fn(JAVA_LONG, JAVA_INT)
}

/** Function addresses in libkn.so, resolved when the process starts (never at image build time). */
object A {
    private val LIB: SymbolLookup = SymbolLookup.libraryLookup(
        java.nio.file.Path.of(System.getProperty("kn.lib") ?: System.getenv("KN_LIB") ?: error("kn.lib / KN_LIB not set")),
        Arena.global(),
    )
    private fun f(name: String): MemorySegment = LIB.find(name).orElseThrow { IllegalStateException("no symbol $name") }
    @JvmField val STEP = f("jv_step")
    @JvmField val WAIT = f("jv_wait")
    @JvmField val SEND = f("jv_send")
    @JvmField val FEED = f("jv_feed")
    @JvmField val POST = f("jv_post")
    @JvmField val ADD_LIKE = f("db_wq_add_like")
    @JvmField val ADD_POST = f("jv_wq_add_post")
    @JvmField val WQ_START = f("db_wq_start")
    @JvmField val WQ_RESULTS = f("jv_wq_results")
    @JvmField val WQ_RELEASE = f("jv_wq_release")
    @JvmField val OPEN = f("jv_open")
    @JvmField val INIT = f("jv_init")
    @JvmField val HEALTH = f("jv_health")
    @JvmField val WQ_INIT = f("db_wq_init")
    @JvmField val CKPT_START = f("ckpt_start")
    @JvmField val VERIFY = f("db_verify")
    @JvmField val WATCH = f("ur_watch_eventfd")
    @JvmField val UR_STAT = f("ur_stat")
    @JvmField val DB_STAT = f("db_stat")
}

/** Thin typed wrappers; each is one invokeExact on a constant handle (inlined by both compilers). */
object N {
    @JvmStatic fun step(tab: MemorySegment, n: Int, out: MemorySegment, ev: MemorySegment, inp: MemorySegment, incap: Int,
                        max: Int, waitNr: Int, timeoutUs: Long): Int =
        H.STEP.invokeExact(A.STEP, tab, n, out, ev, inp, incap, max, waitNr, timeoutUs) as Int
    @JvmStatic fun waitEvents(waitNr: Int, timeoutUs: Long): Int = H.WAIT.invokeExact(A.WAIT, waitNr, timeoutUs) as Int
    @JvmStatic fun send(tab: MemorySegment, n: Int, out: MemorySegment): Int = H.SEND.invokeExact(A.SEND, tab, n, out) as Int
    @JvmStatic fun feed(base: MemorySegment, off: Int, cap: Int): Int = H.FEED.invokeExact(A.FEED, base, off, cap) as Int
    @JvmStatic fun post(id: Long, base: MemorySegment, off: Int, cap: Int): Int = H.POST.invokeExact(A.POST, id, base, off, cap) as Int
    @JvmStatic fun addLike(uid: Long, pid: Long): Int = H.ADD_LIKE.invokeExact(A.ADD_LIKE, uid, pid) as Int
    @JvmStatic fun addPost(uid: Long, b: MemorySegment, boff: Int, blen: Int, a: MemorySegment, aoff: Int, alen: Int): Int =
        H.ADD_POST.invokeExact(A.ADD_POST, uid, b, boff, blen, a, aoff, alen) as Int
    @JvmStatic fun wqStart(): Int = H.WQ_START.invokeExact(A.WQ_START) as Int
    @JvmStatic fun wqResults(res: MemorySegment, maxOps: Int, out: MemorySegment, cap: Int): Int =
        H.WQ_RESULTS.invokeExact(A.WQ_RESULTS, res, maxOps, out, cap) as Int
    @JvmStatic fun wqRelease(): Int = H.WQ_RELEASE.invokeExact(A.WQ_RELEASE) as Int
    @JvmStatic fun open(path: MemorySegment, vfs: MemorySegment, btree: Int, err: MemorySegment, cap: Int): Int =
        H.OPEN.invokeExact(A.OPEN, path, vfs, btree, err, cap) as Int
    @JvmStatic fun init(host: MemorySegment, port: Int, rings: Int): Int = H.INIT.invokeExact(A.INIT, host, port, rings) as Int
    @JvmStatic fun health(err: MemorySegment, cap: Int): Int = H.HEALTH.invokeExact(A.HEALTH, err, cap) as Int
    @JvmStatic fun wqInit(): Int = H.INT0.invokeExact(A.WQ_INIT) as Int
    @JvmStatic fun ckptStart(): Int = H.INT0.invokeExact(A.CKPT_START) as Int
    @JvmStatic fun verify(): Int = H.INT0.invokeExact(A.VERIFY) as Int
    @JvmStatic fun watch(fd: Int): Int = H.INT1.invokeExact(A.WATCH, fd) as Int
    @JvmStatic fun urStat(w: Int): Long = H.STAT.invokeExact(A.UR_STAT, w) as Long
    @JvmStatic fun dbStat(w: Int): Long = H.STAT.invokeExact(A.DB_STAT, w) as Long
}

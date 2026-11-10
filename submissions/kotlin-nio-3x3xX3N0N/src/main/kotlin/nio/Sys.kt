package nio

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.foreign.ValueLayout.ADDRESS
import java.nio.channels.ServerSocketChannel

/** The few Linux calls the JDK has no option for, through FFM. */
object Sys {
    private const val IPPROTO_TCP = 6
    private const val TCP_DEFER_ACCEPT = 9

    private val linker = Linker.nativeLinker()
    private val setsockopt = linker.downcallHandle(
        linker.defaultLookup().find("setsockopt").orElseThrow(),
        FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT),
    )

    /** The fd behind a ServerSocketChannel (needs --add-opens java.base/sun.nio.ch=ALL-UNNAMED); -1 if hidden. */
    fun fd(ch: ServerSocketChannel): Int = try {
        val f = ch.javaClass.getDeclaredField("fdVal"); f.isAccessible = true; f.getInt(ch)
    } catch (e: Exception) { -1 }

    private fun setInt(fd: Int, level: Int, opt: Int, v: Int): Boolean = Arena.ofConfined().use { a ->
        val p = a.allocate(JAVA_INT); p.set(JAVA_INT, 0, v)
        (setsockopt.invokeExact(fd, level, opt, p, 4) as Int) == 0
    }

    /**
     * TCP_DEFER_ACCEPT: the listener reports a connection only once its first request bytes arrived, so a new
     * connection costs one wakeup (accept + read) instead of two. 5 s: a client that connects and stays silent
     * longer is accepted anyway (the kernel then completes it as usual).
     */
    fun deferAccept(ch: ServerSocketChannel, seconds: Int): Boolean {
        val fd = fd(ch)
        return fd >= 0 && setInt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, seconds)
    }
}

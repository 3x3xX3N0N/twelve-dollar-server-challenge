package nio

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.foreign.ValueLayout.JAVA_LONG

/** The few Linux calls the JDK has no API for, through FFM. */
object Sys {
    private const val RLIMIT_NOFILE = 7
    private val linker = Linker.nativeLinker()
    private val getrlimit = linker.downcallHandle(
        linker.defaultLookup().find("getrlimit").orElseThrow(), FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS),
    )
    private val setrlimit = linker.downcallHandle(
        linker.defaultLookup().find("setrlimit").orElseThrow(), FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS),
    )

    /** Raises the soft RLIMIT_NOFILE to the hard limit; returns the soft limit now in force (-1 if unknown). */
    fun raiseNofile(): Long = Arena.ofConfined().use { a ->
        val r = a.allocate(16)
        if ((getrlimit.invokeExact(RLIMIT_NOFILE, r) as Int) != 0) return -1
        val hard = r.get(JAVA_LONG, 8)
        if (r.get(JAVA_LONG, 0) != hard) {
            r.set(JAVA_LONG, 0, hard)
            if ((setrlimit.invokeExact(RLIMIT_NOFILE, r) as Int) != 0) System.err.println("setrlimit(NOFILE) failed")
            if ((getrlimit.invokeExact(RLIMIT_NOFILE, r) as Int) != 0) return -1
        }
        r.get(JAVA_LONG, 0)
    }

    /** Descriptors this process has open right now. */
    fun openFds(): Int = java.io.File("/proc/self/fd").list()?.size ?: 0
}

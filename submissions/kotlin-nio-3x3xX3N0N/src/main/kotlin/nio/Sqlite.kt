package nio

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemorySegment
import java.lang.foreign.SymbolLookup
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.foreign.ValueLayout.JAVA_LONG
import java.lang.invoke.MethodHandle
import java.nio.file.Path

class SqliteException(val code: Int, msg: String) : RuntimeException("SQLite error $code: $msg")

/**
 * Direct FFM bindings to the libsqlite3.so that build.sh compiles from the pinned amalgamation.
 * No JDBC: statements are raw pointers, results are read straight out of SQLite's memory.
 * Hot calls use Linker.Option.critical (no thread-state transition; heap arrays can be passed in place).
 */
object Sqlite {
    const val OK = 0; const val BUSY = 5; const val ROW = 100; const val DONE = 101
    private const val OPEN_READWRITE = 0x2; private const val OPEN_NOMUTEX = 0x8000
    private const val PREPARE_PERSISTENT = 0x1
    private val TRANSIENT: MemorySegment = MemorySegment.ofAddress(-1L) // SQLITE_TRANSIENT: SQLite copies the value

    private val linker = Linker.nativeLinker()
    private val lib = SymbolLookup.libraryLookup(
        Path.of(System.getProperty("sqlite.lib") ?: System.getenv("SQLITE_LIB") ?: "build/native/libsqlite3.so"), Arena.global())
    private val crit = Linker.Option.critical(true)

    private fun fn(name: String, d: FunctionDescriptor, critical: Boolean = false): MethodHandle =
        linker.downcallHandle(lib.find(name).orElseThrow { IllegalStateException("missing $name") }, d, *(if (critical) arrayOf(crit) else emptyArray()))

    private val open_v2 = fn("sqlite3_open_v2", FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS))
    private val exec = fn("sqlite3_exec", FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, ADDRESS, ADDRESS))
    private val prepare_v3 = fn("sqlite3_prepare_v3", FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, JAVA_INT, ADDRESS, ADDRESS))
    private val busy_timeout = fn("sqlite3_busy_timeout", FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT))
    private val errmsg = fn("sqlite3_errmsg", FunctionDescriptor.of(ADDRESS, ADDRESS))
    private val libversion = fn("sqlite3_libversion", FunctionDescriptor.of(ADDRESS))
    private val step_ = fn("sqlite3_step", FunctionDescriptor.of(JAVA_INT, ADDRESS), critical = true)
    private val reset_ = fn("sqlite3_reset", FunctionDescriptor.of(JAVA_INT, ADDRESS), critical = true)
    private val bind_int64 = fn("sqlite3_bind_int64", FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_LONG), critical = true)
    private val bind_text = fn("sqlite3_bind_text", FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT, ADDRESS), critical = true)
    private val column_blob = fn("sqlite3_column_blob", FunctionDescriptor.of(ADDRESS, ADDRESS, JAVA_INT), critical = true)
    private val column_bytes = fn("sqlite3_column_bytes", FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT), critical = true)
    private val changes_ = fn("sqlite3_changes", FunctionDescriptor.of(JAVA_INT, ADDRESS), critical = true)

    fun version(): String = (libversion.invokeExact() as MemorySegment).reinterpret(64).getString(0)

    /** Opens an existing database read-write; returns the sqlite3* handle. */
    fun open(path: String, busyMs: Int): MemorySegment {
        Arena.ofConfined().use { a ->
            val pp = a.allocate(ADDRESS)
            val rc = open_v2.invokeExact(a.allocateFrom(path), pp, OPEN_READWRITE or OPEN_NOMUTEX, MemorySegment.NULL) as Int
            val db = pp.get(ADDRESS, 0)
            if (rc != OK) throw SqliteException(rc, if (db == MemorySegment.NULL) "open failed" else errmsg(db))
            busy_timeout.invokeExact(db, busyMs) as Int
            return db
        }
    }

    fun exec(db: MemorySegment, sql: String) {
        Arena.ofConfined().use { a ->
            val rc = exec.invokeExact(db, a.allocateFrom(sql), MemorySegment.NULL, MemorySegment.NULL, MemorySegment.NULL) as Int
            if (rc != OK) throw SqliteException(rc, errmsg(db))
        }
    }

    fun prepare(db: MemorySegment, sql: String): MemorySegment {
        Arena.ofConfined().use { a ->
            val pp = a.allocate(ADDRESS)
            val rc = prepare_v3.invokeExact(db, a.allocateFrom(sql), -1, PREPARE_PERSISTENT, pp, MemorySegment.NULL) as Int
            if (rc != OK) throw SqliteException(rc, errmsg(db) + " in: " + sql)
            return pp.get(ADDRESS, 0)
        }
    }

    fun errmsg(db: MemorySegment): String = (errmsg.invokeExact(db) as MemorySegment).reinterpret(4096).getString(0)

    fun step(st: MemorySegment): Int = step_.invokeExact(st) as Int
    fun reset(st: MemorySegment): Int = reset_.invokeExact(st) as Int
    fun bindLong(st: MemorySegment, i: Int, v: Long) { bind_int64.invokeExact(st, i, v) as Int }
    /** UTF-8 bytes straight from a Java array (critical call, SQLite copies them: SQLITE_TRANSIENT). */
    fun bindText(st: MemorySegment, i: Int, utf8: ByteArray) {
        bind_text.invokeExact(st, i, MemorySegment.ofArray(utf8), utf8.size, TRANSIENT) as Int
    }
    fun columnBytes(st: MemorySegment, col: Int): Int = column_bytes.invokeExact(st, col) as Int
    /** Pointer to the column's bytes; valid until the next step/reset on st. */
    fun columnBlob(st: MemorySegment, col: Int, len: Int): MemorySegment =
        (column_blob.invokeExact(st, col) as MemorySegment).reinterpret(len.toLong())
    fun changes(db: MemorySegment): Int = changes_.invokeExact(db) as Int
}

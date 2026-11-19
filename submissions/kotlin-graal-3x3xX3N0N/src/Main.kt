package app

import java.lang.foreign.MemorySegment
import kotlin.system.exitProcess

private fun cstr(s: String): MemorySegment = MemorySegment.ofArray((s + "\u0000").encodeToByteArray())

fun main() {
    val path = System.getenv("SQLITE_PATH") ?: error("SQLITE_PATH is not set")
    val secret = System.getenv("JWT_SECRET") ?: error("JWT_SECRET is not set")
    val host = System.getenv("HOST") ?: "0.0.0.0"
    val port = (System.getenv("PORT") ?: "3000").toInt()
    // KN_VFS: SQLite VFS (default "unix"). KN_BTREE=0: SQL only. KN_VERIFY=1: B-tree vs SQL for every post id, exit.
    val vfs = System.getenv("KN_VFS") ?: ""
    val btree = if (System.getenv("KN_BTREE") == "0") 0 else 1

    val err = ByteArray(512)
    if (N.open(cstr(path), cstr(vfs), btree, MemorySegment.ofArray(err), err.size) != 0) {
        var e = 0
        while (e < err.size && err[e] != 0.toByte()) e++
        println("db_open: ${err.decodeToString(0, e)}")
        exitProcess(1)
    }
    if (System.getenv("KN_VERIFY") == "1") exitProcess(if (N.verify() == 0) 0 else 1)
    if (N.ckptStart() != 0) println("checkpointer thread not started")
    if (N.init(cstr(host), port, envLong("KN_RINGS", 8).toInt()) != 0) exitProcess(1)
    // Group commit runs on its own thread; it wakes the loop through this eventfd (watched by ring 0).
    val wakeFd = N.wqInit()
    if (wakeFd < 0 || N.watch(wakeFd) != 0) { println("committer thread not started"); exitProcess(1) }
    println("listening on $host:$port (vfs ${vfs.ifEmpty { "unix" }}, btree reads ${if (btree == 1) "on" else "off"})")
    Server(Jwt(secret)).run()
}

package app

import kotlin.system.exitProcess

fun main() {
    val path = System.getenv("SQLITE_PATH") ?: error("SQLITE_PATH is not set")
    val secret = System.getenv("JWT_SECRET") ?: error("JWT_SECRET is not set")
    val host = System.getenv("HOST") ?: "0.0.0.0"
    val port = (System.getenv("PORT") ?: "3000").toInt()
    // KJ_VFS: SQLite VFS for all connections (default "unix"). KJ_BTREE=0: SQL only.
    // KJ_VERIFY=1: compare the B-tree paths with SQL for every post id and exit.
    val vfs = System.getenv("KJ_VFS")?.takeIf { it.isNotEmpty() }
    val btree = if (System.getenv("KJ_BTREE") == "0") 0 else 1

    dbOpen(path, vfs, btree)?.let { println("db_open: $it"); exitProcess(1) }
    if (System.getenv("KJ_VERIFY") == "1") exitProcess(if (dbVerify() == 0) 0 else 1)
    if (ckptStart() != 0) println("checkpointer thread not started")
    if (urInit(host, port, envLong("KJ_RINGS", 8).toInt()) != 0) exitProcess(1)
    // Group commit runs on its own thread; it wakes the loop through this eventfd (watched by ring 0).
    val wakeFd = wqInit()
    if (wakeFd < 0 || watchEventfd(wakeFd) != 0) { println("committer thread not started"); exitProcess(1) }
    println("listening on $host:$port (vfs ${vfs ?: "unix"}, btree reads ${if (btree == 1) "on" else "off"})")
    Server(Jwt(secret)).run()
}

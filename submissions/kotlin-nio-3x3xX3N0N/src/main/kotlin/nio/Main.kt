package nio

fun main() {
    val path = System.getenv("SQLITE_PATH") ?: error("SQLITE_PATH is not set")
    val secret = System.getenv("JWT_SECRET") ?: error("JWT_SECRET is not set")
    val host = System.getenv("HOST") ?: "0.0.0.0"
    val port = (System.getenv("PORT") ?: "3000").toInt()

    val db = Db(path)
    db.ping()
    Checkpointer(path).start()
    Server(host, port, db, Jwt(secret)).run()
}

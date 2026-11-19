package app

import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.Base64
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.atomic.AtomicLong
import kotlin.system.exitProcess

/**
 * Build-time only: the PGO training client (build.sh runs it on the GraalVM JDK, never in the scored server; it is
 * not reachable from app.MainKt, so it is not in the native image). Keep-alive connections, each looping over the
 * load test's user loop without think time: GET /feed, GET /posts/:id of a post from that feed, a like (15 %), a new
 * post (2 %). Every 64th loop also sends one of the test suite's error cases (bad or missing token, missing post,
 * bad body, unknown route, health), so those paths are profiled too, at roughly their weight (rare).
 *
 *   Train <host> <port> <jwt secret> <users> <requests> <connections>
 */
object Train {
    private val b64 = Base64.getUrlEncoder().withoutPadding()
    private val done = AtomicLong()
    private val fails = AtomicLong()

    private fun token(mac: HmacSha256, uid: Int, exp: Long): String {
        val h = b64.encodeToString("""{"alg":"HS256","typ":"JWT"}""".toByteArray())
        val p = b64.encodeToString("""{"sub":"$uid","username":"user_$uid","iat":${exp - 3600},"exp":$exp}""".toByteArray())
        val si = "$h.$p".toByteArray()
        val out = ByteArray(32)
        mac.mac(si, 0, si.size, out)
        return "$h.$p.${b64.encodeToString(out)}"
    }

    private class Conn(val dstHost: String, val dstPort: Int) {
        var s = open(); var inp: InputStream = s.getInputStream(); var out: OutputStream = s.getOutputStream()
        val buf = ByteArray(1 shl 16)
        // (not inside Socket().apply: there `port` would be Socket.getPort())
        private fun open(): Socket { val k = Socket(); k.tcpNoDelay = true; k.connect(InetSocketAddress(dstHost, dstPort), 5000); k.soTimeout = 30000; return k }
        fun reopen() { runCatching { s.close() }; s = open(); inp = s.getInputStream(); out = s.getOutputStream() }

        /** Sends one request and reads the whole response; returns the status, the body is in buf[0, bodyLen). */
        var bodyLen = 0
        fun call(req: ByteArray): Int {
            out.write(req); out.flush()
            var n = 0; var hEnd = -1
            while (hEnd < 0) {
                val r = inp.read(buf, n, buf.size - n); if (r < 0) throw java.io.EOFException()
                n += r
                for (i in maxOf(0, n - r - 3) until n - 3)
                    if (buf[i] == '\r'.code.toByte() && buf[i + 1] == '\n'.code.toByte() && buf[i + 2] == '\r'.code.toByte() && buf[i + 3] == '\n'.code.toByte()) { hEnd = i + 4; break }
            }
            val head = String(buf, 0, hEnd, Charsets.ISO_8859_1)
            val status = head.substring(9, 12).toInt()
            val cl = Regex("(?i)content-length: *(\\d+)").find(head)?.groupValues?.get(1)?.toInt() ?: 0
            while (n < hEnd + cl) { val r = inp.read(buf, n, buf.size - n); if (r < 0) throw java.io.EOFException(); n += r }
            System.arraycopy(buf, hEnd, buf, 0, cl); bodyLen = cl
            if (head.contains("onnection: close", ignoreCase = true)) reopen()
            return status
        }
    }

    private fun get(path: String) = "GET $path HTTP/1.1\r\nHost: t\r\n\r\n".toByteArray()
    private fun post(path: String, tok: String?, body: String): ByteArray {
        val b = body.toByteArray()
        val a = if (tok != null) "Authorization: Bearer $tok\r\n" else ""
        return "POST $path HTTP/1.1\r\nHost: t\r\n${a}Content-Type: application/json\r\nContent-Length: ${b.size}\r\n\r\n".toByteArray() + b
    }

    @JvmStatic
    fun main(args: Array<String>) {
        val host = args[0]; val port = args[1].toInt(); val mac = HmacSha256(args[2].toByteArray())
        val users = args[3].toInt(); val total = args[4].toLong(); val nconn = args[5].toInt()
        val exp = System.currentTimeMillis() / 1000 + 7200
        val idRe = Regex("\"id\":(\\d+),\"body\"")
        val t0 = System.nanoTime()
        val threads = (0 until nconn).map { c ->
            Thread {
                val rnd = ThreadLocalRandom.current()
                var c0: Conn? = null
                while (c0 == null) c0 = try { Conn(host, port) } catch (e: Exception) { if (fails.incrementAndGet() > 1000) return@Thread; Thread.sleep(100); null }
                val conn: Conn = c0
                val tok = token(mac, 1 + c % users, exp)
                var loop = 0
                while (done.get() < total) {
                    try {
                        fun expect(st: Int, vararg ok: Int) { done.incrementAndGet(); if (st !in ok) fails.incrementAndGet() }
                        expect(conn.call(get("/feed")), 200)
                        val ids = idRe.findAll(String(conn.buf, 0, conn.bodyLen, Charsets.UTF_8)).map { it.groupValues[1] }.toList()
                        val id = if (ids.isEmpty()) "1" else ids[rnd.nextInt(ids.size)]
                        expect(conn.call(get("/posts/$id")), 200)
                        if (rnd.nextInt(100) < 15) expect(conn.call(post("/posts/$id/like", tok, "")), 200, 201)
                        if (rnd.nextInt(100) < 2) expect(conn.call(post("/posts", tok, """{"body":"user_$c says \"hi\" at ${System.nanoTime()} (loop $loop) é"}""")), 201)
                        if (loop % 64 == 63) when ((loop / 64) % 8) {
                            0 -> expect(conn.call(get("/posts/999999999")), 404)
                            1 -> expect(conn.call(post("/posts", null, """{"body":"x"}""")), 401)
                            2 -> expect(conn.call(post("/posts", tok.dropLast(2) + "AA", """{"body":"x"}""")), 401)
                            3 -> expect(conn.call(post("/posts", tok, """{"body":""}""")), 400)
                            4 -> expect(conn.call(post("/posts", tok, """{"nobody":1}""")), 400)
                            5 -> expect(conn.call(get("/nope")), 404)
                            6 -> expect(conn.call(post("/posts/999999999/like", tok, "")), 404)
                            else -> expect(conn.call(get("/health")), 200)
                        }
                        loop++
                    } catch (e: Exception) {
                        fails.incrementAndGet(); runCatching { conn.reopen() }
                    }
                }
            }.apply { start() }
        }
        threads.forEach { it.join() }
        val s = (System.nanoTime() - t0) / 1e9
        println("train: ${done.get()} requests in ${"%.1f".format(s)} s over $nconn connections, ${fails.get()} unexpected")
        exitProcess(if (fails.get() * 100 > done.get()) 1 else 0)
    }
}

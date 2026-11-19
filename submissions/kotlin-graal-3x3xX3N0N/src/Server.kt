package app

import java.lang.foreign.MemorySegment

/**
 * One thread, one event loop over io_uring (csrc/uring.c does the kernel plumbing, csrc/jv.c batches it for FFM).
 * The HTTP parsing, routing and handlers are the JVM entry's (kotlin-nio-3x3xX3N0N), by way of the Kotlin/Native
 * entry (kotlin-native-3x3xX3N0N): reads are answered inline from SQLite (B-tree plans, SQL as the fallback);
 * writes are staged on the C side and committed together on a committer thread (group commit) once the oldest has
 * waited WRITE_WINDOW_NS or BATCH_MAX are queued, and are answered only after COMMIT.
 *
 * Hot path shape: connections are slots (ring << 16 | direct-descriptor index) with flat per-slot arrays; requests
 * are parsed in place in the pass's input array; responses go into one pass-wide output array with a send table
 * (slot, gen, offset, length) that the next jv_step hands to the kernel. One downcall per pass, one per read plan,
 * one per staged write. No object is allocated on the GET path; there is no virtual call on it (every class is final,
 * events dispatch on an int).
 */
class Server(private val jwt: Jwt) {
    // ---- pass input: events (kind, slot, gen, len) and their bytes, packed by jv_step
    private val ev = IntArray(4 * MAX_EV)
    private val evSeg = MemorySegment.ofArray(ev)
    private val inp = ByteArray(MAX_EV * 2048)
    private val inSeg = MemorySegment.ofArray(inp)
    // concatenation of a connection's stashed input with new bytes
    private val rbuf = ByteArray(64 * 1024)
    private var b = rbuf            // the array the current request is parsed from (inp or rbuf)

    // ---- pass output: responses and the send table
    private val obuf = ByteArray(1 shl 21)
    private val oSeg = MemorySegment.ofArray(obuf)
    private var olen = 0
    private var segStart = 0        // start of the current connection's unsent span in obuf
    private val tab = IntArray(4 * MAX_SEND)
    private val tabSeg = MemorySegment.ofArray(tab)
    private var ntab = 0

    private val tmp = ByteArray(1 shl 16)
    private val tmpSeg = MemorySegment.ofArray(tmp)

    // ---- per slot
    private val open = BooleanArray(NSLOT)
    private val sgen = IntArray(NSLOT)
    private val busy = BooleanArray(NSLOT)        // has a write waiting for the group commit
    private val closeAfter = BooleanArray(NSLOT)
    private val pending = arrayOfNulls<ByteArray>(NSLOT)   // unparsed input (partial or pipelined requests)
    private val pendingLen = IntArray(NSLOT)

    // ---- group commit: the staged batch (on the C side, metadata here) and the one being committed
    private var qSlot = IntArray(1024); private var qGen = IntArray(1024); private var qPost = LongArray(1024)
    private var qFlags = IntArray(1024)   // bit 0 like, bit 1 close
    private var qn = 0
    private var fSlot = IntArray(1024); private var fGen = IntArray(1024); private var fPost = LongArray(1024)
    private var fFlags = IntArray(1024)
    private var fn = -1                    // ops in flight, -1 = none
    private var firstWriteNs = 0L
    private val wres = IntArray(2 * 65536)
    private val wresSeg = MemorySegment.ofArray(wres)
    private val wout = ByteArray(1 shl 20)
    private val woutSeg = MemorySegment.ofArray(wout)

    private val started = System.nanoTime()
    private val num = ByteArray(24)
    private val likeBuf = ByteArray(96)
    private val bodyBuf = ByteArray(8 * 1024)
    private val bodySeg = MemorySegment.ofArray(bodyBuf)

    companion object {
        private const val MAX_EV = 4096
        private const val MAX_SEND = 16384
        private const val NSLOT = 8 shl 16
        private const val GET = 1
        private const val POST = 2
        private const val MAX_REQ = 60 * 1024
        private const val HEAD_ROOM = 160    // room left for the status line + headers before a body from SQLite
        private const val READ_ROOM = 64 * 1024

        private val WRITE_WINDOW_NS = envLong("KN_WINDOW_US", 2000) * 1000
        private val BATCH_MAX = envLong("KN_BATCH_MAX", 64).toInt()
        private val PACE_NR = envLong("KN_PACE_NR", 1).toInt()
        private val PACE_US = envLong("KN_PACE_US", 1000)
        private val STATS = envLong("KN_STATS", 0) != 0L

        private fun a(s: String) = s.encodeToByteArray()
        private fun head(code: String) = a("HTTP/1.1 $code\r\nContent-Type: application/json\r\nContent-Length: ")
        private val H200 = head("200 OK")
        private val H201 = head("201 Created")
        private val H400 = head("400 Bad Request")
        private val H401 = head("401 Unauthorized")
        private val H404 = head("404 Not Found")
        private val H500 = head("500 Internal Server Error")
        private val H503 = head("503 Service Unavailable")
        private val CRLF2 = a("\r\n\r\n")
        private val CLOSE = a("\r\nConnection: close\r\n\r\n")

        private val E_NOT_FOUND = a("{\"error\":\"not found\"}")
        private val E_BAD_ID = a("{\"error\":\"invalid post id\"}")
        private val E_NO_POST = a("{\"error\":\"post not found\"}")
        private val E_MISSING = a("{\"error\":\"missing bearer token\"}")
        private val E_INVALID = a("{\"error\":\"invalid or expired token\"}")
        private val E_PAYLOAD = a("{\"error\":\"invalid token payload\"}")
        private val E_JSON = a("{\"error\":\"malformed JSON body\"}")
        private val E_BODY = a("{\"error\":\"body is required\"}")
        private val E_LONG = a("{\"error\":\"body must be at most 500 characters\"}")
        private val E_500 = a("{\"error\":\"internal server error\"}")

        private val P_HEALTH = a("/health")
        private val P_FEED = a("/feed")
        private val P_POSTS = a("/posts")
        private val P_LIKE = a("/like")
        private val LIKED_NEW = a("{\"liked\":true,\"already_liked\":false,\"post_id\":")
        private val LIKED_OLD = a("{\"liked\":true,\"already_liked\":true,\"post_id\":")

        private const val EV_DATA = 1
        private const val EV_OPEN = 2
        private const val EV_CLOSED = 3
        private const val EV_WAKE = 4
    }

    fun run() {
        var light = false
        var lastStats = System.nanoTime()
        while (true) {
            var waitNr = if (light) PACE_NR else 1
            var timeoutUs = if (light) PACE_US else -1L
            if (qn > 0 && fn < 0) {
                val left = WRITE_WINDOW_NS - (System.nanoTime() - firstWriteNs)
                val w = if (left <= 0 || qn >= BATCH_MAX) 0 else (left + 999) / 1000
                timeoutUs = if (timeoutUs < 0) w else minOf(timeoutUs, w)
            }
            // Sends the previous pass's output, ends the pass on the DB side, waits, and copies the new events in.
            var n = N.step(tabSeg, ntab, oSeg, evSeg, inSeg, inp.size, MAX_EV, 1, 0L)
            ntab = 0; olen = 0; segStart = 0
            if (n == 0 && timeoutUs != 0L) {
                // nothing ready: sleep in a plain (non-critical) downcall, then reap
                N.waitEvents(waitNr, timeoutUs)
                n = N.step(tabSeg, 0, oSeg, evSeg, inSeg, inp.size, MAX_EV, 1, 0L)
            }
            var at = 0
            for (i in 0 until n) {
                val k = 4 * i
                val slot = ev[k + 1]; val gen = ev[k + 2]
                when (ev[k]) {
                    EV_DATA -> { val len = ev[k + 3]; onData(slot, gen, at, len); at += len }
                    EV_OPEN -> { open[slot] = true; sgen[slot] = gen; busy[slot] = false; closeAfter[slot] = false; pending[slot] = null }
                    EV_CLOSED -> if (sgen[slot] == gen) { open[slot] = false; pending[slot] = null }
                    EV_WAKE -> finishBatch()
                }
            }
            if (qn > 0 && fn < 0 && (qn >= BATCH_MAX || System.nanoTime() - firstWriteNs >= WRITE_WINDOW_NS)) startBatch()
            light = n in 1 until PACE_NR
            if (STATS && System.nanoTime() - lastStats > 10_000_000_000L) {
                lastStats = System.nanoTime()
                println("stats: open=${N.urStat(0)} rings=${N.urStat(3)} enobufs=${N.urStat(1)} rearms=${N.urStat(4)} " +
                    "accept_err=${N.urStat(2)} btree=${N.dbStat(0)} sql=${N.dbStat(1)} snapshots=${N.dbStat(2)}")
            }
        }
    }

    // ---------------------------------------------------------------- input

    private fun onData(slot: Int, gen: Int, off: Int, n: Int) {
        if (!open[slot] || sgen[slot] != gen || closeAfter[slot]) return
        val pend = pending[slot]
        if (pend == null) {
            b = inp
            if (busy[slot]) { stash(slot, off, off + n); return }   // a write is in the group commit: keep the order
            process(slot, gen, off, off + n)
            return
        }
        val len = pendingLen[slot]
        pending[slot] = null
        if (len + n > rbuf.size) { closeNow(slot, gen); return }
        System.arraycopy(pend, 0, rbuf, 0, len)
        System.arraycopy(inp, off, rbuf, len, n)
        b = rbuf
        if (busy[slot]) { stash(slot, 0, len + n); return }
        process(slot, gen, 0, len + n)
    }

    private fun stash(slot: Int, from: Int, to: Int) {
        val rest = to - from
        val p = ByteArray(maxOf(rest, 1024))
        System.arraycopy(b, from, p, 0, rest)
        pending[slot] = p; pendingLen[slot] = rest
    }

    private fun closeNow(slot: Int, gen: Int) {
        closeAfter[slot] = true
        flush(slot, gen)
    }

    /** Handles every complete request in b[from, to), stages the answers, and stashes the remainder. */
    private fun process(slot: Int, gen: Int, from: Int, to: Int) {
        var pos = from
        while (pos < to && !busy[slot] && !closeAfter[slot]) {
            val used = request(slot, gen, pos, to)
            if (used < 0) { closeNow(slot, gen); return }
            if (used == 0) break
            pos += used
        }
        flush(slot, gen)
        if (closeAfter[slot]) return
        if (pos < to) {
            if (to - pos >= MAX_REQ) { closeNow(slot, gen); return }
            stash(slot, pos, to)
        }
    }

    /** Parses one request at b[s, e). Returns bytes consumed, 0 if incomplete, -1 to drop the connection. */
    private fun request(slot: Int, gen: Int, s: Int, e: Int): Int {
        val b = b
        var he = -1
        var i = s
        while (i + 3 < e) {
            if (b[i + 3] != '\n'.code.toByte()) { i++; continue }
            if (b[i] == '\r'.code.toByte() && b[i + 1] == '\n'.code.toByte() && b[i + 2] == '\r'.code.toByte()) { he = i + 4; break }
            i++
        }
        if (he < 0) return if (e - s > 16 * 1024) -1 else 0

        var method = 0
        var p: Int
        if (e - s > 4 && b[s] == 'G'.code.toByte() && b[s + 1] == 'E'.code.toByte() && b[s + 2] == 'T'.code.toByte() && b[s + 3] == ' '.code.toByte()) {
            method = GET; p = s + 4
        } else if (e - s > 5 && b[s] == 'P'.code.toByte() && b[s + 1] == 'O'.code.toByte() && b[s + 2] == 'S'.code.toByte() && b[s + 3] == 'T'.code.toByte() && b[s + 4] == ' '.code.toByte()) {
            method = POST; p = s + 5
        } else {
            p = s
            while (p < he && b[p] != ' '.code.toByte()) p++
            p++
        }
        val ts = p
        while (p < he && b[p] != ' '.code.toByte() && b[p] != '\r'.code.toByte()) p++
        val te = p
        var pathEnd = ts
        while (pathEnd < te && b[pathEnd] != '?'.code.toByte()) pathEnd++
        val http10 = p + 8 < he && b[p + 6] == '1'.code.toByte() && b[p + 8] == '0'.code.toByte()
        while (p < he && b[p] != '\n'.code.toByte()) p++
        p++

        var cl = 0
        var authS = -1; var authE = -1
        var close = http10
        while (p < he - 2) {
            var le = p
            while (b[le] != '\r'.code.toByte()) le++
            var colon = p
            while (colon < le && b[colon] != ':'.code.toByte()) colon++
            var vs = colon + 1
            while (vs < le && (b[vs] == ' '.code.toByte() || b[vs] == '\t'.code.toByte())) vs++
            var ve = le
            while (ve > vs && (b[ve - 1] == ' '.code.toByte() || b[ve - 1] == '\t'.code.toByte())) ve--
            when (colon - p) {
                14 -> if (ieq(b, p, "content-length")) {
                    cl = 0
                    for (k in vs until ve) {
                        val d = b[k] - '0'.code.toByte()
                        if (d !in 0..9) return -1
                        cl = cl * 10 + d
                        if (cl > MAX_REQ) return -1
                    }
                }
                13 -> if (ieq(b, p, "authorization")) { authS = vs; authE = ve }
                10 -> if (ieq(b, p, "connection")) {
                    if (icontains(b, vs, ve, "close")) close = true
                    else if (icontains(b, vs, ve, "keep-alive")) close = false
                }
                17 -> if (ieq(b, p, "transfer-encoding")) return -1 // chunked bodies aren't supported
            }
            p = le + 2
        }
        val total = he - s + cl
        if (cl > MAX_REQ - (he - s)) return -1
        if (e - s < total) return 0

        try {
            route(slot, gen, method, ts, pathEnd, authS, authE, he, he + cl, close)
        } catch (ex: Exception) {
            println("request failed: $ex")
            respond(slot, gen, H500, E_500, 0, E_500.size, close)
        }
        return total
    }

    private fun route(slot: Int, gen: Int, method: Int, ps: Int, pe: Int, authS: Int, authE: Int, bs: Int, be: Int, close: Boolean) {
        val b = b
        if (eq(b, ps, pe, P_FEED)) {
            if (method == GET) return fromDb(slot, gen, close, -1L)
        } else if (eq(b, ps, pe, P_HEALTH)) {
            if (method == GET) return health(slot, gen, close)
        } else if (startsWith(b, ps, pe, P_POSTS)) {
            val rest = ps + P_POSTS.size
            if (rest == pe) {
                if (method == POST) return createPost(slot, gen, authS, authE, bs, be, close)
            } else if (b[rest] == '/'.code.toByte()) {
                val idS = rest + 1
                var sl = idS
                while (sl < pe && b[sl] != '/'.code.toByte()) sl++
                if (sl == pe) {
                    if (method == GET) {
                        val id = parseId(b, idS, pe)
                        if (id <= 0) return err(slot, gen, H400, E_BAD_ID, close)
                        return fromDb(slot, gen, close, id)
                    }
                } else if (eq(b, sl, pe, P_LIKE) && method == POST) {
                    if (!auth(slot, gen, authS, authE, close)) return
                    val id = parseId(b, idS, sl)
                    if (id <= 0) return err(slot, gen, H400, E_BAD_ID, close)
                    if (N.addLike(jwt.userId, id) != 0) return err(slot, gen, H500, E_500, close)
                    return enqueue(slot, gen, id, 1 or (if (close) 2 else 0))
                }
            }
        }
        err(slot, gen, H404, E_NOT_FOUND, close)
    }

    /** GET /feed (id < 0) or GET /posts/:id: SQLite writes the JSON body straight into obuf; the head goes in
     *  front of it (written into the gap left before the body), so the body is never moved. */
    private fun fromDb(slot: Int, gen: Int, close: Boolean, id: Long) {
        room(slot, gen, HEAD_ROOM + READ_ROOM)
        val at = olen + HEAD_ROOM
        val n = if (id < 0) N.feed(oSeg, at, obuf.size - at) else N.post(id, oSeg, at, obuf.size - at)
        if (n < 0) return err(slot, gen, H500, E_500, close)
        if (n == 0) return err(slot, gen, H404, E_NO_POST, close)
        val h = headLen(H200, n, close)
        if (olen == segStart) {
            // nothing else of this connection is staged: start its span at the head
            putHead(at - h, H200, n, close)
            segStart = at - h
        } else {
            putHead(olen, H200, n, close)
            System.arraycopy(obuf, at, obuf, olen + h, n)
            olen += h
            olen += n
            if (close) closeAfter[slot] = true
            return
        }
        olen = at + n
        if (close) closeAfter[slot] = true
    }

    private fun health(slot: Int, gen: Int, close: Boolean) {
        if (N.health(tmpSeg, 512) == 0) {
            val up = (System.nanoTime() - started) / 1_000_000_000L
            val body = a("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":$up}")
            respond(slot, gen, H200, body, 0, body.size, close)
        } else {
            var e = 0
            while (e < 512 && tmp[e] != 0.toByte()) e++
            val msg = tmp.decodeToString(0, e).replace("\\", "\\\\").replace("\"", "\\\"").replace(Regex("[\\x00-\\x1f]"), " ")
            val body = a("{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"$msg\"}")
            respond(slot, gen, H503, body, 0, body.size, close)
        }
    }

    private fun auth(slot: Int, gen: Int, s: Int, e: Int, close: Boolean): Boolean {
        when (jwt.verify(b, s, e, System.currentTimeMillis() / 1000)) {
            Jwt.OK -> return true
            Jwt.MISSING -> err(slot, gen, H401, E_MISSING, close)
            Jwt.INVALID -> err(slot, gen, H401, E_INVALID, close)
            else -> err(slot, gen, H401, E_PAYLOAD, close)
        }
        return false
    }

    private fun createPost(slot: Int, gen: Int, authS: Int, authE: Int, bs: Int, be: Int, close: Boolean) {
        if (!auth(slot, gen, authS, authE, close)) return
        val doc = try { Json.parse(b, bs, be - bs) } catch (_: Json.Bad) { return err(slot, gen, H400, E_JSON, close) }
        val raw = (doc as? Map<*, *>)?.get("body") as? String ?: return err(slot, gen, H400, E_BODY, close)
        val body = raw.trim()
        if (body.isEmpty()) return err(slot, gen, H400, E_BODY, close)
        if (codePoints(body) > 500) return err(slot, gen, H400, E_LONG, close)
        val bb = body.encodeToByteArray()
        val ab = jwt.username.encodeToByteArray()
        if (bb.size + ab.size > bodyBuf.size) return err(slot, gen, H400, E_LONG, close)
        System.arraycopy(bb, 0, bodyBuf, 0, bb.size)
        System.arraycopy(ab, 0, bodyBuf, bb.size, ab.size)
        if (N.addPost(jwt.userId, bodySeg, 0, bb.size, bodySeg, bb.size, ab.size) != 0) return err(slot, gen, H500, E_500, close)
        enqueue(slot, gen, 0, if (close) 2 else 0)
    }

    private fun codePoints(s: String): Int {
        var n = 0; var i = 0
        while (i < s.length) {
            if (s[i].isHighSurrogate() && i + 1 < s.length && s[i + 1].isLowSurrogate()) i++
            i++; n++
        }
        return n
    }

    /** The write is staged on the C side already; remember who to answer. */
    private fun enqueue(slot: Int, gen: Int, post: Long, flags: Int) {
        if (qn == 0) firstWriteNs = System.nanoTime()
        if (qn == qSlot.size) {
            qSlot = qSlot.copyOf(qn * 2); qGen = qGen.copyOf(qn * 2); qPost = qPost.copyOf(qn * 2); qFlags = qFlags.copyOf(qn * 2)
        }
        qSlot[qn] = slot; qGen[qn] = gen; qPost[qn] = post; qFlags[qn] = flags
        qn++
        busy[slot] = true
    }

    // ---------------------------------------------------------------- group commit

    /** Hands the staged writes to the committer thread (csrc/db.c). */
    private fun startBatch() {
        if (fn >= 0) return
        var t = fSlot; fSlot = qSlot; qSlot = t
        t = fGen; fGen = qGen; qGen = t
        t = fFlags; fFlags = qFlags; qFlags = t
        val l = fPost; fPost = qPost; qPost = l
        fn = qn; qn = 0
        N.wqStart()
    }

    /** The committer thread signalled: if the batch is committed, answer everybody and resume their pipelined input. */
    private fun finishBatch() {
        if (fn < 0) return
        val n = N.wqResults(wresSeg, wres.size / 2, woutSeg, wout.size)
        if (n < 0) return
        N.wqRelease()   // the reader drops its snapshot: later reads see this commit
        val cnt = fn
        fn = -1
        var jo = 0
        for (k in 0 until cnt) {
            val code = if (k < n && k < wres.size / 2) wres[2 * k] else -2
            val len = if (k < n && k < wres.size / 2) wres[2 * k + 1] else 0
            val slot = fSlot[k]; val gen = fGen[k]; val flags = fFlags[k]
            val close = flags and 2 != 0
            val off = jo
            jo += len
            if (!open[slot] || sgen[slot] != gen) continue
            busy[slot] = false
            if (flags and 1 != 0) {
                when (code) {
                    -1 -> err(slot, gen, H404, E_NO_POST, close)
                    1 -> like(slot, gen, H201, LIKED_NEW, fPost[k], close)
                    0 -> like(slot, gen, H200, LIKED_OLD, fPost[k], close)
                    else -> err(slot, gen, H500, E_500, close)
                }
            } else if (code == 201) respond(slot, gen, H201, wout, off, len, close)
            else err(slot, gen, H500, E_500, close)
            val pend = pending[slot]
            if (pend != null && !closeAfter[slot]) {
                val plen = pendingLen[slot]
                flush(slot, gen)
                System.arraycopy(pend, 0, rbuf, 0, plen)
                pending[slot] = null
                b = rbuf
                process(slot, gen, 0, plen)
            } else flush(slot, gen)
        }
    }

    private fun like(slot: Int, gen: Int, head: ByteArray, prefix: ByteArray, id: Long, close: Boolean) {
        System.arraycopy(prefix, 0, likeBuf, 0, prefix.size)
        var v = id; var p = num.size
        do { num[--p] = ('0'.code + (v % 10).toInt()).toByte(); v /= 10 } while (v > 0)
        val nd = num.size - p
        System.arraycopy(num, p, likeBuf, prefix.size, nd)
        likeBuf[prefix.size + nd] = '}'.code.toByte()
        respond(slot, gen, head, likeBuf, 0, prefix.size + nd + 1, close)
    }

    // ---------------------------------------------------------------- output

    private fun digits(v0: Int): Int { var v = v0; var d = 1; while (v >= 10) { v /= 10; d++ }; return d }

    private fun headLen(head: ByteArray, n: Int, close: Boolean) = head.size + digits(n) + (if (close) CLOSE.size else CRLF2.size)

    /** Writes the status line + headers for a body of n bytes at obuf[at]; returns their length. */
    private fun putHead(at: Int, head: ByteArray, n: Int, close: Boolean): Int {
        var o = at
        System.arraycopy(head, 0, obuf, o, head.size); o += head.size
        var v = n; var p = num.size
        do { num[--p] = ('0'.code + v % 10).toByte(); v /= 10 } while (v > 0)
        System.arraycopy(num, p, obuf, o, num.size - p); o += num.size - p
        val end = if (close) CLOSE else CRLF2
        System.arraycopy(end, 0, obuf, o, end.size); o += end.size
        return o - at
    }

    private fun err(slot: Int, gen: Int, head: ByteArray, body: ByteArray, close: Boolean) =
        respond(slot, gen, head, body, 0, body.size, close)

    private fun respond(slot: Int, gen: Int, head: ByteArray, body: ByteArray, off: Int, len: Int, close: Boolean) {
        room(slot, gen, HEAD_ROOM + len)
        olen += putHead(olen, head, len, close)
        System.arraycopy(body, off, obuf, olen, len); olen += len
        if (close) closeAfter[slot] = true
    }

    /** Makes room in obuf: if fewer than need bytes are left, sends everything staged so far right now. */
    private fun room(slot: Int, gen: Int, need: Int) {
        if (obuf.size - olen >= need && ntab < MAX_SEND - 2) return
        span(slot, gen)
        N.send(tabSeg, ntab, oSeg)
        ntab = 0; olen = 0; segStart = 0
    }

    private fun span(slot: Int, gen: Int) {
        if (olen > segStart) {
            val k = 4 * ntab++
            tab[k] = slot; tab[k + 1] = gen; tab[k + 2] = segStart; tab[k + 3] = olen - segStart
        }
        segStart = olen
    }

    /** Ends this connection's span in the send table, then a close entry if asked. */
    private fun flush(slot: Int, gen: Int) {
        if (ntab >= MAX_SEND - 2) room(slot, gen, obuf.size)
        span(slot, gen)
        if (closeAfter[slot] && !busy[slot]) {
            val k = 4 * ntab++
            tab[k] = slot; tab[k + 1] = gen; tab[k + 2] = 0; tab[k + 3] = -1
        }
    }

    // ---------------------------------------------------------------- byte helpers

    private fun eq(b: ByteArray, s: Int, e: Int, lit: ByteArray): Boolean {
        if (e - s != lit.size) return false
        for (k in lit.indices) if (b[s + k] != lit[k]) return false
        return true
    }

    private fun startsWith(b: ByteArray, s: Int, e: Int, lit: ByteArray): Boolean {
        if (e - s < lit.size) return false
        for (k in lit.indices) if (b[s + k] != lit[k]) return false
        return true
    }

    /** Case-insensitive match of an ASCII lowercase literal at b[s..]. */
    private fun ieq(b: ByteArray, s: Int, lit: String): Boolean {
        for (k in lit.indices) if ((b[s + k].toInt() or 0x20) != lit[k].code) return false
        return true
    }

    private fun icontains(b: ByteArray, s: Int, e: Int, lit: String): Boolean {
        var i = s
        while (i + lit.length <= e) { if (ieq(b, i, lit)) return true; i++ }
        return false
    }

    /** Positive decimal integer, or -1. */
    private fun parseId(b: ByteArray, s: Int, e: Int): Long {
        if (s >= e || e - s > 18) return -1
        var v = 0L
        for (k in s until e) {
            val d = b[k] - '0'.code.toByte()
            if (d !in 0..9) return -1
            v = v * 10 + d
        }
        return if (v > 0) v else -1
    }
}

fun envLong(name: String, def: Long): Long = System.getenv(name)?.toLongOrNull() ?: def

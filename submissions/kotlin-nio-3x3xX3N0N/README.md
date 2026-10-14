# Kotlin, no framework (java.nio + sqlite-jdbc)

| | |
|---|---|
| Language | Kotlin 2.4.21 on the JVM (Temurin JDK 25.0.4.1, HotSpot C2) |
| Framework | none: one `java.nio` epoll selector and a hand-written HTTP/1.1 parser |
| SQLite driver | `org.xerial:sqlite-jdbc` 3.53.4.0 (bundled SQLite 3.53.4) |
| Nginx or direct | **Direct.** Serves `HOST:PORT` itself (use `0.0.0.0:80` on the box). It works behind the Nginx config too |
| Code | ~880 lines across `Server.kt`, `Db.kt`, `Jwt.kt`, `Json.kt`, `Main.kt` |

## Design

All the work happens on one thread, which suits a 1-vCPU box: there's no handoff between threads and no locks.

1. **Single event loop.** One `Selector` (epoll) accepts connections, reads requests, runs the reads against SQLite inline and writes the responses. There's one shared 64 KB read buffer and one shared 1 MB direct output buffer. A connection only gets its own buffer when a request arrives split across reads or the socket won't take the whole response.
2. **SQLite builds the JSON.** `json_object(...)` creates each post object and the feed array is assembled with `group_concat(... ORDER BY ...)`. The driver returns the result as raw UTF-8 bytes (`getBytes`), so a response never becomes a Kotlin object, a `String` or serializer output. The output matches `test/golden` byte for byte.
3. **One connection, statements prepared once** (reusing prepared statements is allowed by rule 5).
4. **Group commit.** `POST /posts` and `POST /posts/:id/like` are queued. After each pass over the ready sockets, the loop runs `BEGIN IMMEDIATE`, all the queued writes and one `COMMIT`. Only then does it send their 201/200s. If the commit fails, every request in that batch gets a 500. A connection with a write in flight doesn't parse its next pipelined request until that write is answered, so responses stay in order.
5. **Checkpoints off the response path.** `wal_autocheckpoint=0` on the serving connection. A low-priority daemon thread on its own connection runs `PRAGMA wal_checkpoint(PASSIVE)` once a second.
6. **JWT verified on every request, without copies.** HMAC-SHA256 runs over the header bytes in place (reused `Mac`, constant-time compare), then the header and payload get a tiny JSON parse (`alg` must be `HS256`, plus the `exp` and `sub`/`username` checks).
7. **Small JVM.** `-XX:+UseSerialGC -Xmx448m`, compact object headers. About 210 MB RSS with 64k open connections.
8. **fd exhaustion doesn't spin.** If `accept()` hits EMFILE (`LimitNOFILE=65535`), the loop stops polling the listen socket and resumes as soon as any connection closes.

## Durability trade-off

The database runs in WAL mode with `synchronous=NORMAL`, the minimum rule 6 allows. Each 201 is sent after `COMMIT` returns. With NORMAL, though, a commit isn't fsynced, so a power loss (not a process crash) can lose the most recent transactions. Switching to `FULL` means editing one line in `Db.config()`.

## Local numbers (not the droplet)

Measured on an i7-10700K. The server was pinned to one core in a `MemoryMax=2G` cgroup with no swap and `ulimit -n 65535`. k6 (`bench/load.js`) ran on the other cores across several loopback IPs:

| VUs | hold | p95 | p99 | errors | server CPU | RSS |
|---|---|---|---|---|---|---|
| 10,000 | 30 s | 1.5 ms | 3.6 ms | 0 % | 11 % | 164 MB |
| 30,000 | 45 s | 1.1 ms | 3.5 ms | 0 % | 22 % | 181 MB |
| 64,000 | 60 s | 3.6 ms | 16 ms | 0 % | 45 % | 208 MB |
| **64,000** | **5 min** (full method) | **3.1 ms** | **18 ms** | **0 %** (2.39M reqs) | **45 %** | **212 MB** |
| 64,000 at a 40 % CPU quota | 60 s | 422 ms | 540 ms | 0 % | 40 % | 206 MB |
| 110,000 (fd limit raised, outside the rules) | 60 s | 143 ms | 327 ms | 0 % | 68 % | 240 MB |

A desktop core is much faster than a shared DigitalOcean vCPU, so treat these as relative numbers. The 40 % quota row is a rough stand-in for the droplet.

Profile at 64k (JFR): about 59 % of the busy time is inside SQLite `step` (mostly the feed's 20 like counts), about 17 % is socket read/write syscalls, and the Kotlin code is a few percent.

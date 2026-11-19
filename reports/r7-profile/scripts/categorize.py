#!/usr/bin/env python3
"""Splits async-profiler collapsed CPU stacks (thread-rooted, from jfrconv -t) into per-request categories.

  categorize.py <cpu-all.collapsed> <us_per_req_total> [--detail]

us_per_req_total = measured CPU per request in the same window (from run.sh); every category gets
samples/total * us_per_req_total. Rules are evaluated per stack; the first matching rule wins.
"""
import re, sys
from collections import Counter, defaultdict

path, usreq = sys.argv[1], float(sys.argv[2])
detail = '--detail' in sys.argv

SYSCALL_LEAF = re.compile(r'^(__syscall_cancel_arch_end|__syscall_cancel|__internal_syscall_cancel|__GI___fcntl64|__fcntl64_nocancel_adjusted|__libc_pread64|__libc_pwrite64|__pread64|__pwrite64|fdatasync|__fsync|__GI___libc_write|__GI___libc_read|syscall|__lseek64|__libc_fcntl64)')
SQLITE_LIB = re.compile(r'libsqlitejdbc\.so|^sqlite3|^Java_org_sqlite')


def sqlite_layer(frames, i0):
    """frames[i0] is the outermost org.sqlite frame; classify the work below it."""
    leaf = frames[-1]
    below = frames[i0:]
    natives = [f for f in below if not f.endswith(('_[j]', '_[i]', '_[c]'))]
    if 'fcntl' in leaf:
        return 'syscall fcntl (file locks)'
    if SYSCALL_LEAF.match(leaf):
        # name the libc wrapper right above the generic cancel frames
        for f in reversed(below):
            if f.startswith(('__libc_', '__GI___libc', '__pread', '__pwrite', '__lseek', '__fsync', 'fdatasync', '__GI___fcntl')):
                return 'syscall ' + f
        return 'syscall (pread/pwrite/other)'
    if any(SQLITE_LIB.search(f) and not f.startswith('Java_org_sqlite') for f in below):
        # inside the engine (incl. libc memcpy/malloc it calls) unless the leaf is a JNI/JVM upcall
        if re.match(r'^(jni_|JNI|JavaCalls|TypeArrayKlass|InstanceKlass|MemAllocator|ObjAllocator|OptoRuntime|SharedRuntime|ThreadInVMfromNative|JavaThread|HandleMark|Handle)', leaf):
            return 'JNI upcalls (NewByteArray etc.)'
        return 'engine (native, stripped)'
    if natives:
        return 'JNI glue (native side)'
    return 'JDBC Java layer'


def classify(line):
    stack, n = line.rsplit(' ', 1)
    n = int(n)
    frames = stack.split(';')
    thread = frames[0].strip('[]')
    frames = frames[1:]
    if thread != 'main':
        if thread.startswith('VM Thread'):
            return 'GC (Serial, VM Thread)', n
        if 'CompilerThre' in thread:
            return 'JIT compiler threads', n
        if thread.startswith('checkpointer'):
            return 'SQLite checkpointer thread (worker 0)', n
        return 'other JVM threads', n
    s = ';'.join(frames)
    leaf = frames[-1] if frames else ''
    # --- syscalls of the event loop
    if 'SocketDispatcher.write0' in s:
        return 'socket write (write syscall, kernel TCP send)', n
    if 'SocketDispatcher.read0' in s:
        return 'socket read (read syscall)', n
    if 'EPoll.wait' in s:
        return 'epoll_wait', n
    if 'EPoll.ctl' in s:
        return 'epoll_ctl', n
    if 'Unsafe.park' in s:
        return 'pacing park (parkNanos syscall)', n
    if 'ServerSocketChannelImpl' in s or 'nio.Server.accept' in s:
        return 'accept + socket setup', n
    if 'nio.Server.close' in s:
        return 'close', n
    # --- SQLite (context x layer)
    i0 = next((i for i, f in enumerate(frames) if f.startswith('org.sqlite.')), None)
    if i0 is not None:
        if 'nio.Server.runBatch' in s:
            if 'nio.Db.like' in s: ctx = 'W like'
            elif 'nio.Db.insertPost' in s: ctx = 'W insertPost'
            elif 'nio.Db.commit' in s: ctx = 'W COMMIT'
            elif 'nio.Db.tryBegin' in s: ctx = 'W BEGIN'
            else: ctx = 'W other'
            grp = 'SQLite writes'
        else:
            if 'nio.Db.feedRange' in s:
                ctx = 'R feed'
                for q, name in (('step', None), ):
                    pass
            elif 'nio.Db.post' in s: ctx = 'R post'
            elif 'nio.Db.ping' in s: ctx = 'R ping'
            else: ctx = 'R other'
            grp = 'SQLite reads'
        return f'{grp} | {ctx} | {sqlite_layer(frames, i0)}', n
    # --- our own code
    if 'nio.Jwt.verify' in s:
        return 'auth: JWT verify (HMAC-SHA256)', n
    if 'nio.Json.' in s or 'nio.Server.createPost' in s:
        return 'POST body JSON parse + validation', n
    if 'nio.Db.feedRange' in s or 'nio.Db.put' in s:
        return 'JSON building: feed assembly in Kotlin', n
    if re.search(r'nio\.Server\.(respond|putResponse|likeBody)', s):
        return 'response building (status line, headers, copy to obuf)', n
    if 'nio.Server.runBatch' in leaf or 'nio.Server.enqueue' in s or 'WriteOp' in s:
        return 'write batching (runBatch/enqueue own code)', n
    if re.search(r'nio\.Server\.(route|eq|startsWith|parseId)', leaf):
        return 'routing', n
    if re.search(r'nio\.Server\.(request|ieq|icontains)', leaf):
        return 'HTTP parse (request head scan)', n
    if re.search(r'nio\.Server\.(process|takePending|onReadable)', leaf):
        return 'HTTP input buffering (process/takePending)', n
    if 'nio.Server.flush' in s or 'SocketChannelImpl.write' in s or 'IOUtil.write' in s:
        return 'NIO write path (Java side)', n
    if 'SocketChannelImpl.read' in s or 'IOUtil.read' in s:
        return 'NIO read path (Java side)', n
    if 'SelectorImpl' in s or 'EPollSelectorImpl' in s or 'nio.Server.handleKey' in s:
        return 'NIO selector dispatch (processReadyEvents, keys)', n
    if 'nio.Server.run' in leaf:
        return 'event loop own code', n
    if 'nio.Server.route' in s or 'nio.Server.request' in s:
        return 'route/request: other (alloc, runtime)', n
    return 'other main-thread (JVM runtime, safepoints, ...)', n


cats = Counter()
leaves = defaultdict(Counter)
total = 0
for line in open(path):
    line = line.rstrip('\n')
    if not line:
        continue
    c, n = classify(line)
    cats[c] += n
    total += n
    leaves[c][line.rsplit(' ', 1)[0].split(';')[-1]] += n

print(f'samples {total}, scale {usreq} us/req total')
print(f'{"us/req":>7} {"share":>6}  category')
for c, n in sorted(cats.items(), key=lambda x: -x[1]):
    print(f'{n / total * usreq:7.2f} {100 * n / total:5.1f}%  {c}')
    if detail:
        for l, m in leaves[c].most_common(4):
            print(f'{"":15}{100 * m / total:5.1f}%  {l}')

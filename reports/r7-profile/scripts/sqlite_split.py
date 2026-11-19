#!/usr/bin/env python3
"""SQLite engine time by function family and by caller (needs the unstripped libsqlitejdbc.so profile).

  sqlite_split.py <cpu-all.collapsed> <us_per_req_total>

Only main-thread stacks that pass through org.sqlite.*. Inclusive families are assigned from the leaf upward:
the innermost frame that matches a family wins, so json_object's own string appends count as JSON, while a
B-tree seek done for the users JOIN counts as B-tree.
"""
import re, sys
from collections import Counter, defaultdict

path, usreq = sys.argv[1], float(sys.argv[2])
TRANSPARENT = re.compile(r'^(__syscall_cancel|__internal_syscall|malloc|free|_int_malloc|_int_free|cfree|realloc|_int_realloc|__memcpy|__memmove|__memset|__memcmp|__strlen|__strchr|pthread_mutex|__GI___pthread_mutex|__pthread_mutex|__lll_lock|malloc_consolidate|unlink_chunk|tcache)')
SYSCALL = [('syscall: fcntl lock/unlock', re.compile(r'fcntl')), ('syscall: pread', re.compile(r'pread')),
           ('syscall: pwrite (WAL append)', re.compile(r'pwrite'))]
FAM = [
    ('JVM upcalls from JNI (NewByteArray, NewObject, ...)', re.compile(r'^(jni_|JNI_|JNIHandle|JavaCalls|TypeArrayKlass|InstanceKlass|MemAllocator|ObjAllocator|ThreadInVMfromNative|ThreadStateTransition|HandleMark|AccessInternal|jbyte_|jlong_|jint_|jshort_|unsafe_arraycopy|SharedRuntime|OptoRuntime|itable stub|vtable stub|java_lang_Throwable|JVM_)')),
    ('JSON functions (json_object, json escaping)', re.compile(r'^json|^sqlite3Json')),
    ('string/concat/group_concat/strftime', re.compile(r'^(groupConcat|concatFunc|sqlite3VdbeMemStringify|sqlite3StrAccum|sqlite3_str|strftimeFunc|datetimeFunc|sqlite3Utf|enlargeAndAppend|sqlite3VdbeMemSetStr|sqlite3VdbeMemTranslate|sqlite3FpDecode|sqlite3Int64ToText|sqlite3VdbeMemFinalize|computeYMD|computeHMS|isDate|parseDateOrTime|sqlite3StmtCurrentTime|setDateTimeToCurrent)')),
    ('WAL index / shm locks (read txn begin/end)', re.compile(r'^(wal|sqlite3Wal|unixShm|unixLock|unixUnlock|posixUnlock|unixFileLock|sqlite3OsShm|osFcntl|robust_|unixFileControl|sqlite3OsLock|sqlite3OsUnlock|pagerLockDb|pagerUnlockDb)')),
    ('pager + page cache (incl. cache reset)', re.compile(r'^(pager|sqlite3Pager|getPage|pcache|sqlite3Pcache|readDbPage|btreeGetPage|getAndInitPage|releasePage|btreePagecount|unixRead|unixWrite|seekAndRead|seekAndWrite|sqlite3OsRead|sqlite3OsWrite|sqlite3BitvecTest|sqlite3BitvecSet|syncJournal|sqlite3PcacheMakeDirty|pager_|btreeInitPage|decodeFlags|zeroPage|sqlite3BtreeBeginTrans|sqlite3BtreeCommit|sqlite3BtreeRollback|btreeEndTransaction|unlockBtreeIfUnused|lockBtree|newDatabase|pageReinit)')),
    ('B-tree (seek, cursor, cell parse, insert)', re.compile(r'^(sqlite3Btree|btree|moveTo|getCellInfo|cellSize|insertCell|balance|accessPayload|fetchPayload|allocateBtreePage|clearCell|dropCell|freeSpace|allocateSpace|defragmentPage|sqlite3GetVarint|sqlite3PutVarint|sqlite3VdbeRecordCompare|vdbeRecordCompare|sqlite3VdbeIdxKeyCompare|sqlite3VdbeFindCompare|sqlite3VdbeRecordUnpack|ptrmapPut|saveAllCursors|saveCursor|handleMovedCursor|sqlite3VdbeCursorMoveto|sqlite3VdbeFinishMoveto|sqlite3VdbeHandleMovedCursor|copyPayload|getOverflowPage|sqlite3VdbeSerialGet|sqlite3VdbeSerialType|serialGet)')),
    ('SQLite allocator (sqlite3Malloc/DbMalloc/free)', re.compile(r'^(sqlite3Malloc|sqlite3DbMalloc|sqlite3_malloc|sqlite3_free|sqlite3DbFree|sqlite3MemMalloc|sqlite3MemFree|sqlite3Realloc|sqlite3DbRealloc|measureAllocationSize|sqlite3MemSize|sqlite3DbNNFreeNN|sqlite3DbFreeNN|dbMallocRawFinish|sqlite3MallocSize|sqlite3MemRealloc|sqlite3DbStrDup)')),
    ('VDBE values (Mem ops, column/bind access)', re.compile(r'^(sqlite3VdbeMem|vdbeMemClear|sqlite3_value|sqlite3Value|sqlite3_column|columnMem|columnMallocFailure|sqlite3_bind|vdbeUnbind|bindText|sqlite3VdbeIntValue|sqlite3VdbeChangeEncoding|applyAffinity|sqlite3VdbeIntegerAffinity|sqlite3_result|setResultStrOrError|sqlite3VdbeMemCopy|sqlite3RealSameAsInt|numericType|sqlite3AtoF|sqlite3Atoi64)')),
    ('statement lifecycle (step entry, reset, halt, locks, mutex)', re.compile(r'^(sqlite3_step|sqlite3Step|sqlite3VdbeHalt|sqlite3VdbeReset|sqlite3_reset|sqlite3DbMask|sqlite3VdbeEnter|sqlite3VdbeLeave|sqlite3BtreeEnter|sqlite3BtreeLeave|sqlite3_initialize|sqlite3_mutex|pthreadMutex|sqlite3VdbeTransferError|sqlite3VdbeCheckFk|invokeProfileCallback|sqlite3VdbeRewind|sqlite3VdbeMakeReady|vdbeCommit|sqlite3VdbeCloseStatement|checkActiveVdbeCnt|sqlite3CommitInternalChanges|sqlite3VdbeFreeCursor|sqlite3VdbeAllocUnpackedRecord|sqlite3VdbeError|sqlite3ApiExit|sqlite3SafetyCheck|sqlite3_changes|sqlite3_sql|closeCursorsInFrame|closeAllCursors|releaseMemArray|sqlite3VdbeDeleteAuxData|sqlite3VdbeClearObject|sqlite3RollbackAll|sqlite3VdbeSetChanges|sqlite3VdbeExplain|sqlite3VdbeLoadString|allocateCursor|sqlite3VdbeSorter|sqlite3VdbeTransferError|schemaIsValid|sqlite3_expired|sqlite3VdbeExpandSql|sqlite3VdbeFrameRestore|sqlite3VdbeDelete|sqlite3_finalize)')),
    ('JDBC native glue (NativeDB.c)', re.compile(r'^Java_org_sqlite|^toref|^fromref|^utf8|^bytesToJavaString|^throwex|^freeUtf8|^gethandle|^getdb')),
    ('VDBE interpreter (sqlite3VdbeExec self)', re.compile(r'^sqlite3VdbeExec')),
]


def family(frames, i0):
    sys_seen = False; transparent_leaf = None
    for f in reversed(frames[i0:]):
        if f.endswith(('_[j]', '_[i]', '_[c]')):
            break
        if sys_seen:
            for name, rx in SYSCALL:
                if rx.search(f): return name
            if not TRANSPARENT.match(f): return 'syscall: other (' + f + ')'
            continue
        if f.startswith(('__syscall_cancel', '__internal_syscall')) or 'fcntl' in f:
            if 'fcntl' in f: return 'syscall: fcntl lock/unlock'
            sys_seen = True; continue
        if TRANSPARENT.match(f):
            transparent_leaf = transparent_leaf or f; continue
        for name, rx in FAM:
            if rx.search(f):
                return name
        return 'other native: ' + f
    if transparent_leaf: return 'libc (malloc/mem*) outside SQLite: ' + transparent_leaf
    return 'JDBC Java layer (org.sqlite Java code)'


def ctx(s):
    if 'nio.Server.runBatch' in s:
        for k, v in (('nio.Db.like', 'W like'), ('nio.Db.insertPost', 'W insertPost'), ('nio.Db.commit', 'W COMMIT'), ('nio.Db.tryBegin', 'W BEGIN')):
            if k in s: return v
        return 'W other'
    if 'nio.Db.feedRange' in s: return 'R feed'
    if 'nio.Db.post' in s: return 'R post'
    return 'R other'


tot = 0
fam = Counter(); byctx = defaultdict(Counter); otherleaf = Counter(); json_incl = Counter()
for line in open(path):
    stack, n = line.rstrip('\n').rsplit(' ', 1); n = int(n)
    fr = stack.split(';'); tot += n
    if fr[0] != '[main]': continue
    i0 = next((i for i, f in enumerate(fr) if f.startswith('org.sqlite.')), None)
    if i0 is None: continue
    s = ';'.join(fr); f = family(fr, i0); c = ctx(s)
    # a stack under a Java org.sqlite frame that is all Java: the JDBC layer
    jdbc_java = all(x.endswith(('_[j]', '_[i]', '_[c]')) for x in fr[i0:])
    if jdbc_java: f = 'JDBC Java layer (org.sqlite Java code)'
    fam[f] += n; byctx[c][f] += n
    if f.startswith('other native'): otherleaf[fr[-1]] += n
    if 'jsonObjectFunc' in s: json_incl[c] += n

ctxs = ['R feed', 'R post', 'W like', 'W insertPost', 'W BEGIN', 'W COMMIT', 'R other', 'W other']
print(f'us per (average) request; total {usreq} us/req, {tot} samples')
print(f'{"family":<70}{"all":>7}' + ''.join(f'{c:>10}' for c in ctxs))
for f, n in sorted(fam.items(), key=lambda x: -x[1]):
    if f.startswith('other native') and n / tot * usreq < 0.05: continue
    print(f'{f[:70]:<70}{n / tot * usreq:7.2f}' + ''.join(f'{byctx[c][f] / tot * usreq:10.2f}' for c in ctxs))
print(f'{"TOTAL through org.sqlite":<70}{sum(fam.values()) / tot * usreq:7.2f}' + ''.join(f'{sum(byctx[c].values()) / tot * usreq:10.2f}' for c in ctxs))
print('\njson_object inclusive (us/req):', {k: round(v / tot * usreq, 2) for k, v in json_incl.items()})
print('top "other native" leaves:', otherleaf.most_common(12))

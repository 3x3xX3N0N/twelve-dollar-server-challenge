#!/usr/bin/env python3
"""ksym.py <System.map> <perf.data> [top=40]: flat profile with kernel symbols although /proc/kallsyms is hidden
(kptr_restrict=1, no root). The KASLR slide is found from the callchains: the outermost kernel frame of a syscall is
in entry_SYSCALL_64 (2 MB-aligned slide). Prints self-time by symbol (kernel resolved via System.map, user via perf),
and kernel time grouped into buckets. Needs `perf record -g`."""
import bisect, collections, re, subprocess, sys
smap, data = sys.argv[1], sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
addrs, names = [], []
for line in open(smap):
    a, t, n = line.split()[:3]
    if t in 'tTwW':
        addrs.append(int(a, 16)); names.append(n)
order = sorted(range(len(addrs)), key=lambda i: addrs[i]); addrs = [addrs[i] for i in order]; names = [names[i] for i in order]
entry = addrs[names.index('entry_SYSCALL_64')]
out = subprocess.run(['perf', 'script', '-i', data, '-F', 'comm,tid,ip,sym,dso', '--no-inline'], capture_output=True, text=True).stdout
samples = []   # list of frames [(ip, sym, dso)] innermost first
cur = None
for line in out.splitlines():
    if not line.strip():
        if cur: samples.append(cur)
        cur = None; continue
    if not line.startswith((' ', '\t')):
        if cur: samples.append(cur)
        cur = []; continue
    m = re.match(r'\s+([0-9a-f]+)\s+(.*?)\s+\((.*)\)\s*$', line)
    if m and cur is not None: cur.append((int(m.group(1), 16), m.group(2), m.group(3)))
if cur: samples.append(cur)
# slide: outermost kernel frame of most samples
outer = collections.Counter()
for s in samples:
    k = [ip for ip, _, _ in s if ip >= 0xffff800000000000]
    if k: outer[k[-1] & ~0x1fffff] += 1
base = outer.most_common(1)[0][0]
slide = base - (entry & ~0x1fffff)
def ksym(ip):
    a = ip - slide
    i = bisect.bisect_right(addrs, a) - 1
    return names[i] if i >= 0 else hex(ip)
BUCKETS = [  # (bucket, substrings of any frame in the chain, checked in order)
    ('softirq/net rx (loopback)', ('net_rx_action', '__netif_receive_skb', 'ip_rcv', 'tcp_v4_rcv', 'do_softirq', '__local_bh_enable_ip')),
    ('tcp send', ('tcp_sendmsg', 'io_send', 'sock_sendmsg')),
    ('tcp recv', ('tcp_recvmsg', 'io_recv', 'sock_recvmsg')),
    ('accept/close/shutdown', ('io_accept', 'do_accept', 'io_close', 'io_shutdown', 'tcp_close', '__sys_shutdown', 'inet_accept')),
    ('io_uring task work / cqe', ('io_run_local_work', 'tctx_task_work', 'io_handle_tw_list', 'io_req_task', 'io_cqring_wait', '__io_run_local_work', 'io_submit_flush')),
    ('io_uring submit', ('io_submit_sqes', 'io_issue_sqe')),
    ('file read/write (SQLite)', ('ksys_pread64', 'ksys_pwrite64', 'vfs_read', 'vfs_write', '__x64_sys_pread64', '__x64_sys_pwrite64', 'ext4_')),
    ('futex/sched', ('futex', 'schedule', '__schedule')),
    ('page faults / mm', ('asm_exc_page_fault', 'handle_mm_fault', 'do_user_addr_fault')),
]
selfc = collections.Counter(); kb = collections.Counter(); other = collections.Counter(); n = len(samples); kern = 0
for s in samples:
    if not s: continue
    ip, sym, dso = s[0]
    if ip >= 0xffff800000000000:
        kern += 1
        selfc['[k] ' + ksym(ip)] += 1
        chain = [ksym(f[0]) if f[0] >= 0xffff800000000000 else f[1] for f in s]
        b = 'other kernel'
        for name, keys in BUCKETS:
            if any(k in c for c in chain for k in keys): b = name; break
        kb[b] += 1
        if b == 'other kernel': other[' < '.join(chain[:4])] += 1
    else:
        selfc[sym if sym and sym != '[unknown]' else dso] += 1
print(f'samples {n}, kernel {kern} ({kern / n * 100:.1f} %), slide {slide:#x}')
print('-- kernel buckets (share of all samples; first match in the order listed)')
for b, c in kb.most_common(): print(f'{c / n * 100:6.2f} %  {b}')
print(f'-- top {top} self')
for k, c in selfc.most_common(top): print(f'{c / n * 100:6.2f} %  {k}')
print('-- other kernel: top chains (innermost first)')
for k, c in other.most_common(8): print(f'{c / n * 100:6.2f} %  {k}')

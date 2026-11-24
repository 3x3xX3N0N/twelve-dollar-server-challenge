"""tl.py <run dir>: server timeline from the 5 s monitor samples of a run (CPU %, softirq %, process CPU %, TCP)."""
import sys, time
L = [dict(kv.split('=', 1) for kv in l.split()) for l in open(sys.argv[1] + '/mon.txt') if l.startswith('t=')]
B = ('cpu_user', 'cpu_nice', 'cpu_sys', 'cpu_irq', 'cpu_softirq')
for p, d in zip(L, L[1:]):
    dt = float(d['t']) - float(p['t'])
    f = lambda k: (float(d[k]) - float(p[k])) / dt
    print(time.strftime('%H:%M:%S', time.gmtime(float(d['t']))), 'alloc', d['tcp_alloc'], 'cpu', round(sum(f(k) for k in B)),
          'si', round(f('cpu_softirq')), 'proc', round((float(d['cg_usage_usec']) - float(p['cg_usage_usec'])) / dt / 1e4),
          'avail', int(d['mi_MemAvailable']) // 1024, 'sock', int(d.get('cgm_sock', 0)) >> 20, 'tcpmem', d['tcp_mem_pages'])

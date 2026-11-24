"""tl2.py <run dir>: 5 s server timeline with packet rates and TCP loss counters (from snap.sh samples in mon.txt)."""
import sys, time
L = [dict(kv.split('=', 1) for kv in l.split()) for l in open(sys.argv[1] + '/mon.txt') if l.startswith('t=')]
nic = [k for k in L[0] if k.endswith('_rxp')]
K = ['TcpRetransSegs', 'TcpExtTCPTimeouts', 'TcpExtPruneCalled', 'TcpExtTCPAbortOnTimeout']
for p, d in zip(L, L[1:]):
    dt = float(d['t']) - float(p['t']); f = lambda k: (float(d.get(k, 0)) - float(p.get(k, 0))) / dt
    busy = sum(f(k) for k in ('cpu_user', 'cpu_nice', 'cpu_sys', 'cpu_irq', 'cpu_softirq'))
    print(time.strftime('%H:%M:%S', time.gmtime(float(d['t']))), 'alloc', d['tcp_alloc'], 'cpu', round(busy), 'si', round(f('cpu_softirq')),
          'proc', round((float(d.get('cg_usage_usec', 0)) - float(p.get('cg_usage_usec', 0))) / dt / 1e4), 'tcpmem', d['tcp_mem_pages'],
          'rx', round(sum(f(n) for n in nic) / 1e3, 1), 'k tx', round(sum(f(n.replace('rxp', 'txp')) for n in nic) / 1e3, 1), 'k',
          ' '.join(f"{k.replace('TcpExt', '').replace('Tcp', '')}={f(k):.0f}" for k in K))

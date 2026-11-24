"""merge.py <kload.json>...: merges several generators' kload JSON (sparse histograms, Hist.kt layout) into one
k6-style verdict: p95/p99 over all requests, failure rate, hold window, sums of counters. Prints one JSON line."""
import json, math, sys

def mid(i):
    if i < 64: return float(i)
    e = (i >> 6) + 5; lo = (64 + (i & 63)) << (e - 6)
    return lo + (1 << (e - 6)) / 2.0

def pct(c, n, mx, p):
    if n <= 0: return 0.0
    t = max(1, math.ceil(p * n)); acc = 0
    for i in sorted(c):
        acc += c[i]
        if acc >= t: return min(mid(i), float(mx))
    return float(mx)

def merge(hs):
    c = {}; n = 0; mx = 0
    for h in hs:
        for i, k in h['c']: c[i] = c.get(i, 0) + k
        n += h['n']; mx = max(mx, h['max'])
    return c, n, mx

D = [json.load(open(f)) for f in sys.argv[1:]]
c, n, mx = merge([d['hist'] for d in D]); hc, hn, hmx = merge([d['hist_hold'] for d in D])
reqs = sum(d['reqs'] for d in D); failed = sum(d['failed'] for d in D)
out = dict(gens=len(D), vus=sum(d['vus'] for d in D), reqs=reqs, failed=failed, fail_rate=failed / max(reqs, 1),
           med_ms=pct(c, n, mx, .5) / 1e3, p95_ms=pct(c, n, mx, .95) / 1e3, p99_ms=pct(c, n, mx, .99) / 1e3, max_ms=mx / 1e3,
           hold=dict(reqs=sum(d['hold']['reqs'] for d in D), failed=sum(d['hold']['failed'] for d in D),
                     p95_ms=pct(hc, hn, hmx, .95) / 1e3, p99_ms=pct(hc, hn, hmx, .99) / 1e3))
for k in ('conn_attempts', 'conn_failed', 'timeouts', 'bytes_in', 'bytes_out', 'gen_loop_stalls', 'gen_cpu_s'):
    out[k] = sum(d.get(k, 0) for d in D)
out['connect_p99_ms_max'] = max(d['connect_p99_ms'] for d in D)
out['max_open'] = sum(d['max_open'] for d in D)
out['gen_rss_peak_mb_max'] = max(d['gen_rss_peak_mb'] for d in D)
out['pass'] = out['p95_ms'] < 500 and out['p99_ms'] < 1000 and out['fail_rate'] < 0.01
print(json.dumps(out))

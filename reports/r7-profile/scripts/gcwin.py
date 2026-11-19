#!/usr/bin/env python3
"""gcwin.py <run dir>: allocation + GC pauses inside the measurement window, from -Xlog:gc lines t0..t1."""
import re, sys
R = sys.argv[1]
t0 = dict(l.split() for l in open(f'{R}/gc-lines-t0.txt')); t1 = dict(l.split() for l in open(f'{R}/gc-lines-t1.txt'))
r0, r1, s0, s1 = open(f'{R}/window.txt').read().split(); n = int(r1) - int(r0); el = float(s1) - float(s0)
rx = re.compile(r'\[([\d.]+)s\] GC\(\d+\) Pause (\w+).*?(\d+)M->(\d+)M\(\d+M\) ([\d.]+)ms')
alloc = 0; pause = 0.0; cnt = 0; kinds = {}
for p in t0:
    lines = open(f'{R}/gc-{p}.log').read().splitlines()
    prev_after = None
    for i, l in enumerate(lines[:int(t1[p])]):
        m = rx.search(l)
        if not m: continue
        before, after, ms = int(m.group(3)), int(m.group(4)), float(m.group(5))
        if i >= int(t0[p]):
            if prev_after is not None: alloc += before - prev_after
            pause += ms; cnt += 1; kinds[m.group(2)] = kinds.get(m.group(2), 0) + 1
        prev_after = after
print(f'window {el:.1f}s, {n} reqs: {cnt} GCs {kinds}, pauses {pause:.0f} ms = {pause * 1000 / n:.2f} us/req '
      f'({pause / el / 10:.2f}% of wall), allocated ~{alloc} MB = {alloc * 1048576 / n:.0f} B/req (GC-log estimate, 1 MB granularity)')

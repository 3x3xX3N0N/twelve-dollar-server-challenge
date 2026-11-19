#!/usr/bin/env python3
"""inlining.py <vm-*.log ...>: C2 (tier 4) inlining failures that look megamorphic or size-limited on our hot path.
Prints (compiled method -> callee : reason) counts summed over the given -XX:+PrintInlining logs."""
import html, re, sys
from collections import Counter
hdr = re.compile(r'^\s*\d+\s+\d+\s+[%sbn!]*\s*(\d)\s+(\S+::\S+)')
call = re.compile(r'@ (\d+)\s+(\S+::\S+) \(.*?\)\s+(failed to inline: [^<\\]*?|inline \(hot\))(?:\s{2,}|$)')
INTEREST = re.compile(r'^(nio\.|org\.sqlite\.|sun\.nio\.ch\.)')
REASONS = ('virtual call', 'no static binding', 'receiver not constant', 'callee is too large', 'hot method too big',
           'already compiled into a big method', 'too big', 'callee uses too much stack')
out = Counter()
for f in sys.argv[1:]:
    cur = None; tier = None
    for line in open(f, errors='replace'):
        line = html.unescape(line.rstrip('\n'))
        m = hdr.match(line)
        if m:
            tier, cur = m.group(1), m.group(2); continue
        if tier != '4' or not cur or not INTEREST.match(cur): continue
        c = call.search(line)
        if not c or not c.group(3).startswith('failed'): continue
        reason = c.group(3)[len('failed to inline: '):].strip()
        if any(reason.startswith(r) for r in REASONS):
            out[(cur, c.group(2), reason)] += 1
for (m, callee, r), n in sorted(out.items(), key=lambda x: (x[0][2], -x[1])):
    print(f'{n:3d}  {m}  ->  {callee}  : {r}')

"""rank.py <LEADERBOARD.md> <users>...: projected rank = 1 + number of leaderboard rows with more users held."""
import re, sys
rows = []
for l in open(sys.argv[1]):
    m = re.match(r"\| *(\d+|—) *\| *([^|]+?) *\| *(#\d+)? *\|[^|]*\| *\*\*([\d,]+)\*\*", l)
    if m: rows.append((int(m.group(4).replace(",", "")), m.group(2).strip()))
print(f"{len(rows)} scored rows")
for u in map(int, sys.argv[2:]):
    above = [r for r in rows if r[0] > u]; tie = [r for r in rows if r[0] == u]
    print(f"{u:,}: rank {1 + len(above)} ({len(tie)} rows tie at {u:,})")

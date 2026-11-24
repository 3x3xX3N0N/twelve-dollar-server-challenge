"""table.py <results.tsv>: markdown rows (counted runs only, warm-ups skipped)."""
import sys
for line in open(sys.argv[1]):
    d = dict(kv.split("=", 1) for kv in line.rstrip("\n").split("\t"))
    if "warmup" in d["label"]:
        continue
    tcp = d.get("tcp_alloc", d.get("tcp_inuse"))
    print(f"| {d['label']} | {int(d['vus']):,} | {d['pass']} | {d['err%']} | {d['p95']} / {d['p99']} | {int(d['hold_rps']):,} | "
          f"{d['box_cpu%']} % | {d['softirq%']} % | {d['proc_us/req']} ({d['proc_user_us/req']}) | {d['box_us/req']} | "
          f"{d['rss_peak_mb']} | {d['cg_peak_mb']} | {d['memavail_min_mb']} | {d['slab_mb']} | {d['gen_stalls']} | {d.get('slow_commit_logs','-')} | `{d['dir']}` |")

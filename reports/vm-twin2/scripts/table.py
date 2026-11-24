"""table.py <results.tsv> [label-prefix...]: markdown rows (warm-ups skipped)."""
import sys
pre = sys.argv[2:]
for line in open(sys.argv[1]):
    d = dict(kv.split("=", 1) for kv in line.rstrip("\n").split("\t"))
    if "warmup" in d["label"] or (pre and not any(d["label"].startswith(p) for p in pre)):
        continue
    nd = {k: v for k, v in (x.split(":") for x in d.get("net_drops", "-").split(",") if ":" in x)}
    print(f"| {d['label']} | {int(d['vus']):,} | {d['pass']} | {d['err%']} | {d['p95']} / {d['p99']} | {int(d['hold_rps']):,} | "
          f"{d['box_cpu%']} % | {d['softirq%']} % | {d['proc_us/req']} ({d['proc_user_us/req']}) | {d['box_us/req']} | "
          f"{d['rss_peak_mb']} | {d['cg_peak_mb']} | {d['memavail_min_mb']} | {nd.get('TCPTimeouts', 0)} | {nd.get('TcpRetransSegs', 0)} | {d['gen_stalls']} | `{d['dir']}` |")

"""row.py <outdir> <label> <vus> <hold_s>: one results.tsv row from kload.json + server snapshots at hold start/end
(+ peaks from the 5 s monitor samples of the run, + slow-disk guard lines from the journal)."""
import json, sys

out, label, vus, hold = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])


def parse(line):
    d = {}
    for kv in line.split():
        k, _, v = kv.partition("=")
        try:
            d[k] = float(v)
        except ValueError:
            d[k] = v
    return d


def snap(name):
    return parse(open(f"{out}/{name}").read().split("\n")[0])


j = json.load(open(f"{out}/kload.json"))
a, b = snap("snap0.txt"), snap("snap1.txt")
dt = b["t"] - a["t"]
rps = j["hold"]["reqs"] / hold
hz = 100.0
busy = sum(b[k] - a[k] for k in ("cpu_user", "cpu_nice", "cpu_sys", "cpu_irq", "cpu_softirq")) / hz
steal = (b["cpu_steal"] - a["cpu_steal"]) / hz
cg = (b.get("cg_usage_usec", 0) - a.get("cg_usage_usec", 0)) / 1e6
cgu = (b.get("cg_user_usec", 0) - a.get("cg_user_usec", 0)) / 1e6
soft = (b["cpu_softirq"] - a["cpu_softirq"]) / hz
mon = []
try:
    mon = [parse(l) for l in open(f"{out}/mon.txt") if l.startswith("t=")]
except OSError:
    pass
rss_peak = max([m.get("rss_kb", 0) for m in mon] + [b.get("rss_kb", 0)]) / 1024
cg_peak = max([m.get("cg_mem", 0) for m in mon] + [b.get("cg_mem", 0)]) / 1048576
avail_min = min([m.get("mi_MemAvailable", 1e12) for m in mon] + [b["mi_MemAvailable"]]) / 1024
jr = open(f"{out}/journal.txt", errors="replace").read() if True else ""
slow = jr.count("slow commit on the loop")
stats = [l for l in jr.splitlines() if "stats:" in l]
last = stats[-1].split("commits", 1)[-1].strip().replace(" ", ",") if stats else "-"
row = {
    "label": label, "vus": vus, "pass": "PASS" if j["pass"] else "FAIL",
    "reqs": j["reqs"], "err%": f"{j['fail_rate'] * 100:.3f}", "p95": f"{j['p95_ms']:.1f}", "p99": f"{j['p99_ms']:.1f}",
    "hold_p95": f"{j['hold']['p95_ms']:.1f}", "hold_p99": f"{j['hold']['p99_ms']:.1f}", "hold_rps": f"{rps:.0f}",
    "box_cpu%": f"{busy / dt * 100:.0f}", "steal%": f"{steal / dt * 100:.1f}", "softirq%": f"{soft / dt * 100:.0f}",
    "box_us/req": f"{busy / dt / rps * 1e6:.1f}", "proc_us/req": f"{cg / dt / rps * 1e6:.1f}",
    "proc_user_us/req": f"{cgu / dt / rps * 1e6:.1f}",
    "rss_mb": f"{b.get('rss_kb', 0) / 1024:.0f}", "rss_peak_mb": f"{rss_peak:.0f}", "cg_peak_mb": f"{cg_peak:.0f}",
    "memavail_min_mb": f"{avail_min:.0f}", "slab_mb": f"{b['mi_Slab'] / 1024:.0f}", "tcp_alloc": int(b["tcp_alloc"]),
    "conntrack": b["conntrack"], "max_open": j["max_open"], "conn_failed": j["conn_failed"], "timeouts": j["timeouts"],
    "gen_stalls": j["gen_loop_stalls"], "gen_cpu_s": j["gen_cpu_s"], "slow_commit_logs": slow, "kn_commits": last,
    "dir": out.split("/")[-1],
}
print("\t".join(f"{k}={v}" for k, v in row.items()))

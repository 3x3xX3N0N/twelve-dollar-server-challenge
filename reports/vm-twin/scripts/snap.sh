#!/usr/bin/env bash
# snap.sh [unit]: one line of key=value counters from the server box (CPU, memory, sockets) for the unit's cgroup.
U="${1:-srv}"
CG="/sys/fs/cgroup/system.slice/$U.service"
read -r _ us ni sy id io irq sirq st _ < /proc/stat
o="t=$(date +%s.%N) cpu_user=$us cpu_nice=$ni cpu_sys=$sy cpu_idle=$id cpu_iowait=$io cpu_irq=$irq cpu_softirq=$sirq cpu_steal=$st"
if [ -d "$CG" ]; then
  o="$o $(awk '{printf "cg_%s=%s ", $1, $2}' "$CG/cpu.stat" | sed 's/ $//')"
  o="$o cg_mem=$(cat "$CG/memory.current") cg_peak=$(cat "$CG/memory.peak" 2>/dev/null || echo 0)"
  o="$o $(awk '$1~/^(anon|file|kernel|sock|slab)$/{printf "cgm_%s=%s ", $1, $2}' "$CG/memory.stat" | sed 's/ $//')"
  rss=0; for p in $(cat "$CG/cgroup.procs"); do r=$(awk '/^VmRSS/{print $2}' /proc/$p/status 2>/dev/null); rss=$((rss + ${r:-0})); done
  o="$o rss_kb=$rss nprocs=$(wc -l < "$CG/cgroup.procs")"
fi
o="$o $(awk '$1~/^(MemTotal|MemFree|MemAvailable|Cached|Slab|AnonPages):$/{sub(":","",$1); printf "mi_%s=%s ", $1, $2}' /proc/meminfo | sed 's/ $//')"
o="$o $(awk '$1=="TCP:"{printf "tcp_inuse=%s tcp_orphan=%s tcp_tw=%s tcp_alloc=%s tcp_mem_pages=%s", $3, $5, $7, $9, $11}' /proc/net/sockstat)"
o="$o io_some=$(awk '/^some/{print $2}' /proc/pressure/io | cut -d= -f2) conntrack=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo none) load=$(cut -d' ' -f1 /proc/loadavg)"
echo "$o"

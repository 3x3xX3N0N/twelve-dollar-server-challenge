#!/usr/bin/env bash
# gsnap.sh: one line of generator counters (CPU jiffies, sockstat, conntrack, memory, softnet drops, NIC drops).
read -r _ us ni sy id io irq sirq st _ < /proc/stat
o="t=$(date +%s.%N) cpu_user=$us cpu_nice=$ni cpu_sys=$sy cpu_idle=$id cpu_irq=$irq cpu_softirq=$sirq cpu_steal=$st"
o="$o $(awk '$1=="TCP:"{printf "tcp_inuse=%s tcp_orphan=%s tcp_tw=%s tcp_alloc=%s tcp_mem_pages=%s", $3, $5, $7, $9, $11}' /proc/net/sockstat)"
o="$o mi_avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo) conntrack=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo none)"
sd=0; sq=0; while read -r _ d q _; do sd=$((sd + 16#$d)); sq=$((sq + 16#$q)); done < /proc/net/softnet_stat
o="$o softnet_drop=$sd squeeze=$sq"
for i in $(ls /sys/class/net | grep -v lo); do o="$o ${i}_rxdrop=$(cat /sys/class/net/$i/statistics/rx_dropped) ${i}_txdrop=$(cat /sys/class/net/$i/statistics/tx_dropped) ${i}_rxp=$(cat /sys/class/net/$i/statistics/rx_packets) ${i}_txp=$(cat /sys/class/net/$i/statistics/tx_packets)"; done
echo "$o"

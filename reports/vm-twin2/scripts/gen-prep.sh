#!/usr/bin/env bash
# gen-prep.sh <own-private-ip> <k> (root, generator VM k, before a reboot): Java 21 for kload, no firewall/conntrack,
# no swap, apt timers off, 8 extra VPC source addresses 10.79.0.(100+10k+j) in netplan (one source IP holds ~64.5k
# connections to one ip:port; netplan so a networkd restart cannot drop them). Load-generator sysctls like
# arjaythedev's published load-generator config (somaxconn, port range 1024-65535, tw_reuse).
set -uo pipefail
ME="$1"; K="$2"; P=${ME%.*}
uname -r; grep -m1 'model name' /proc/cpuinfo; nproc
cloud-init status --wait >/dev/null 2>&1
for i in $(seq 120); do fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break; sleep 5; done
swapoff -a; sed -i '/swap/d' /etc/fstab; rm -f /swapfile
ufw disable >/dev/null 2>&1; systemctl disable --now ufw unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -qq && apt-get -o DPkg::Lock::Timeout=600 install -y -qq openjdk-21-jre-headless >/dev/null; java -version 2>&1 | head -1
rm -rf /root/kload; tar -xzf /root/kload.tgz -C /root; install -m 755 /root/k6 /usr/local/bin/k6 2>/dev/null
IF=$(ip -o -4 addr show | awk -v ip="$ME" '$4 ~ "^"ip"/" {print $2}')
[ -z "$IF" ] && IF=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|enp1s0|ens3|eth0)$/ {print $2; exit}')
A="$ME/24"; for j in $(seq 0 7); do A="$A, $P.$((100 + 10 * K + j))/24"; done
printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      addresses: [%s]\n      mtu: 1450\n' "$IF" "$A" > /etc/netplan/60-vpc.yaml
chmod 600 /etc/netplan/60-vpc.yaml; cat /etc/netplan/60-vpc.yaml
cat > /etc/sysctl.d/90-gen.conf <<S
net.ipv4.tcp_max_tw_buckets=0
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
fs.nr_open=2000000
fs.file-max=4000000
net.core.somaxconn=65535
S
echo PREP-DONE

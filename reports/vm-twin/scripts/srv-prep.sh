#!/usr/bin/env bash
# srv-prep.sh <own-private-ip> (root, server VM, before a reboot): records the box, waits for cloud-init/apt, makes it
# match the scored box: Vultr's swapfile removed, ufw off (its rules load nf_conntrack), unattended-upgrades and apt
# timers off. Installs the seed tools (node, sqlite3), creates the unprivileged user `bench`. No sysctl touched.
set -uo pipefail
ME="$1"
echo "== box"; uname -a; grep -m1 'model name' /proc/cpuinfo; nproc; grep -E 'MemTotal|SwapTotal' /proc/meminfo
grep -r . /sys/devices/system/cpu/vulnerabilities/ | sed 's|.*/||'
cat /proc/cmdline; lsb_release -ds 2>/dev/null; systemd-detect-virt; df -h / | tail -1; lsblk -d -o NAME,ROTA,SIZE,MODEL
echo "== wait cloud-init"; cloud-init status --wait >/dev/null 2>&1; cloud-init status
for i in $(seq 120); do fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break; sleep 5; done
echo "== swap"; swapon --show; swapoff -a; sed -i '/swap/d' /etc/fstab; rm -f /swapfile /swap.img; swapon --show; grep SwapTotal /proc/meminfo
echo "== firewall"; ufw status 2>/dev/null | head -1; ufw disable 2>/dev/null; systemctl disable --now ufw 2>/dev/null
echo "== apt timers"; systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>&1 | tail -2
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -qq && apt-get -o DPkg::Lock::Timeout=600 install -y -qq nodejs sqlite3 bc >/dev/null; node --version; sqlite3 --version | cut -c1-20
IF=$(ip -o -4 addr show | awk -v ip="$ME" '$4 ~ "^"ip"/" {print $2}')
echo "vpc if: ${IF:-none}"
if [ -z "$IF" ]; then  # VPC NIC not configured by cloud-init: configure it persistently
  IF=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|enp1s0|ens3|eth0)$/ {print $2; exit}')
  printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      addresses: [%s/24]\n      mtu: 1450\n' "$IF" "$ME" > /etc/netplan/60-vpc.yaml
  chmod 600 /etc/netplan/60-vpc.yaml
fi
id bench >/dev/null 2>&1 || useradd -m -s /bin/bash bench
echo "== sysctl as shipped"; sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_mem fs.nr_open net.ipv4.ip_local_port_range kernel.io_uring_disabled 2>/dev/null
echo PREP-DONE

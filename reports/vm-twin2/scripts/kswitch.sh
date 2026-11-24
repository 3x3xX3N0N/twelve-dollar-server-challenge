#!/usr/bin/env bash
# kswitch.sh <abi> (root, server VM): installs Ubuntu's linux-image/modules 6.8.0-<abi>-generic from the noble archive
# (no other package changes) and makes it the GRUB default for the next boot. The caller reboots and checks uname -r.
set -euo pipefail
A="$1"; V="6.8.0-$A-generic"
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends linux-image-$V linux-modules-$V >/dev/null
ls /boot/vmlinuz-$V
E="Advanced options for Ubuntu>Ubuntu, with Linux $V"
grep -q "$E" <(awk -F"'" '/submenu |menuentry /{print $2}' /boot/grub/grub.cfg | sed 's/^/x/') 2>/dev/null || true
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$E\"|" /etc/default/grub
update-grub >/dev/null 2>&1
grep -c "$V" /boot/grub/grub.cfg; grep ^GRUB_DEFAULT /etc/default/grub
echo KSWITCH-DONE

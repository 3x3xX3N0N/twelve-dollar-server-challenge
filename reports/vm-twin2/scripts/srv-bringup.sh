#!/usr/bin/env bash
# srv-bringup.sh <tag>: prep (srv-prep.sh), reboot, build all three entries + seed + tests (box-build.sh), and copy the
# box's tokens.json to every generator. Logs in box-logs/<tag>-*.log.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"; . "$W/state"; T="$1"; P=$W/pkg; B=$S/../box-logs
SSH="ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30 -o BatchMode=yes"
SCP="scp -q -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
$SCP $S/srv-prep.sh $S/srv-start.sh $S/snap.sh $S/box-build.sh $P/repo.tgz root@$server_ip:/root/
$SSH root@$server_ip "bash /root/srv-prep.sh $server_priv" > $B/$T-srv-prep.log 2>&1
$SSH root@$server_ip "systemctl reboot" 2>/dev/null; sleep 20
until $SSH root@$server_ip true 2>/dev/null; do sleep 5; done
$SSH root@$server_ip 'echo "$(uname -r) swap=$(swapon --show | wc -l) ct=$(lsmod | grep -c nf_conntrack)"' >> $B/$T-srv-prep.log
$SSH root@$server_ip "bash /root/box-build.sh java-iouring-davidhsv kotlin-native-3x3xX3N0N kotlin-nio-3x3xX3N0N" > $B/$T-build.log 2>&1
$SCP root@$server_ip:/home/bench/repo/seed/tokens.json $W/tokens.json
for k in 1 2 3 4; do eval ip=\$gen${k}_ip; $SCP $W/tokens.json root@$ip:/root/tokens.json; done
echo BRINGUP-DONE >> $B/$T-build.log

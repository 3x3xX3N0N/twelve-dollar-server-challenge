#!/usr/bin/env bash
# nicq.sh <n> : sets the server's VPC NIC (virtio_net, max 8 channels) to n combined queues; prints the result.
W="${W:?}"; . "$W/state"
ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o ConnectTimeout=20 -o BatchMode=yes root@$server_ip \
  "IF=\$(ip -o -4 addr show | awk -v ip=$server_priv '\$4 ~ \"^\"ip\"/\" {print \$2}'); ethtool -L \$IF combined $1; echo \$IF \$(ethtool -l \$IF | tail -1)"

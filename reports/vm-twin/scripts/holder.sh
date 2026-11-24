#!/usr/bin/env bash
# holder.sh <workdir>: creates an ssh key, a VPC and two VMs labelled $LABEL (server vhp-1c-2gb-intel, load generator
# $GPLAN), keeps them until <workdir>/stop exists or 3 h 45 min pass, and deletes exactly the ids it created on ANY exit
# (trap). Right after creation it starts a systemd --user watchdog unit that deletes the same instance ids 4 h after
# creation, whatever happens to this process. It never lists or touches any other instance.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="$1"
LOG="$W/holder.log"; ST="$W/state"; : > "$ST"
exec >>"$LOG" 2>&1
. "$S/api.sh"
REGION="${REGION:-ewr}"; SPLAN="${SPLAN:-vhp-1c-2gb-intel}"; GPLAN="${GPLAN:-vhp-8c-16gb-intel}"
LABEL="${LABEL:-tdsc-vmtwin-$(date -u +%F)}"
IDS=(); VPC=""; SSHK=""
cleanup() {
  trap - EXIT INT TERM HUP
  log "cleanup: deleting instances ${IDS[*]:-none}"
  for i in "${IDS[@]}"; do for t in 1 2 3; do
    code=$(api DELETE "instances/$i" -o /dev/null -w '%{http_code}'); log "DELETE $i -> $code"
    { [ "$code" = 204 ] || [ "$code" = 404 ]; } && break; sleep 5; done; done
  if [ -n "$VPC" ]; then for t in $(seq 30); do
    code=$(api DELETE "vpcs/$VPC" -o /dev/null -w '%{http_code}'); log "DELETE vpc $VPC -> $code"
    { [ "$code" = 204 ] || [ "$code" = 404 ]; } && break; sleep 10; done; fi
  [ -n "$SSHK" ] && log "DELETE ssh-key $SSHK -> $(api DELETE "ssh-keys/$SSHK" -o /dev/null -w '%{http_code}')"
  echo "deleted=1" >> "$ST"; log "cleanup done"
}
trap cleanup EXIT INT TERM HUP
echo "label=$LABEL" >> "$ST"
SSHK=$(api POST ssh-keys --data "{\"name\":\"$LABEL\",\"ssh_key\":\"$(cat "$W/id_ed25519.pub")\"}" | jget "d['ssh_key']['id']") || exit 1
log "ssh key $SSHK"
VPC=$(api POST vpcs --data "{\"region\":\"$REGION\",\"description\":\"$LABEL\",\"v4_subnet\":\"10.78.0.0\",\"v4_subnet_mask\":24}" | jget "d['vpc']['id']") || exit 1
log "vpc $VPC"
mk() { api POST instances --data "{\"region\":\"$REGION\",\"plan\":\"$1\",\"os_id\":2284,\"label\":\"$LABEL\",\"hostname\":\"$2\",\"tags\":[\"$LABEL\"],\"sshkey_id\":[\"$SSHK\"],\"attach_vpc\":[\"$VPC\"],\"enable_ipv6\":false,\"backups\":\"disabled\",\"activation_email\":false}"; }
r=$(mk "$SPLAN" twin-server); SID=$(echo "$r" | jget "d['instance']['id']") || { log "server create failed: $r"; exit 1; }
IDS+=("$SID"); echo "server_id=$SID" >> "$ST"; log "server $SID ($SPLAN)"
r=$(mk "$GPLAN" twin-loadgen); GID=$(echo "$r" | jget "d['instance']['id']") || { log "loadgen create failed: $r"; exit 1; }
IDS+=("$GID"); echo "gen_id=$GID" >> "$ST"; log "loadgen $GID ($GPLAN)"
T0=$(date +%s); echo "t_created=$T0" >> "$ST"
# independent watchdog (systemd --user unit): deletes these ids 4 h after creation, whatever happened to this process
systemd-run --user --unit="tdsc-vmtwin-watchdog-$T0" --collect -p RuntimeMaxSec=6h \
  /bin/bash "$S/watchdog.sh" "$((T0 + 14400))" "$W/watchdog.log" "${IDS[@]}"
log "watchdog unit tdsc-vmtwin-watchdog-$T0 rc=$?"; echo "watchdog_unit=tdsc-vmtwin-watchdog-$T0" >> "$ST"
for i in $(seq 120); do
  s=$(api GET "instances/$SID"); g=$(api GET "instances/$GID")
  ss=$(echo "$s" | jget "d['instance']['status']+'/'+d['instance']['server_status']"); gs=$(echo "$g" | jget "d['instance']['status']+'/'+d['instance']['server_status']")
  log "status server $ss gen $gs"
  if [ "$ss" = "active/ok" ] && [ "$gs" = "active/ok" ]; then break; fi; sleep 10
done
echo "$s" | jget "'server_ip='+d['instance']['main_ip']+'\nserver_priv='+d['instance']['internal_ip']" >> "$ST"
echo "$g" | jget "'gen_ip='+d['instance']['main_ip']+'\ngen_priv='+d['instance']['internal_ip']" >> "$ST"
echo "ready=1" >> "$ST"; log "ready"
while [ ! -e "$W/stop" ] && [ $(( $(date +%s) - T0 )) -lt 13500 ]; do sleep 15; done
log "stop requested or 3h45 reached"
exit 0

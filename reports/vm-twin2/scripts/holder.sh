#!/usr/bin/env bash
# holder.sh <workdir>: creates an ssh key, a VPC, the server (vhp-1c-2gb-intel) and $NG load generators ($GPLAN), all
# labelled $LABEL. Keeps them until <workdir>/stop exists or 4 h 40 min pass, and deletes exactly the ids it created on
# ANY exit (trap). Right after creation it starts a systemd --user watchdog unit that deletes the same instance ids 5 h
# after creation, whatever happens to this process. It never lists or touches any other instance.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="$1"
LOG="$W/holder.log"; ST="$W/state"; : > "$ST"
exec >>"$LOG" 2>&1
. "$S/api.sh"
REGION="${REGION:-ewr}"; SPLAN="${SPLAN:-vhp-1c-2gb-intel}"; GPLAN="${GPLAN:-vhp-8c-16gb-intel}"; NG="${NG:-4}"
LABEL="${LABEL:-tdsc-vmtwin2-$(date -u +%F)}"
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
VPC=$(api POST vpcs --data "{\"region\":\"$REGION\",\"description\":\"$LABEL\",\"v4_subnet\":\"10.79.0.0\",\"v4_subnet_mask\":24}" | jget "d['vpc']['id']") || exit 1
log "vpc $VPC"
mk() { api POST instances --data "{\"region\":\"$REGION\",\"plan\":\"$1\",\"os_id\":2284,\"label\":\"$LABEL\",\"hostname\":\"$2\",\"tags\":[\"$LABEL\"],\"sshkey_id\":[\"$SSHK\"],\"attach_vpc\":[\"$VPC\"],\"enable_ipv6\":false,\"backups\":\"disabled\",\"activation_email\":false}"; }
r=$(mk "$SPLAN" twin-server); SID=$(echo "$r" | jget "d['instance']['id']") || { log "server create failed: $r"; exit 1; }
IDS+=("$SID"); echo "server_id=$SID" >> "$ST"; log "server $SID ($SPLAN)"
GIDS=()
for k in $(seq "$NG"); do
  r=$(mk "$GPLAN" "twin-gen$k"); GID=$(echo "$r" | jget "d['instance']['id']") || { log "gen$k create failed: $r"; exit 1; }
  IDS+=("$GID"); GIDS+=("$GID"); echo "gen${k}_id=$GID" >> "$ST"; log "gen$k $GID ($GPLAN)"
done
T0=$(date +%s); echo "t_created=$T0" >> "$ST"; echo "ng=$NG" >> "$ST"
systemd-run --user --unit="tdsc-vmtwin2-watchdog-$T0" --collect -p RuntimeMaxSec=7h \
  /bin/bash "$S/watchdog.sh" "$((T0 + 18000))" "$W/watchdog.log" "${IDS[@]}"
log "watchdog unit tdsc-vmtwin2-watchdog-$T0 rc=$?"; echo "watchdog_unit=tdsc-vmtwin2-watchdog-$T0" >> "$ST"
for i in $(seq 120); do
  ok=1
  for id in "${IDS[@]}"; do
    st=$(api GET "instances/$id" | jget "d['instance']['status']+'/'+d['instance']['server_status']+'/'+d['instance']['main_ip']+'/'+d['instance']['internal_ip']")
    [[ "$st" == active/ok/* ]] && [[ "$st" != */0.0.0.0/* ]] && [[ "$st" != */ ]] || ok=0
  done
  log "poll $i ok=$ok"; [ $ok = 1 ] && break; sleep 10
done
api GET "instances/$SID" | jget "'server_ip='+d['instance']['main_ip']+'\nserver_priv='+d['instance']['internal_ip']" >> "$ST"
k=0; for g in "${GIDS[@]}"; do k=$((k+1))
  api GET "instances/$g" | jget "'gen${k}_ip='+d['instance']['main_ip']+'\ngen${k}_priv='+d['instance']['internal_ip']" >> "$ST"; done
echo "ready=1" >> "$ST"; log "ready"
while [ ! -e "$W/stop" ] && [ $(( $(date +%s) - T0 )) -lt 16800 ]; do sleep 15; done
log "stop requested or 4h40 reached"
exit 0

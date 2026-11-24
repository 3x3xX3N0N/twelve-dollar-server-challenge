#!/usr/bin/env bash
# srv-holder.sh <workdir> <tag>: replaces the server. Deletes the current server_id from <workdir>/state (an id this run
# created), then creates one new $SPLAN instance labelled $LABEL on the same VPC and ssh key (ids from holder.log), with
# its own trap (deletes exactly that id on ANY exit) and its own systemd --user watchdog (same 5 h deadline as the
# fleet, t_created + 18000). Appends the new server_* lines to state (later lines win when state is sourced).
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="$1"; TAG="$2"
exec >>"$W/srv-holder-$TAG.log" 2>&1
. "$S/api.sh"; . "$W/state"
SPLAN="${SPLAN:-vhp-1c-2gb-intel}"; REGION=ewr
VPC=$(awk '/ vpc /{print $3}' "$W/holder.log" | head -1); SSHK=$(awk '/ ssh key /{print $4}' "$W/holder.log" | head -1)
NEW=""
cleanup() { trap - EXIT INT TERM HUP; [ -n "$NEW" ] && for t in 1 2 3; do code=$(api DELETE "instances/$NEW" -o /dev/null -w '%{http_code}'); log "DELETE $NEW -> $code"; { [ "$code" = 204 ] || [ "$code" = 404 ]; } && break; sleep 5; done; log "cleanup done"; }
trap cleanup EXIT INT TERM HUP
log "deleting old server $server_id -> $(api DELETE "instances/$server_id" -o /dev/null -w '%{http_code}')"
for i in $(seq 30); do [ "$(api GET "instances/$server_id" -o /dev/null -w '%{http_code}')" = 404 ] && break; sleep 5; done
r=$(api POST instances --data "{\"region\":\"$REGION\",\"plan\":\"$SPLAN\",\"os_id\":2284,\"label\":\"$label\",\"hostname\":\"twin-server-$TAG\",\"tags\":[\"$label\"],\"sshkey_id\":[\"$SSHK\"],\"attach_vpc\":[\"$VPC\"],\"enable_ipv6\":false,\"backups\":\"disabled\",\"activation_email\":false}")
NEW=$(echo "$r" | jget "d['instance']['id']") || { log "create failed: $r"; NEW=""; exit 1; }
log "new server $NEW"; echo "server_id=$NEW" >> "$W/state"
systemd-run --user --unit="tdsc-vmtwin2-watchdog-$TAG" --collect -p RuntimeMaxSec=7h \
  /bin/bash "$S/watchdog.sh" "$((t_created + 18000))" "$W/watchdog-$TAG.log" "$NEW"; log "watchdog-$TAG rc=$?"
for i in $(seq 120); do
  st=$(api GET "instances/$NEW" | jget "d['instance']['status']+'/'+d['instance']['server_status']+'/'+d['instance']['main_ip']+'/'+d['instance']['internal_ip']")
  [[ "$st" == active/ok/* ]] && [[ "$st" != */0.0.0.0/* ]] && [[ "$st" != */ ]] && break; sleep 10; done
api GET "instances/$NEW" | jget "'server_ip='+d['instance']['main_ip']+'\nserver_priv='+d['instance']['internal_ip']" >> "$W/state"
echo "srv_ready_$TAG=1" >> "$W/state"; log "ready"
while [ ! -e "$W/stop" ]; do sleep 15; done
log "stop requested"; exit 0

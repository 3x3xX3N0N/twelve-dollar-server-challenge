#!/usr/bin/env bash
# watchdog.sh <deadline-epoch> <logfile> <instance-id>...: deletes exactly these instance ids at the deadline, whatever
# else happened. Exits once every id is gone (404). Runs as a systemd --user unit (holder.sh starts it).
set -uo pipefail
DL=$1; LOGF=$2; shift 2
exec >>"$LOGF" 2>&1
. "$(cd "$(dirname "$0")" && pwd)/api.sh"
log "watchdog: deadline $(date -u -d @"$DL" +%FT%TZ) ids $*"
while :; do
  gone=0; for i in "$@"; do [ "$(api GET "instances/$i" -o /dev/null -w '%{http_code}')" = 404 ] && gone=$((gone+1)); done
  [ $gone = $# ] && { log "watchdog: all gone, exiting"; exit 0; }
  if [ "$(date +%s)" -ge "$DL" ]; then
    for i in "$@"; do log "watchdog: DELETE $i -> $(api DELETE "instances/$i" -o /dev/null -w '%{http_code}')"; done
  fi
  sleep 60
done

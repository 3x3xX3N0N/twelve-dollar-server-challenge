# api.sh (sourced): api <METHOD> <path> [curl args...]. The Vultr key is read from the env file into a shell variable
# and handed to curl on stdin as a config line (never argv, never a file, never a log).
K=$(grep -E '^(export )?VULTR_API_KEY=' "$HOME/dev0/keys/.tessera-cloud.env" | head -1 | cut -d= -f2- | tr -d '"'"'"'\r \t')
api() { local m=$1 p=$2; shift 2; printf 'header = "Authorization: Bearer %s"\n' "$K" |
  curl -sS -K - -X "$m" -H 'Content-Type: application/json' "https://api.vultr.com/v2/$p" "$@"; }
jget() { python3 -I -c "import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
log() { echo "$(date -u +%FT%TZ) $*"; }

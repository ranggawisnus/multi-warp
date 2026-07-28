#!/usr/bin/env bash
# Export SOCKS pool file for farm tools / proxy rotators.
set -euo pipefail

BASE_PORT="${BASE_PORT:-40001}"
COUNT="${COUNT:-10}"
HOST="${HOST:-127.0.0.1}"
SCHEME="${SCHEME:-socks5}"   # socks5 | socks5h
OUT="${OUT:-warp-pool.txt}"
EXTRA_HOSTS="${EXTRA_HOSTS:-}"  # optional comma-separated extra hosts (e.g. Tailscale IP)

usage() {
  cat <<EOF
Usage: $0 [options]

  -n, --count N
  -p, --base-port PORT
  -H, --host HOST           Primary host in URLs (default 127.0.0.1)
  --extra-hosts h1,h2       Also emit the same ports for extra hosts
  --scheme socks5|socks5h   Default socks5 (browser/Playwright often want socks5 not socks5h)
  -o, --out FILE            Output path (default warp-pool.txt)
  --stdout

Example pool line:
  socks5://127.0.0.1:40001
EOF
}

STDOUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--count) COUNT="$2"; shift 2 ;;
    -p|--base-port) BASE_PORT="$2"; shift 2 ;;
    -H|--host) HOST="$2"; shift 2 ;;
    --extra-hosts) EXTRA_HOSTS="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    -o|--out) OUT="$2"; shift 2 ;;
    --stdout) STDOUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

hosts=("$HOST")
if [[ -n "$EXTRA_HOSTS" ]]; then
  IFS=',' read -r -a extra <<< "$EXTRA_HOSTS"
  for h in "${extra[@]}"; do
    h=$(echo "$h" | xargs)
    [[ -n "$h" ]] && hosts+=("$h")
  done
fi

tmp=$(mktemp)
{
  for h in "${hosts[@]}"; do
    for ((i=0; i<COUNT; i++)); do
      port=$((BASE_PORT + i))
      echo "${SCHEME}://${h}:${port}"
    done
  done
} > "$tmp"

if [[ $STDOUT -eq 1 ]]; then
  cat "$tmp"
else
  mv "$tmp" "$OUT"
  echo "Wrote $OUT ($(wc -l < "$OUT") lines)"
fi

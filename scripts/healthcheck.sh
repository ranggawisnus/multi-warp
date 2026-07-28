#!/usr/bin/env bash
# Probe every multi-WARP SOCKS5 exit: exit IP + (optional) WARP status.
set -euo pipefail

BASE_PORT="${BASE_PORT:-40001}"
COUNT="${COUNT:-10}"
BIND_HOST="${BIND_HOST:-127.0.0.1}"
TIMEOUT="${TIMEOUT:-12}"
URL="${URL:-https://api.ipify.org}"
SHOW_TRACE=0
JSON=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -n, --count N          Number of nodes (default: $COUNT)
  -p, --base-port PORT   First port (default: $BASE_PORT)
  -H, --host HOST        SOCKS host (default: $BIND_HOST)
  -t, --timeout SEC      curl max-time (default: $TIMEOUT)
  --trace                Also print cloudflare cdn-cgi/trace warp= line
  --json                 Machine-readable JSON lines
  -h, --help             Show help

Env overrides: COUNT BASE_PORT BIND_HOST TIMEOUT URL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--count) COUNT="$2"; shift 2 ;;
    -p|--base-port) BASE_PORT="$2"; shift 2 ;;
    -H|--host) BIND_HOST="$2"; shift 2 ;;
    -t|--timeout) TIMEOUT="$2"; shift 2 ;;
    --trace) SHOW_TRACE=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

ok=0
fail=0
declare -A seen_ips=()

for ((i=0; i<COUNT; i++)); do
  port=$((BASE_PORT + i))
  proxy="socks5h://${BIND_HOST}:${port}"
  ip=""
  err=""
  if ! ip=$(curl -fsS --max-time "$TIMEOUT" --proxy "$proxy" "$URL" 2>/dev/null); then
    err="FAIL"
    ip=""
  fi

  warp_line=""
  if [[ $SHOW_TRACE -eq 1 && -n "$ip" ]]; then
    warp_line=$(curl -fsS --max-time "$TIMEOUT" --proxy "$proxy" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^warp=' || true)
  fi

  if [[ -n "$ip" ]]; then
    ok=$((ok + 1))
    seen_ips["$ip"]=1
    if [[ $JSON -eq 1 ]]; then
      printf '{"port":%s,"ok":true,"ip":"%s","warp":"%s"}\n' "$port" "$ip" "${warp_line#warp=}"
    else
      if [[ $SHOW_TRACE -eq 1 ]]; then
        printf 'port %-5s OK  ip=%-15s %s\n' "$port" "$ip" "$warp_line"
      else
        printf 'port %-5s OK  ip=%s\n' "$port" "$ip"
      fi
    fi
  else
    fail=$((fail + 1))
    if [[ $JSON -eq 1 ]]; then
      printf '{"port":%s,"ok":false,"ip":null,"error":"unreachable"}\n' "$port"
    else
      printf 'port %-5s FAIL\n' "$port"
    fi
  fi
done

unique=${#seen_ips[@]}
if [[ $JSON -eq 0 ]]; then
  echo "----"
  echo "ok=$ok fail=$fail unique_exit_ips=$unique / $COUNT"
  if [[ $fail -gt 0 ]]; then
    echo "Tip: docker compose ps && docker compose logs --tail=50 warp-n1"
  fi
  if [[ $ok -gt 1 && $unique -eq 1 ]]; then
    echo "WARN: all healthy nodes share ONE exit IP (WARP may not have unique identities yet)."
  fi
fi

[[ $fail -eq 0 ]]

#!/usr/bin/env bash
# Hit each multi-warp exit once (round-robin demo).
set -euo pipefail
BASE_PORT="${BASE_PORT:-40001}"
COUNT="${COUNT:-10}"
HOST="${HOST:-127.0.0.1}"

for ((i=0; i<COUNT; i++)); do
  port=$((BASE_PORT + i))
  echo -n ":$port -> "
  curl -fsS --max-time 12 --proxy "socks5h://${HOST}:${port}" https://api.ipify.org || echo FAIL
  echo
done

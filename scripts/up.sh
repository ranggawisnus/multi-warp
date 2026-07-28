#!/usr/bin/env bash
# One-shot: generate compose (if missing) → create data dirs → pull → up → healthcheck.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COUNT="${COUNT:-10}"
BASE_PORT="${BASE_PORT:-40001}"
BIND="${BIND:-127.0.0.1}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "No $COMPOSE_FILE — generating ($COUNT nodes, bind=$BIND)..."
  python3 scripts/generate-compose.py -n "$COUNT" --base-port "$BASE_PORT" --bind "$BIND" -o "$COMPOSE_FILE"
fi

# Ensure data dirs exist for every service volume mentioned
for ((i=1; i<=COUNT; i++)); do
  mkdir -p "data-n$i"
done

if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    DC=(docker compose -f "$COMPOSE_FILE")
  else
    DC=(docker-compose -f "$COMPOSE_FILE")
  fi
else
  echo "docker not found" >&2
  exit 1
fi

# Kernel modules / device sanity
if [[ ! -e /dev/net/tun ]]; then
  echo "ERROR: /dev/net/tun missing. On bare metal/VPS usually: modprobe tun" >&2
  exit 1
fi

"${DC[@]}" pull
"${DC[@]}" up -d
echo "Waiting for WARP registration (25s)..."
sleep 25
./scripts/healthcheck.sh --base-port "$BASE_PORT" --count "$COUNT" --trace || {
  echo "Some nodes still warming up — recheck in a minute:"
  echo "  ./scripts/healthcheck.sh -n $COUNT -p $BASE_PORT --trace"
  exit 1
}
./scripts/export-pool.sh -n "$COUNT" -p "$BASE_PORT" -o warp-pool.txt
echo "Ready. Pool file: $ROOT/warp-pool.txt"

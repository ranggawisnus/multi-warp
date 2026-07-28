#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
if docker compose version >/dev/null 2>&1; then
  docker compose -f "$COMPOSE_FILE" down
else
  docker-compose -f "$COMPOSE_FILE" down
fi

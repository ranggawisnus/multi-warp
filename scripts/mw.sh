#!/usr/bin/env bash
# multi-warp control: run | stop | status | restart
# run → start N WARP exits and keep recreating bad nodes until all exit IPs are unique.
set -euo pipefail

_SCRIPT_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_SCRIPT_SRC" ]]; do
  _link="$(readlink "$_SCRIPT_SRC")"
  if [[ "$_link" == /* ]]; then
    _SCRIPT_SRC="$_link"
  else
    _SCRIPT_SRC="$(cd "$(dirname "$_SCRIPT_SRC")" && pwd)/$_link"
  fi
done
ROOT="$(cd "$(dirname "$_SCRIPT_SRC")/.." && pwd)"
cd "$ROOT"
unset _SCRIPT_SRC _link

COUNT="${COUNT:-10}"
BASE_PORT="${BASE_PORT:-40001}"
BIND="${BIND:-127.0.0.1}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
POOL_FILE="${POOL_FILE:-warp-pool.txt}"
NAME_PREFIX="${NAME_PREFIX:-warp-n}"

# run tuning
INITIAL_WAIT="${INITIAL_WAIT:-30}"
RECREATE_WAIT="${RECREATE_WAIT:-55}"
MAX_ROUNDS="${MAX_ROUNDS:-8}"
RECREATE_BATCH="${RECREATE_BATCH:-3}"
BATCH_GAP="${BATCH_GAP:-25}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-12}"
TRACE_URL="${TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
IP_URL="${IP_URL:-https://api.ipify.org}"

usage() {
  cat <<EOF
Usage: $0 <run|stop|status|restart> [options]

Commands:
  run       Start stack, healthcheck, recreate until all exit IPs unique
  stop      docker compose down
  status    Probe ports (IP + warp=)
  restart   stop then run

Options (also env vars):
  -n, --count N          Nodes (default: $COUNT)
                         Always regenerates compose when N/bind/port differ
  -p, --base-port PORT   First host port (default: $BASE_PORT)
  --bind ADDR            Host bind (default: $BIND)
  --max-rounds N         Recreate rounds (default: $MAX_ROUNDS)
  --recreate-batch N     Max nodes wiped/recreated per batch (default: $RECREATE_BATCH)
  --initial-wait SEC     Wait after first up (default: $INITIAL_WAIT)
  --recreate-wait SEC    Wait after recreate (default: $RECREATE_WAIT)
  -h, --help

Examples:
  $0 run
  $0 run -n 20
  $0 run -n 10 --max-rounds 12
  $0 stop
  $0 status
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

dc_init() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  if docker compose version >/dev/null 2>&1; then
    DC=(docker compose -f "$COMPOSE_FILE")
  elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose -f "$COMPOSE_FILE")
  else
    die "docker compose / docker-compose not found"
  fi
}

node_name() {
  local idx="$1"
  echo "${NAME_PREFIX}${idx}"
}

# Probe one port → prints: port|ok|ip|warp   (warp = on|off|unknown|empty)
probe_one() {
  local port="$1"
  local proxy="socks5h://${BIND}:${port}"
  local ip="" warp=""

  if ! ip=$(curl -fsS --max-time "$PROBE_TIMEOUT" --proxy "$proxy" "$IP_URL" 2>/dev/null); then
    echo "${port}|fail||"
    return 0
  fi
  ip="${ip//$'\r'/}"
  ip="${ip//$'\n'/}"

  warp=$(curl -fsS --max-time "$PROBE_TIMEOUT" --proxy "$proxy" "$TRACE_URL" 2>/dev/null \
    | grep -E '^warp=' | head -1 | cut -d= -f2- || true)
  warp="${warp:-unknown}"
  echo "${port}|ok|${ip}|${warp}"
}

# Fill arrays RESULT_LINES, BAD_IDXS (1-based node indices to recreate)
# Sets: OK_COUNT FAIL_COUNT UNIQUE_COUNT WARP_ON_COUNT
probe_all() {
  RESULT_LINES=()
  BAD_IDXS=()
  OK_COUNT=0
  FAIL_COUNT=0
  WARP_ON_COUNT=0
  UNIQUE_COUNT=0

  local -A first_owner=()   # ip -> first node idx
  local -A seen=()
  local i port line status ip warp idx

  echo "Probing ${COUNT} exits on ${BIND}:${BASE_PORT}–$((BASE_PORT + COUNT - 1)) ..."
  for ((i = 0; i < COUNT; i++)); do
    port=$((BASE_PORT + i))
    idx=$((i + 1))
    line=$(probe_one "$port")
    RESULT_LINES+=("$line")
    IFS='|' read -r _port status ip warp <<<"$line"

    if [[ "$status" != "ok" ]]; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      BAD_IDXS+=("$idx")
      printf '  port %-5s FAIL  (will recreate %s)\n' "$port" "$(node_name "$idx")"
      continue
    fi

    OK_COUNT=$((OK_COUNT + 1))
    if [[ "$warp" == "on" ]]; then
      WARP_ON_COUNT=$((WARP_ON_COUNT + 1))
    fi

    # warp off / unknown → bad even if curl got an IP (often host IP leak)
    if [[ "$warp" != "on" ]]; then
      BAD_IDXS+=("$idx")
      printf '  port %-5s BAD   ip=%-15s warp=%s  (will recreate %s)\n' \
        "$port" "$ip" "$warp" "$(node_name "$idx")"
      continue
    fi

    if [[ -n "${first_owner[$ip]+x}" ]]; then
      # duplicate: keep first owner, recreate this one
      BAD_IDXS+=("$idx")
      printf '  port %-5s DUP   ip=%-15s warp=%s  (same as n%s; recreate %s)\n' \
        "$port" "$ip" "$warp" "${first_owner[$ip]}" "$(node_name "$idx")"
      continue
    fi

    first_owner["$ip"]=$idx
    seen["$ip"]=1
    printf '  port %-5s OK    ip=%-15s warp=%s\n' "$port" "$ip" "$warp"
  done

  UNIQUE_COUNT=${#seen[@]}
  echo "----"
  echo "ok=$OK_COUNT fail=$FAIL_COUNT warp_on=$WARP_ON_COUNT unique_exit_ips=$UNIQUE_COUNT / $COUNT"
}

wipe_data_dir() {
  local idx="$1"
  local dir="$ROOT/data-n${idx}"
  mkdir -p "$dir"
  docker run --rm \
    -v "$dir:/wipe" \
    --user 0:0 \
    alpine:3.20 \
    sh -c 'rm -rf /wipe/* /wipe/.[!.]* /wipe/..?* 2>/dev/null; exit 0' \
    >/dev/null 2>&1 || true
  mkdir -p "$dir"
}

recreate_nodes() {
  local idxs=("$@")
  [[ ${#idxs[@]} -eq 0 ]] && return 0

  local idx name batch=() i
  local batch_size="${RECREATE_BATCH:-3}"
  local between="${BATCH_GAP:-25}"
  if ((${#idxs[@]} > 6)) && ((batch_size > 2)); then
    batch_size=2
  fi
  echo "Recreating ${#idxs[@]} node(s) in batches of ${batch_size} (gap ${between}s): ${idxs[*]}"

  i=0
  for idx in "${idxs[@]}"; do
    batch+=("$idx")
    i=$((i + 1))
    if ((i >= batch_size)); then
      _recreate_batch "${batch[@]}"
      batch=()
      i=0
      echo "  gap ${between}s before next batch..."
      sleep "$between"
    fi
  done
  if ((${#batch[@]} > 0)); then
    _recreate_batch "${batch[@]}"
  fi

  echo "Waiting ${RECREATE_WAIT}s for WARP re-registration..."
  sleep "$RECREATE_WAIT"
}

_recreate_batch() {
  local idxs=("$@")
  local idx names=()
  [[ ${#idxs[@]} -eq 0 ]] && return 0

  for idx in "${idxs[@]}"; do
    names+=("$(node_name "$idx")")
  done
  echo "  batch: ${names[*]}"

  "${DC[@]}" stop "${names[@]}" 2>/dev/null || true
  "${DC[@]}" rm -f "${names[@]}" 2>/dev/null || true

  for idx in "${idxs[@]}"; do
    wipe_data_dir "$idx"
  done

  "${DC[@]}" up -d --force-recreate "${names[@]}"
}

cmd_stop() {
  dc_init
  if [[ -f "$COMPOSE_FILE" ]]; then
    "${DC[@]}" down
    echo "Stopped."
  else
    echo "No $COMPOSE_FILE — nothing to stop."
  fi
}

cmd_status() {
  dc_init
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    die "No $COMPOSE_FILE — run first"
  fi
  "${DC[@]}" ps 2>/dev/null || true
  echo
  probe_all
  if [[ $FAIL_COUNT -eq 0 && $UNIQUE_COUNT -eq $COUNT && $WARP_ON_COUNT -eq $COUNT ]]; then
    echo "STATUS: healthy (all unique + warp=on)"
    return 0
  fi
  echo "STATUS: not fully unique / not all warp=on"
  return 1
}

compose_service_count() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo 0
    return
  fi
  grep -E "^[[:space:]]*${NAME_PREFIX}[0-9]+:" "$COMPOSE_FILE" 2>/dev/null | wc -l | tr -d ' '
}

compose_matches_desired() {
  [[ -f "$COMPOSE_FILE" ]] || return 1
  local hdr n
  hdr="$(head -n 5 "$COMPOSE_FILE")"
  echo "$hdr" | grep -qE "^# ${COUNT} independent " || return 1
  echo "$hdr" | grep -qE "Ports: ${BASE_PORT}\\.\\." || return 1
  echo "$hdr" | grep -qE "bind=${BIND}" || return 1
  n="$(compose_service_count)"
  [[ "$n" == "$COUNT" ]]
}

ensure_compose() {
  local existing extras=() i
  existing="$(compose_service_count)"

  if compose_matches_desired; then
    echo "Compose OK: $COUNT nodes, ports ${BASE_PORT}–$((BASE_PORT + COUNT - 1)), bind=$BIND"
  else
    if [[ -f "$COMPOSE_FILE" ]]; then
      echo "Regenerating $COMPOSE_FILE: was ${existing} service(s) → $COUNT nodes (ports ${BASE_PORT}–$((BASE_PORT + COUNT - 1)), bind=$BIND)"
      if [[ "$existing" =~ ^[0-9]+$ ]] && ((existing > COUNT)); then
        for ((i = COUNT + 1; i <= existing; i++)); do
          extras+=("$(node_name "$i")")
        done
        if ((${#extras[@]} > 0)); then
          echo "Stopping extra nodes: ${extras[*]}"
          "${DC[@]}" stop "${extras[@]}" 2>/dev/null || true
          "${DC[@]}" rm -f "${extras[@]}" 2>/dev/null || true
        fi
      fi
    else
      echo "Generating $COMPOSE_FILE ($COUNT nodes, bind=$BIND, base=$BASE_PORT)..."
    fi
    python3 scripts/generate-compose.py \
      -n "$COUNT" \
      --base-port "$BASE_PORT" \
      --bind "$BIND" \
      --name-prefix "$NAME_PREFIX" \
      -o "$COMPOSE_FILE"
  fi

  for ((i = 1; i <= COUNT; i++)); do
    mkdir -p "data-n$i"
  done
}

cmd_run() {
  dc_init
  [[ -e /dev/net/tun ]] || die "/dev/net/tun missing (try: sudo modprobe tun)"
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"

  ensure_compose

  local wait="$INITIAL_WAIT"
  if ((COUNT > 15)) && ((wait < COUNT + 20)); then
    wait=$((COUNT + 20))
  fi

  echo "Pulling image + starting $COUNT nodes..."
  "${DC[@]}" pull
  "${DC[@]}" up -d
  echo "Waiting ${wait}s for first WARP registration..."
  sleep "$wait"

  local round=1
  while ((round <= MAX_ROUNDS)); do
    echo
    echo "======== round $round / $MAX_ROUNDS ========"
    probe_all

    if ((FAIL_COUNT == 0 && UNIQUE_COUNT == COUNT && WARP_ON_COUNT == COUNT)); then
      "$ROOT/scripts/export-pool.sh" -n "$COUNT" -p "$BASE_PORT" -H "$BIND" -o "$POOL_FILE"
      echo
      echo "READY: $COUNT unique WARP exits."
      echo "Pool: $ROOT/$POOL_FILE"
      echo
      local line port status ip warp
      for line in "${RESULT_LINES[@]}"; do
        IFS='|' read -r port status ip warp <<<"$line"
        printf '  %s  →  %s\n' "socks5://${BIND}:${port}" "$ip"
      done
      return 0
    fi

    if ((${#BAD_IDXS[@]} == 0)); then
      # edge: unique < COUNT but no BAD classified (shouldn't happen)
      die "unique=$UNIQUE_COUNT but no bad nodes listed — bug in classifier"
    fi

    if ((round == MAX_ROUNDS)); then
      break
    fi

    recreate_nodes "${BAD_IDXS[@]}"
    round=$((round + 1))
  done

  echo
  echo "FAILED after $MAX_ROUNDS rounds: unique=$UNIQUE_COUNT / $COUNT (want all different + warp=on)."
  echo "Tips:"
  echo "  ${DC[*]} logs --tail=80 $(node_name 1)"
  echo "  MAX_ROUNDS=12 RECREATE_WAIT=90 $0 run -n $COUNT"
  return 1
}

cmd_restart() {
  cmd_stop || true
  cmd_run
}

# --- arg parse ---
CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    run|stop|status|restart)
      CMD="$1"
      shift
      ;;
    -n|--count)
      COUNT="$2"
      shift 2
      ;;
    -p|--base-port)
      BASE_PORT="$2"
      shift 2
      ;;
    --bind)
      BIND="$2"
      shift 2
      ;;
    --max-rounds)
      MAX_ROUNDS="$2"
      shift 2
      ;;
    --initial-wait)
      INITIAL_WAIT="$2"
      shift 2
      ;;
    --recreate-wait)
      RECREATE_WAIT="$2"
      shift 2
      ;;
    --recreate-batch)
      RECREATE_BATCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ -n "$CMD" ]] || { usage; exit 2; }
[[ "$COUNT" =~ ^[0-9]+$ ]] && ((COUNT >= 1 && COUNT <= 64)) || die "count must be 1..64"
[[ "$BASE_PORT" =~ ^[0-9]+$ ]] || die "base-port must be a number"

case "$CMD" in
  run) cmd_run ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  restart) cmd_restart ;;
esac

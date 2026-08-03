# multi-warp

**N independent Cloudflare WARP exits as local SOCKS5 proxies — one command.**

Battle-tested pattern for browser farms, multi-account tooling, and anything that needs **several clean egress IPs** without buying residential proxies.

```text
Your app / browser / farm
        │  round-robin
        ▼
┌──────────────────────────────┐
│  warp-n1  → socks5://…:40001 │──► WARP exit IP A
│  warp-n2  → socks5://…:40002 │──► WARP exit IP B
│  ...                         │
│  warp-n10 → socks5://…:40010 │──► WARP exit IP J
└──────────────────────────────┘
   each container = own WARP identity (own data volume)
```

> Bahasa Indonesia: lihat [docs/README.id.md](docs/README.id.md)

---

## Why this exists

Single WARP (or single VPS IP) gets rate-limited fast when you open many sessions.

**multi-warp** runs **N Docker containers** of [`caomingjun/warp`](https://github.com/caomingjun/warp):

| Property | Behavior |
|---|---|
| Identity | **1 data volume per node** → separate WARP registration |
| Protocol | SOCKS5 on host ports `40001…` |
| Isolation | Default bind **`127.0.0.1` only** (not public) |
| Ops | **`./mw run`** (or `generate` → `up` → `healthcheck` → `export-pool`) |

Used in production with **10 healthy exits** on a farm VPS.

### Pool size expectations (read this)

| Target size | Realistic outcome |
|---|---|
| **10–15 exits** | **Normal / recommended.** Most nodes reach `warp=on`; unique IPs often close to N (anycast may still reuse a few). |
| **~20 exits** | **Hard.** Simultaneous registration from one host often leaves nodes stuck at `warp=off` (daemon hang / watchdog). Getting **20 unique** exit IPs needs serial recreate + long waits; Cloudflare anycast frequently overlaps. |
| **30+** | Not practical on a single host for “all unique”. Prefer multiple hosts or accept heavy IP reuse. |

`./mw run` will **recreate** bad nodes (FAIL, `warp≠on`, or **duplicate exit IP**) until every exit is unique or `MAX_ROUNDS` is hit. That does **not** guarantee Cloudflare hands out N distinct anycast addresses—especially past ~15.

---

## Requirements

- Linux VPS/bare metal (x86_64 or arm64)
- Docker + Compose plugin (`docker compose`) **or** classic `docker-compose`
- `/dev/net/tun` available
- Capability `NET_ADMIN` allowed for containers
- Outbound UDP/TCP free enough for WARP (WireGuard)

**Not supported as-is:** plain shared hosting without TUN, most Windows Docker Desktop setups without extra networking work.

---

## Quick start (recommended: `mw`)

One entrypoint for start / stop / status. On `run` it regenerates compose when `-n` changes, probes every port, and recreates bad nodes (including root-owned `data-n*` wipe via a helper container).

```bash
git clone https://github.com/Micolaabdi/multi-warp.git
cd multi-warp
chmod +x scripts/*.sh mw

# 10 exits — typical sweet spot
./mw run -n 10

# status / stop
./mw status -n 10
./mw stop
```

```bash
# 15 is usually still OK with patience
./mw run -n 15 --max-rounds 12 --recreate-wait 90

# 20 is hard: use small batches + long waits (may still land <20 unique)
./mw run -n 20 --max-rounds 12 --recreate-batch 2 --recreate-wait 90
```

| Command | Meaning |
|---|---|
| `./mw run [-n N]` | Generate/scale compose → `up` → probe → recreate until unique + `warp=on` → write `warp-pool.txt` |
| `./mw stop` | `docker compose down` |
| `./mw status [-n N]` | List containers + probe ports |
| `./mw restart [-n N]` | stop then run |

Useful env / flags: `COUNT` / `-n`, `BASE_PORT` / `-p`, `--bind`, `--max-rounds`, `--recreate-batch`, `--recreate-wait`, `--initial-wait`.

Symlink: `./mw` → `scripts/mw.sh`.

### Classic path (`up.sh`)

```bash
COUNT=10 ./scripts/up.sh
```

What `up.sh` does (one-shot, **no** unique-IP recreate loop):

1. Generates `docker-compose.yml` if missing  
2. Creates `data-n1…data-nN`  
3. `docker compose pull && up -d`  
4. Waits ~25s for registration  
5. Runs healthcheck (exit IP per port)  
6. Writes `warp-pool.txt`

Manual equivalent:

```bash
python3 scripts/generate-compose.py -n 10 -o docker-compose.yml
mkdir -p data-n{1..10}
docker compose up -d
sleep 25
./scripts/healthcheck.sh -n 10 --trace
./scripts/export-pool.sh -n 10 -o warp-pool.txt
```

Expected healthcheck:

```text
port 40001 OK  ip=104.x.x.x   warp=on
port 40002 OK  ip=162.x.x.x   warp=on
...
ok=10 fail=0 unique_exit_ips=8 / 10
```

> Unique IPs can be **&lt; N** (Cloudflare may reuse some anycast exits).  
> **All N sharing one IP** after several minutes → problem (see troubleshooting).  
> Prefer **`./mw run`** when you need automated recreate until unique.

---

## Use the pool

`warp-pool.txt`:

```text
socks5://127.0.0.1:40001
socks5://127.0.0.1:40002
...
```

### curl

```bash
curl --proxy socks5h://127.0.0.1:40001 https://api.ipify.org
```

### Python `requests`

```python
import requests
proxies = {"http": "socks5h://127.0.0.1:40001", "https": "socks5h://127.0.0.1:40001"}
print(requests.get("https://api.ipify.org", proxies=proxies, timeout=15).text)
# pip install "requests[socks]" PySocks
```

### Browser / Playwright / Camoufox note

Many browser stacks want **`socks5://`** (DNS via browser) not **`socks5h://`** (DNS via proxy).  
`export-pool.sh` defaults to `socks5://` for that reason. curl/requests often prefer `socks5h://`.

### Round-robin snippet

```python
from itertools import cycle
POOL = [f"socks5h://127.0.0.1:{40001+i}" for i in range(10)]
proxy_cycle = cycle(POOL)
def next_proxy():
    u = next(proxy_cycle)
    return {"http": u, "https": u}
```

More examples: [`examples/`](examples/).

---

## Common configs

### Fewer / more nodes

```bash
./mw run -n 5
# or classic:
python3 scripts/generate-compose.py -n 5 -o docker-compose.yml
COUNT=5 ./scripts/up.sh
```

`mw run -n N` **regenerates** `docker-compose.yml` when N / base-port / bind differ from the current file (so scaling 10 → 15 actually starts 15 services).

### Remote farm host needs to reach WARP on another machine

**Prefer Tailscale / private network**, not raw public `0.0.0.0`.

```bash
# on WARP host — still bind localhost, expose via Tailscale serve/SSH tunnel
# OR bind all interfaces ONLY behind firewall:
python3 scripts/generate-compose.py -n 5 --bind 0.0.0.0 -o docker-compose.yml
```

If you must use `0.0.0.0`:

- Firewall: allow **only** your farm host IP/Tailscale IP to ports `40001-4000N`
- Never leave SOCKS open to the whole internet

Export pool with extra host:

```bash
./scripts/export-pool.sh -n 10 -H 127.0.0.1 \
  --extra-hosts 100.x.y.z \
  -o combined_multi_warp_pool.txt
```

### Stop / wipe

```bash
./mw stop
# or: ./scripts/down.sh

# wipe WARP identities (will re-register on next up).
# Files under data-n* are often root-owned (container); plain rm may fail:
#   docker run --rm -v "$PWD/data-n3:/wipe" --user 0:0 alpine sh -c 'rm -rf /wipe/*'
# ./mw run already wipes bad nodes this way during recreate.
```

---

## Layout

```text
multi-warp/
├── mw                        # symlink → scripts/mw.sh
├── scripts/
│   ├── mw.sh                 # run | stop | status | restart (+ unique-IP loop)
│   ├── generate-compose.py   # build docker-compose.yml for N nodes
│   ├── up.sh                 # generate + start + healthcheck (no recreate loop)
│   ├── down.sh
│   ├── healthcheck.sh        # per-port exit IP (+ optional warp=on)
│   └── export-pool.sh        # write socks URL list
├── examples/
│   ├── curl-rotate.sh
│   ├── python-requests.py
│   └── docker-compose.5.yml  # sample checked-in compose (5 nodes)
├── docs/
│   ├── README.id.md          # panduan Bahasa Indonesia
│   └── troubleshooting.md
├── LICENSE
└── README.md
```

`data-n*` and `warp-pool.txt` are **gitignored** (runtime state / local pool).

---

## Security

- Default bind **`127.0.0.1`** — SOCKS is an open proxy to whoever can connect.
- Do **not** commit `data-n*` (device keys / registration).
- Cloudflare WARP **Terms of Service** apply to each identity — this is infra glue, not a ToS bypass product.
- Use for legitimate multi-egress needs (testing, geo checks, isolation). Abuse is on you.

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

Quick hits:

| Symptom | Fix |
|---|---|
| `/dev/net/tun` missing | `sudo modprobe tun` |
| All ports FAIL | `docker compose logs warp-n1` — wait 1–2 min first boot |
| All OK but **same IP** | `./mw run` recreate loop, or wipe one `data-nX` + recreate that service |
| Many `warp=off` after large `-n` | Start fewer nodes (10–15); recreate **serially** (`--recreate-batch 1`–`2`, longer `--recreate-wait`) |
| `rm: Operation not permitted` on `data-n*` | Root-owned files from container — use `./mw` wipe or alpine root mount (see Stop / wipe) |
| `healthy` in docker but curl FAIL | healthcheck vs host path — re-run `./scripts/healthcheck.sh` or `./mw status` |
| Permission / NET_ADMIN | run Docker as root or proper userns; avoid rootless without TUN |

---

## Credits

- Container image: [caomingjun/warp](https://github.com/caomingjun/warp)  
- Pattern extracted from real multi-exit farm ops (10× SOCKS on `40001–40010`)

## License

MIT — see [LICENSE](LICENSE).

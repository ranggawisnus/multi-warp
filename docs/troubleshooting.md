# Troubleshooting

## 1. `/dev/net/tun` missing

```bash
ls -l /dev/net/tun
sudo modprobe tun
# persist (Debian/Ubuntu):
echo tun | sudo tee /etc/modules-load.d/tun.conf
```

OpenVZ/some LXC: may need host enable TUN for the container.

## 2. Containers start then exit

```bash
docker compose ps -a
docker compose logs --tail=100 warp-n1
```

Common causes:

- no `NET_ADMIN`
- no TUN device mounted
- kernel too locked down
- image pull incomplete

## 3. Healthcheck all FAIL on first boot

WARP registration can take 30–90s per node under load.

```bash
sleep 60
./scripts/healthcheck.sh -n 10 --trace
```

Still fail → logs + try one node only:

```bash
python3 scripts/generate-compose.py -n 1 -o docker-compose.yml
docker compose up -d
./scripts/healthcheck.sh -n 1 --trace
```

## 4. All nodes healthy but **same public IP**

Mild: Cloudflare anycast can overlap — 10 nodes → ~6–9 unique is OK.

Bad: 10/10 identical forever.

Try:

```bash
docker compose restart warp-n3
# or hard reset one identity:
docker compose stop warp-n3
rm -rf data-n3
mkdir data-n3
docker compose up -d warp-n3
./scripts/healthcheck.sh -n 10
```

## 5. Docker says healthy, host curl fails

Container healthcheck hits `127.0.0.1:1080` **inside** the container.  
Host must use published port `4000x`.

```bash
docker port warp-n1
curl -x socks5h://127.0.0.1:40001 https://api.ipify.org
```

If you bound `127.0.0.1` only, remote hosts cannot connect — by design.

## 6. Port already allocated

```bash
ss -lptn | grep 4000
# change base:
python3 scripts/generate-compose.py -n 10 --base-port 41001 -o docker-compose.yml
```

## 7. `socks5` vs `socks5h`

| Scheme | DNS |
|---|---|
| `socks5h://` | resolved **through** proxy (good for curl/requests) |
| `socks5://` | often local DNS (many browsers want this) |

Mismatch → weird timeouts or IP leaks in apps.

## 8. Resource usage

Rough ballpark per node: tens of MB RAM + a WireGuard path.  
10 nodes on a 2–4 vCPU / 4 GB VPS is usually fine; 30+ needs headroom.

## 9. Legal / ToS

You are responsible for Cloudflare WARP ToS and local law.  
This repo only orchestrates containers.

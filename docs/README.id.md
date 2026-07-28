# multi-warp (Bahasa Indonesia)

**Banyak exit Cloudflare WARP sekaligus, masing-masing jadi SOCKS5 lokal.**

Cocok buat farm browser, multi-akun, atau tool yang butuh **beberapa IP egress** tanpa beli proxy mahal.

## Kenapa

1 IP VPS / 1 WARP → gampang ke-limit.

multi-warp = **N container Docker**, tiap container:

- volume data sendiri → identitas WARP sendiri  
- port SOCKS sendiri (`40001`, `40002`, …)  
- default **hanya localhost** (aman)

## Syarat

- VPS Linux + Docker  
- ada `/dev/net/tun`  
- container boleh `NET_ADMIN`

## Pasang cepat (10 exit)

```bash
git clone https://github.com/Micolaabdi/multi-warp.git
cd multi-warp
chmod +x scripts/*.sh
COUNT=10 ./scripts/up.sh
```

Cek:

```bash
./scripts/healthcheck.sh -n 10 --trace
cat warp-pool.txt
```

Contoh isi pool:

```text
socks5://127.0.0.1:40001
socks5://127.0.0.1:40002
```

## Pakai di tool

- **curl:** `curl --proxy socks5h://127.0.0.1:40001 https://api.ipify.org`  
- **Browser / Playwright:** sering harus `socks5://` (bukan `socks5h://`)  
- **Python:** `pip install "requests[socks]"` lalu `proxies={"http": "...", "https": "..."}`

## Jumlah node beda

```bash
python3 scripts/generate-compose.py -n 5 -o docker-compose.yml
COUNT=5 ./scripts/up.sh
```

## Buka ke mesin lain (hati-hati)

Jangan sembarangan `0.0.0.0` ke internet.

Lebih aman:

1. Bind tetap `127.0.0.1`  
2. Akses lewat **Tailscale / SSH tunnel**

Kalau terpaksa bind semua interface:

```bash
python3 scripts/generate-compose.py -n 5 --bind 0.0.0.0 -o docker-compose.yml
```

Lalu **firewall** hanya izinkan IP farm kamu ke port `40001–4000N`.

## Stop

```bash
./scripts/down.sh
```

Hapus identitas WARP (daftar ulang nanti):

```bash
rm -rf data-n*
```

## Masalah umum

| Gejala | Arti |
|---|---|
| Semua port FAIL | WARP belum ready / TUN rusak → cek log container |
| Semua OK tapi IP sama | Identitas belum beda / anycast sama → tunggu atau recreate 1 node |
| `tun` missing | `sudo modprobe tun` |

Detail: [troubleshooting.md](troubleshooting.md)

## Lisensi

MIT

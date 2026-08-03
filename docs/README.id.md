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

## Ukuran pool (penting)

| Target | Realistis |
|---|---|
| **10–15 exit** | **Normal / disarankan.** Biasanya stabil, unique IP mendekati N. |
| **~20 exit** | **Sulit.** Registrasi massal sering `warp=off` / hang; IP unik 20 butuh recreate serial + sabar; anycast Cloudflare sering overlap. |
| **30+** | Tidak praktis di 1 host kalau target “semua IP beda”. |

## Pasang cepat (disarankan: `mw`)

```bash
git clone https://github.com/Micolaabdi/multi-warp.git
cd multi-warp
chmod +x scripts/*.sh mw

./mw run -n 10          # sweet spot
./mw status -n 10
./mw stop
```

`./mw run` regenerate compose jika `-n` berubah, probe tiap port, recreate node jelek (FAIL / `warp≠on` / IP duplikat) sampai unique atau habis round.

```bash
# 15 biasanya masih OK
./mw run -n 15 --max-rounds 12 --recreate-wait 90

# 20 sulit — batch kecil
./mw run -n 20 --recreate-batch 2 --recreate-wait 90
```

Klasik (tanpa loop unique-IP):

```bash
COUNT=10 ./scripts/up.sh
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
./mw run -n 5
# atau:
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
./mw stop
# atau: ./scripts/down.sh
```

Hapus identitas WARP (daftar ulang nanti). Isi `data-n*` sering milik root (dari container) — `rm -rf` di host bisa gagal; `./mw run` sudah wipe lewat container helper saat recreate.

## Masalah umum

| Gejala | Arti |
|---|---|
| Semua port FAIL | WARP belum ready / TUN rusak → cek log container |
| Semua OK tapi IP sama | Identitas belum beda / anycast sama → `./mw run` atau recreate 1 node |
| Banyak `warp=off` di `-n` besar | Turunkan ke 10–15; recreate serial (`--recreate-batch 1`) |
| `tun` missing | `sudo modprobe tun` |

Detail: [troubleshooting.md](troubleshooting.md)

## Lisensi

MIT

#!/usr/bin/env python3
"""Round-robin requests through multi-warp SOCKS exits.

  pip install "requests[socks]" PySocks
  python3 examples/python-requests.py
"""
from __future__ import annotations

from itertools import cycle
import sys

try:
    import requests
except ImportError:
    print("pip install \"requests[socks]\" PySocks", file=sys.stderr)
    raise SystemExit(1)

BASE_PORT = 40001
COUNT = 10
HOST = "127.0.0.1"

POOL = [f"socks5h://{HOST}:{BASE_PORT + i}" for i in range(COUNT)]
proxy_cycle = cycle(POOL)


def fetch_ip(proxy_url: str) -> str:
    proxies = {"http": proxy_url, "https": proxy_url}
    r = requests.get("https://api.ipify.org", proxies=proxies, timeout=15)
    r.raise_for_status()
    return r.text.strip()


def main() -> None:
    seen = {}
    for i in range(COUNT):
        proxy = next(proxy_cycle)
        try:
            ip = fetch_ip(proxy)
            seen[ip] = seen.get(ip, 0) + 1
            print(f"{proxy} -> {ip}")
        except Exception as e:
            print(f"{proxy} -> ERROR: {e}")
    print(f"unique_ips={len(seen)} detail={seen}")


if __name__ == "__main__":
    main()

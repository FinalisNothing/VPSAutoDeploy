#!/usr/bin/env python3
"""Turn a vless:// share link into a client config with a SOCKS inbound.

usage: link2client.py LINK SOCKS_PORT [ADDRESS_OVERRIDE] > client.json
Follows the share link standard (XTLS/Xray-core discussion #716); type=tcp is RAW.
TLS clients trust the OS CA store (useSystemCA), where the test CA is installed;
by default xray >= 26.10.10 trusts only its built-in roots.
"""
import json
import re
import sys
from urllib.parse import unquote


def parse(link):
    m = re.match(r"^vless://([^@]+)@(\[[^\]]+\]|[^:/?#]+):(\d+)\?([^#]*)(?:#(.*))?$", link)
    if not m:
        sys.exit(f"not a vless link: {link[:60]}")
    q = {}
    for kv in m.group(4).split("&"):
        k, _, v = kv.partition("=")
        q[k] = unquote(v)
    return m.group(1), m.group(2).strip("[]"), int(m.group(3)), q


def outbound(link, address=None):
    uuid, host, port, q = parse(link)
    net, sec = q.get("type", "tcp"), q.get("security", "none")
    settings = {"address": address or host, "port": port, "id": uuid, "encryption": q.get("encryption", "none")}
    if q.get("flow"):
        settings["flow"] = q["flow"]
    stream = {"network": "raw" if net == "tcp" else net, "security": sec}
    if net == "xhttp":
        stream["xhttpSettings"] = {k: q[k] for k in ("path", "host", "mode") if k in q}
    if sec == "tls":
        stream["tlsSettings"] = {"serverName": q.get("sni", host), "fingerprint": q.get("fp", "chrome"),
                                 "useSystemCA": True}
        if "alpn" in q:
            stream["tlsSettings"]["alpn"] = q["alpn"].split(",")
    elif sec == "reality":
        stream["realitySettings"] = {
            "serverName": q.get("sni", host), "fingerprint": q["fp"], "password": q["pbk"],
            "shortId": q.get("sid", ""), "spiderX": q.get("spx", ""), "mldsa65Verify": q.get("pqv", ""),
        }
    return {"tag": "proxy", "protocol": "vless", "settings": settings, "streamSettings": stream}


def main():
    link, socks_port = sys.argv[1], int(sys.argv[2])
    address = sys.argv[3] if len(sys.argv) > 3 else None
    cfg = {
        "log": {"loglevel": "warning"},
        "inbounds": [{"listen": "127.0.0.1", "port": socks_port, "protocol": "socks", "settings": {"udp": True}}],
        "outbounds": [outbound(link, address)],
    }
    json.dump(cfg, sys.stdout, indent=1)


if __name__ == "__main__":
    main()

# Scheme `nginx-xray-443-fallback`

xray owns TCP 443 and answers with VLESS + REALITY. REALITY's target is the
local nginx on a unix socket, so every TLS connection that is not a REALITY
client — browsers, scanners, the Cloudflare CDN — is handed to nginx (PROXY
protocol, real client IP preserved) and routed there by SNI.

```
TCP 443 ─> xray REALITY ── REALITY client ─> VLESS
              │                  ├─ Vision (RAW)                   reality_in
              │                  └─ not VLESS: fallback ─> XHTTP   xhttp_reality_in
              └─ anything else ─> nginx  (unix:/dev/shm/uds8443.sock)
                    ├─ DIRECT_DOMAIN  camouflage site mirroring BACKEND_WEB,
                    │                 /XHTTP_PATH ─> XHTTP         xhttp_tls_in
                    ├─ CDN_DOMAIN     (Cloudflare origin certificate) the same, via CDN
                    └─ unknown SNI    handshake rejected
nginx also owns TCP 80 (ACME, redirect to HTTPS) and UDP 443 (HTTP/3 for the site).
```

## Client entries

`phase2-deploy.sh --links` prints one share link per entry:

| Link | Transport | Security | Reaches |
|---|---|---|---|
| `<direct> REALITY Vision` | RAW, `xtls-rprx-vision` | REALITY (+ ML-DSA-65 `pqv`) | `reality_in` |
| `<direct> XHTTP REALITY` | XHTTP | REALITY (+ ML-DSA-65 `pqv`) | `xhttp_reality_in` via VLESS fallback |
| `<direct> XHTTP TLS` | XHTTP, `alpn=h2` | TLS by nginx (ZeroSSL) + VLESS Encryption (ML-KEM-768) | `xhttp_tls_in` |
| `<cdn> XHTTP CDN` | XHTTP, `alpn=h2` | TLS by Cloudflare + VLESS Encryption (ML-KEM-768) | `xhttp_tls_in` |

Clients should run a current Xray-core: the REALITY entries carry the ML-DSA-65
verify key (`pqv`), the TLS/CDN entries VLESS Encryption, and the scheme is
verified against the release pinned in `scheme.sh`.

## What you prepare

In the Cloudflare dashboard, before running phase2 (the guide repeats this and
checks each item):

1. DNS: `A` record for the direct domain → the VPS's IPv4, **DNS only**.
2. DNS: `A` record for the CDN domain → the VPS's IPv4, **Proxied**.
3. SSL/TLS → Overview: **Full (strict)**.
4. SSL/TLS → Origin Server: an Origin Certificate (PEM) covering the CDN
   domain, saved as `cf-fullchain.pem` + `cf-privkey.pem` (upload or paste).
5. Provider firewall / security group, if any: TCP 80, TCP 443, UDP 443.

## Inputs

| Input | |
|---|---|
| `ACME_EMAIL` | ZeroSSL account |
| `DIRECT_DOMAIN` | REALITY server name, camouflage site, XHTTP over TLS |
| `CDN_DOMAIN` | XHTTP through Cloudflare |
| `BACKEND_WEB` | the website the camouflage site mirrors — no default, every deployment picks its own (see the guide's advice) |
| `XHTTP_PATH` | XHTTP path behind nginx (random by default) |
| advanced | `XHTTP_REALITY_PATH`, link fingerprints |
| secrets | client UUIDs, REALITY private key / ML-DSA-65 seed / shortId, VLESS decryption — generated on the VPS when empty |

## Egress

Where traffic leaves the VPS is not part of this scheme: `xray.json` holds the
inbounds only, and the deployment composes it with the machine's egress
policy (see "Egress" in the top-level README).

## Values that only work together

- REALITY `serverNames` is `DIRECT_DOMAIN`: the name nginx serves on the target.
- `mldsa65Seed` makes REALITY pad its handshake to the target's certificate
  message; the chain nginx serves for `DIRECT_DOMAIN` must exceed 3500 bytes or
  REALITY handshakes fail. The ZeroSSL RSA-4096 fullchain does; `--status`
  measures it.
- VLESS Encryption excludes fallbacks, so the REALITY inbound (which falls back
  to the XHTTP REALITY inbound) keeps `decryption: none`.
- The unix socket paths are constants in `scheme.sh`, rendered into both
  `nginx.conf` and `xray.json`.
- `loglevel: debug` — logs rotate daily, 7 kept.

## Idle connections

A proxied connection with no traffic in either direction is closed by xray
after 300 s (its `connIdle` policy). The XHTTP locations in `nginx.conf` wait
315 s, so nginx never cuts one first (its 60 s defaults did). Through the CDN,
Cloudflare closes an idle connection after about 100 s, whatever the origin
allows; applications that stay silent longer (SSH without keepalives, …) should
use another entry or send keepalives.

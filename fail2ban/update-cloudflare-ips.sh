#!/bin/bash
# /usr/local/bin/update-cloudflare-ips.sh
#
# Updates Cloudflare IP ranges in:
# 1) nginx geo file (/nginx/conf/cloudflare-ips.geo)
#    — nginx.conf 中 geo $conn_src_ip $from_cf 依赖此文件判断 CF 流量。
#      若 geo 文件过期而 CF 新增 IP 段, 这些新 IP 段的请求会被误判为非 CF 流量,
#      导致 $client_ip 记录 CF 边缘 IP 而非用户真实 IP。
# 2) /etc/fail2ban/jail.local [DEFAULT] ignoreip block
#    — 保留你的手动自定义 ignoreip 条目, 仅刷新 Cloudflare 范围。

set -euo pipefail

CF_V4_URL="https://www.cloudflare.com/ips-v4"
CF_V6_URL="https://www.cloudflare.com/ips-v6"

NGINX_GEO="/nginx/conf/cloudflare-ips.geo"
JAIL_LOCAL="/etc/fail2ban/jail.local"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: Please run as root."
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "[*] Fetching Cloudflare IP ranges..."
curl -fsS --connect-timeout 10 --max-time 30 "$CF_V4_URL" > "$TMPDIR/v4.txt"
curl -fsS --connect-timeout 10 --max-time 30 "$CF_V6_URL" > "$TMPDIR/v6.txt"

# Validate: CF currently publishes ~15 v4 and ~7 v6 ranges
if [ "$(wc -l < "$TMPDIR/v4.txt")" -lt 10 ] || [ "$(wc -l < "$TMPDIR/v6.txt")" -lt 3 ]; then
    echo "ERROR: Downloaded Cloudflare IP list is suspiciously short. Aborting."
    exit 1
fi

# --- Update nginx geo file ---
echo "[*] Updating nginx geo: $NGINX_GEO"
{
    echo "# Cloudflare IP ranges - auto-updated $(date -Iseconds)"
    echo "# Source: $CF_V4_URL + $CF_V6_URL"
    # NOTE: 不要在此文件中写 default 0; 因为 nginx.conf 的 geo 块已经定义了 default

    while IFS= read -r cidr; do
        [ -n "$cidr" ] && echo "$cidr 1;"
    done < "$TMPDIR/v4.txt"

    while IFS= read -r cidr; do
        [ -n "$cidr" ] && echo "$cidr 1;"
    done < "$TMPDIR/v6.txt"
} > "$TMPDIR/cloudflare-ips.geo"

cp "$TMPDIR/cloudflare-ips.geo" "$NGINX_GEO"
chown root:root "$NGINX_GEO"
chmod 644 "$NGINX_GEO"

# --- Update fail2ban ignoreip block (preserve custom manual entries) ---
echo "[*] Updating fail2ban ignoreip in $JAIL_LOCAL"

if [ ! -f "$JAIL_LOCAL" ]; then
    echo "ERROR: $JAIL_LOCAL not found"
    exit 1
fi

JAIL_BACKUP="${JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
cp "$JAIL_LOCAL" "$JAIL_BACKUP"
echo "[*] Backup created: $JAIL_BACKUP"

export TMPDIR JAIL_LOCAL

python3 - <<'PY2'
import os
import re
from pathlib import Path

tmpdir = Path(os.environ["TMPDIR"])
jail_path = Path(os.environ["JAIL_LOCAL"])

v4 = (tmpdir / "v4.txt").read_text().splitlines()
v6 = (tmpdir / "v6.txt").read_text().splitlines()
cloudflare = [x.strip() for x in v4 + v6 if x.strip()]
cf_set = set(cloudflare)

content = jail_path.read_text()

pattern = re.compile(r"(^\s*ignoreip\s*=\s*[^\n]*(?:\n\s{2,}[^\n]*)*)", re.MULTILINE)
m = pattern.search(content)
if not m:
    raise SystemExit("ERROR: ignoreip block not found in jail.local")

block = m.group(1)
lines = block.splitlines()

# Extract all entries including the first line's value (new version fix)
entries = []
for idx, line in enumerate(lines):
    if idx == 0:
        rhs = line.split("=", 1)[1] if "=" in line else ""
        entries.extend(rhs.split())
    else:
        entries.extend(line.strip().split())

manual_raw = [entry for entry in entries if entry and entry not in cf_set]

# De-duplicate while preserving order; force localhost entries at top
seen = set()
manual = []
for entry in ["127.0.0.1/8", "::1"] + manual_raw:
    if entry not in seen:
        seen.add(entry)
        manual.append(entry)

combined = manual[:]
for entry in cloudflare:
    if entry not in seen:
        seen.add(entry)
        combined.append(entry)

prefix_match = re.match(r"^(\s*ignoreip\s*=)", lines[0])
prefix = prefix_match.group(1) if prefix_match else "ignoreip ="

new_lines = [f"{prefix} {combined[0]}"]
for entry in combined[1:]:
    new_lines.append(f"           {entry}")

new_block = "\n".join(new_lines)
new_content = content[:m.start(1)] + new_block + content[m.end(1):]
jail_path.write_text(new_content)
PY2

# --- Validate and reload services ---
echo "[*] Validating nginx config..."
/nginx/sbin/nginx -t

echo "[*] Validating fail2ban config..."
fail2ban-client -t >/dev/null

echo "[*] Reloading nginx..."
/nginx/sbin/nginx -s reload

echo "[*] Reloading fail2ban..."
fail2ban-client reload

echo "[+] Done. Cloudflare IPs updated successfully."
echo "    IPv4 ranges: $(wc -l < "$TMPDIR/v4.txt")"
echo "    IPv6 ranges: $(wc -l < "$TMPDIR/v6.txt")"

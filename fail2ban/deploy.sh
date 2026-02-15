#!/bin/bash
# deploy.sh - Deploy fail2ban configuration to VPS
# Run as root on the VPS after uploading the fail2ban/ directory.
#
# Usage:
#   sudo bash deploy.sh
#
# This script:
# 1. Copies jail.local and custom filters
# 2. Tests filter syntax (config test + regex validation)
# 3. Enables and starts fail2ban
# 4. Sets up the Cloudflare IP update cron job
# 5. Checks nginx dependency configuration
# 6. Shows status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_STAMP="$(date +%Y%m%d%H%M%S)"

SSH_PORT_INPUT="${SSH_PORT:-}"

if [ -z "$SSH_PORT_INPUT" ]; then
    read -r -p "Enter SSH port for [sshd] jail [22]: " SSH_PORT_INPUT || true
fi

SSH_PORT_INPUT="${SSH_PORT_INPUT:-22}"

if ! [[ "$SSH_PORT_INPUT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT_INPUT" -lt 1 ] || [ "$SSH_PORT_INPUT" -gt 65535 ]; then
    echo "ERROR: Invalid SSH port: $SSH_PORT_INPUT"
    exit 1
fi

SSH_PORT="$SSH_PORT_INPUT"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo bash deploy.sh)."
    exit 1
fi

echo "============================================"
echo "  fail2ban Deployment for Xray+Nginx+UFW"
echo "============================================"
echo "  SSH jail port: $SSH_PORT"

# --- Check prerequisites ---
echo ""
echo "[1/8] Checking prerequisites..."

if ! command -v fail2ban-client &>/dev/null; then
    echo "  Installing fail2ban..."
    apt update && apt install -y fail2ban
fi

if ! command -v ufw &>/dev/null; then
    echo "  ERROR: ufw not found. Install it first."
    exit 1
fi

if [ ! -f /nginx/logs/access.log ]; then
    echo "  WARNING: /nginx/logs/access.log not found."
    echo "  Creating empty log for fail2ban startup..."
    touch /nginx/logs/access.log
fi

if [ ! -f /nginx/logs/error.log ]; then
    echo "  WARNING: /nginx/logs/error.log not found."
    echo "  Creating empty log for fail2ban startup..."
    touch /nginx/logs/error.log
fi

# --- Backup existing config ---
echo ""
echo "[2/8] Backing up existing configuration..."

BACKUP_DIR="/etc/fail2ban/backup-${BACKUP_STAMP}"
mkdir -p "$BACKUP_DIR"

if [ -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.local "$BACKUP_DIR/jail.local"
fi

for f in /etc/fail2ban/filter.d/nginx-sslerror.conf \
         /etc/fail2ban/filter.d/nginx-path-scan.conf \
         /etc/fail2ban/filter.d/nginx-4xx-flood.conf \
         /etc/fail2ban/filter.d/nginx-protocol-probe.conf \
         /etc/fail2ban/filter.d/nginx-scanner-ua.conf \
         /etc/fail2ban/filter.d/botsearch-common.local; do
    [ -f "$f" ] && cp "$f" "$BACKUP_DIR/"
done

[ -f /usr/local/bin/update-cloudflare-ips.sh ] && cp /usr/local/bin/update-cloudflare-ips.sh "$BACKUP_DIR/"

if crontab -l >/dev/null 2>&1; then
    crontab -l > "$BACKUP_DIR/root.crontab"
fi

echo "  Backup saved to $BACKUP_DIR"

# --- Deploy config files ---
echo ""
echo "[3/8] Deploying configuration files..."

cp "$SCRIPT_DIR/jail.local" /etc/fail2ban/jail.local
sed -i "/^\[sshd\]/,/^\[/ s/^[[:space:]]*port[[:space:]]*=.*/port     = ${SSH_PORT}/" /etc/fail2ban/jail.local

if ! awk '
/^\[sshd\]$/ { in_sshd=1; next }
in_sshd && /^\[/ { in_sshd=0 }
in_sshd && /^[[:space:]]*port[[:space:]]*=[[:space:]]*[0-9]+/ { ok=1 }
END { exit ok ? 0 : 1 }
' /etc/fail2ban/jail.local; then
    echo "  ERROR: Failed to set sshd port in jail.local"
    exit 1
fi

chown root:root /etc/fail2ban/jail.local
chmod 644 /etc/fail2ban/jail.local
echo "  Deployed jail.local"
echo "  Set [sshd] port = $SSH_PORT"

for filter in "$SCRIPT_DIR"/filter.d/*.conf "$SCRIPT_DIR"/filter.d/*.local; do
    [ -f "$filter" ] || continue
    fname=$(basename "$filter")
    cp "$filter" "/etc/fail2ban/filter.d/$fname"
    chown root:root "/etc/fail2ban/filter.d/$fname"
    chmod 644 "/etc/fail2ban/filter.d/$fname"
    echo "  Deployed filter.d/$fname"
done

# --- Deploy update script ---
echo ""
echo "[4/8] Deploying Cloudflare IP update script..."

cp "$SCRIPT_DIR/update-cloudflare-ips.sh" /usr/local/bin/update-cloudflare-ips.sh
chown root:root /usr/local/bin/update-cloudflare-ips.sh
chmod 700 /usr/local/bin/update-cloudflare-ips.sh
echo "  Deployed /usr/local/bin/update-cloudflare-ips.sh"

# Run immediately if nginx geo file doesn't exist (first deploy)
NGINX_GEO="/nginx/conf/cloudflare-ips.geo"
if [ ! -f "$NGINX_GEO" ]; then
    echo "  $NGINX_GEO not found, running initial Cloudflare IP update..."
    /usr/local/bin/update-cloudflare-ips.sh
elif ! /nginx/sbin/nginx -t 2>/dev/null; then
    echo "  nginx config test failed, re-running Cloudflare IP update..."
    /usr/local/bin/update-cloudflare-ips.sh
fi

# --- Test filter syntax ---
echo ""
echo "[5/8] Testing configuration and filters..."

# Full config test
echo "  Running fail2ban config test..."
if ! fail2ban-client -t 2>&1; then
    echo "  ERROR: fail2ban configuration test failed!"
    echo "  Fix the errors above, then re-run this script."
    exit 1
fi
echo "  Configuration test: PASSED"

# Test custom filters against actual log files with fail2ban-regex
declare -A FILTER_LOGS=(
    ["nginx-sslerror"]="/nginx/logs/error.log"
    ["nginx-path-scan"]="/nginx/logs/access.log"
    ["nginx-4xx-flood"]="/nginx/logs/access.log"
    ["nginx-bad-request"]="/nginx/logs/access.log"
    ["nginx-protocol-probe"]="/nginx/logs/access.log"
    ["nginx-scanner-ua"]="/nginx/logs/access.log"
)

for filter in "${!FILTER_LOGS[@]}"; do
    filter_file="/etc/fail2ban/filter.d/${filter}.conf"
    log_file="${FILTER_LOGS[$filter]}"

    if [ ! -f "$filter_file" ]; then
        continue
    fi

    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        echo "  Testing $filter against $log_file..."
        result=$(fail2ban-regex "$log_file" "$filter_file" 2>&1) || true
        # Extract match summary
        matched=$(echo "$result" | grep -oP 'Lines: \K.*' || echo "parse ok, no summary")
        echo "    $matched"
    else
        echo "  Filter $filter: deployed (log empty or missing, skipping regex test)"
    fi
done

# --- Setup cron for CF IP updates ---
echo ""
echo "[6/8] Setting up monthly Cloudflare IP update cron..."

CRON_LINE="0 3 1 * * /usr/local/bin/update-cloudflare-ips.sh >> /var/log/cf-ip-update.log 2>&1"

# Read existing crontab, remove old entry, add new one
{
    crontab -l 2>/dev/null | grep -v "update-cloudflare-ips" || true
    echo "$CRON_LINE"
} | crontab -

echo "  Cron job added: runs 1st of each month at 03:00"

# --- Enable and start ---
echo ""
echo "[7/8] Enabling and starting fail2ban..."

systemctl enable fail2ban
systemctl restart fail2ban

sleep 2

# --- Check nginx dependency configuration ---
echo ""
echo "[8/8] Checking nginx configuration dependencies..."

NGINX_CONF_DIR="/nginx/conf"
NGINX_WARNINGS=0

# Check for limit_req_zone (needed by nginx-limit-req jail)
if [ -d "$NGINX_CONF_DIR" ]; then
    if ! grep -rq 'limit_req_zone' "$NGINX_CONF_DIR"/ 2>/dev/null; then
        echo "  WARNING: nginx 未配置 limit_req_zone"
        echo "    → [nginx-limit-req] jail 将空转 (已启用但无日志可匹配)"
        echo "    → 参考 nginx-additions.conf 第 1 节添加 limit_req_zone 配置"
        NGINX_WARNINGS=$((NGINX_WARNINGS + 1))
    else
        echo "  OK: limit_req_zone detected → [nginx-limit-req] jail effective"
    fi

    # Check for deny rules (needed by nginx-forbidden jail)
    if ! grep -rq 'deny all' "$NGINX_CONF_DIR"/ 2>/dev/null; then
        echo "  WARNING: nginx 未配置 deny all 规则"
        echo "    → [nginx-forbidden] jail 将空转 (已启用但无日志可匹配)"
        echo "    → 参考 nginx-additions.conf 第 2 节添加 deny 规则"
        NGINX_WARNINGS=$((NGINX_WARNINGS + 1))
    else
        echo "  OK: deny rules detected → [nginx-forbidden] jail effective"
    fi
else
    echo "  WARNING: $NGINX_CONF_DIR not found, skipping nginx dependency checks"
    NGINX_WARNINGS=$((NGINX_WARNINGS + 1))
fi

echo ""
echo "============================================"
echo "  Deployment Complete"
echo "============================================"

if [ "$NGINX_WARNINGS" -gt 0 ]; then
    echo ""
    echo "  ⚠ $NGINX_WARNINGS nginx dependency warning(s) above."
    echo "  Apply nginx-additions.conf to enable full protection."
fi

echo ""
echo "Active jails:"
fail2ban-client status
echo ""
echo "--- Useful commands ---"
echo ""
echo "  # Check status of all jails"
echo "  fail2ban-client status"
echo ""
echo "  # Check specific jail"
echo "  fail2ban-client status sshd"
echo "  fail2ban-client status nginx-path-scan"
echo ""
echo "  # Test a filter against a log file"
echo "  fail2ban-regex /nginx/logs/access.log /etc/fail2ban/filter.d/nginx-path-scan.conf"
echo "  fail2ban-regex /nginx/logs/error.log /etc/fail2ban/filter.d/nginx-sslerror.conf"
echo ""
echo "  # Manually unban an IP"
echo "  fail2ban-client set sshd unbanip 1.2.3.4"
echo ""
echo "  # View fail2ban log"
echo "  tail -f /var/log/fail2ban.log"
echo ""
echo "  # View UFW rules (including fail2ban bans)"
echo "  ufw status numbered"
echo ""
echo "  # Update Cloudflare IPs manually"
echo "  /usr/local/bin/update-cloudflare-ips.sh"
echo ""

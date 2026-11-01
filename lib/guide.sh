#!/bin/bash
# lib/guide.sh - Helpers for a scheme's guide: explain what to prepare, then
# check that it is in place. Checks observe the real world (DNS answers,
# HTTP responses). When something cannot be checked they say so instead of
# passing silently, and a failed check asks before continuing.

guide_text() {
    local line
    echo ""
    while IFS= read -r line; do
        printf "  ${CYAN}│${NC} %s\n" "$line"
    done
    echo ""
}

# Public IPv4 of this machine, from several independent sources.
public_ipv4() {
    local url ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip="$(curl -fsS4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# A records of a domain: the system resolver, then DNS-over-HTTPS (which also
# sidesteps a stale local cache right after the record was created).
resolve_a() {
    local domain="$1" ips
    ips="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)" || ips=""
    if [ -z "$ips" ]; then
        ips="$(curl -fsS --max-time 8 -H 'accept: application/dns-json' \
            "https://cloudflare-dns.com/dns-query?name=$domain&type=A" 2>/dev/null \
            | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null | sort -u)" || ips=""
    fi
    [ -z "$ips" ] || printf '%s\n' "$ips"
}

ip4_to_int() {
    local IFS=.
    # shellcheck disable=SC2086
    set -- $1
    printf '%s' $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

ip4_in_cidr() {
    local ip net bits mask
    ip="$(ip4_to_int "$1")"
    net="$(ip4_to_int "${2%/*}")"
    bits="${2#*/}"
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( ip & mask )) -eq $(( net & mask )) ]
}

guide_problem() {
    msg_warn "$1"
    [ -n "${2:-}" ] && msg_warn "$2"
    confirm "Continue anyway?" || die "Stopped. Fix the above, then run phase2-deploy.sh again."
}

# The domain must resolve to this VPS, without a CDN in between.
guide_check_points_here() {
    local domain="$1" mine ips
    ips="$(resolve_a "$domain")"
    if [ -z "$ips" ]; then
        guide_problem "$domain has no A record yet." "Create it (DNS only) and wait until it resolves."
        return 0
    fi
    if ! mine="$(public_ipv4)"; then
        guide_problem "Cannot determine this VPS's public IPv4, so '$domain -> $(paste -sd' ' <<<"$ips")' is unverified."
        return 0
    fi
    if grep -qxF "$mine" <<<"$ips"; then
        msg_ok "$domain resolves to this VPS ($mine)"
    else
        guide_problem "$domain resolves to $(paste -sd' ' <<<"$ips"), but this VPS is $mine." \
            "If the record is proxied by a CDN, switch it to DNS only."
    fi
}

# The domain must resolve to Cloudflare edge addresses (orange cloud).
guide_check_behind_cloudflare() {
    local domain="$1" ips cidrs ip c ok=1
    ips="$(resolve_a "$domain")"
    if [ -z "$ips" ]; then
        guide_problem "$domain has no A record yet." "Create it with proxy status Proxied (orange cloud)."
        return 0
    fi
    if ! cidrs="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null)"; then
        guide_problem "Cannot fetch Cloudflare's IP ranges, so '$domain is proxied' is unverified."
        return 0
    fi
    while IFS= read -r ip; do
        local hit=0
        while IFS= read -r c; do
            [ -n "$c" ] && ip4_in_cidr "$ip" "$c" && { hit=1; break; }
        done <<<"$cidrs"
        [ "$hit" -eq 1 ] || ok=0
    done <<<"$ips"
    if [ "$ok" -eq 1 ]; then
        msg_ok "$domain is proxied by Cloudflare"
    else
        guide_problem "$domain resolves to $(paste -sd' ' <<<"$ips"), which is not Cloudflare." \
            "Set the record's proxy status to Proxied (orange cloud)."
    fi
}

guide_check_https() {
    local domain="$1" code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$domain/" 2>/dev/null || true)"
    if [[ "$code" =~ ^[23] ]]; then
        msg_ok "https://$domain/ answers ($code)"
    else
        guide_problem "https://$domain/ does not answer normally (HTTP ${code:-no response})."
    fi
}

guide_check_ipv6_egress() {
    local why="$1" code
    code="$(curl -6 -sS -o /dev/null -w '%{http_code}' --max-time 10 https://www.google.com/generate_204 2>/dev/null || true)"
    if [ "$code" = 204 ]; then
        msg_ok "IPv6 egress works"
    else
        guide_problem "This VPS has no working IPv6 egress (HTTP ${code:-no response})." "$why"
    fi
}

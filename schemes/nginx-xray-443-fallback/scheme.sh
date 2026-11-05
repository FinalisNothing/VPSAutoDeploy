#!/bin/bash
# schemes/nginx-xray-443-fallback/scheme.sh
#
# xray owns TCP 443 and answers with VLESS + REALITY. REALITY's target is the
# local nginx on a unix socket, so every TLS connection that is not a REALITY
# client (browsers, scanners, the Cloudflare CDN) is handed to nginx with the
# PROXY protocol and routed there by SNI:
#
#   TCP 443 -> xray REALITY --- REALITY client --> VLESS
#                   |                 |- Vision (RAW)                  reality_in
#                   |                 '- not VLESS: fallback -> XHTTP  xhttp_reality_in
#                   '- anything else -> nginx (NGINX_TLS_SOCK)
#                         |- DIRECT_DOMAIN: camouflage site mirroring BACKEND_WEB,
#                         |                 /XHTTP_PATH -> XHTTP        xhttp_tls_in
#                         |- CDN_DOMAIN (Cloudflare origin certificate): the same, via CDN
#                         '- unknown SNI: handshake rejected
#   nginx also owns TCP 80 (ACME, redirect) and UDP 443 (HTTP/3 for the site).
#
# Values that only work together - change them together or not at all:
#   - REALITY serverNames is DIRECT_DOMAIN: the name nginx serves on the target.
#   - mldsa65Seed makes REALITY pad its handshake to the target's certificate
#     message; the target chain must exceed 3500 bytes or REALITY handshakes
#     fail. The ZeroSSL RSA-4096 fullchain does; scheme_verify measures it.
#   - VLESS Encryption cannot be combined with fallbacks: the REALITY inbound
#     (which has the fallback) keeps decryption "none".
#   - The unix socket paths appear in both templates and are filled from the
#     constants below, so nginx and xray cannot disagree about them.

# shellcheck disable=SC2034 # the SCHEME_* variables are read by lib/engine.sh
SCHEME_TITLE="xray on 443: REALITY (Vision, XHTTP) + XHTTP over TLS and Cloudflare CDN, nginx behind REALITY"
SCHEME_SUMMARY=(
    "Four client entries, all on TCP 443: VLESS REALITY Vision; XHTTP over REALITY; XHTTP over TLS"
    "on the direct domain and through the Cloudflare CDN (both with VLESS post-quantum encryption)."
    "Everything else reaches nginx: a camouflage site mirroring another website, HTTP/3 included."
    "You need: two domains on Cloudflare DNS (direct: DNS only, CDN: proxied), a Cloudflare Origin"
    "Certificate for the CDN domain, and an email for ZeroSSL."
)
SCHEME_PORTS=(tcp/80 tcp/443 udp/443)
SCHEME_COMPONENTS=(nginx xray)
SCHEME_XRAY_VERSION=26.10.31

NGINX_TLS_SOCK=/dev/shm/uds8443.sock
XHTTP_TLS_SOCK=/dev/shm/uds2023.sock
XHTTP_REALITY_SOCK=/dev/shm/uds2024.sock

scheme_inputs() {
    input ACME_EMAIL      email  "Email for the ZeroSSL (ACME) account"
    input DIRECT_DOMAIN   domain "Direct domain (A record -> this VPS, DNS only)"
    input CDN_DOMAIN      domain "CDN domain (A record -> this VPS, proxied by Cloudflare)"
    input BACKEND_WEB     domain "Website the camouflage site mirrors" --default quarkus.io \
        --help "A real HTTPS site; visitors who are not proxy clients see its pages."
    input XHTTP_PATH      path   "XHTTP path behind nginx (TLS and CDN)" --default "$(random_alnum 32)"
    input XHTTP_REALITY_PATH path "XHTTP path over REALITY" --advanced --default "$(random_alnum 32)"
    input REALITY_FINGERPRINT word "uTLS fingerprint in the REALITY links" --advanced --default firefox
    input TLS_FINGERPRINT word   "uTLS fingerprint in the TLS/CDN links" --advanced --default chrome

    input VISION_UUID          uuid     "UUID of the REALITY Vision client" --secret
    input XHTTP_TLS_UUID       uuid     "UUID of the XHTTP TLS/CDN client" --secret
    input XHTTP_REALITY_UUID   uuid     "UUID of the XHTTP REALITY client" --secret
    input REALITY_PRIVATE_KEY  key32    "REALITY private key (xray x25519)" --secret
    input REALITY_MLDSA65_SEED key32    "REALITY ML-DSA-65 seed (xray mldsa65)" --secret
    input REALITY_SHORT_IDS    shortids "REALITY shortIds" --secret
    input XHTTP_TLS_DECRYPTION vlessdec "VLESS Encryption decryption string of xhttp_tls_in" --secret
}

scheme_guide() {
    guide_text <<'EOF'
Prepare this in the Cloudflare dashboard before you continue:
  1. DNS: an A record for the DIRECT domain -> this VPS's IPv4, proxy status "DNS only".
  2. DNS: an A record for the CDN domain    -> this VPS's IPv4, proxy status "Proxied".
  3. SSL/TLS -> Overview: encryption mode "Full (strict)".
  4. SSL/TLS -> Origin Server: create an Origin Certificate (PEM) covering the CDN
     domain. Save the certificate as cf-fullchain.pem and the key as cf-privkey.pem;
     you can upload both now or paste them when asked.
If your provider has its own firewall / security group: open TCP 80, TCP 443, UDP 443.
EOF
    ask ACME_EMAIL
    ask DIRECT_DOMAIN
    guide_check_points_here "$(param DIRECT_DOMAIN)"
    ask CDN_DOMAIN
    [ "$(param CDN_DOMAIN)" != "$(param DIRECT_DOMAIN)" ] || die "CDN_DOMAIN must differ from DIRECT_DOMAIN."
    guide_check_behind_cloudflare "$(param CDN_DOMAIN)"
    ask BACKEND_WEB
    guide_check_https "$(param BACKEND_WEB)"
    ask XHTTP_PATH
    ask_file CF_ORIGIN_CERT cf-fullchain.pem pem_cert_valid "Cloudflare Origin Certificate for $(param CDN_DOMAIN)"
    ask_file CF_ORIGIN_KEY cf-privkey.pem pem_key_valid "Cloudflare Origin Certificate private key"
    if ! cert_key_match "$SCHEME_STATE/files/CF_ORIGIN_CERT" "$SCHEME_STATE/files/CF_ORIGIN_KEY"; then
        rm -f "$SCHEME_STATE/files/CF_ORIGIN_CERT" "$SCHEME_STATE/files/CF_ORIGIN_KEY"
        die "cf-fullchain.pem and cf-privkey.pem do not belong together. Provide a matching pair and re-run."
    fi
    if ! cert_covers "$SCHEME_STATE/files/CF_ORIGIN_CERT" "$(param CDN_DOMAIN)"; then
        guide_problem "The origin certificate does not cover $(param CDN_DOMAIN)."
    fi
}

scheme_deploy() {
    step firewall   "Firewall: allow ${SCHEME_PORTS[*]}"            fw_open "${SCHEME_PORTS[@]}"
    step nginx      "nginx (custom build) and nginx.service"         nginx_install_and_service
    step acme       "Certificate for $(param DIRECT_DOMAIN) (ZeroSSL, RSA 4096)" \
                    acme_ensure "$(param DIRECT_DOMAIN)" "$(param ACME_EMAIL)" 4096
    step cdn-cert   "Origin certificate for $(param CDN_DOMAIN)" \
                    cert_install_pair "$(param CDN_DOMAIN)" "$SCHEME_STATE/files/CF_ORIGIN_CERT" "$SCHEME_STATE/files/CF_ORIGIN_KEY"
    step nginx-conf "nginx.conf"                                      scheme_nginx_conf
    step fail2ban   "fail2ban jails for nginx"                        fail2ban_nginx
    step xray       "Xray-core v${XRAY_VERSION:-$SCHEME_XRAY_VERSION}" xray_install "${XRAY_VERSION:-$SCHEME_XRAY_VERSION}"
    step keys       "Client UUIDs and keys"                           scheme_keys
    step xray-conf  "xray config"                                     scheme_xray_conf
}

nginx_install_and_service() {
    nginx_install
    nginx_service
}

scheme_values() {
    local -n _sv="$1"
    local k
    for k in "${!PARAMS[@]}"; do _sv[$k]="${PARAMS[$k]}"; done
    _sv[NGINX_TLS_SOCK]="$NGINX_TLS_SOCK"
    _sv[XHTTP_TLS_SOCK]="$XHTTP_TLS_SOCK"
    _sv[XHTTP_REALITY_SOCK]="$XHTTP_REALITY_SOCK"
    _sv[DIRECT_CERT_DIR]="$(cert_dir "${PARAMS[DIRECT_DOMAIN]}")"
    _sv[CDN_CERT_DIR]="$(cert_dir "${PARAMS[CDN_DOMAIN]}")"
}

scheme_nginx_conf() {
    local tmp
    # shellcheck disable=SC2034 # read by render_template through a nameref
    local -A vals=()
    scheme_values vals
    # nginx.conf includes cloudflare-ips.geo, so it must exist first
    cloudflare_ips_update
    tmp="$(mktemp)"
    render_template "$SCHEME_DIR/nginx.conf" "$tmp" text vals
    nginx_apply_config "$tmp"
    rm -f "$tmp"
}

# One shortId: every link of this scheme uses the same one.
scheme_short_ids() {
    jq -nc --arg id "$(random_hex 16)" '[$id]'
}

scheme_vless_decryption() {
    printf 'mlkem768x25519plus.native.600s.%s' "$(xray_gen mlkem768-seed)"
}

scheme_keys() {
    ensure_secret VISION_UUID random_uuid
    ensure_secret XHTTP_TLS_UUID random_uuid
    ensure_secret XHTTP_REALITY_UUID random_uuid
    ensure_secret REALITY_PRIVATE_KEY xray_gen x25519-private
    ensure_secret REALITY_MLDSA65_SEED xray_gen mldsa65-seed
    ensure_secret REALITY_SHORT_IDS scheme_short_ids
    ensure_secret XHTTP_TLS_DECRYPTION scheme_vless_decryption
    msg_ok "All client keys present"
}

# Socket files a different user left behind (e.g. an xray that ran as root)
# would make xray fail to listen; nobody can be using them if nothing listens.
scheme_clear_stale_socket() {
    local sock="$1" f
    for f in "$sock" "$sock.lock"; do
        [ -e "$f" ] || continue
        [ "$(stat -c %U "$f")" = "$XRAY_USER" ] && continue
        ss -H -xlp 2>/dev/null | awk '{print $5}' | grep -qxF "$sock" \
            && die "$sock is held by another process: $(ss -H -xlp | grep -F "$sock")"
        rm -f "$f"
        msg_info "Removed stale $f"
    done
}

scheme_xray_conf() {
    local tmp
    # shellcheck disable=SC2034 # read by render_template through a nameref
    local -A vals=()
    scheme_values vals
    tmp="$(mktemp)"
    render_template "$SCHEME_DIR/xray.json" "$tmp" json vals
    scheme_clear_stale_socket "$XHTTP_TLS_SOCK"
    scheme_clear_stale_socket "$XHTTP_REALITY_SOCK"
    xray_apply_scheme "$tmp"
    rm -f "$tmp"
}

scheme_verify() {
    local d c code bytes n dir
    d="$(param DIRECT_DOMAIN)"
    c="$(param CDN_DOMAIN)"
    check_service nginx
    check_service xray
    check_listening tcp/443 xray
    check_listening tcp/80 nginx
    check_listening udp/443 nginx
    check_unix_socket "$NGINX_TLS_SOCK" nginx
    check_unix_socket "$XHTTP_TLS_SOCK" xray
    check_unix_socket "$XHTTP_REALITY_SOCK" xray

    # TLS on 443 that is not REALITY must come out of nginx (REALITY target path).
    for dir in "$d" "$c"; do
        code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$dir:443:127.0.0.1" "https://$dir/" 2>/dev/null || true)"
        if [[ "$code" =~ ^[234] ]]; then
            check_ok "https://$dir/ via xray -> nginx answers ($code)"
        else
            check_fail "https://$dir/ via xray -> nginx: HTTP ${code:-no response}"
        fi
    done
    code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$d:443:127.0.0.1" "https://$d/$(param XHTTP_PATH)" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != 000 ] && [ "$code" != 502 ] && [ "$code" != 504 ]; then
        check_ok "/XHTTP_PATH reaches xray behind nginx ($code)"
    else
        check_fail "/XHTTP_PATH: nginx cannot reach xray on $XHTTP_TLS_SOCK (HTTP ${code:-no response})"
    fi

    read -r bytes n <<<"$(cert_chain_bytes 127.0.0.1:443 "$d")"
    if [ "${bytes:-0}" -gt 3500 ]; then
        check_ok "REALITY target chain for $d: $bytes bytes in $n certs (> 3500, required by mldsa65Seed)"
    else
        check_fail "REALITY target chain for $d is ${bytes:-0} bytes; mldsa65Seed needs > 3500 or REALITY handshakes fail"
    fi
    for dir in "$d" "$c"; do
        local cert
        cert="$(cert_dir "$dir")/fullchain.pem"
        if openssl x509 -noout -checkend $((14 * 86400)) -in "$cert" >/dev/null 2>&1; then
            check_ok "certificate for $dir valid until $(cert_expiry "$cert")"
        else
            check_fail "certificate for $dir expires within 14 days or is missing ($cert)"
        fi
    done

    # The checks above go to 127.0.0.1; these take the way clients take.
    scheme_check_points_here "$d"
    scheme_check_through_cloudflare "$c"
}

scheme_check_points_here() {
    local domain="$1" ips mine
    ips="$(resolve_a "$domain")"
    mine="$(public_ipv4 || true)"
    if [ -z "$ips" ]; then
        check_warn "$domain does not resolve (no A record), so clients cannot reach it"
    elif [ -z "$mine" ]; then
        check_warn "cannot determine this VPS's public IPv4; $domain -> $(paste -sd' ' <<<"$ips") is unchecked"
    elif grep -qxF "$mine" <<<"$ips"; then
        check_ok "$domain resolves to this VPS ($mine)"
    else
        check_fail "$domain resolves to $(paste -sd' ' <<<"$ips"), not to this VPS ($mine)"
    fi
}

# A request through Cloudflare, the way CDN clients come in. Cloudflare's 52x
# codes say which part of the dashboard setup is wrong.
scheme_check_through_cloudflare() {
    local domain="$1" code rc=0
    resolves_to_cloudflare "$domain" || rc=$?
    if [ "$rc" -eq 1 ]; then
        check_warn "$domain does not resolve to Cloudflare: the CDN entry works only with its record Proxied (orange cloud)"
        return 0
    elif [ "$rc" -ne 0 ]; then
        check_warn "cannot tell whether $domain is proxied by Cloudflare; the way through Cloudflare is unchecked"
        return 0
    fi
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://$domain/" 2>/dev/null || true)"
    case "$code" in
        2??|3??) check_ok "https://$domain/ through Cloudflare reaches this VPS ($code)" ;;
        521) check_fail "Cloudflare reaches no web server for $domain (HTTP 521): its A record in the Cloudflare dashboard must be this VPS ($(public_ipv4 || echo '?'))" ;;
        522|523) check_fail "Cloudflare cannot connect to the origin of $domain (HTTP $code): check the A record's IP and the provider firewall for TCP 443" ;;
        525) check_fail "Cloudflare's TLS handshake with this VPS failed for $domain (HTTP 525)" ;;
        526) check_fail "Cloudflare rejects the origin certificate of $domain (HTTP 526): it must be a Cloudflare Origin Certificate covering $domain" ;;
        *) check_fail "https://$domain/ through Cloudflare: HTTP ${code:-no response}" ;;
    esac
}

# Client encryption string for a server decryption string: same mode and
# padding, 0-RTT, each key replaced by its client half.
scheme_vless_encryption() {
    local dec="$1" mode rest seg out=()
    mode="$(cut -d. -f2 <<<"$dec")"
    rest="$(cut -d. -f4- <<<"$dec")"
    local IFS=.
    for seg in $rest; do
        case "${#seg}" in
            86) out+=("$(xray_derive mlkem768 "$seg")") ;;
            43) out+=("$(xray_derive x25519 "$seg")") ;;
            *)  out+=("$seg") ;;
        esac
    done
    printf 'mlkem768x25519plus.%s.0rtt.%s' "$mode" "${out[*]}"
}

scheme_links() {
    local d c pbk pqv sid enc
    d="$(param DIRECT_DOMAIN)"
    c="$(param CDN_DOMAIN)"
    pbk="$(xray_derive x25519 "$(param REALITY_PRIVATE_KEY)")"
    pqv="$(xray_derive mldsa65 "$(param REALITY_MLDSA65_SEED)")"
    sid="$(jq -r '.[0]' <<<"$(param REALITY_SHORT_IDS)")"
    enc="$(scheme_vless_encryption "$(param XHTTP_TLS_DECRYPTION)")"
    vless_link "$(param VISION_UUID)" "$d" 443 "$d REALITY Vision" \
        type=tcp encryption=none flow=xtls-rprx-vision security=reality \
        sni="$d" fp="$(param REALITY_FINGERPRINT)" pbk="$pbk" sid="$sid" pqv="$pqv" spx=/
    vless_link "$(param XHTTP_REALITY_UUID)" "$d" 443 "$d XHTTP REALITY" \
        type=xhttp encryption=none security=reality path="/$(param XHTTP_REALITY_PATH)" mode=auto \
        sni="$d" fp="$(param REALITY_FINGERPRINT)" pbk="$pbk" sid="$sid" pqv="$pqv" spx=/
    vless_link "$(param XHTTP_TLS_UUID)" "$d" 443 "$d XHTTP TLS" \
        type=xhttp encryption="$enc" security=tls path="/$(param XHTTP_PATH)" host="$d" mode=auto \
        sni="$d" fp="$(param TLS_FINGERPRINT)" alpn=h2
    vless_link "$(param XHTTP_TLS_UUID)" "$c" 443 "$c XHTTP CDN" \
        type=xhttp encryption="$enc" security=tls path="/$(param XHTTP_PATH)" host="$c" mode=auto \
        sni="$c" fp="$(param TLS_FINGERPRINT)" alpn=h2
}

#!/bin/bash
# components/certs/component.sh - TLS certificates for nginx.
#
#   acme_ensure          ZeroSSL certificate via acme.sh, HTTP-01 on nginx's webroot
#   cert_install_pair    a certificate/key pair the user supplied (e.g. a
#                        Cloudflare Origin Certificate)
# Certificates live in /etc/vpsautodeploy/certs/<domain>/{fullchain,privkey}.pem.

CERTS_ASSETS="$VPSAD_ROOT/components/certs"
ACME_HOME=/root/.acme.sh
ACME_WEBROOT=/nginx/acme_challenge

cert_dir() {
    printf '%s' "$VPSAD_STATE_DIR/certs/$1"
}

pem_cert_valid() {
    openssl x509 -noout -in "$1" >/dev/null 2>&1
}

pem_key_valid() {
    openssl pkey -noout -in "$1" >/dev/null 2>&1
}

cert_key_match() {
    local cert="$1" key="$2" a b
    a="$(openssl x509 -noout -pubkey -in "$cert" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" || return 1
    b="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum)" || return 1
    [ -n "$a" ] && [ "$a" = "$b" ]
}

cert_covers() {
    openssl x509 -noout -checkhost "$2" -in "$1" 2>/dev/null | grep -q 'does match'
}

# cert_usable CERT KEY DOMAIN [DAYS]: parses, matches, covers DOMAIN, valid for DAYS more.
cert_usable() {
    local cert="$1" key="$2" domain="$3" days="${4:-0}"
    [ -s "$cert" ] && [ -s "$key" ] || return 1
    pem_cert_valid "$cert" && pem_key_valid "$key" && cert_key_match "$cert" "$key" \
        && cert_covers "$cert" "$domain" \
        && openssl x509 -noout -checkend $((days * 86400)) -in "$cert" >/dev/null 2>&1
}

cert_expiry() {
    openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2
}

# Total DER size of the chain served for SNI on host:port - the number REALITY
# compares against when mldsa65Seed is set (same metric as `xray tls ping`).
cert_chain_bytes() {
    local hostport="$1" sni="$2" tmp total=0 n=0 f
    tmp="$(mktemp -d)"
    { openssl s_client -connect "$hostport" -servername "$sni" -showcerts </dev/null 2>/dev/null || true; } \
        | awk -v d="$tmp" '/BEGIN CERTIFICATE/{n++; f=sprintf("%s/%02d.pem", d, n)} f{print > f} /END CERTIFICATE/{f=""}'
    for f in "$tmp"/*.pem; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        total=$((total + $(openssl x509 -in "$f" -outform DER 2>/dev/null | wc -c)))
    done
    rm -rf "$tmp"
    printf '%s %s' "$total" "$n"
}

cert_install_pair() {
    local domain="$1" cert="$2" key="$3" dir
    dir="$(cert_dir "$domain")"
    install -d -m 700 "$VPSAD_STATE_DIR/certs" "$dir"
    cert_key_match "$cert" "$key" || die "$domain: certificate and key do not belong together"
    install -m 600 "$cert" "$dir/fullchain.pem"
    install -m 600 "$key" "$dir/privkey.pem"
    msg_ok "$domain: certificate installed (expires $(cert_expiry "$dir/fullchain.pem"))"
}

# Does nginx already answer ACME challenges for DOMAIN on port 80?
acme_webroot_served() {
    local domain="$1" token got
    token="vpsad-$(random_alnum 16)"
    install -d "$ACME_WEBROOT/.well-known/acme-challenge"
    printf '%s' "$token" > "$ACME_WEBROOT/.well-known/acme-challenge/$token"
    chmod 644 "$ACME_WEBROOT/.well-known/acme-challenge/$token"
    got="$(curl -fsS --max-time 5 -H "Host: $domain" "http://127.0.0.1/.well-known/acme-challenge/$token" 2>/dev/null || true)"
    rm -f "$ACME_WEBROOT/.well-known/acme-challenge/$token"
    [ "$got" = "$token" ]
}

# acme_ensure DOMAIN EMAIL [KEYLENGTH]: issue unless a usable certificate with
# 30+ days left exists. KEYLENGTH 4096 (RSA) keeps the chain long enough for
# REALITY's ML-DSA-65 padding when nginx is the REALITY target.
acme_ensure() {
    local domain="$1" email="$2" keylen="${3:-4096}" dir rc tmp
    dir="$(cert_dir "$domain")"
    if cert_usable "$dir/fullchain.pem" "$dir/privkey.pem" "$domain" 30; then
        msg_ok "$domain: certificate valid until $(cert_expiry "$dir/fullchain.pem")"
        return 0
    fi
    if ! acme_webroot_served "$domain"; then
        msg_info "Serving the ACME webroot for $domain with a temporary nginx config"
        # shellcheck disable=SC2034 # read by render_template through a nameref
        local -A vals=([DOMAIN]="$domain")
        tmp="$(mktemp)"
        render_template "$CERTS_ASSETS/nginx-acme.conf" "$tmp" text vals
        nginx_apply_config "$tmp"
        rm -f "$tmp"
        acme_webroot_served "$domain" || die "nginx does not serve the ACME webroot for $domain on port 80"
    fi
    if [ ! -x "$ACME_HOME/acme.sh" ]; then
        msg_info "Installing acme.sh"
        tmp="$(mktemp)"
        fetch https://get.acme.sh "$tmp"
        (cd /root && HOME=/root sh "$tmp" "email=$email")
        rm -f "$tmp"
    fi
    msg_info "Issuing a certificate for $domain (ZeroSSL, RSA $keylen, HTTP-01)"
    rc=0
    HOME=/root "$ACME_HOME/acme.sh" --issue -d "$domain" --webroot "$ACME_WEBROOT" \
        -k "$keylen" --server zerossl || rc=$?
    # 2 = a certificate exists and is not due for renewal: install it anyway
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || die "acme.sh could not issue a certificate for $domain (exit $rc)"
    install -d -m 700 "$VPSAD_STATE_DIR/certs" "$dir"
    HOME=/root "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --fullchain-file "$dir/fullchain.pem" --key-file "$dir/privkey.pem" \
        --reloadcmd "systemctl reload nginx"
    chmod 600 "$dir"/*.pem
    cert_usable "$dir/fullchain.pem" "$dir/privkey.pem" "$domain" \
        || die "$domain: the installed certificate is not usable"
    msg_ok "$domain: certificate issued (expires $(cert_expiry "$dir/fullchain.pem"))"
}

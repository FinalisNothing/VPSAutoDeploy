#!/bin/bash
# tests/e2e/schemes/e2e-reality-8443/scheme.sh - exists only so tests/e2e can
# exercise switching between schemes. Never deploy it for real.

# shellcheck disable=SC2034 # the SCHEME_* variables are read by lib/engine.sh
SCHEME_TITLE="E2E only: VLESS REALITY Vision on tcp/8443, target www.cloudflare.com"
SCHEME_SUMMARY=("Used by tests/e2e/run.sh to test scheme switching; not a real deployment.")
SCHEME_PORTS=(tcp/8443)
SCHEME_COMPONENTS=(xray)
SCHEME_XRAY_VERSION=26.10.31

scheme_inputs() {
    input SNI         domain "REALITY serverName and target" --advanced --default www.cloudflare.com
    input UUID        uuid   "Client UUID" --secret
    input PRIVATE_KEY key32  "REALITY private key" --secret
}

scheme_guide() {
    ask SNI
}

scheme_deploy() {
    step firewall  "Firewall: allow ${SCHEME_PORTS[*]}" fw_open "${SCHEME_PORTS[@]}"
    step xray      "Xray-core"                          xray_install "${XRAY_VERSION:-$SCHEME_XRAY_VERSION}"
    step keys      "Keys"                               e2e_keys
    step xray-conf "xray config"                        e2e_xray_conf
}

e2e_keys() {
    ensure_secret UUID random_uuid
    ensure_secret PRIVATE_KEY xray_gen x25519-private
}

e2e_xray_conf() {
    local tmp
    tmp="$(mktemp)"
    render_template "$SCHEME_DIR/xray.json" "$tmp" json PARAMS
    xray_apply_scheme "$tmp"
    rm -f "$tmp"
}

scheme_verify() {
    check_service xray
    check_listening tcp/8443 xray
}

scheme_links() {
    vless_link "$(param UUID)" 127.0.0.1 8443 "e2e REALITY 8443" \
        type=tcp encryption=none flow=xtls-rprx-vision security=reality sni="$(param SNI)" fp=chrome \
        pbk="$(xray_derive x25519 "$(param PRIVATE_KEY)")" sid= spx=/
}

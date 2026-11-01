#!/bin/bash
# components/warp/component.sh - Register a free Cloudflare WARP device.
#
# Same API call the 3x-ui panel makes. The result is everything a WireGuard
# outbound needs; nothing else on the machine changes. If Cloudflare changes
# this API, register with any other tool (wgcf, a panel) and put the values
# into the scheme's WARP_* inputs instead.

WARP_API=https://api.cloudflareclient.com/v0a2158/reg

# warp_register ARRAY: fills secret_key address_v4 address_v6 reserved
# peer_public_key endpoint device_id access_token license_key.
warp_register() {
    local -n _warp="$1"
    local priv pub body resp cid
    priv="$(xray_gen wg-private)"
    pub="$("$XRAY_BIN" wg -i "$priv" | sed -n 's/^Password (PublicKey): //p')"
    [ -n "$priv" ] && [ -n "$pub" ] || die "Could not generate a WireGuard key pair"
    body="$(jq -nc --arg key "$pub" --arg tos "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" --arg name "$(hostname)" \
        '{key: $key, tos: $tos, type: "PC", model: "vpsautodeploy", name: $name}')"
    resp="$(curl -fsS --retry 3 --connect-timeout 15 -X POST "$WARP_API" \
        -H 'CF-Client-Version: a-7.21-0721' -H 'Content-Type: application/json' -d "$body")" \
        || die "WARP registration request failed"
    cid="$(jq -r '.config.client_id // empty' <<<"$resp" 2>/dev/null)" || cid=""
    [ -n "$cid" ] || die "Unexpected WARP registration response: $(head -c 300 <<<"$resp")"
    _warp["secret_key"]="$priv"
    _warp["address_v4"]="$(jq -r '.config.interface.addresses.v4 // empty' <<<"$resp")/32"
    _warp["address_v6"]="$(jq -r '.config.interface.addresses.v6 // empty' <<<"$resp")/128"
    _warp["reserved"]="$(printf '%s' "$cid" | base64 -d | od -An -tu1 | xargs | jq -Rc 'split(" ") | map(tonumber)')"
    _warp["peer_public_key"]="$(jq -r '.config.peers[0].public_key' <<<"$resp")"
    _warp["endpoint"]="$(jq -r '.config.peers[0].endpoint.host' <<<"$resp")"
    _warp["device_id"]="$(jq -r '.id' <<<"$resp")"
    _warp["access_token"]="$(jq -r '.token' <<<"$resp")"
    _warp["license_key"]="$(jq -r '.account.license // empty' <<<"$resp")"
    msg_ok "WARP device registered (${_warp["address_v4"]}, ${_warp["address_v6"]})"
}

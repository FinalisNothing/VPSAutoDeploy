#!/bin/bash
# components/xray/component.sh - Bare Xray-core.
#
# Layout (the same paths as the official Xray-install):
#   /usr/local/bin/xray                 symlink to the active version below
#   /usr/local/lib/vpsautodeploy/xray/<version>/xray   verified release binaries
#   /usr/local/share/xray/{geoip,geosite}.dat          Loyalsoldier geodata
#   /usr/local/etc/xray/config.json     the active scheme's rendered config
#   /var/log/xray/                      logs (logrotate: daily, 7 kept)
#
# xray runs as the unprivileged user "xray" with only CAP_NET_BIND_SERVICE
# (port 443). Config checks run as the same user, without capabilities.
#
# Egress - where traffic leaves the VPS (outbounds and routing) - belongs to
# the machine, not to a scheme. A scheme's xray.json holds its inbounds (and,
# only if it really needs them, its own outbounds and routing rules);
# xray_apply_scheme composes it with the one egress policy in effect:
#   default  components/xray/egress.json rendered for this machine: Google and
#            YouTube leave over IPv6 when the VPS has working IPv6 egress,
#            directly otherwise. Kept as /etc/vpsautodeploy/egress.default.json.
#   custom   /etc/vpsautodeploy/egress.json, written by the user (a copy of
#            egress.default.json is the place to start). It replaces the
#            default for every scheme; deployments, switches and updates
#            never write it.

XRAY_BIN=/usr/local/bin/xray
XRAY_LIB=/usr/local/lib/vpsautodeploy/xray
XRAY_ASSET_DIR=/usr/local/share/xray
XRAY_CONF_DIR=/usr/local/etc/xray
XRAY_CONF=$XRAY_CONF_DIR/config.json
XRAY_LOG_DIR=/var/log/xray
XRAY_USER=xray
XRAY_REPO=XTLS/Xray-core
GEODATA_REPO=Loyalsoldier/v2ray-rules-dat
XRAY_ASSETS="$VPSAD_ROOT/components/xray"
XRAY_EGRESS_CUSTOM="$VPSAD_STATE_DIR/egress.json"
XRAY_EGRESS_DEFAULT="$VPSAD_STATE_DIR/egress.default.json"
XRAY_EGRESS_STATE="$VPSAD_STATE_DIR/egress.state"
XRAY_LOG_STATE="$VPSAD_STATE_DIR/xray-log.state"
GEODATA_UNIT=vpsautodeploy-geodata

xray_zip_name() {
    case "$(uname -m)" in
        x86_64|amd64)  echo Xray-linux-64.zip ;;
        aarch64|arm64) echo Xray-linux-arm64-v8a.zip ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

xray_version_of() {
    "$1" version 2>/dev/null | awk 'NR == 1 {print $2}'
}

xray_installed_version() {
    [ -x "$XRAY_BIN" ] && xray_version_of "$XRAY_BIN"
    return 0
}

xray_resolve_version() {
    local spec="$1" tag
    if [ "$spec" = latest ]; then
        tag="$(github_latest_tag "$XRAY_REPO")" || die "Cannot resolve the latest Xray-core release"
        spec="${tag#v}"
    fi
    [[ "$spec" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Bad Xray-core version '$spec'"
    printf '%s' "$spec"
}

# Download and verify a release; prints the path of its binary.
xray_fetch() {
    local version="$1" dir="$XRAY_LIB/$1" zip tmp want got
    if [ -x "$dir/xray" ] && [ "$(xray_version_of "$dir/xray")" = "$version" ]; then
        printf '%s' "$dir/xray"
        return 0
    fi
    ensure_packages unzip >&2
    zip="$(xray_zip_name)"
    tmp="$(mktemp -d)"
    msg_info "Downloading Xray-core v$version ($zip)" >&2
    fetch "https://github.com/$XRAY_REPO/releases/download/v$version/$zip" "$tmp/$zip"
    fetch "https://github.com/$XRAY_REPO/releases/download/v$version/$zip.dgst" "$tmp/$zip.dgst"
    want="$(awk -F'= ' '$1 == "SHA2-256" {print $2}' "$tmp/$zip.dgst")"
    got="$(sha256_of "$tmp/$zip")"
    [ -n "$want" ] && [ "$want" = "$got" ] || die "$zip checksum mismatch (want ${want:-none}, got $got)"
    install -d -m 755 "$dir"
    unzip -p "$tmp/$zip" xray > "$dir/xray.new"
    chmod 755 "$dir/xray.new"
    [ "$(xray_version_of "$dir/xray.new")" = "$version" ] || die "The downloaded binary does not report version $version"
    mv -f "$dir/xray.new" "$dir/xray"
    rm -rf "$tmp"
    msg_ok "Xray-core v$version verified (sha256)" >&2
    printf '%s' "$dir/xray"
}

xray_activate_binary() {
    local bin="$1"
    ln -sfn "$bin" "$XRAY_BIN.new"
    mv -Tf "$XRAY_BIN.new" "$XRAY_BIN"
}

# Keep the active version and the newest other one (the rollback target).
xray_prune_versions() {
    local active d n=0
    active="$(dirname "$(readlink -f "$XRAY_BIN")")"
    while read -r _ d; do
        [ "$d" = "$active" ] && continue
        n=$((n + 1))
        [ "$n" -le 1 ] || rm -rf "$d"
    done < <(find "$XRAY_LIB" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn)
}

xray_runtime() {
    local tmp
    if ! id "$XRAY_USER" >/dev/null 2>&1; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "$XRAY_USER"
    fi
    install -d -m 755 "$XRAY_ASSET_DIR"
    install -d -o root -g "$XRAY_USER" -m 750 "$XRAY_CONF_DIR"
    install -d -o "$XRAY_USER" -g adm -m 750 "$XRAY_LOG_DIR"
    tmp="$(mktemp)"
    cp "$XRAY_ASSETS/xray.service" "$tmp"
    if ! cmp -s "$tmp" /etc/systemd/system/xray.service; then
        install -m 644 "$tmp" /etc/systemd/system/xray.service
        systemctl daemon-reload
    fi
    rm -f "$tmp"
    install -m 644 "$XRAY_ASSETS/xray.logrotate" /etc/logrotate.d/xray
}

# xray_install VERSION: binary + user/dirs/unit/logrotate + geodata.
xray_install() {
    local version bin cur
    version="$(xray_resolve_version "$1")"
    cur="$(xray_installed_version)"
    xray_runtime
    if [ "$cur" = "$version" ]; then
        msg_ok "Xray-core v$version installed"
    elif [ -n "$cur" ] && [ -f "$XRAY_CONF" ]; then
        xray_upgrade "$version"
    else
        bin="$(xray_fetch "$version")"
        xray_activate_binary "$bin"
        msg_ok "Xray-core v$version installed at $XRAY_BIN"
    fi
    [ -s "$XRAY_ASSET_DIR/geoip.dat" ] && [ -s "$XRAY_ASSET_DIR/geosite.dat" ] || xray_geodata_update
    xray_geodata_timer
}

# xray_test_config FILE [BIN] [ASSET_DIR]
xray_test_config() {
    local file="$1" bin="${2:-$XRAY_BIN}" assets="${3:-$XRAY_ASSET_DIR}" out
    if ! out="$(runuser -u "$XRAY_USER" -- env XRAY_LOCATION_ASSET="$assets" "$bin" run -test -c "$file" 2>&1)"; then
        printf '%s\n' "$out" | grep -v '^\(Xray \|A unified platform\)' | tail -20 >&2
        return 1
    fi
}

xray_wait_active() {
    local ok=0
    for _ in $(seq 1 15); do
        sleep 1
        if systemctl is-active --quiet xray; then
            ok=$((ok + 1))
            [ "$ok" -ge 3 ] && return 0
        else
            ok=0
            systemctl is-failed --quiet xray && return 1
        fi
    done
    return 1
}

# xray_apply_config RENDERED_FILE: test, back up, swap, restart, roll back on failure.
xray_apply_config() {
    local rendered="$1" candidate="$XRAY_CONF_DIR/.config.candidate.json" backup
    install -o root -g "$XRAY_USER" -m 640 "$rendered" "$candidate"
    if ! xray_test_config "$candidate"; then
        rm -f "$candidate"
        die "xray rejected the new configuration; the running one is unchanged."
    fi
    if cmp -s "$candidate" "$XRAY_CONF" && systemctl is-active --quiet xray; then
        rm -f "$candidate"
        msg_ok "xray config unchanged"
        return 0
    fi
    backup="$(backup_file "$XRAY_CONF")"
    mv -f "$candidate" "$XRAY_CONF"
    systemctl enable --quiet xray
    systemctl restart xray
    if ! xray_wait_active; then
        msg_error "xray did not stay up with the new configuration:"
        journalctl -u xray -n 25 --no-pager >&2 || true
        if [ -n "$backup" ]; then
            install -o root -g "$XRAY_USER" -m 640 "$backup" "$XRAY_CONF"
            systemctl restart xray || true
            msg_warn "Previous xray config restored from $backup"
        fi
        die "xray activation failed"
    fi
    msg_ok "xray config activated, xray running${backup:+ (previous saved as $backup)}"
}

ipv6_egress_works() {
    local code _
    for _ in 1 2 3; do
        code="$(curl -6 -sS -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com/generate_204 2>/dev/null || true)"
        [ "$code" = 204 ] && return 0
    done
    return 1
}

# xray_egress_default OUT [IPV6_OUT]: the default policy rendered for this
# machine. IPV6_OUT (IPV6OUT or direct) is detected unless given.
xray_egress_default() {
    local out="$1" ipv6="${2:-}"
    if [ -z "$ipv6" ]; then
        ipv6=direct
        ipv6_egress_works && ipv6=IPV6OUT
    fi
    # shellcheck disable=SC2034 # read by render_template through a nameref
    local -A vals=([IPV6_OUT]="$ipv6")
    render_template "$XRAY_ASSETS/egress.json" "$out" json vals
}

# xray_compose SCHEME_JSON EGRESS_JSON OUT: one config. The egress outbounds
# come first (the first is where unmatched traffic goes), then the scheme's;
# the scheme's routing rules are checked before the egress rules. Egress may
# also set dns (and what balancers need); everything else is the scheme's.
xray_compose() {
    jq -s '
        .[0] as $s | .[1] as $e
        | ($e | keys - ["outbounds", "routing", "dns", "fakedns", "observatory", "burstObservatory"]) as $extra
        | if ($extra | length) > 0 then error("egress policy: keys it may not set: \($extra | join(", "))") else . end
        | if (($s.routing // {}) | keys - ["rules"] | length) > 0 then error("scheme xray.json: routing may only add rules") else . end
        | ($s | del(.outbounds, .routing)) + ($e | del(.outbounds, .routing))
          + {outbounds: (($e.outbounds // []) + ($s.outbounds // []))}
          + {routing: (($e.routing // {}) + {rules: (($s.routing.rules // []) + ($e.routing.rules // []))})}
    ' "$1" "$2" > "$3.tmp" || { rm -f "$3.tmp"; die "cannot compose the xray config from $1 and $2"; }
    mv -f "$3.tmp" "$3"
}

# xray_apply_scheme RENDERED: compose a scheme's xray.json with the egress
# policy in effect, then xray_apply_config. Records which policy that was.
xray_apply_scheme() {
    local rendered="$1" egress out ipv6=direct
    local -A st=()
    egress="$(mktemp)"
    out="$(mktemp)"
    ipv6_egress_works && ipv6=IPV6OUT
    xray_egress_default "$egress" "$ipv6"
    install -d -m 700 "$VPSAD_STATE_DIR"
    install -m 600 "$egress" "$XRAY_EGRESS_DEFAULT"
    if [ -f "$XRAY_EGRESS_CUSTOM" ]; then
        jq -e 'type == "object"' "$XRAY_EGRESS_CUSTOM" >/dev/null 2>&1 \
            || die "$XRAY_EGRESS_CUSTOM is not a JSON object"
        cp "$XRAY_EGRESS_CUSTOM" "$egress"
        st=([EGRESS]=custom [EGRESS_SHA256]="$(sha256_of "$XRAY_EGRESS_CUSTOM")")
        msg_info "Egress: your policy in $XRAY_EGRESS_CUSTOM"
    else
        st=([EGRESS]=default [EGRESS_IPV6_OUT]="$ipv6")
        if [ "$ipv6" = IPV6OUT ]; then
            msg_info "Egress: default policy; Google and YouTube leave over IPv6"
        else
            msg_info "Egress: default policy; no IPv6 egress here, so Google and YouTube leave over IPv4"
        fi
    fi
    xray_compose "$rendered" "$egress" "$out"
    xray_log_override "$out"
    xray_apply_config "$out"
    kv_save "$XRAY_EGRESS_STATE" st EGRESS
    rm -f "$egress" "$out"
}

# The machine's log setting (--xray-log): "debug" adds debug errors and the
# access log on top of the scheme's own log settings; "default" leaves those.
xray_log_mode() {
    local -A st=()
    [ -f "$XRAY_LOG_STATE" ] && kv_load "$XRAY_LOG_STATE" st
    printf '%s' "${st[XRAY_LOG]:-default}"
}

xray_log_override() {
    [ "$(xray_log_mode)" = debug ] || return 0
    jq '.log = ((.log // {}) + {loglevel: "debug", access: "/var/log/xray/access.log", error: "/var/log/xray/error.log"})' \
        "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"
    msg_warn "xray logs at debug level with an access log (--xray-log default to stop)"
}

# xray_set_log debug|default: store the setting and apply it to the running config.
xray_set_log() {
    local mode="$1" out
    # shellcheck disable=SC2034 # read by kv_save through a nameref
    local -A st=([XRAY_LOG]="$mode")
    install -d -m 700 "$VPSAD_STATE_DIR"
    kv_save "$XRAY_LOG_STATE" st XRAY_LOG
    if [ ! -f "$XRAY_CONF" ]; then
        msg_ok "xray log setting: $mode (applies at the next deployment)"
        return 0
    fi
    out="$(mktemp)"
    if [ "$mode" = debug ]; then
        cp "$XRAY_CONF" "$out"
        xray_log_override "$out"
    else
        jq '.log = {access: "none", error: "/var/log/xray/error.log", loglevel: "warning"}' "$XRAY_CONF" > "$out"
    fi
    xray_apply_config "$out"
    rm -f "$out"
}

# Daily geodata refresh (Loyalsoldier publishes daily). A systemd timer runs
# phase2-deploy.sh --geodata from this checkout: the files are swapped only
# after the active config passes a test with them, and xray restarts only when
# they changed - at a random moment between 04:00 and 05:00.
xray_geodata_timer() {
    local unit=/etc/systemd/system/$GEODATA_UNIT tmp changed=0
    tmp="$(mktemp)"
    printf '%s\n' "[Unit]" "Description=Refresh xray geodata (VPSAutoDeploy)" \
        "After=network-online.target" "Wants=network-online.target" "" \
        "[Service]" "Type=oneshot" "ExecStart=/bin/bash $VPSAD_ROOT/phase2-deploy.sh --geodata" > "$tmp"
    install_if_changed "$tmp" "$unit.service" && changed=1
    printf '%s\n' "[Unit]" "Description=Daily xray geodata refresh (VPSAutoDeploy)" "" \
        "[Timer]" "OnCalendar=*-*-* 04:00:00" "RandomizedDelaySec=1h" "Persistent=true" "" \
        "[Install]" "WantedBy=timers.target" > "$tmp"
    install_if_changed "$tmp" "$unit.timer" && changed=1
    rm -f "$tmp"
    [ "$changed" -eq 0 ] || systemctl daemon-reload
    systemctl enable --now --quiet "$GEODATA_UNIT.timer"
    msg_ok "Geodata refreshes daily ($GEODATA_UNIT.timer)"
}

# Is the egress in the running config still the one phase2 would choose now?
xray_egress_verify() {
    local -A st=()
    local ipv6=direct
    [ -f "$XRAY_EGRESS_STATE" ] && kv_load "$XRAY_EGRESS_STATE" st
    if [ -f "$XRAY_EGRESS_CUSTOM" ]; then
        if [ "${st[EGRESS]:-}" != custom ]; then
            check_warn "egress: $XRAY_EGRESS_CUSTOM is not in effect yet - run phase2-deploy.sh to apply it"
        elif [ "${st[EGRESS_SHA256]:-}" != "$(sha256_of "$XRAY_EGRESS_CUSTOM")" ]; then
            check_warn "egress: $XRAY_EGRESS_CUSTOM changed since it was applied - run phase2-deploy.sh"
        else
            check_ok "egress: your policy ($XRAY_EGRESS_CUSTOM)"
        fi
        return 0
    fi
    if [ "${st[EGRESS]:-}" = custom ]; then
        check_warn "egress: $XRAY_EGRESS_CUSTOM was removed; run phase2-deploy.sh to return to the default"
        return 0
    fi
    ipv6_egress_works && ipv6=IPV6OUT
    if [ "${st[EGRESS_IPV6_OUT]:-}" != "$ipv6" ]; then
        if [ "$ipv6" = IPV6OUT ]; then
            check_warn "egress: this VPS has IPv6 egress now, but Google/YouTube still leave over IPv4 - run phase2-deploy.sh"
        else
            check_warn "egress: IPv6 egress stopped working; Google/YouTube are routed to it - run phase2-deploy.sh to use IPv4"
        fi
    elif [ "$ipv6" = IPV6OUT ]; then
        check_ok "egress: default policy, Google/YouTube over IPv6 (IPv6 egress works)"
    else
        check_ok "egress: default policy, Google/YouTube over IPv4 (no IPv6 egress)"
    fi
}

xray_release() {
    systemctl disable --now xray 2>/dev/null || true
    systemctl disable --now "$GEODATA_UNIT.timer" 2>/dev/null || true
    if [ -f "$XRAY_CONF" ]; then
        local backup
        backup="$(backup_file "$XRAY_CONF")"
        rm -f "$XRAY_CONF"
        msg_ok "xray stopped; its config saved as $backup"
    fi
}

# xray_upgrade VERSION: switch the binary only if it accepts the active config.
xray_upgrade() {
    local version="$1" bin old
    bin="$(xray_fetch "$version")"
    old="$(readlink -f "$XRAY_BIN" 2>/dev/null || true)"
    if [ -f "$XRAY_CONF" ]; then
        xray_test_config "$XRAY_CONF" "$bin" \
            || die "Xray-core v$version rejects the active config; staying on $(xray_installed_version)."
    fi
    xray_activate_binary "$bin"
    if systemctl is-active --quiet xray || systemctl is-enabled --quiet xray 2>/dev/null; then
        systemctl restart xray
        if ! xray_wait_active; then
            journalctl -u xray -n 25 --no-pager >&2 || true
            if [ -n "$old" ]; then
                xray_activate_binary "$old"
                systemctl restart xray || true
                msg_warn "Rolled back to $(xray_installed_version)"
            fi
            die "xray did not stay up on v$version"
        fi
    fi
    xray_prune_versions
    msg_ok "Xray-core is now v$version"
}

# Loyalsoldier geodata: checksum-verified, and only
# swapped in after the active config passes a test against it.
xray_geodata_update() {
    local tag tmp f want got
    tag="$(github_latest_tag "$GEODATA_REPO")" || die "Cannot resolve the latest $GEODATA_REPO release"
    if [ "$tag" = "$(cat "$XRAY_ASSET_DIR/.vpsautodeploy-geodata" 2>/dev/null)" ] \
        && [ -s "$XRAY_ASSET_DIR/geoip.dat" ] && [ -s "$XRAY_ASSET_DIR/geosite.dat" ]; then
        msg_ok "Geodata $tag is current"
        return 0
    fi
    tmp="$(mktemp -d)"
    chmod 755 "$tmp"
    for f in geoip.dat geosite.dat; do
        fetch "https://github.com/$GEODATA_REPO/releases/download/$tag/$f" "$tmp/$f"
        fetch "https://github.com/$GEODATA_REPO/releases/download/$tag/$f.sha256sum" "$tmp/$f.sha256sum"
        want="$(awk '{print $1}' "$tmp/$f.sha256sum")"
        got="$(sha256_of "$tmp/$f")"
        [ -n "$want" ] && [ "$want" = "$got" ] || die "$f checksum mismatch (want ${want:-none}, got $got)"
        chmod 644 "$tmp/$f"
    done
    if [ -f "$XRAY_CONF" ] && [ -x "$XRAY_BIN" ]; then
        xray_test_config "$XRAY_CONF" "$XRAY_BIN" "$tmp" \
            || die "The active config does not load with geodata $tag; keeping the current files."
    fi
    for f in geoip.dat geosite.dat; do
        install -m 644 "$tmp/$f" "$XRAY_ASSET_DIR/.$f.new"
        mv -f "$XRAY_ASSET_DIR/.$f.new" "$XRAY_ASSET_DIR/$f"
    done
    printf '%s\n' "$tag" > "$XRAY_ASSET_DIR/.vpsautodeploy-geodata"
    rm -rf "$tmp"
    msg_ok "Geodata $tag installed ($GEODATA_REPO, sha256 verified)"
    if systemctl is-active --quiet xray; then
        systemctl restart xray
        xray_wait_active || die "xray did not stay up after the geodata update"
    fi
}

# Client-side values derived from server secrets with the installed binary.
xray_derive() {
    local kind="$1" secret="$2" out
    case "$kind" in
        x25519)   out="$("$XRAY_BIN" x25519 -i "$secret" | sed -n 's/^Password (PublicKey): //p')" ;;
        mldsa65)  out="$("$XRAY_BIN" mldsa65 -i "$secret" | sed -n 's/^Verify: //p')" ;;
        mlkem768) out="$("$XRAY_BIN" mlkem768 -i "$secret" | sed -n 's/^Client: //p')" ;;
        *) die "internal: xray_derive $kind" ;;
    esac
    [ -n "$out" ] || die "xray $kind could not derive a value"
    printf '%s' "$out"
}

xray_gen() {
    case "$1" in
        x25519-private) "$XRAY_BIN" x25519 | sed -n 's/^PrivateKey: //p' ;;
        mldsa65-seed)   "$XRAY_BIN" mldsa65 | sed -n 's/^Seed: //p' ;;
        mlkem768-seed)  "$XRAY_BIN" mlkem768 | sed -n 's/^Seed: //p' ;;
        *) die "internal: xray_gen $1" ;;
    esac
}

# vless_link UUID HOST PORT NAME KEY=VALUE... -> share link (XTLS discussion #716).
vless_link() {
    local uuid="$1" host="$2" port="$3" name="$4" kv query=""
    shift 4
    for kv in "$@"; do
        query+="${query:+&}${kv%%=*}=$(urlencode "${kv#*=}")"
    done
    printf 'vless://%s@%s:%s?%s#%s\n' "$uuid" "$host" "$port" "$query" "$(urlencode "$name")"
}

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
# xray runs as the unprivileged user "xray" with CAP_NET_BIND_SERVICE (port
# 443) and CAP_NET_ADMIN. The latter lets a WireGuard outbound use a kernel
# TUN, as it would when run as root.
#
# Config checks run as "xray" WITHOUT capabilities: `xray run -test` builds the
# whole core, and with CAP_NET_ADMIN a WireGuard outbound would create a real
# TUN device, rewrite sysctls and leave policy routing rules behind. Without
# it the outbound uses the userspace stack and the check has no side effects.

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
}

# xray_test_config FILE [BIN] [ASSET_DIR] - see the header for why it drops privileges.
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

xray_release() {
    systemctl disable --now xray 2>/dev/null || true
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
        wg-private)     "$XRAY_BIN" wg | sed -n 's/^PrivateKey: //p' ;;
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

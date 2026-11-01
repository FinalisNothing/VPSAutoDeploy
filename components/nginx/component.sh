#!/bin/bash
# components/nginx/component.sh - Custom nginx build (FinalisNothing/nginx-build).
#
# The release tarball installs under /nginx. A scheme renders its own
# nginx.conf; nginx_apply_config tests it before it replaces anything, so a
# bad config never takes the running server down. Other local services put
# their server blocks into /nginx/conf/sites.d/ - every scheme's nginx.conf
# must include that directory, and those files are never touched by a
# scheme switch.

NGINX_PREFIX=/nginx
NGINX_BIN=/nginx/sbin/nginx
NGINX_CONF=/nginx/conf/nginx.conf
NGINX_SITES_DIR=/nginx/conf/sites.d
NGINX_REPO=FinalisNothing/nginx-build
NGINX_ASSETS="$VPSAD_ROOT/components/nginx"

nginx_install() {
    if [ -x "$NGINX_BIN" ]; then
        msg_ok "nginx present: $("$NGINX_BIN" -v 2>&1 | head -1) (build $(nginx_build_version))"
    else
        [ ! -e "$NGINX_PREFIX" ] || die "$NGINX_PREFIX exists but $NGINX_BIN does not - inspect and remove it first."
        local tag tmp want got
        tag="$(github_latest_tag "$NGINX_REPO")" || die "Cannot resolve the latest $NGINX_REPO release"
        tmp="$(mktemp -d)"
        msg_info "Downloading $NGINX_REPO release $tag"
        fetch "https://github.com/$NGINX_REPO/releases/download/$tag/nginx-root.tar.gz" "$tmp/nginx-root.tar.gz"
        fetch "https://github.com/$NGINX_REPO/releases/download/$tag/SHA256SUMS.txt" "$tmp/SHA256SUMS.txt"
        want="$(awk '$2 == "nginx-root.tar.gz" {print $1}' "$tmp/SHA256SUMS.txt")"
        got="$(sha256_of "$tmp/nginx-root.tar.gz")"
        [ -n "$want" ] && [ "$want" = "$got" ] || die "nginx-root.tar.gz checksum mismatch (want ${want:-none}, got $got)"
        mkdir "$tmp/root"
        tar -xzf "$tmp/nginx-root.tar.gz" -C "$tmp/root"
        "$tmp/root/nginx/sbin/nginx" -v >/dev/null 2>&1 \
            || die "The nginx build does not run on this CPU (it needs x86-64-v2)."
        cp -a "$tmp/root/nginx" /
        printf '%s\n' "$tag" > "$NGINX_PREFIX/.vpsautodeploy-build"
        rm -rf "$tmp"
        msg_ok "nginx installed to $NGINX_PREFIX ($tag, sha256 verified)"
    fi
    install -d -m 755 "$NGINX_SITES_DIR"
    if [ -d "$NGINX_PREFIX/html/errors" ]; then
        chown -R root:nogroup "$NGINX_PREFIX/html/errors"
        chmod 750 "$NGINX_PREFIX/html/errors"
        find "$NGINX_PREFIX/html/errors" -name '*.html' -exec chmod 640 {} +
    fi
    install -d "$NGINX_PREFIX/acme_challenge/.well-known/acme-challenge"
    chown -R "${USERNAME:-root}":nogroup "$NGINX_PREFIX/acme_challenge"
    chmod 750 "$NGINX_PREFIX/acme_challenge/.well-known/acme-challenge"
}

nginx_build_version() {
    cat "$NGINX_PREFIX/.vpsautodeploy-build" 2>/dev/null || echo unknown
}

# nginx.service with jemalloc preloaded (nginx is C; Go programs ignore LD_PRELOAD).
nginx_service() {
    local jemalloc tmp
    ensure_packages libjemalloc2
    jemalloc="$(find /usr/lib -name 'libjemalloc.so*' -print -quit)"
    [ -n "$jemalloc" ] || die "libjemalloc.so not found after installing libjemalloc2"
    # shellcheck disable=SC2034 # read by render_template through a nameref
    local -A vals=([JEMALLOC_PATH]="$jemalloc")
    tmp="$(mktemp)"
    render_template "$NGINX_ASSETS/nginx.service" "$tmp" text vals
    if ! cmp -s "$tmp" /etc/systemd/system/nginx.service; then
        install -m 644 "$tmp" /etc/systemd/system/nginx.service
        systemctl daemon-reload
    fi
    rm -f "$tmp"
    systemctl enable --quiet nginx
    msg_ok "nginx.service enabled (LD_PRELOAD=$jemalloc)"
}

# nginx_apply_config RENDERED_FILE: test, back up, swap, reload/start, roll back on failure.
nginx_apply_config() {
    local rendered="$1" candidate="$NGINX_PREFIX/conf/.nginx.conf.candidate" backup out
    install -o root -g root -m 600 "$rendered" "$candidate"
    if ! out="$("$NGINX_BIN" -t -c "$candidate" 2>&1)"; then
        rm -f "$candidate"
        printf '%s\n' "$out" >&2
        die "nginx rejected the new configuration; the running one is unchanged."
    fi
    if cmp -s "$candidate" "$NGINX_CONF" && systemctl is-active --quiet nginx; then
        rm -f "$candidate"
        msg_ok "nginx.conf unchanged"
        return 0
    fi
    backup="$(backup_file "$NGINX_CONF")"
    mv -f "$candidate" "$NGINX_CONF"
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx || true
    fi
    sleep 1
    if ! systemctl is-active --quiet nginx; then
        msg_error "nginx did not come up with the new configuration:"
        journalctl -u nginx -n 20 --no-pager >&2 || true
        if [ -n "$backup" ]; then
            cp -p "$backup" "$NGINX_CONF"
            systemctl restart nginx || true
            msg_warn "Previous nginx.conf restored from $backup"
        fi
        die "nginx activation failed"
    fi
    msg_ok "nginx.conf activated${backup:+ (previous saved as $backup)}"
}

# The scheme no longer uses nginx: keep serving only sites.d (other services).
nginx_release() {
    [ -x "$NGINX_BIN" ] || return 0
    local tmp
    # shellcheck disable=SC2034 # read by render_template through a nameref
    local -A vals=()
    tmp="$(mktemp)"
    render_template "$NGINX_ASSETS/idle.conf" "$tmp" text vals
    nginx_apply_config "$tmp"
    rm -f "$tmp"
    msg_ok "nginx now serves only $NGINX_SITES_DIR/"
}

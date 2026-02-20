#!/bin/bash
# phase2-configure.sh - Main VPS configuration script
# Run this after BBR v3 kernel reboot (phase1).
#
# Supports:
#   bash phase2-configure.sh           # Normal run (with resume)
#   bash phase2-configure.sh --status  # Show service status
#   bash phase2-configure.sh --reset   # Restore backups, stop services

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

BACKUP_DIR="/root/.vpsautodeploy.backup"

###############################################################################
# Backup / restore helpers
###############################################################################

# Backup a file before modifying it (only first time)
backup_file() {
    local filepath="$1"
    local backname
    backname="$(echo "$filepath" | tr '/' '_')"
    mkdir -p "$BACKUP_DIR"
    if [ -f "$filepath" ] && [ ! -f "$BACKUP_DIR/$backname" ]; then
        cp -p "$filepath" "$BACKUP_DIR/$backname"
    fi
}

# Restore a file from backup
restore_file() {
    local filepath="$1"
    local backname
    backname="$(echo "$filepath" | tr '/' '_')"
    if [ -f "$BACKUP_DIR/$backname" ]; then
        cp -p "$BACKUP_DIR/$backname" "$filepath"
        msg_ok "Restored $filepath"
    else
        msg_warn "No backup for $filepath"
    fi
}

###############################################################################
# --status: show all service states
###############################################################################
if [ "${1:-}" = "--status" ]; then
    echo ""
    echo "=========================================="
    echo "  VPS Service Status"
    echo "=========================================="
    echo ""

    # Load config for display
    if load_config; then
        echo "  Config: $CONFIG_FILE"
        echo "  State:  $STATE_FILE"
        if [ -f "$STATE_FILE" ]; then
            echo "  Steps completed: $(wc -l < "$STATE_FILE")/20"
        fi
        echo ""
    fi

    for svc in ssh ufw nginx x-ui fail2ban; do
        printf "  %-14s " "$svc:"
        if [ "$svc" = "ufw" ]; then
            if ufw status 2>/dev/null | grep -q "Status: active"; then
                printf "${GREEN}active${NC}\n"
            else
                printf "${RED}inactive${NC}\n"
            fi
        elif systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "${GREEN}active${NC}\n"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            printf "${YELLOW}enabled but stopped${NC}\n"
        else
            printf "${RED}inactive${NC}\n"
        fi
    done

    # CLIProxyAPI (user service)
    if load_config && id "$USERNAME" &>/dev/null; then
        USER_UID=$(id -u "$USERNAME")
        printf "  %-14s " "cliproxyapi:"
        if sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user is-active --quiet cliproxyapi 2>/dev/null; then
            printf "${GREEN}active${NC}\n"
        else
            printf "${RED}inactive${NC}\n"
        fi
    fi

    echo ""

    # jemalloc check
    msg_info "jemalloc injection:"
    for proc in nginx x-ui cli-proxy-api; do
        DISPLAY_NAME="$proc"
        [ "$proc" = "cli-proxy-api" ] && DISPLAY_NAME="cliproxyapi"
        PID=$(pgrep -x "$proc" -o 2>/dev/null || pgrep -f "$proc" -o 2>/dev/null || true)
        if [ -n "$PID" ]; then
            if grep -q libjemalloc "/proc/$PID/maps" 2>/dev/null; then
                printf "  %-14s ${GREEN}jemalloc loaded${NC} (PID %s)\n" "$DISPLAY_NAME:" "$PID"
            else
                printf "  %-14s ${YELLOW}no jemalloc${NC} (PID %s)\n" "$DISPLAY_NAME:" "$PID"
            fi
        else
            printf "  %-14s ${RED}not running${NC}\n" "$DISPLAY_NAME:"
        fi
    done

    echo ""

    # UFW
    msg_info "Firewall:"
    ufw status 2>/dev/null | head -20
    echo ""

    # Certificates
    if load_config; then
        msg_info "Certificates:"
        for domain in "$DIRECT_DOMAIN" "$CDN_DOMAIN"; do
            CERT="/home/$USERNAME/xray_cert/$domain/fullchain.pem"
            if [ -f "$CERT" ]; then
                EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
                printf "  %-30s ${GREEN}OK${NC} (expires: %s)\n" "$domain:" "$EXPIRY"
            else
                printf "  %-30s ${RED}MISSING${NC}\n" "$domain:"
            fi
        done
    fi

    echo ""
    exit 0
fi

###############################################################################
# --reset: restore backups and stop services
###############################################################################
if [ "${1:-}" = "--reset" ]; then
    echo ""
    echo "=========================================="
    echo "  Reset: Restore backups & stop services"
    echo "=========================================="
    echo ""

    msg_warn "This will restore original config files and stop deployed services."
    read -r -p "Proceed? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted."

    # Stop services
    for svc in nginx x-ui fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc"
            msg_ok "Stopped $svc"
        fi
    done

    # Restore backed up files
    if [ -d "$BACKUP_DIR" ]; then
        msg_info "Restoring backups from $BACKUP_DIR:"
        restore_file "/etc/ssh/sshd_config"
        restore_file "/etc/default/ufw"
        systemctl restart ssh 2>/dev/null || true
    else
        msg_warn "No backup directory found at $BACKUP_DIR"
    fi

    # Remove state so next run starts fresh
    rm -f "$STATE_FILE"
    msg_ok "State file cleared. Next run will re-execute all steps."
    msg_info "Config file preserved at $CONFIG_FILE (inputs will be reused)."
    echo ""
    exit 0
fi

###############################################################################
# Normal run
###############################################################################

echo ""
echo "=========================================="
echo "  Phase 2: Main VPS Configuration"
echo "=========================================="
echo ""

###############################################################################
# User input — load saved config or collect interactively
###############################################################################

if load_config; then
    msg_ok "Loaded saved configuration from $CONFIG_FILE"
    echo ""
    msg_info "Configuration summary:"
    echo "  USERNAME       = $USERNAME"
    echo "  SSH_PORT       = $SSH_PORT"
    echo "  ACME_EMAIL     = $ACME_EMAIL"
    echo "  DIRECT_DOMAIN  = $DIRECT_DOMAIN"
    echo "  CDN_DOMAIN     = $CDN_DOMAIN"
    echo "  XHTTP_PATH     = $XHTTP_PATH"
    echo "  CLIPROXY_PATH  = $CLIPROXY_PATH"
    echo "  XUI_PANEL_PATH = $XUI_PANEL_PATH"
    echo "  XUI_PANEL_PORT = $XUI_PANEL_PORT"
    echo "  BACKEND_WEB    = $BACKEND_WEB"
    echo ""
    read -r -p "Use saved config? [Y/n]: " USE_SAVED
    if [[ "$USE_SAVED" =~ ^[Nn]$ ]]; then
        rm -f "$CONFIG_FILE" "$STATE_FILE"
        msg_info "Cleared saved config and state. Starting fresh."
        exec "$0" "$@"
    fi
else
    msg_info "Collecting configuration parameters..."
    echo ""

    prompt_value "New Linux username" ""
    USERNAME="$REPLY"; validate_username "$USERNAME"

    prompt_password "Password for $USERNAME"
    USER_PASSWORD="$REPLY"; validate_nonempty "USER_PASSWORD" "$USER_PASSWORD"

    prompt_password "New root password"
    ROOT_PASSWORD="$REPLY"; validate_nonempty "ROOT_PASSWORD" "$ROOT_PASSWORD"

    prompt_value "Custom SSH port" "2222"
    SSH_PORT="$REPLY"; validate_port "SSH_PORT" "$SSH_PORT"

    prompt_value "ACME registration email" ""
    ACME_EMAIL="$REPLY"; validate_email "$ACME_EMAIL"

    prompt_value "Direct domain (e.g. b.example.com)" ""
    DIRECT_DOMAIN="$REPLY"; validate_domain "DIRECT_DOMAIN" "$DIRECT_DOMAIN"

    prompt_value "CDN origin domain (e.g. a.example.com)" ""
    CDN_DOMAIN="$REPLY"; validate_domain "CDN_DOMAIN" "$CDN_DOMAIN"

    DEFAULT_XHTTP=$(generate_random_path 32)
    prompt_value "XHTTP location path" "$DEFAULT_XHTTP"
    XHTTP_PATH="$REPLY"; validate_path "XHTTP_PATH" "$XHTTP_PATH"

    DEFAULT_CLIPROXY=$(generate_random_path 32)
    prompt_value "CLIProxyAPI location path" "$DEFAULT_CLIPROXY"
    CLIPROXY_PATH="$REPLY"; validate_path "CLIPROXY_PATH" "$CLIPROXY_PATH"

    DEFAULT_XUI_PATH=$(generate_random_path 32)
    prompt_value "3x-ui panel location path" "$DEFAULT_XUI_PATH"
    XUI_PANEL_PATH="$REPLY"; validate_path "XUI_PANEL_PATH" "$XUI_PANEL_PATH"

    prompt_value "3x-ui panel listen port" "54321"
    XUI_PANEL_PORT="$REPLY"; validate_port "XUI_PANEL_PORT" "$XUI_PANEL_PORT"

    prompt_value "Upstream disguise website domain" "quarkus.io"
    BACKEND_WEB="$REPLY"; validate_domain "BACKEND_WEB" "$BACKEND_WEB"

    echo ""
    msg_info "Configuration summary:"
    echo "  USERNAME       = $USERNAME"
    echo "  SSH_PORT       = $SSH_PORT"
    echo "  ACME_EMAIL     = $ACME_EMAIL"
    echo "  DIRECT_DOMAIN  = $DIRECT_DOMAIN"
    echo "  CDN_DOMAIN     = $CDN_DOMAIN"
    echo "  XHTTP_PATH     = $XHTTP_PATH"
    echo "  CLIPROXY_PATH  = $CLIPROXY_PATH"
    echo "  XUI_PANEL_PATH = $XUI_PANEL_PATH"
    echo "  XUI_PANEL_PORT = $XUI_PANEL_PORT"
    echo "  BACKEND_WEB    = $BACKEND_WEB"
    echo ""
    read -r -p "Proceed? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted by user."

    save_config
    msg_ok "Configuration saved to $CONFIG_FILE"
fi

# Show resume status
if [ -f "$STATE_FILE" ]; then
    DONE_COUNT=$(wc -l < "$STATE_FILE")
    msg_info "Resuming — $DONE_COUNT step(s) already completed, will be skipped."
fi

###############################################################################
# Step 1: Disable virtio_balloon
###############################################################################
if ! is_done "step1"; then
    msg_step "1/20: Disable virtio_balloon"
    if lsmod | grep -q balloon; then
        echo "blacklist virtio_balloon" | tee /etc/modprobe.d/blacklist-balloon.conf
        update-initramfs -u
        msg_ok "virtio_balloon blacklisted"
    else
        msg_info "virtio_balloon not loaded, skipping"
    fi
    mark_done "step1"
else
    msg_step "1/20: Disable virtio_balloon — SKIPPED (done)"
fi

###############################################################################
# Step 2: Create user + set passwords
###############################################################################
if ! is_done "step2"; then
    msg_step "2/20: Create user and set passwords"
    if id "$USERNAME" &>/dev/null; then
        msg_info "User $USERNAME already exists, updating passwords"
    else
        useradd -m -G sudo -s /bin/bash "$USERNAME"
    fi
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    echo "root:$ROOT_PASSWORD" | chpasswd
    msg_ok "User $USERNAME ready, passwords set"
    mark_done "step2"
else
    msg_step "2/20: Create user and set passwords — SKIPPED (done)"
fi

###############################################################################
# Step 3: SSH initial hardening
###############################################################################
if ! is_done "step3"; then
    msg_step "3/20: SSH initial hardening"
    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
    backup_file "$SSHD_CONFIG"

    # Remove any drop-in overrides that might conflict (e.g., CloudCone's 01-permitrootlogin.conf)
    if [ -d "$SSHD_CONF_DIR" ]; then
        for f in "$SSHD_CONF_DIR"/*.conf; do
            [ -f "$f" ] || continue
            backup_file "$f"
            rm -f "$f"
            msg_info "Removed conflicting drop-in: $f"
        done
    fi

    if grep -q "^#\?Port " "$SSHD_CONFIG"; then
        sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
    else
        echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
    fi

    if grep -q "^#\?PermitRootLogin " "$SSHD_CONFIG"; then
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" "$SSHD_CONFIG"
    else
        echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
    fi

    systemctl restart ssh
    msg_ok "SSH configured: Port=$SSH_PORT, PermitRootLogin=prohibit-password"
    mark_done "step3"
else
    msg_step "3/20: SSH initial hardening — SKIPPED (done)"
fi

###############################################################################
# Step 4: UFW firewall
###############################################################################
if ! is_done "step4"; then
    msg_step "4/20: Configure UFW firewall"
    apt install -y ufw
    backup_file "/etc/default/ufw"
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
    ufw default allow outgoing
    ufw default deny incoming
    ufw allow proto tcp from 0.0.0.0/0 to any port "$SSH_PORT"
    ufw allow proto tcp from 0.0.0.0/0 to any port 80
    ufw allow proto tcp from 0.0.0.0/0 to any port 443
    ufw allow proto udp from 0.0.0.0/0 to any port 443
    ufw --force enable
    msg_ok "UFW enabled: SSH($SSH_PORT)/80/443(tcp+udp) allowed, IPv4 only"
    mark_done "step4"
else
    msg_step "4/20: Configure UFW firewall — SKIPPED (done)"
fi

###############################################################################
# Step 5: Deploy custom-built Nginx
###############################################################################
if ! is_done "step5"; then
    msg_step "5/20: Deploy custom-built Nginx"
    NGINX_URL="https://github.com/FinalisNothing/nginx-build/releases/latest/download/nginx-root.tar.gz"
    msg_info "Downloading nginx from GitHub Release..."
    curl -fLo /tmp/nginx-root.tar.gz "$NGINX_URL" \
        || die "Failed to download nginx-root.tar.gz from GitHub Release"

    tar -xzf /tmp/nginx-root.tar.gz -C /
    msg_ok "Nginx extracted to /nginx"

    chown -R root:nogroup /nginx/html/errors && chmod 750 /nginx/html/errors
    if ls /nginx/html/errors/*.html >/dev/null 2>&1; then
        chmod 640 /nginx/html/errors/*.html
    fi
    chown -R "$USERNAME":nogroup /nginx/acme_challenge
    chmod 750 /nginx/acme_challenge/.well-known/acme-challenge
    msg_ok "Nginx permissions configured"
    mark_done "step5"
else
    msg_step "5/20: Deploy custom-built Nginx — SKIPPED (done)"
fi

###############################################################################
# Step 6: Install jemalloc
###############################################################################
if ! is_done "step6"; then
    msg_step "6/20: Install jemalloc"
    apt install -y libjemalloc2
    mark_done "step6"
else
    msg_step "6/20: Install jemalloc — SKIPPED (done)"
fi
# Always resolve path (needed by later steps)
JEMALLOC_PATH=$(find /usr/lib -name "libjemalloc.so*" | head -1)
[ -n "$JEMALLOC_PATH" ] || die "Could not find libjemalloc.so"
msg_ok "jemalloc at $JEMALLOC_PATH"

###############################################################################
# Step 7: Create nginx.service (with jemalloc LD_PRELOAD)
###############################################################################
if ! is_done "step7"; then
    msg_step "7/20: Create nginx systemd service"
    render_template "$SCRIPT_DIR/templates/nginx.service" \
        /etc/systemd/system/nginx.service \
        "JEMALLOC_PATH=$JEMALLOC_PATH"
    systemctl daemon-reload
    systemctl enable nginx
    msg_ok "nginx.service installed and enabled"
    mark_done "step7"
else
    msg_step "7/20: Create nginx systemd service — SKIPPED (done)"
fi

###############################################################################
# Step 8: ACME certificate
###############################################################################
if ! is_done "step8"; then
    msg_step "8/20: ACME certificate for $DIRECT_DOMAIN"

    # Check if cert already exists (e.g., from a previous partial run)
    CERT_FILE="/home/$USERNAME/xray_cert/$DIRECT_DOMAIN/fullchain.pem"
    if [ -f "$CERT_FILE" ]; then
        msg_info "Certificate already exists at $CERT_FILE, skipping issuance"
    else
        render_template "$SCRIPT_DIR/templates/nginx-temp.conf.template" \
            /nginx/conf/nginx.conf \
            "DIRECT_DOMAIN=$DIRECT_DOMAIN"

        systemctl start nginx || systemctl restart nginx
        msg_ok "Nginx started with temporary ACME config"

        msg_info "Installing acme.sh..."
        sudo -i bash -c "curl https://get.acme.sh | sh -s email=$ACME_EMAIL"

        msg_info "Issuing certificate for $DIRECT_DOMAIN..."
        sudo -i /root/.acme.sh/acme.sh --issue \
            -d "$DIRECT_DOMAIN" \
            --webroot /nginx/acme_challenge \
            -k 4096 \
            --server zerossl

        mkdir -p "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN"
        mkdir -p "/home/$USERNAME/xray_cert/$CDN_DOMAIN"

        sudo -i /root/.acme.sh/acme.sh --install-cert -d "$DIRECT_DOMAIN" \
            --fullchain-file "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN/fullchain.pem" \
            --key-file "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN/privkey.pem" \
            --reloadcmd "/nginx/sbin/nginx -s reload"
    fi

    msg_ok "ACME certificate ready for $DIRECT_DOMAIN"
    mark_done "step8"
else
    msg_step "8/20: ACME certificate — SKIPPED (done)"
fi

###############################################################################
# Step 9: Cloudflare origin certificate (user paste)
###############################################################################
if ! is_done "step9"; then
    msg_step "9/20: Cloudflare origin certificate for $CDN_DOMAIN"
    mkdir -p "/home/$USERNAME/xray_cert/$CDN_DOMAIN"

    echo ""
    msg_info "Paste the fullchain.pem for $CDN_DOMAIN (Cloudflare origin cert)."
    msg_info "End with a line containing only 'EOF':"
    echo ""
    CF_CERT=""
    while IFS= read -r line; do
        [ "$line" = "EOF" ] && break
        CF_CERT="${CF_CERT}${line}"$'\n'
    done
    printf '%s' "$CF_CERT" > "/home/$USERNAME/xray_cert/$CDN_DOMAIN/fullchain.pem"

    echo ""
    msg_info "Paste the privkey.pem for $CDN_DOMAIN (Cloudflare origin key)."
    msg_info "End with a line containing only 'EOF':"
    echo ""
    CF_KEY=""
    while IFS= read -r line; do
        [ "$line" = "EOF" ] && break
        CF_KEY="${CF_KEY}${line}"$'\n'
    done
    printf '%s' "$CF_KEY" > "/home/$USERNAME/xray_cert/$CDN_DOMAIN/privkey.pem"

    msg_ok "Cloudflare origin cert saved for $CDN_DOMAIN"
    mark_done "step9"
else
    msg_step "9/20: Cloudflare origin certificate — SKIPPED (done)"
fi

###############################################################################
# Step 10: Certificate directory permissions
###############################################################################
if ! is_done "step10"; then
    msg_step "10/20: Set certificate directory permissions"
    grep -qF "umask 0077" /root/.bashrc || echo "umask 0077" >> /root/.bashrc
    chmod 700 "/home/$USERNAME/xray_cert"
    chmod 700 "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN"
    chmod 700 "/home/$USERNAME/xray_cert/$CDN_DOMAIN"
    chmod 600 "/home/$USERNAME/xray_cert"/*/*.pem
    msg_ok "Certificate permissions locked down"
    mark_done "step10"
else
    msg_step "10/20: Set certificate directory permissions — SKIPPED (done)"
fi

###############################################################################
# Step 11: Generate cloudflare-ips.geo
###############################################################################
if ! is_done "step11"; then
    msg_step "11/20: Generate cloudflare-ips.geo"
    CF_V4_URL="https://www.cloudflare.com/ips-v4"
    CF_V6_URL="https://www.cloudflare.com/ips-v6"
    NGINX_GEO="/nginx/conf/cloudflare-ips.geo"

    CF_TMPDIR="$(mktemp -d)"
    curl -fsS --connect-timeout 10 --max-time 30 "$CF_V4_URL" > "$CF_TMPDIR/v4.txt"
    curl -fsS --connect-timeout 10 --max-time 30 "$CF_V6_URL" > "$CF_TMPDIR/v6.txt"

    {
        echo "# Cloudflare IP ranges - auto-generated $(date -Iseconds)"
        while IFS= read -r cidr; do
            [ -n "$cidr" ] && echo "$cidr 1;"
        done < "$CF_TMPDIR/v4.txt"
        while IFS= read -r cidr; do
            [ -n "$cidr" ] && echo "$cidr 1;"
        done < "$CF_TMPDIR/v6.txt"
    } > "$NGINX_GEO"

    chown root:root "$NGINX_GEO"
    chmod 644 "$NGINX_GEO"
    rm -rf "$CF_TMPDIR"
    msg_ok "cloudflare-ips.geo generated"
    mark_done "step11"
else
    msg_step "11/20: Generate cloudflare-ips.geo — SKIPPED (done)"
fi

###############################################################################
# Step 12: Deploy final nginx.conf
###############################################################################
if ! is_done "step12"; then
    msg_step "12/20: Deploy final nginx.conf"
    systemctl stop nginx || true
    backup_file "/nginx/conf/nginx.conf"

    render_template "$SCRIPT_DIR/templates/nginx.conf.template" \
        /nginx/conf/nginx.conf \
        "DIRECT_DOMAIN=$DIRECT_DOMAIN" \
        "CDN_DOMAIN=$CDN_DOMAIN" \
        "USERNAME=$USERNAME" \
        "XHTTP_PATH=$XHTTP_PATH" \
        "CLIPROXY_PATH=$CLIPROXY_PATH" \
        "XUI_PANEL_PATH=$XUI_PANEL_PATH" \
        "XUI_PANEL_PORT=$XUI_PANEL_PORT" \
        "BACKEND_WEB=$BACKEND_WEB"

    chown root:root /nginx/conf/nginx.conf
    chmod 600 /nginx/conf/nginx.conf
    /nginx/sbin/nginx -t || die "nginx config test failed"
    systemctl start nginx
    msg_ok "Final nginx.conf deployed and nginx restarted"
    mark_done "step12"
else
    msg_step "12/20: Deploy final nginx.conf — SKIPPED (done)"
fi

###############################################################################
# Step 13: Deploy Fail2ban
###############################################################################
if ! is_done "step13"; then
    msg_step "13/20: Deploy Fail2ban"
    FAIL2BAN_DIR="$SCRIPT_DIR/fail2ban"
    if [ ! -d "$FAIL2BAN_DIR" ]; then
        msg_info "Cloning fail2ban config from repository..."
        git clone --depth 1 https://github.com/FinalisNothing/VPSAutoConfig.git /tmp/vpsautoconfig-tmp
        FAIL2BAN_DIR="/tmp/vpsautoconfig-tmp/fail2ban"
    fi
    SSH_PORT="$SSH_PORT" bash "$FAIL2BAN_DIR/deploy.sh"
    msg_ok "Fail2ban deployed"
    mark_done "step13"
else
    msg_step "13/20: Deploy Fail2ban — SKIPPED (done)"
fi

###############################################################################
# Step 14: Install 3x-ui
###############################################################################
if ! is_done "step14"; then
    msg_step "14/20: Install 3x-ui"
    curl -Ls -o /tmp/x-ui-install.sh https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
    sed -i 's/^[[:space:]]*config_after_install$/#config_after_install/' /tmp/x-ui-install.sh
    bash /tmp/x-ui-install.sh
    msg_ok "3x-ui installed (interactive config skipped)"
    mark_done "step14"
else
    msg_step "14/20: Install 3x-ui — SKIPPED (done)"
fi

###############################################################################
# Step 15: Replace x-ui.db
###############################################################################
if ! is_done "step15"; then
    msg_step "15/20: Replace x-ui.db"
    echo ""
    msg_info "Upload your x-ui.db to the VPS from another terminal:"
    echo ""
    echo "  scp x-ui.db $USERNAME@<VPS_IP>:~/x-ui.db"
    echo ""
    msg_info "Waiting for /home/$USERNAME/x-ui.db to appear..."

    while [ ! -f "/home/$USERNAME/x-ui.db" ]; do
        sleep 2
    done

    cp "/home/$USERNAME/x-ui.db" /etc/x-ui/x-ui.db
    /usr/local/x-ui/x-ui migrate
    msg_ok "x-ui.db replaced and migrated"
    mark_done "step15"
else
    msg_step "15/20: Replace x-ui.db — SKIPPED (done)"
fi

###############################################################################
# Step 16: 3x-ui service configuration
###############################################################################
if ! is_done "step16"; then
    msg_step "16/20: Configure 3x-ui systemd service"
    cp /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
    chown root:root /etc/systemd/system/x-ui.service
    chmod 644 /etc/systemd/system/x-ui.service
    msg_ok "x-ui.service configured"
    mark_done "step16"
else
    msg_step "16/20: Configure 3x-ui systemd service — SKIPPED (done)"
fi

###############################################################################
# Step 17: 3x-ui jemalloc (via EnvironmentFile)
###############################################################################
if ! is_done "step17"; then
    msg_step "17/20: Enable jemalloc for 3x-ui"
    echo "LD_PRELOAD=$JEMALLOC_PATH" > /etc/default/x-ui
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
    msg_ok "3x-ui restarted with jemalloc"
    mark_done "step17"
else
    msg_step "17/20: Enable jemalloc for 3x-ui — SKIPPED (done)"
fi

###############################################################################
# Step 18: Install CLIProxyAPI
###############################################################################
if ! is_done "step18"; then
    msg_step "18/20: Install CLIProxyAPI"
    loginctl enable-linger "$USERNAME"
    sudo -u "$USERNAME" bash -c 'curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash'
    msg_ok "CLIProxyAPI installed"
    mark_done "step18"
else
    msg_step "18/20: Install CLIProxyAPI — SKIPPED (done)"
fi

###############################################################################
# Step 19: CLIProxyAPI jemalloc (via systemd drop-in override)
###############################################################################
if ! is_done "step19"; then
    msg_step "19/20: Enable jemalloc for CLIProxyAPI"
    USER_UID=$(id -u "$USERNAME")
    mkdir -p "/home/$USERNAME/.config/systemd/user/cliproxyapi.service.d"
    cat > "/home/$USERNAME/.config/systemd/user/cliproxyapi.service.d/override.conf" << EOF
[Service]
Environment="LD_PRELOAD=$JEMALLOC_PATH"
EOF
    chown -R "$USERNAME":"$USERNAME" "/home/$USERNAME/.config"
    sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user daemon-reload
    sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user restart cliproxyapi
    msg_ok "CLIProxyAPI restarted with jemalloc"
    mark_done "step19"
else
    msg_step "19/20: Enable jemalloc for CLIProxyAPI — SKIPPED (done)"
fi

###############################################################################
# Step 20: SSH Key authentication
###############################################################################
if ! is_done "step20"; then
    msg_step "20/20: SSH Key authentication"
    echo ""
    msg_info "On your LOCAL machine (PowerShell), generate an SSH key if you haven't:"
    echo ""
    echo "  ssh-keygen -t ed25519"
    echo ""
    msg_info "Paste your PUBLIC key (id_ed25519.pub contents):"
    read -r SSH_PUBKEY
    validate_nonempty "SSH public key" "$SSH_PUBKEY"

    USER_HOME="/home/$USERNAME"
    mkdir -p "$USER_HOME/.ssh"
    echo "$SSH_PUBKEY" > "$USER_HOME/.ssh/authorized_keys"
    chown -R "$USERNAME":"$USERNAME" "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"

    SSHD_CONFIG="/etc/ssh/sshd_config"
    backup_file "$SSHD_CONFIG"

    if grep -q "^#\?PubkeyAuthentication " "$SSHD_CONFIG"; then
        sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD_CONFIG"
    else
        echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
    fi

    if grep -q "^#\?AuthorizedKeysFile " "$SSHD_CONFIG"; then
        sed -i "s|^#\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" "$SSHD_CONFIG"
    else
        echo "AuthorizedKeysFile .ssh/authorized_keys" >> "$SSHD_CONFIG"
    fi

    if grep -q "^#\?PasswordAuthentication " "$SSHD_CONFIG"; then
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD_CONFIG"
    else
        echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    fi

    systemctl restart ssh
    msg_ok "SSH key authentication configured, password login disabled"
    mark_done "step20"
else
    msg_step "20/20: SSH Key authentication — SKIPPED (done)"
fi

###############################################################################
# Done
###############################################################################

USER_UID=$(id -u "$USERNAME")

echo ""
echo "=========================================="
echo "  Phase 2: Configuration Complete!"
echo "=========================================="
echo ""
msg_warn "IMPORTANT: Before closing this terminal, open a NEW terminal and test:"
echo ""
echo "  ssh -i ~/.ssh/id_ed25519 $USERNAME@<VPS_IP> -p $SSH_PORT"
echo ""
msg_warn "Only close this session after confirming key-based login works!"
echo ""
msg_info "Your services:"
echo "  3x-ui panel : https://$DIRECT_DOMAIN/$XUI_PANEL_PATH/"
echo "  CLIProxyAPI : https://$DIRECT_DOMAIN/$CLIPROXY_PATH/"
echo "  XHTTP path  : /$XHTTP_PATH"
echo ""
msg_info "Useful commands:"
echo "  bash phase2-configure.sh --status   # Show all service status"
echo "  bash phase2-configure.sh --reset    # Restore backups, stop services"
echo "  ufw status                          # Check firewall"
echo "  fail2ban-client status              # Check fail2ban jails"
echo ""
msg_info "State files (safe to delete after successful deployment):"
echo "  $CONFIG_FILE   # Saved inputs"
echo "  $STATE_FILE    # Completed steps"
echo "  $BACKUP_DIR/   # Config backups"
echo ""

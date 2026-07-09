#!/bin/bash
# phase2-deploy.sh - Deploy the service stack on the hardened VPS.
# Run after the phase1 kernel reboot.
#
# Earlier phases own identity and login, so this script never asks for them:
#   phase0        created the sudo user, baked the SSH port in at DD time
#   harden-ssh    installed your key, closed password login, set passwords
#   phase1        BBR v3 kernel + qdisc (+ virtio_balloon blacklist)
# The preflight DETECTS the user and SSH port from the system and verifies
# those contracts. The config file carries service parameters only
# (domains, email, paths, ports) - no credentials.
#
# Zero-touch run: pre-upload the optional artifacts together with the config
# and the run needs no interaction at all:
#   scp vpsautodeploy.conf cf-fullchain.pem cf-privkey.pem x-ui.db <user>@<VPS_IP>:~/
#
# Supports:
#   bash phase2-deploy.sh                    # Normal run (with resume)
#   bash phase2-deploy.sh --status           # Show service status
#   bash phase2-deploy.sh --reset            # Restore backups, stop services
#   bash phase2-deploy.sh --generate-config  # Generate config template file

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

BACKUP_DIR="/root/vpsautodeploy.backup"
TOTAL_STEPS=11

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
# System detection - the phase2 entry point.
# Identity facts are read from the system, never asked for:
#   USERNAME  the phase0 user (sudo -i keeps SUDO_USER; fallback: UID 1000)
#   SSH_PORT  the running sshd's effective port
###############################################################################
detect_system() {
    USERNAME="${SUDO_USER:-}"
    if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
        USERNAME="$(getent passwd 1000 2>/dev/null | cut -d: -f1)" || USERNAME=""
    fi
    [ -n "$USERNAME" ] || die "Cannot detect the phase0 user (no SUDO_USER, no UID-1000 account). Log in as your user, then: sudo -i"
    validate_username "$USERNAME"
    USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
    [ "$USER_HOME" = "/home/$USERNAME" ] || die "Unexpected home '$USER_HOME' for $USERNAME - the nginx template assumes /home/$USERNAME."
    [ -d "$USER_HOME" ] || die "Home directory $USER_HOME not found."
    id -nG "$USERNAME" | tr ' ' '\n' | grep -qx sudo \
        || die "$USERNAME is not in the sudo group - were phase0 and harden-ssh completed?"

    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')" || SSH_PORT=""
    [ -n "$SSH_PORT" ] || die "Cannot read the effective SSH port (sshd -T failed). Is sshd running?"
    validate_port "SSH_PORT (detected)" "$SSH_PORT"
}

# Verify the contracts the earlier phases established. Warn-and-confirm, not
# die: a recovery re-run on a half-configured box is legitimate.
verify_hardening() {
    local pa cc
    pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')" || pa=""
    if [ "$pa" = "no" ]; then
        msg_ok "sshd: password login closed (harden-ssh contract holds)"
    else
        msg_warn "sshd still accepts passwords (PasswordAuthentication=${pa:-unknown})."
        msg_warn "harden-ssh.sh was not run or was undone. Deploying on an unhardened box is unsafe."
        read -r -p "Continue anyway? [y/N]: " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || die "Aborted. Run: bash harden-ssh.sh"
    fi

    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" || cc=""
    if [ "$cc" = "bbr" ]; then
        msg_ok "kernel: BBR active (phase1 contract holds)"
    else
        msg_warn "TCP congestion control is '${cc:-unknown}', not bbr - phase1 missing or its reboot skipped."
        read -r -p "Continue anyway? [y/N]: " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || die "Aborted. Run: bash phase1-kernel.sh"
    fi
}

# Search /root and every /home/* for a pre-uploaded file; prints first match.
find_artifact() {
    local name="$1" candidate
    for candidate in "/root/$name" "$USER_HOME/$name" /home/*/"$name"; do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# Block until a file's size stops changing (upload finished).
wait_until_stable() {
    local path="$1" s1 s2
    while :; do
        s1="$(stat -c%s "$path" 2>/dev/null)" || s1="x1"
        sleep 2
        s2="$(stat -c%s "$path" 2>/dev/null)" || s2="x2"
        [ "$s1" = "$s2" ] && break
    done
    msg_ok "$path stable at $s1 bytes"
}

###############################################################################
# --generate-config: output a template config file for pre-filling
###############################################################################
if [ "${1:-}" = "--generate-config" ]; then
    TARGET="${2:-$CONFIG_FILE}"
    if [ -f "$TARGET" ]; then
        msg_warn "Config file already exists at $TARGET"
        read -r -p "Overwrite? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted."
    fi
    cat > "$TARGET" << 'TEMPLATE'
# VPSAutoDeploy configuration file
# Fill in the values below, then run: bash phase2-deploy.sh
# Lines starting with # are comments.
#
# Identity (username, passwords, SSH port) is NOT configured here - phase0
# and harden-ssh already own it, and phase2 detects it from the system.
#
# Upload to VPS:  scp vpsautodeploy.conf <user>@<VPS_IP>:~/
#
# Optional zero-touch artifacts (searched in /root and every /home/*):
#   cf-fullchain.pem / cf-privkey.pem   Cloudflare origin cert for CDN_DOMAIN
#   x-ui.db                             existing 3x-ui database to restore
# Upload them together with this file and phase2 runs without any prompts:
#   scp vpsautodeploy.conf cf-fullchain.pem cf-privkey.pem x-ui.db <user>@<VPS_IP>:~/

# ── Required fields (must fill in) ──────────────────────────────────

# ACME registration email (for ZeroSSL certificate issuance)
# Example: ACME_EMAIL=admin@example.com
ACME_EMAIL=

# Direct-connect domain (DNS A record pointing to VPS IP)
# Example: DIRECT_DOMAIN=b.example.com
DIRECT_DOMAIN=

# CDN origin domain (Cloudflare proxied, orange-cloud enabled)
# Example: CDN_DOMAIN=a.example.com
CDN_DOMAIN=

# ── Optional fields (leave empty for auto-generated random values) ──

# XHTTP location path (letters, digits, underscore, hyphen only)
# Leave empty to auto-generate a random 32-character string
XHTTP_PATH=

# 3x-ui panel location path (same format as above)
XUI_PANEL_PATH=

# ── Fields with defaults (change if needed) ─────────────────────────

# 3x-ui panel listen port (range: 1024-65535)
XUI_PANEL_PORT=54321

# Upstream disguise website domain (used as reverse proxy backend)
# Should be a real, publicly accessible HTTPS website
BACKEND_WEB=quarkus.io
TEMPLATE
    chmod 600 "$TARGET"
    msg_ok "Config template generated at $TARGET"
    msg_info "Edit the file, fill in the required values, then run:"
    echo ""
    echo "  bash phase2-deploy.sh"
    echo ""
    msg_info "Or: edit locally and upload via SCP to any user's home directory:"
    echo ""
    echo "  scp vpsautodeploy.conf <user>@<VPS_IP>:~/"
    echo ""
    msg_info "The script will auto-detect and move it to $CONFIG_FILE"
    exit 0
fi

###############################################################################
# --status: show all service states
###############################################################################
if [ "${1:-}" = "--status" ]; then
    echo ""
    echo "=========================================="
    echo "  VPS Service Status"
    echo "=========================================="
    echo ""

    detect_system
    echo "  Detected: user=$USERNAME  ssh_port=$SSH_PORT"

    if load_config; then
        echo "  Config: $CONFIG_FILE"
        echo "  State:  $STATE_FILE"
        if [ -f "$STATE_FILE" ]; then
            echo "  Steps completed: $(wc -l < "$STATE_FILE")/$TOTAL_STEPS"
        fi
    fi
    echo ""

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

    echo ""

    # jemalloc check (only nginx — Go binaries are statically linked, LD_PRELOAD has no effect)
    msg_info "jemalloc (nginx only — Go programs ignore LD_PRELOAD):"
    PID=$(pgrep -x nginx -o 2>/dev/null || true)
    if [ -n "$PID" ]; then
        if grep -q libjemalloc "/proc/$PID/maps" 2>/dev/null; then
            printf "  %-14s ${GREEN}jemalloc loaded${NC} (PID %s)\n" "nginx:" "$PID"
        else
            printf "  %-14s ${YELLOW}no jemalloc${NC} (PID %s)\n" "nginx:" "$PID"
        fi
    else
        printf "  %-14s ${RED}not running${NC}\n" "nginx:"
    fi

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

    msg_warn "This stops deployed services and restores the files phase2 modified."
    msg_info "NOT touched: SSH config (harden-ssh owns it). UFW stays enabled."
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
        restore_file "/nginx/conf/nginx.conf"
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
echo "  Phase 2: Service Deployment"
echo "=========================================="
echo ""

###############################################################################
# Preflight: detect system facts, verify earlier phases, spot artifacts
###############################################################################
msg_step "Preflight"
detect_system
msg_ok "User: $USERNAME (home: $USER_HOME)"
msg_ok "SSH port: $SSH_PORT"
verify_hardening

# Pre-uploaded artifacts (optional - they make the run zero-touch)
for artifact in cf-fullchain.pem cf-privkey.pem x-ui.db; do
    FOUND="$(find_artifact "$artifact")" || FOUND=""
    if [ -n "$FOUND" ]; then
        msg_ok "Found pre-uploaded $artifact: $FOUND"
    fi
done

###############################################################################
# User input — load saved/pre-filled config or collect interactively
###############################################################################

# validate_config: check all required fields are present and valid
validate_config() {
    validate_email "$ACME_EMAIL"
    validate_domain "DIRECT_DOMAIN" "$DIRECT_DOMAIN"
    validate_domain "CDN_DOMAIN" "$CDN_DOMAIN"
    validate_domain "BACKEND_WEB" "$BACKEND_WEB"
    validate_port "XUI_PANEL_PORT" "$XUI_PANEL_PORT"
    # Paths: auto-generate if empty, then validate
    if [ -z "${XHTTP_PATH:-}" ]; then
        XHTTP_PATH=$(generate_random_path 32)
    fi
    validate_path "XHTTP_PATH" "$XHTTP_PATH"
    if [ -z "${XUI_PANEL_PATH:-}" ]; then
        XUI_PANEL_PATH=$(generate_random_path 32)
    fi
    validate_path "XUI_PANEL_PATH" "$XUI_PANEL_PATH"
}

show_config_summary() {
    msg_info "Configuration summary:"
    echo "  USERNAME       = $USERNAME (detected)"
    echo "  SSH_PORT       = $SSH_PORT (detected)"
    echo "  ACME_EMAIL     = $ACME_EMAIL"
    echo "  DIRECT_DOMAIN  = $DIRECT_DOMAIN"
    echo "  CDN_DOMAIN     = $CDN_DOMAIN"
    echo "  XHTTP_PATH     = $XHTTP_PATH"
    echo "  XUI_PANEL_PATH = $XUI_PANEL_PATH"
    echo "  XUI_PANEL_PORT = $XUI_PANEL_PORT"
    echo "  BACKEND_WEB    = $BACKEND_WEB"
}

if load_config; then
    msg_ok "Loaded configuration from $CONFIG_FILE"
    validate_config
    echo ""
    show_config_summary
    echo ""
    # Auto-continue after 10s so a pre-uploaded config stays zero-touch.
    read -r -t 10 -p "Use this config? [Y/n] (auto-yes in 10s): " USE_SAVED || USE_SAVED=""
    if [ -z "${USE_SAVED:-}" ]; then echo ""; fi
    if [[ "${USE_SAVED:-}" =~ ^[Nn]$ ]]; then
        rm -f "$CONFIG_FILE" "$STATE_FILE"
        msg_info "Cleared saved config and state. Starting fresh."
        exec "$0" "$@"
    fi
    # Re-save to normalize (auto-generated paths, stripped comments)
    save_config
else
    echo "  No config file found."
    echo ""
    echo "  1) Upload config file — I will SCP vpsautodeploy.conf to VPS"
    echo "  2) Interactive input  — Enter values one by one in this terminal"
    echo ""
    read -r -p "Choose [1/2]: " INPUT_MODE

    if [ "$INPUT_MODE" = "1" ]; then
        echo ""
        msg_info "Upload vpsautodeploy.conf to any user's home directory:"
        echo ""
        echo "  scp -P $SSH_PORT vpsautodeploy.conf $USERNAME@<VPS_IP>:~/"
        echo ""
        msg_info "Tip: generate a template first with: bash phase2-deploy.sh --generate-config"
        echo ""
        msg_info "Waiting for vpsautodeploy.conf to appear..."

        while ! load_config; do
            sleep 2
        done

        msg_ok "Config file loaded from $CONFIG_FILE"
        validate_config
        echo ""
        show_config_summary
        echo ""
        read -r -p "Confirm config is correct? Press Enter to continue (or Ctrl+C to abort)..."
        save_config
    else
        msg_info "Collecting parameters interactively..."
        msg_info "(Tip: run with --generate-config to create a template file instead)"
        echo ""

        prompt_value "ACME registration email" ""
        ACME_EMAIL="$REPLY"; validate_email "$ACME_EMAIL"

        prompt_value "Direct domain (e.g. b.example.com)" ""
        DIRECT_DOMAIN="$REPLY"; validate_domain "DIRECT_DOMAIN" "$DIRECT_DOMAIN"

        prompt_value "CDN origin domain (e.g. a.example.com)" ""
        CDN_DOMAIN="$REPLY"; validate_domain "CDN_DOMAIN" "$CDN_DOMAIN"

        DEFAULT_XHTTP=$(generate_random_path 32)
        prompt_value "XHTTP location path" "$DEFAULT_XHTTP"
        XHTTP_PATH="$REPLY"; validate_path "XHTTP_PATH" "$XHTTP_PATH"

        DEFAULT_XUI_PATH=$(generate_random_path 32)
        prompt_value "3x-ui panel location path" "$DEFAULT_XUI_PATH"
        XUI_PANEL_PATH="$REPLY"; validate_path "XUI_PANEL_PATH" "$XUI_PANEL_PATH"

        prompt_value "3x-ui panel listen port" "54321"
        XUI_PANEL_PORT="$REPLY"; validate_port "XUI_PANEL_PORT" "$XUI_PANEL_PORT"

        prompt_value "Upstream disguise website domain" "quarkus.io"
        BACKEND_WEB="$REPLY"; validate_domain "BACKEND_WEB" "$BACKEND_WEB"

        echo ""
        show_config_summary
        echo ""
        read -r -p "Proceed? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted by user."

        save_config
        msg_ok "Configuration saved to $CONFIG_FILE"
    fi
fi

# Show resume status
if [ -f "$STATE_FILE" ]; then
    DONE_COUNT=$(wc -l < "$STATE_FILE")
    msg_info "Resuming — $DONE_COUNT step(s) already completed, will be skipped."
fi

###############################################################################
# Step 1: UFW firewall
###############################################################################
if ! is_done "ufw"; then
    msg_step "1/$TOTAL_STEPS: Configure UFW firewall"
    apt install -y ufw
    # Debian default IPV6=yes — no need to change.
    # "default deny incoming" blocks all inbound (v4+v6), then allow rules whitelist specific ports.
    # Allow rules use "from 0.0.0.0/0" so only IPv4 inbound is whitelisted; IPv6 inbound stays denied.
    # "default allow outgoing" permits all outbound (v4+v6).
    ufw default allow outgoing
    ufw default deny incoming
    ufw allow proto tcp from 0.0.0.0/0 to any port "$SSH_PORT"
    ufw allow proto tcp from 0.0.0.0/0 to any port 80
    ufw allow proto tcp from 0.0.0.0/0 to any port 443
    ufw allow proto udp from 0.0.0.0/0 to any port 443
    ufw --force enable
    msg_ok "UFW enabled: SSH($SSH_PORT)/80/443(tcp+udp) allowed, IPv4 only"
    mark_done "ufw"
else
    msg_step "1/$TOTAL_STEPS: Configure UFW firewall — SKIPPED (done)"
fi

###############################################################################
# Step 2: Deploy custom-built Nginx
###############################################################################
if ! is_done "nginx"; then
    msg_step "2/$TOTAL_STEPS: Deploy custom-built Nginx"
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
    mark_done "nginx"
else
    msg_step "2/$TOTAL_STEPS: Deploy custom-built Nginx — SKIPPED (done)"
fi

###############################################################################
# Step 3: Install jemalloc (for nginx only — Go binaries ignore LD_PRELOAD)
###############################################################################
if ! is_done "jemalloc"; then
    msg_step "3/$TOTAL_STEPS: Install jemalloc"
    apt install -y libjemalloc2
    mark_done "jemalloc"
else
    msg_step "3/$TOTAL_STEPS: Install jemalloc — SKIPPED (done)"
fi
# Always resolve path (needed by the service step on every run)
JEMALLOC_PATH=$(find /usr/lib -name "libjemalloc.so*" | head -1)
[ -n "$JEMALLOC_PATH" ] || die "Could not find libjemalloc.so"
msg_ok "jemalloc at $JEMALLOC_PATH"

###############################################################################
# Step 4: Create nginx.service (with jemalloc LD_PRELOAD)
###############################################################################
if ! is_done "nginx-service"; then
    msg_step "4/$TOTAL_STEPS: Create nginx systemd service"
    render_template "$SCRIPT_DIR/templates/nginx.service" \
        /etc/systemd/system/nginx.service \
        "JEMALLOC_PATH=$JEMALLOC_PATH"
    systemctl daemon-reload
    systemctl enable nginx
    msg_ok "nginx.service installed and enabled"
    mark_done "nginx-service"
else
    msg_step "4/$TOTAL_STEPS: Create nginx systemd service — SKIPPED (done)"
fi

###############################################################################
# Step 5: ACME certificate
###############################################################################
if ! is_done "acme"; then
    msg_step "5/$TOTAL_STEPS: ACME certificate for $DIRECT_DOMAIN"

    # Check if cert already exists (e.g., from a previous partial run)
    CERT_FILE="/home/$USERNAME/xray_cert/$DIRECT_DOMAIN/fullchain.pem"
    if [ -f "$CERT_FILE" ]; then
        msg_info "Certificate already exists at $CERT_FILE, skipping issuance"
    else
        # A-record sanity check: http-01 fails if DNS does not point here yet.
        # Only blocks when a mismatch is proven; unknown IPs pass silently.
        VPS_IP="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null)" || VPS_IP=""
        DOMAIN_IP="$(getent ahostsv4 "$DIRECT_DOMAIN" 2>/dev/null | awk '{print $1; exit}')" || DOMAIN_IP=""
        if [ -n "$VPS_IP" ] && [ -n "$DOMAIN_IP" ] && [ "$VPS_IP" != "$DOMAIN_IP" ]; then
            msg_warn "$DIRECT_DOMAIN resolves to $DOMAIN_IP but this VPS looks like $VPS_IP."
            read -r -p "Issue the certificate anyway? [y/N]: " CONT
            [[ "$CONT" =~ ^[Yy]$ ]] || die "Fix the DNS A record, then re-run."
        fi

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
    mark_done "acme"
else
    msg_step "5/$TOTAL_STEPS: ACME certificate — SKIPPED (done)"
fi

###############################################################################
# Step 6: Cloudflare origin certificate (pre-uploaded file or paste)
###############################################################################
if ! is_done "cdn-cert"; then
    msg_step "6/$TOTAL_STEPS: Cloudflare origin certificate for $CDN_DOMAIN"
    CERT_DIR="/home/$USERNAME/xray_cert/$CDN_DOMAIN"
    mkdir -p "$CERT_DIR"

    CF_CERT_SRC="$(find_artifact cf-fullchain.pem)" || CF_CERT_SRC=""
    CF_KEY_SRC="$(find_artifact cf-privkey.pem)" || CF_KEY_SRC=""

    if [ -n "$CF_CERT_SRC" ] && [ -n "$CF_KEY_SRC" ]; then
        msg_info "Using pre-uploaded origin cert: $CF_CERT_SRC + $CF_KEY_SRC"
        wait_until_stable "$CF_CERT_SRC"
        wait_until_stable "$CF_KEY_SRC"
        # mv, not cp: don't leave a stray private key in a home directory
        mv "$CF_CERT_SRC" "$CERT_DIR/fullchain.pem"
        mv "$CF_KEY_SRC" "$CERT_DIR/privkey.pem"
    else
        echo ""
        msg_info "Paste the fullchain.pem for $CDN_DOMAIN (Cloudflare origin cert)."
        msg_info "End with a line containing only 'EOF':"
        echo ""
        CF_CERT=""
        while IFS= read -r line; do
            [ "$line" = "EOF" ] && break
            CF_CERT="${CF_CERT}${line}"$'\n'
        done
        printf '%s' "$CF_CERT" > "$CERT_DIR/fullchain.pem"

        echo ""
        msg_info "Paste the privkey.pem for $CDN_DOMAIN (Cloudflare origin key)."
        msg_info "End with a line containing only 'EOF':"
        echo ""
        CF_KEY=""
        while IFS= read -r line; do
            [ "$line" = "EOF" ] && break
            CF_KEY="${CF_KEY}${line}"$'\n'
        done
        printf '%s' "$CF_KEY" > "$CERT_DIR/privkey.pem"
    fi

    openssl x509 -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null \
        || die "$CERT_DIR/fullchain.pem is not a valid certificate. Re-run this step."
    openssl pkey -noout -in "$CERT_DIR/privkey.pem" 2>/dev/null \
        || die "$CERT_DIR/privkey.pem is not a valid private key. Re-run this step."

    msg_ok "Cloudflare origin cert installed for $CDN_DOMAIN"
    mark_done "cdn-cert"
else
    msg_step "6/$TOTAL_STEPS: Cloudflare origin certificate — SKIPPED (done)"
fi

###############################################################################
# Step 7: Certificate directory permissions
###############################################################################
if ! is_done "cert-perms"; then
    msg_step "7/$TOTAL_STEPS: Set certificate directory permissions"
    chmod 700 "/home/$USERNAME/xray_cert"
    chmod 700 "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN"
    chmod 700 "/home/$USERNAME/xray_cert/$CDN_DOMAIN"
    chmod 600 "/home/$USERNAME/xray_cert"/*/*.pem
    msg_ok "Certificate permissions locked down"
    mark_done "cert-perms"
else
    msg_step "7/$TOTAL_STEPS: Set certificate directory permissions — SKIPPED (done)"
fi

###############################################################################
# Step 8: Cloudflare geo + final nginx.conf
###############################################################################
if ! is_done "nginx-conf"; then
    msg_step "8/$TOTAL_STEPS: Cloudflare geo + final nginx.conf"

    # The updater owns cloudflare-ips.geo (and later the fail2ban ignoreip).
    # fail2ban is not installed yet - the updater skips that target for now;
    # fail2ban/deploy.sh runs it again in step 11.
    install -o root -g root -m 700 "$SCRIPT_DIR/fail2ban/update-cloudflare-ips.sh" \
        /usr/local/bin/update-cloudflare-ips.sh
    /usr/local/bin/update-cloudflare-ips.sh

    systemctl stop nginx || true
    backup_file "/nginx/conf/nginx.conf"

    render_template "$SCRIPT_DIR/templates/nginx.conf.template" \
        /nginx/conf/nginx.conf \
        "DIRECT_DOMAIN=$DIRECT_DOMAIN" \
        "CDN_DOMAIN=$CDN_DOMAIN" \
        "USERNAME=$USERNAME" \
        "XHTTP_PATH=$XHTTP_PATH" \
        "XUI_PANEL_PATH=$XUI_PANEL_PATH" \
        "XUI_PANEL_PORT=$XUI_PANEL_PORT" \
        "BACKEND_WEB=$BACKEND_WEB"

    chown root:root /nginx/conf/nginx.conf
    chmod 600 /nginx/conf/nginx.conf
    /nginx/sbin/nginx -t || die "nginx config test failed"
    systemctl start nginx
    msg_ok "cloudflare-ips.geo generated, final nginx.conf deployed, nginx running"
    mark_done "nginx-conf"
else
    msg_step "8/$TOTAL_STEPS: Cloudflare geo + final nginx.conf — SKIPPED (done)"
fi

###############################################################################
# Step 9: Install 3x-ui
###############################################################################
if ! is_done "xui"; then
    msg_step "9/$TOTAL_STEPS: Install 3x-ui"
    curl -Ls -o /tmp/x-ui-install.sh https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
    sed -i 's/^[[:space:]]*config_after_install$/#config_after_install/' /tmp/x-ui-install.sh
    bash /tmp/x-ui-install.sh
    msg_ok "3x-ui installed (interactive config skipped)"
    mark_done "xui"
else
    msg_step "9/$TOTAL_STEPS: Install 3x-ui — SKIPPED (done)"
fi

###############################################################################
# Step 10: Restore x-ui.db
###############################################################################
if ! is_done "xui-db"; then
    msg_step "10/$TOTAL_STEPS: Restore x-ui.db"

    DB_SOURCE="$(find_artifact x-ui.db)" || DB_SOURCE=""

    if [ -z "$DB_SOURCE" ]; then
        echo ""
        msg_info "Upload your x-ui.db to the VPS from another terminal:"
        msg_info "(Note: root login is disabled; use the $USERNAME account)"
        echo ""
        echo "  scp -P $SSH_PORT x-ui.db $USERNAME@<VPS_IP>:~/"
        echo ""
        msg_info "Waiting for x-ui.db to appear (Ctrl+C to abort)..."
        while [ -z "$DB_SOURCE" ]; do
            sleep 2
            DB_SOURCE="$(find_artifact x-ui.db)" || DB_SOURCE=""
        done
    fi

    msg_ok "Found x-ui.db at $DB_SOURCE"
    msg_info "Waiting for the upload to finish (size must stop changing)..."
    wait_until_stable "$DB_SOURCE"

    systemctl stop x-ui
    cp "$DB_SOURCE" /etc/x-ui/x-ui.db
    /usr/local/x-ui/x-ui migrate
    systemctl start x-ui
    msg_ok "x-ui.db restored, migrated, and x-ui restarted"
    mark_done "xui-db"
else
    msg_step "10/$TOTAL_STEPS: Restore x-ui.db — SKIPPED (done)"
fi

###############################################################################
# Step 11: Deploy Fail2ban
###############################################################################
if ! is_done "fail2ban"; then
    msg_step "11/$TOTAL_STEPS: Deploy Fail2ban"
    SSH_PORT="$SSH_PORT" bash "$SCRIPT_DIR/fail2ban/deploy.sh"
    msg_ok "Fail2ban deployed"
    mark_done "fail2ban"
else
    msg_step "11/$TOTAL_STEPS: Deploy Fail2ban — SKIPPED (done)"
fi

###############################################################################
# Done
###############################################################################

echo ""
echo "=========================================="
echo "  Phase 2: Deployment Complete!"
echo "=========================================="
echo ""
msg_info "Your services:"
echo "  3x-ui panel : https://$DIRECT_DOMAIN/$XUI_PANEL_PATH/"
echo "  XHTTP path  : /$XHTTP_PATH"
echo ""
msg_info "Login/SSH were not touched — phase0 and harden-ssh own them."
echo ""
msg_info "Useful commands:"
echo "  bash phase2-deploy.sh --status              # Show all service status"
echo "  bash phase2-deploy.sh --reset               # Restore backups, stop services"
echo "  bash phase2-deploy.sh --generate-config     # Generate config template"
echo "  ufw status                                  # Check firewall"
echo "  fail2ban-client status                      # Check fail2ban jails"
echo ""
msg_info "State files (safe to delete after successful deployment):"
echo "  $CONFIG_FILE   # Saved inputs (service parameters, no credentials)"
echo "  $STATE_FILE    # Completed steps"
echo "  $BACKUP_DIR/   # Config backups"
echo ""

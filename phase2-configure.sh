#!/bin/bash
# phase2-configure.sh - Main VPS configuration script
# Run this after BBR v3 kernel reboot (phase1).
# This is the largest script: 20 steps covering everything from
# user creation to SSH key authentication.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

echo ""
echo "=========================================="
echo "  Phase 2: Main VPS Configuration"
echo "=========================================="
echo ""

###############################################################################
# User input — collect everything upfront
###############################################################################

msg_info "Collecting configuration parameters..."
echo ""

# USERNAME
prompt_value "New Linux username" ""
USERNAME="$REPLY"
validate_username "$USERNAME"

# USER_PASSWORD
prompt_password "Password for $USERNAME"
USER_PASSWORD="$REPLY"
validate_nonempty "USER_PASSWORD" "$USER_PASSWORD"

# ROOT_PASSWORD
prompt_password "New root password"
ROOT_PASSWORD="$REPLY"
validate_nonempty "ROOT_PASSWORD" "$ROOT_PASSWORD"

# SSH_PORT
prompt_value "Custom SSH port" "2222"
SSH_PORT="$REPLY"
validate_port "SSH_PORT" "$SSH_PORT"

# ACME_EMAIL
prompt_value "ACME registration email" ""
ACME_EMAIL="$REPLY"
validate_email "$ACME_EMAIL"

# DIRECT_DOMAIN (b.domain.com)
prompt_value "Direct domain (e.g. b.example.com)" ""
DIRECT_DOMAIN="$REPLY"
validate_domain "DIRECT_DOMAIN" "$DIRECT_DOMAIN"

# CDN_DOMAIN (a.domain.com)
prompt_value "CDN origin domain (e.g. a.example.com)" ""
CDN_DOMAIN="$REPLY"
validate_domain "CDN_DOMAIN" "$CDN_DOMAIN"

# XHTTP_PATH
DEFAULT_XHTTP=$(generate_random_path 32)
prompt_value "XHTTP location path" "$DEFAULT_XHTTP"
XHTTP_PATH="$REPLY"
validate_path "XHTTP_PATH" "$XHTTP_PATH"

# CLIPROXY_PATH
DEFAULT_CLIPROXY=$(generate_random_path 32)
prompt_value "CLIProxyAPI location path" "$DEFAULT_CLIPROXY"
CLIPROXY_PATH="$REPLY"
validate_path "CLIPROXY_PATH" "$CLIPROXY_PATH"

# XUI_PANEL_PATH
DEFAULT_XUI_PATH=$(generate_random_path 32)
prompt_value "3x-ui panel location path" "$DEFAULT_XUI_PATH"
XUI_PANEL_PATH="$REPLY"
validate_path "XUI_PANEL_PATH" "$XUI_PANEL_PATH"

# XUI_PANEL_PORT
prompt_value "3x-ui panel listen port" "54321"
XUI_PANEL_PORT="$REPLY"
validate_port "XUI_PANEL_PORT" "$XUI_PANEL_PORT"

# BACKEND_WEB
prompt_value "Upstream disguise website domain" "quarkus.io"
BACKEND_WEB="$REPLY"
validate_domain "BACKEND_WEB" "$BACKEND_WEB"

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

###############################################################################
# Step 1: Disable virtio_balloon
###############################################################################
msg_step "1/20: Disable virtio_balloon"

if lsmod | grep -q balloon; then
    echo "blacklist virtio_balloon" | tee /etc/modprobe.d/blacklist-balloon.conf
    update-initramfs -u
    msg_ok "virtio_balloon blacklisted"
else
    msg_info "virtio_balloon not loaded, skipping"
fi

###############################################################################
# Step 2: Create user + set passwords
###############################################################################
msg_step "2/20: Create user and set passwords"

useradd -m -G sudo -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "root:$ROOT_PASSWORD" | chpasswd
msg_ok "User $USERNAME created, passwords set"

###############################################################################
# Step 3: SSH initial hardening
###############################################################################
msg_step "3/20: SSH initial hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"

# Set port
if grep -q "^#\?Port " "$SSHD_CONFIG"; then
    sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
else
    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
fi

# Set PermitRootLogin
if grep -q "^#\?PermitRootLogin " "$SSHD_CONFIG"; then
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" "$SSHD_CONFIG"
else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
fi

systemctl restart ssh
msg_ok "SSH configured: Port=$SSH_PORT, PermitRootLogin=prohibit-password"

###############################################################################
# Step 4: UFW firewall
###############################################################################
msg_step "4/20: Configure UFW firewall"

apt install -y ufw

# Disable IPv6 in UFW
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw

ufw default allow outgoing
ufw default deny incoming
ufw allow proto tcp from 0.0.0.0/0 to any port "$SSH_PORT"
ufw allow proto tcp from 0.0.0.0/0 to any port 80
ufw allow proto tcp from 0.0.0.0/0 to any port 443
ufw allow proto udp from 0.0.0.0/0 to any port 443
ufw --force enable
msg_ok "UFW enabled: SSH($SSH_PORT)/80/443(tcp+udp) allowed, IPv4 only"

###############################################################################
# Step 5: Deploy custom-built Nginx
###############################################################################
msg_step "5/20: Deploy custom-built Nginx"

NGINX_URL="https://github.com/FinalisNothing/nginx-build/releases/latest/download/nginx-root.tar.gz"
msg_info "Downloading nginx from GitHub Release..."
curl -fLo /tmp/nginx-root.tar.gz "$NGINX_URL" \
    || die "Failed to download nginx-root.tar.gz from GitHub Release"

tar -xzf /tmp/nginx-root.tar.gz -C /
msg_ok "Nginx extracted to /nginx"

# Set permissions for error pages and ACME directory
chown -R root:nogroup /nginx/html/errors && chmod 750 /nginx/html/errors
if ls /nginx/html/errors/*.html >/dev/null 2>&1; then
    chmod 640 /nginx/html/errors/*.html
fi
chown -R "$USERNAME":nogroup /nginx/acme_challenge
chmod 750 /nginx/acme_challenge/.well-known/acme-challenge
msg_ok "Nginx permissions configured"

###############################################################################
# Step 6: Install jemalloc
###############################################################################
msg_step "6/20: Install jemalloc"

apt install -y libjemalloc2
JEMALLOC_PATH=$(find /usr/lib -name "libjemalloc.so*" | head -1)
if [ -z "$JEMALLOC_PATH" ]; then
    die "Could not find libjemalloc.so"
fi
msg_ok "jemalloc found at $JEMALLOC_PATH"

###############################################################################
# Step 7: Create nginx.service (with jemalloc LD_PRELOAD)
###############################################################################
msg_step "7/20: Create nginx systemd service"

render_template "$SCRIPT_DIR/templates/nginx.service" \
    /etc/systemd/system/nginx.service \
    "JEMALLOC_PATH=$JEMALLOC_PATH"

systemctl daemon-reload
systemctl enable nginx
msg_ok "nginx.service installed and enabled"

###############################################################################
# Step 8: ACME certificate
###############################################################################
msg_step "8/20: ACME certificate for $DIRECT_DOMAIN"

# Deploy temporary nginx config for ACME challenge
render_template "$SCRIPT_DIR/templates/nginx-temp.conf.template" \
    /nginx/conf/nginx.conf \
    "DIRECT_DOMAIN=$DIRECT_DOMAIN"

systemctl start nginx
msg_ok "Nginx started with temporary ACME config"

# Install acme.sh as root
msg_info "Installing acme.sh..."
sudo -i bash -c "curl https://get.acme.sh | sh -s email=$ACME_EMAIL"

# Issue certificate
msg_info "Issuing certificate for $DIRECT_DOMAIN..."
sudo -i /root/.acme.sh/acme.sh --issue \
    -d "$DIRECT_DOMAIN" \
    --webroot /nginx/acme_challenge \
    -k 4096 \
    --server zerossl

# Install certificate
mkdir -p "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN"
mkdir -p "/home/$USERNAME/xray_cert/$CDN_DOMAIN"

sudo -i /root/.acme.sh/acme.sh --install-cert -d "$DIRECT_DOMAIN" \
    --fullchain-file "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN/fullchain.pem" \
    --key-file "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN/privkey.pem" \
    --reloadcmd "/nginx/sbin/nginx -s reload"

msg_ok "ACME certificate issued and installed for $DIRECT_DOMAIN"

###############################################################################
# Step 9: Cloudflare origin certificate (user paste)
###############################################################################
msg_step "9/20: Cloudflare origin certificate for $CDN_DOMAIN"

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

###############################################################################
# Step 10: Certificate directory permissions
###############################################################################
msg_step "10/20: Set certificate directory permissions"

echo "umask 0077" >> /root/.bashrc

chmod 700 "/home/$USERNAME/xray_cert"
chmod 700 "/home/$USERNAME/xray_cert/$DIRECT_DOMAIN"
chmod 700 "/home/$USERNAME/xray_cert/$CDN_DOMAIN"
chmod 600 "/home/$USERNAME/xray_cert"/*/*.pem

msg_ok "Certificate permissions locked down"

###############################################################################
# Step 11: Generate cloudflare-ips.geo
###############################################################################
msg_step "11/20: Generate cloudflare-ips.geo"

# Use the update-cloudflare-ips.sh logic inline since fail2ban isn't deployed yet
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

###############################################################################
# Step 12: Deploy final nginx.conf
###############################################################################
msg_step "12/20: Deploy final nginx.conf"

systemctl stop nginx

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

###############################################################################
# Step 13: Deploy Fail2ban
###############################################################################
msg_step "13/20: Deploy Fail2ban"

FAIL2BAN_DIR="$SCRIPT_DIR/fail2ban"
if [ ! -d "$FAIL2BAN_DIR" ]; then
    msg_info "Cloning fail2ban config from repository..."
    # If fail2ban directory doesn't exist alongside this script, attempt clone
    git clone --depth 1 https://github.com/FinalisNothing/VPSAutoConfig.git /tmp/vpsautoconfig-tmp
    FAIL2BAN_DIR="/tmp/vpsautoconfig-tmp/fail2ban"
fi

SSH_PORT="$SSH_PORT" bash "$FAIL2BAN_DIR/deploy.sh"
msg_ok "Fail2ban deployed"

###############################################################################
# Step 14: Install 3x-ui
###############################################################################
msg_step "14/20: Install 3x-ui"

curl -Ls -o /tmp/x-ui-install.sh https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
sed -i 's/config_after_install/#config_after_install/' /tmp/x-ui-install.sh
bash /tmp/x-ui-install.sh
msg_ok "3x-ui installed (interactive config skipped)"

###############################################################################
# Step 15: Replace x-ui.db
###############################################################################
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

###############################################################################
# Step 16: 3x-ui service configuration
###############################################################################
msg_step "16/20: Configure 3x-ui systemd service"

cp /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
chown root:root /etc/systemd/system/x-ui.service
chmod 644 /etc/systemd/system/x-ui.service
msg_ok "x-ui.service configured"

###############################################################################
# Step 17: 3x-ui jemalloc (via EnvironmentFile)
###############################################################################
msg_step "17/20: Enable jemalloc for 3x-ui"

echo "LD_PRELOAD=$JEMALLOC_PATH" > /etc/default/x-ui
systemctl daemon-reload
systemctl enable x-ui
systemctl start x-ui
msg_ok "3x-ui started with jemalloc"

###############################################################################
# Step 18: Install CLIProxyAPI
###############################################################################
msg_step "18/20: Install CLIProxyAPI"

# Enable lingering for the user so user services survive logout
loginctl enable-linger "$USERNAME"

# CLIProxyAPI installer runs as the user
sudo -u "$USERNAME" bash -c 'curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash'
msg_ok "CLIProxyAPI installed"

###############################################################################
# Step 19: CLIProxyAPI jemalloc (via systemd drop-in override)
###############################################################################
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

###############################################################################
# Step 20: SSH Key authentication
###############################################################################
msg_step "20/20: SSH Key authentication"

echo ""
msg_info "On your LOCAL machine (PowerShell), generate an SSH key if you haven't:"
echo ""
echo "  ssh-keygen -t ed25519"
echo ""
msg_info "Paste your PUBLIC key (id_ed25519.pub contents):"
read -r SSH_PUBKEY
validate_nonempty "SSH public key" "$SSH_PUBKEY"

# Write authorized_keys
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_PUBKEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME":"$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# Configure sshd for key auth
SSHD_CONFIG="/etc/ssh/sshd_config"

# PubkeyAuthentication
if grep -q "^#\?PubkeyAuthentication " "$SSHD_CONFIG"; then
    sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD_CONFIG"
else
    echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
fi

# AuthorizedKeysFile
if grep -q "^#\?AuthorizedKeysFile " "$SSHD_CONFIG"; then
    sed -i "s|^#\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" "$SSHD_CONFIG"
else
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> "$SSHD_CONFIG"
fi

# PasswordAuthentication
if grep -q "^#\?PasswordAuthentication " "$SSHD_CONFIG"; then
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD_CONFIG"
else
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
fi

systemctl restart ssh
msg_ok "SSH key authentication configured, password login disabled"

###############################################################################
# Done
###############################################################################

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
echo "  ufw status                     # Check firewall"
echo "  fail2ban-client status         # Check fail2ban jails"
echo "  systemctl status nginx         # Check nginx"
echo "  systemctl status x-ui          # Check 3x-ui"
echo "  sudo -u $USERNAME XDG_RUNTIME_DIR=/run/user/$USER_UID systemctl --user status cliproxyapi"
echo ""

#!/bin/bash
# phase1-kernel.sh - Replace kernel with BBR v3 support
# Run this on the freshly reinstalled Debian 13 system.
# After reboot, run phase2-configure.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

echo ""
echo "=========================================="
echo "  Phase 1: BBR v3 Kernel Replacement"
echo "=========================================="
echo ""

# ── Step 1: Update system and install essentials ────────────────────
msg_step "1: System update and essential packages"
apt update && apt upgrade -y
apt install -y curl wget jq sudo nano
msg_ok "System updated and essentials installed"

# ── Step 2: Install BBR v3 kernel (no reboot yet) ──────────────────
msg_step "2: Install BBR v3 kernel"
msg_info "Downloading BBR v3 install script..."
curl -fsSLo /tmp/bbr-install.sh https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh \
    || die "Failed to download BBR v3 installer"

msg_info "Installing kernel (will NOT reboot yet)..."
echo -e "1\nn" | bash /tmp/bbr-install.sh
msg_ok "BBR v3 kernel installed"

# ── Step 3: Choose BBR queue algorithm ──────────────────────────────
msg_step "3: Choose BBR queue algorithm"
echo ""
echo "  Select a queue discipline to pair with BBR:"
echo ""
echo "  1) fq         — Fair Queue (recommended, Google's default for BBR)"
echo "  2) fq_codel   — Fair Queue + CoDel (good general-purpose)"
echo "  3) fq_pie     — Fair Queue + PIE"
echo "  4) cake       — Common Applications Kept Enhanced (good for bufferbloat)"
echo ""
read -r -p "Choose [1-4] (default 1): " QDISC_CHOICE
case "${QDISC_CHOICE:-1}" in
    1) QDISC="fq" ;;
    2) QDISC="fq_codel" ;;
    3) QDISC="fq_pie" ;;
    4) QDISC="cake" ;;
    *) msg_warn "Invalid choice, defaulting to fq"; QDISC="fq" ;;
esac
msg_ok "Selected: BBR + $QDISC"

# Write persistent sysctl config — uses the SAME file path and format
# as the byJoey BBR script (/etc/sysctl.d/99-joeyblog.conf), so there
# is no conflict if user runs the BBR script manually later.
SYSCTL_CONF="/etc/sysctl.d/99-joeyblog.conf"
MODULES_CONF="/etc/modules-load.d/joeyblog-qdisc.conf"

cat > "$SYSCTL_CONF" << EOF
net.core.default_qdisc=$QDISC
net.ipv4.tcp_congestion_control=bbr
EOF
msg_ok "Written $SYSCTL_CONF"

# fq and fq_codel are kernel builtins; fq_pie and cake need module autoload
if [ "$QDISC" = "fq_pie" ] || [ "$QDISC" = "cake" ]; then
    echo "sch_$QDISC" > "$MODULES_CONF"
    msg_ok "Written $MODULES_CONF (sch_$QDISC module will autoload at boot)"
else
    rm -f "$MODULES_CONF"
fi

# ── Step 4: Reboot ─────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  BBR v3 kernel installed."
echo "  Queue algorithm: BBR + $QDISC"
echo "  All settings take effect after reboot."
echo "=========================================="
echo ""
msg_info "After reboot, verify with:"
echo "  uname -r                                    # should show bbrv3 kernel"
echo "  sysctl net.ipv4.tcp_congestion_control      # should show bbr"
echo "  sysctl net.core.default_qdisc               # should show $QDISC"
echo ""
read -r -p "Reboot now? [Y/n]: " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Nn]$ ]]; then
    msg_info "Remember to run 'reboot' manually, then phase2-configure.sh"
else
    msg_info "Rebooting..."
    reboot
fi

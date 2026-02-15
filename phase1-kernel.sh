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

# ── Step 2: Download and run BBR v3 installer ──────────────────────
msg_step "2: Install BBR v3 kernel"
msg_info "Downloading BBR v3 install script..."
curl -fsSLo /tmp/bbr-install.sh https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh \
    || die "Failed to download BBR v3 installer"

msg_info "Running installer (option 1 = install latest kernel, y = confirm reboot)..."
echo -e "1\ny" | bash /tmp/bbr-install.sh

# If we reach here, the script didn't trigger a reboot automatically
echo ""
echo "=========================================="
echo "  BBR v3 kernel installed."
echo "=========================================="
echo ""
msg_info "The VPS should reboot automatically."
msg_info "If it doesn't, run 'reboot' manually."
echo ""
msg_info "After reboot, verify with:"
echo "  uname -r"
echo "  sysctl net.ipv4.tcp_congestion_control"
echo ""
msg_info "Then run phase2-configure.sh"

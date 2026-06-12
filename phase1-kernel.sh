#!/bin/bash
# phase1-kernel.sh - Replace kernel with BBR v3 support
# Run this on the freshly reinstalled Debian 13 system.
# After reboot, run phase2-configure.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

BBR_INSTALLER="/tmp/bbr-install.sh"

download_bbr_installer() {
    msg_info "Downloading BBR v3 install script..."
    curl -fsSLo "$BBR_INSTALLER" https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh \
        || die "Failed to download BBR v3 installer"
}

# The installer is fetched from the upstream main branch at run time, so its
# menu numbering can change between runs. Derive action numbers from the
# downloaded script instead of hardcoding them — feeding a stale number could
# trigger a different action (one menu entry uninstalls the kernel).
installer_action_for() {
    local marker="$1" action
    action="$(awk -v marker="$marker" '
        /^[[:space:]]*[0-9]+\)[[:space:]]*$/ { n = $1; sub(/\).*/, "", n) }
        n != "" && index($0, marker) { print n; exit }
    ' "$BBR_INSTALLER")"
    [ -n "$action" ] \
        || die "Cannot find a menu action for '$marker' in the downloaded BBR v3 installer. The upstream menu layout changed; refusing to guess menu numbers. Update phase1-kernel.sh."
    printf '%s' "$action"
}

get_tcp_bbr_version() {
    local module_info version

    module_info="$(modinfo tcp_bbr 2>/dev/null || true)"
    if [ -z "$module_info" ]; then
        depmod -a >/dev/null 2>&1 || true
        module_info="$(modinfo tcp_bbr 2>/dev/null || true)"
    fi

    version="$(printf '%s\n' "$module_info" | awk '/^version:/ {print $2; exit}')"
    printf '%s' "$version"
}

running_actions_bbr_v3_kernel() {
    local kernel_release

    kernel_release="$(uname -r)"
    case "$kernel_release" in
        *bbrv3*|*joeyblog*) ;;
        *) return 1 ;;
    esac

    [ "$(get_tcp_bbr_version)" = "3" ]
}

RUNNING_ACTIONS_BBR_V3=0
KERNEL_INSTALLED_THIS_RUN=0
if running_actions_bbr_v3_kernel; then
    RUNNING_ACTIONS_BBR_V3=1
fi

echo ""
echo "=========================================="
echo "  Phase 1: BBR v3 Kernel Replacement"
echo "=========================================="
if [ "$RUNNING_ACTIONS_BBR_V3" -eq 1 ]; then
    msg_info "Detected running Actions-bbr-v3 kernel: $(uname -r)"
    msg_info "Retry mode: full system update and kernel installation will be skipped."
fi
echo ""

# ── Step 1: Update system and install essentials ────────────────────
msg_step "1: System update and essential packages"
if [ "$RUNNING_ACTIONS_BBR_V3" -eq 1 ]; then
    msg_info "Actions-bbr-v3 kernel is already running; skipping full system update on retry."
    if ! command -v curl >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1 \
        || ! command -v jq >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
        apt update
        apt install -y curl wget jq sudo nano
    fi
    msg_ok "Retry prerequisites ready"
else
    apt update && apt upgrade -y
    apt install -y curl wget jq sudo nano
    msg_ok "System updated and essentials installed"
fi

# ── Step 2: Install BBR v3 kernel (no reboot yet) ──────────────────
msg_step "2: Install BBR v3 kernel"
download_bbr_installer

if [ "$RUNNING_ACTIONS_BBR_V3" -eq 1 ]; then
    msg_ok "Already running Actions-bbr-v3 kernel; skipping kernel installation"
else
    msg_info "Installing kernel (will NOT reboot yet)..."
    INSTALL_LATEST_ACTION="$(installer_action_for "install_latest_version")"
    if ! printf '%s\nn\n' "$INSTALL_LATEST_ACTION" | bash "$BBR_INSTALLER"; then
        die "The BBR v3 installer failed before kernel installation completed. Check the messages above (GitHub API / network errors are the most common cause), then rerun phase1-kernel.sh."
    fi
    # The installer prints dpkg/bootloader errors but still exits 0, so
    # confirm the kernel package actually landed before claiming success.
    if ! dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
        | grep -Eq '^linux-image-\S*joeyblog\S* install ok installed$'; then
        die "No installed linux-image-*joeyblog* package found after running the installer. The kernel did NOT install. Review the messages above and do not reboot until this is fixed."
    fi
    KERNEL_INSTALLED_THIS_RUN=1
    msg_ok "BBR v3 kernel installed"
fi

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

INSTALL_ACTION="$(installer_action_for "QDISC=\"$QDISC\"")"
msg_info "Applying and verifying BBR + $QDISC through the BBR v3 installer..."
if ! printf '%s\ny\n' "$INSTALL_ACTION" | bash "$BBR_INSTALLER"; then
    msg_error "Failed to apply BBR + $QDISC through the BBR v3 installer."
    echo ""
    if [ "$KERNEL_INSTALLED_THIS_RUN" -eq 1 ]; then
        msg_warn "The BBR v3 kernel is installed but not running yet; the current kernel likely lacks bbr or $QDISC support."
        msg_info "Recommended recovery:"
        echo "  1. Reboot into the newly installed BBR v3 kernel."
        echo "  2. Run this script again: bash $0"
        echo "     It will detect the new kernel, skip Steps 1-2, and continue to Step 3."
        echo "  3. Select the same queue algorithm in Step 3."
        echo ""
        read -r -p "Reboot now to retry under the new kernel? [Y/n]: " RETRY_REBOOT_NOW
        if [[ "$RETRY_REBOOT_NOW" =~ ^[Nn]$ ]]; then
            die "Stopped before qdisc configuration completed. Reboot manually, then rerun phase1-kernel.sh."
        fi
        msg_info "Rebooting..."
        reboot
        exit 0
    fi
    msg_warn "You are already running the Actions-bbr-v3 kernel, so rebooting will not help."
    msg_info "Rerun this script and pick fq or fq_codel (built into the kernel), or inspect kernel support with:"
    echo "  sysctl net.ipv4.tcp_available_congestion_control"
    echo "  modprobe sch_$QDISC"
    die "qdisc configuration did not complete."
fi
msg_ok "BBR + $QDISC applied and saved by the BBR v3 installer"

# ── Step 4: Reboot ─────────────────────────────────────────────────
echo ""
echo "=========================================="
if [ "$KERNEL_INSTALLED_THIS_RUN" -eq 1 ]; then
    echo "  BBR v3 kernel installed."
else
    echo "  Actions-bbr-v3 kernel already running."
fi
echo "  Queue algorithm: BBR + $QDISC"
if [ "$KERNEL_INSTALLED_THIS_RUN" -eq 1 ]; then
    echo "  All settings take effect after reboot."
else
    echo "  Settings are active now and saved persistently."
fi
echo "=========================================="
echo ""
if [ "$KERNEL_INSTALLED_THIS_RUN" -eq 1 ]; then
    msg_info "After reboot, verify with:"
else
    msg_info "Verify current settings with:"
fi
echo "  uname -r                                    # should show bbrv3 kernel"
echo "  sysctl net.ipv4.tcp_congestion_control      # should show bbr"
echo "  sysctl net.core.default_qdisc               # should show $QDISC"
echo ""

if [ "$KERNEL_INSTALLED_THIS_RUN" -eq 0 ]; then
    msg_info "No reboot is required by phase1. Continue with phase2-configure.sh"
    exit 0
fi

read -r -p "Reboot now? [Y/n]: " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Nn]$ ]]; then
    msg_info "Remember to run 'reboot' manually, then phase2-configure.sh"
else
    msg_info "Rebooting..."
    reboot
fi

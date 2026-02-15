#!/bin/bash
# phase0-reinstall.sh - DD reinstall to Debian 13
# Run this on the OLD system before anything else.
# After reboot, SSH in with the new root password and run phase1-kernel.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

echo ""
echo "=========================================="
echo "  Phase 0: DD Reinstall to Debian 13"
echo "=========================================="
echo ""

# ── Collect input ───────────────────────────────────────────────────
prompt_password "Enter the ROOT password for the new system"
ROOT_PASSWORD="$REPLY"
validate_nonempty "ROOT_PASSWORD" "$ROOT_PASSWORD"

prompt_password "Confirm ROOT password"
if [ "$REPLY" != "$ROOT_PASSWORD" ]; then
    die "Passwords do not match."
fi

# ── Download and run reinstall.sh ───────────────────────────────────
msg_step "1: Download reinstall.sh"
curl -fsSLO https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh \
    || die "Failed to download reinstall.sh"
msg_ok "Downloaded reinstall.sh"

msg_step "2: Execute DD reinstall"
msg_warn "This will WIPE the current system and install Debian 13."
read -r -p "Type YES to proceed: " CONFIRM
[ "$CONFIRM" = "YES" ] || die "Aborted by user."

bash reinstall.sh --password "$ROOT_PASSWORD" debian 13

echo ""
echo "=========================================="
echo "  DD reinstall initiated."
echo "=========================================="
echo ""
msg_info "The system will NOT reboot automatically."
msg_info "Run 'reboot' manually when ready."
echo ""
msg_info "After reboot, wait for the reinstall to finish (~5-10 min),"
msg_info "then SSH into the new system:"
echo ""
echo "  ssh root@<VPS_IP> -p 22"
echo ""
msg_info "Once logged in, run phase1-kernel.sh"

#!/bin/bash
# phase0-reinstall.sh - Reinstall the VPS to Debian 13 via bin456789/reinstall.
#
# Run this on the provider's ORIGINAL system (any distro), as root:
#   - local SSH to the VPS works            -> run it in that SSH session
#   - port 22 blocked from your network     -> run it in the provider's VNC console
#
# Standalone on purpose: the repo is usually NOT cloned yet (especially in VNC),
# so this file must be fetchable and runnable on its own:
#   curl -O https://raw.githubusercontent.com/FinalisNothing/VPSAutoDeploy/main/phase0-reinstall.sh
#   bash phase0-reinstall.sh
#
# What it does: collect <username> <password> <ssh port>, then run
#   reinstall.sh --username U --password PW --ssh-port P debian 13
# Never --ssh-key: the SSH key is installed for the user AFTER the first login,
# over a real SSH session where pasting is safe (VNC is type-only).
#
# The reinstalled Debian 13 (reinstall's non-root mode):
#   - sshd listens on the chosen port; login: ssh <username>@IP -p <port> + password
#   - root has NO password and CANNOT log in; escalate with `sudo -i`
#     (reinstall grants the user passwordless sudo; hardened later, not here)

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
msg_info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
msg_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
msg_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
msg_error() { printf "${RED}[ERR ]${NC}  %s\n" "$*" >&2; }
msg_step()  { printf "\n${CYAN}── Step %s ──${NC}\n" "$*"; }
die()       { msg_error "$@"; exit 1; }

# Read interactive answers from the terminal even if stdin is a pipe (curl | bash).
if [ -t 0 ]; then TTY=/dev/stdin; else TTY=/dev/tty; fi

[ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root (use: sudo -i)."

echo ""
echo "=========================================="
echo "  Phase 0: Reinstall to Debian 13"
echo "=========================================="
echo ""

# ── Collect input ───────────────────────────────────────────────────
msg_step "1: Choose login user, password, SSH port for the NEW system"

# Username: the only login account of the new system (root cannot log in).
while true; do
    printf "Username (lowercase, NOT root): "
    IFS= read -r USERNAME < "$TTY"
    if [ "$USERNAME" = "root" ]; then
        msg_warn "root is not allowed here: reinstall's non-root mode is required"
        msg_warn "(root gets no password and stays un-loginable; you escalate via sudo)."
    elif [[ "$USERNAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        break
    else
        msg_warn "Invalid username. Use: a-z first, then a-z 0-9 _ - (max 32 chars)."
    fi
done

# Password: used to log in as $USERNAME and, later, as the sudo password.
while true; do
    printf "Password for %s (hidden): " "$USERNAME"
    IFS= read -r -s PASSWORD < "$TTY"; echo
    [ -n "$PASSWORD" ] || { msg_warn "Password must not be empty."; continue; }
    printf "Retype password: "
    IFS= read -r -s PASSWORD2 < "$TTY"; echo
    [ "$PASSWORD" = "$PASSWORD2" ] && break
    msg_warn "Passwords do not match. Try again."
done

# SSH port: Enter = random (the right choice in VNC, where typing is the only
# input); or type 1024-65535 yourself (fine over a real SSH session).
while true; do
    printf "SSH port for the NEW system [Enter = random]: "
    IFS= read -r SSH_PORT < "$TTY"
    if [ -z "$SSH_PORT" ]; then
        SSH_PORT=$(( ((RANDOM << 15) | RANDOM) % 45000 + 20000 ))
        break
    elif [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; then
        break
    else
        msg_warn "Port must be a number between 1024 and 65535."
    fi
done

# ── Download reinstall.sh ───────────────────────────────────────────
msg_step "2: Download reinstall.sh"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
elif command -v wget >/dev/null 2>&1; then
    wget -qO reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
else
    die "Neither curl nor wget found. Install one first (e.g. apt/yum/apk install curl)."
fi
[ -s reinstall.sh ] || die "Download failed: reinstall.sh is missing or empty."
msg_ok "Downloaded reinstall.sh ($(wc -c < reinstall.sh) bytes)"

# ── Confirm and run ─────────────────────────────────────────────────
msg_step "3: Confirm"
echo ""
echo "  Target system : Debian 13"
echo "  Login user    : $USERNAME   (root cannot log in)"
echo "  SSH port      : $SSH_PORT"
echo ""
msg_warn "WRITE DOWN the username and port. After reboot they are the ONLY way in."
msg_warn "Reinstalling will ERASE ALL DATA on this VPS."
echo ""
printf "Type YES to proceed: "
IFS= read -r CONFIRM < "$TTY"
[ "$CONFIRM" = "YES" ] || die "Aborted by user."

bash reinstall.sh --username "$USERNAME" --password "$PASSWORD" --ssh-port "$SSH_PORT" debian 13 \
    || die "reinstall.sh failed; nothing has been wiped until you reboot."

# ── What to do next ─────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Reinstall is staged. It starts on the NEXT REBOOT."
echo "=========================================="
echo ""
msg_info "1. If your provider has a firewall/security group, allow TCP $SSH_PORT now."
msg_info "2. Run 'reboot'. The reinstall takes ~5-10 minutes."
msg_info "3. Then log in to the new Debian 13:"
echo ""
echo "       ssh $USERNAME@<VPS_IP> -p $SSH_PORT     (password you just set)"
echo ""
msg_info "   Do NOT try ssh root@... - root cannot log in on this setup."
msg_info "4. Become root with: sudo -i"
msg_info "5. Continue with phase1:"
echo ""
echo "       apt update && apt install -y git"
echo "       git clone https://github.com/FinalisNothing/VPSAutoDeploy.git"
echo "       cd VPSAutoDeploy && bash phase1-kernel.sh"

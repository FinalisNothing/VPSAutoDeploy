#!/bin/bash
# harden-ssh.sh - First-login hardening for the fresh Debian 13 from phase0.
#
# Run as root right after your FIRST SSH login on the reinstalled system:
#   ssh <username>@<VPS_IP> -p <port>     (password from phase0)
#   sudo -i
#   apt update && apt install -y git
#   git clone https://github.com/FinalisNothing/VPSAutoDeploy.git
#   cd VPSAutoDeploy && bash harden-ssh.sh
#
# phase0's reinstall (password mode) leaves these gaps; this script closes them:
#   1. the user has no SSH key  -> install YOUR ed25519 public key, pasted over
#      this SSH session (never typed into VNC, never installed for root)
#   2. the user's password may have been SHOWN on a VNC screen (phase0's
#      random one) -> optionally replace it here, where typing is private;
#      kept or replaced, it is what sudo asks for from now on
#   3. root has no password     -> set one, for `su -` and for VNC-console
#      rescue if the key is ever lost. root stays un-loginable over SSH:
#      PermitRootLogin keeps the compiled default prohibit-password (= key
#      only) and root has no key.
#   4. sudo asks no password    -> remove reinstall's NOPASSWD file; sudo then
#      asks for the user's own password (via the %sudo group rule)
#   5. sshd accepts passwords   -> PasswordAuthentication no +
#      KbdInteractiveAuthentication no, key-only from here on
#
# Every change is fact-checked on the spot (ssh-keygen -lf, passwd -S,
# sudo -l, sshd -T). The session this runs in is never cut: reload does not
# touch established connections.

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
msg_info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
msg_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
msg_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
msg_error() { printf "${RED}[ERR ]${NC}  %s\n" "$*" >&2; }
msg_step()  { printf "\n${CYAN}── Step %s ──${NC}\n" "$*"; }
die()       { msg_error "$@"; exit 1; }

# Read interactive answers from the terminal even if stdin is a pipe.
if [ -t 0 ]; then TTY=/dev/stdin; else TTY=/dev/tty; fi

[ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root (log in as your user, then: sudo -i)."

# The user to harden = the one who ran sudo (sudo -i keeps SUDO_USER set).
USERNAME="${SUDO_USER:-}"
if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
    die "Cannot tell which user to harden (SUDO_USER='${USERNAME}'). Log in as your normal user, then sudo."
fi
HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || die "Home directory of $USERNAME not found."

echo ""
echo "=========================================="
echo "  First-login hardening for user: $USERNAME"
echo "=========================================="

# ── Collect input ───────────────────────────────────────────────────
msg_step "1: Collect input (nothing is changed yet)"

msg_info "On your LOCAL machine:"
echo "        ssh-keygen -t ed25519          # only if you have no key yet"
echo "        cat ~/.ssh/id_ed25519.pub      # copy that single line"
KEY_TMP=$(mktemp)
trap 'rm -f "$KEY_TMP"' EXIT
while true; do
    printf "Paste the public key line: "
    IFS= read -r PUBKEY < "$TTY"
    PUBKEY=${PUBKEY%$'\r'}    # strip the CR a Windows-side paste may carry
    printf '%s\n' "$PUBKEY" > "$KEY_TMP"
    FINGERPRINT=$(ssh-keygen -lf "$KEY_TMP" 2>/dev/null) && break
    msg_warn "Not a valid SSH public key. Paste the one line of id_ed25519.pub."
done
msg_ok "Key parsed: $FINGERPRINT"
msg_info "'ssh-keygen -lf ~/.ssh/id_ed25519.pub' on your local machine must show the SAME fingerprint."

# Two different passwords are handled below - they are easy to mix up.
msg_info "Two passwords are involved - keep them apart:"
echo "        ${USERNAME}'s password : you logged in with it; sudo asks for it from now on."
echo "        root's password        : new; only for 'su -' and the VNC console."

# The user's password: replace it if phase0 displayed it on a VNC screen
# (typing here is private - this is a real SSH session). Enter keeps it.
while true; do
    printf "New password for %s [Enter = keep the current one] (hidden): " "$USERNAME"
    IFS= read -r -s USER_PW < "$TTY"; echo
    [ -z "$USER_PW" ] && break
    printf "Retype %s's new password: " "$USERNAME"
    IFS= read -r -s USER_PW2 < "$TTY"; echo
    [ "$USER_PW" = "$USER_PW2" ] && break
    msg_warn "Passwords do not match. Try again."
done

# root's password: opens `su -` and the provider's VNC console, not SSH.
while true; do
    printf "New password for root (hidden): "
    IFS= read -r -s ROOT_PW < "$TTY"; echo
    [ -n "$ROOT_PW" ] || { msg_warn "Password must not be empty."; continue; }
    printf "Retype root password: "
    IFS= read -r -s ROOT_PW2 < "$TTY"; echo
    [ "$ROOT_PW" = "$ROOT_PW2" ] && break
    msg_warn "Passwords do not match. Try again."
done

# ── Install the key ─────────────────────────────────────────────────
msg_step "2: Install the key for $USERNAME (and only for $USERNAME)"
mkdir -p "$HOME_DIR/.ssh"
printf '%s\n' "$PUBKEY" > "$HOME_DIR/.ssh/authorized_keys"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown -R "$USERNAME:" "$HOME_DIR/.ssh"
msg_ok "Installed: $HOME_DIR/.ssh/authorized_keys"

# ── Passwords ───────────────────────────────────────────────────────
msg_step "3: Set passwords"
if [ -n "$USER_PW" ]; then
    printf '%s:%s\n' "$USERNAME" "$USER_PW" | chpasswd || die "chpasswd ($USERNAME) failed."
    UPW_STATUS=$(passwd -S "$USERNAME" | awk '{print $2}')
    [ "$UPW_STATUS" = "P" ] || die "Fact check failed: 'passwd -S $USERNAME' says '$UPW_STATUS', expected P."
    msg_ok "${USERNAME}'s password replaced - the one shown in VNC is now dead. sudo asks for the NEW one."
else
    msg_info "${USERNAME}'s password kept - sudo asks for it as-is."
fi
printf '%s:%s\n' root "$ROOT_PW" | chpasswd || die "chpasswd (root) failed."
PW_STATUS=$(passwd -S root | awk '{print $2}')
[ "$PW_STATUS" = "P" ] || die "Fact check failed: 'passwd -S root' says '$PW_STATUS', expected P."
msg_ok "root now has a usable password (passwd -S root: P)."
msg_info "It opens 'su -' and the VNC console. SSH still rejects root: PermitRootLogin stays prohibit-password and root has no key."

# ── sudo asks for a password ────────────────────────────────────────
msg_step "4: Make sudo ask for ${USERNAME}'s password"
# Membership in the sudo group is what keeps $USERNAME a sudoer once the
# NOPASSWD file is gone (/etc/sudoers ships '%sudo ALL=(ALL:ALL) ALL').
if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx sudo; then
    msg_ok "$USERNAME is already in the sudo group."
else
    usermod -aG sudo "$USERNAME" || die "usermod -aG sudo $USERNAME failed."
    msg_ok "Added $USERNAME to the sudo group (the NOPASSWD file was its only sudo grant)."
fi
NOPASSWD_FILE="/etc/sudoers.d/99-$USERNAME"
if [ -f "$NOPASSWD_FILE" ]; then
    rm "$NOPASSWD_FILE"
    msg_ok "Removed $NOPASSWD_FILE."
else
    msg_info "$NOPASSWD_FILE is already absent."
fi
SUDO_RULES=$(sudo -l -U "$USERNAME") || die "sudo -l -U $USERNAME failed."
echo "$SUDO_RULES" | grep -q "NOPASSWD" && die "Fact check failed: sudo still grants $USERNAME NOPASSWD."
echo "$SUDO_RULES" | grep -q "(ALL" || die "Fact check failed: $USERNAME has no sudo rights left."
msg_ok "sudo now asks for ${USERNAME}'s own password (checked with 'sudo -l -U $USERNAME')."

# ── Close SSH password login ────────────────────────────────────────
msg_step "5: Close SSH password login (key only from here on)"
# KbdInteractiveAuthentication is PAM's prompt that accepts the same password
# through a second door; its upstream default is yes, so both lines are set
# explicitly instead of trusting a distro default.
DROPIN=/etc/ssh/sshd_config.d/02-hardening.conf
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > "$DROPIN"
if ! sshd -t; then
    rm -f "$DROPIN"
    die "sshd rejected the new config; $DROPIN removed, nothing changed."
fi
systemctl reload ssh || { rm -f "$DROPIN"; die "reload failed; $DROPIN removed, sshd still runs the old config."; }

# Fact check: the effective configuration sshd now parses.
SSHD_EFF=$(sshd -T) || die "sshd -T failed."
PA=$(awk  '$1=="passwordauthentication"      {print $2}' <<<"$SSHD_EFF")
KBD=$(awk '$1=="kbdinteractiveauthentication"{print $2}' <<<"$SSHD_EFF")
PRL=$(awk '$1=="permitrootlogin"             {print $2}' <<<"$SSHD_EFF")
PORT=$(awk '$1=="port"                       {print $2; exit}' <<<"$SSHD_EFF")
[ "$PA" = "no" ]  || die "Fact check failed: passwordauthentication = $PA"
[ "$KBD" = "no" ] || die "Fact check failed: kbdinteractiveauthentication = $KBD"
msg_ok "sshd effective now: passwordauthentication $PA, kbdinteractiveauthentication $KBD"
msg_ok "sshd effective kept: permitrootlogin $PRL (key-only for root, and root has no key)"

# ── Verify before logging out ───────────────────────────────────────
echo ""
echo "=========================================="
echo "  Hardening done - VERIFY before you log out"
echo "=========================================="
echo ""
msg_warn "KEEP THIS SESSION OPEN until the key login is proven."
msg_info "From your LOCAL machine, in a NEW terminal:"
echo ""
echo "       ssh $USERNAME@<VPS_IP> -p $PORT"
echo ""
msg_info "If it logs you in via the key, continue in THIS root shell with:"
echo ""
echo "       bash phase1-kernel.sh"
echo ""
msg_info "If it is rejected, fix it IN THIS session - new sessions need the key now."
msg_info "Key lost some day? VNC console + the root password still gets you in (VNC does not pass through sshd)."

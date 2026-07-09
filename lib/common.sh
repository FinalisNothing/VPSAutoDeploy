#!/bin/bash
# lib/common.sh - Shared utility functions for VPSAutoDeploy
# Source this file from phase scripts: source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

msg_info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
msg_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
msg_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
msg_error() { printf "${RED}[ERR ]${NC}  %s\n" "$*" >&2; }
msg_step()  { printf "\n${CYAN}── Step %s ──${NC}\n" "$*"; }

# ── Error handling ──────────────────────────────────────────────────
die() {
    msg_error "$@"
    exit 1
}

# ── Root check ──────────────────────────────────────────────────────
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "This script must be run as root."
    fi
}

# ── Input validation ────────────────────────────────────────────────

# Validate non-empty string
validate_nonempty() {
    local name="$1" value="$2"
    [ -n "$value" ] || die "$name cannot be empty."
}

# Validate Linux username (POSIX portable: lowercase, digits, underscore, hyphen; start with letter)
validate_username() {
    local val="$1"
    validate_nonempty "USERNAME" "$val"
    if ! [[ "$val" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        die "Invalid username '$val'. Must start with a letter or underscore, contain only lowercase letters, digits, underscores, hyphens."
    fi
    if [ "${#val}" -gt 32 ]; then
        die "Username too long (max 32 characters)."
    fi
}

# Validate port number (1024-65535)
validate_port() {
    local name="$1" val="$2"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1024 ] || [ "$val" -gt 65535 ]; then
        die "$name must be a number between 1024 and 65535. Got: $val"
    fi
}

# Validate email address (basic check)
validate_email() {
    local val="$1"
    if ! [[ "$val" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        die "Invalid email address: $val"
    fi
}

# Validate domain name
validate_domain() {
    local name="$1" val="$2"
    if ! [[ "$val" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        die "$name: invalid domain name '$val'."
    fi
}

# Validate URL path segment (alphanumeric + limited special chars, no leading/trailing slash required)
validate_path() {
    local name="$1" val="$2"
    validate_nonempty "$name" "$val"
    if ! [[ "$val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "$name must contain only letters, digits, underscores, hyphens. Got: $val"
    fi
}

# ── Prompt helpers ──────────────────────────────────────────────────

# Prompt for a value with optional default
# Usage: prompt_value "Prompt text" DEFAULT_VALUE
# Sets REPLY
prompt_value() {
    local prompt="$1"
    local default="${2:-}"
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " REPLY
        REPLY="${REPLY:-$default}"
    else
        read -r -p "$prompt: " REPLY
    fi
}

# Prompt for a password (hidden input)
prompt_password() {
    local prompt="$1"
    read -r -s -p "$prompt: " REPLY
    echo
}

# Generate random alphanumeric string
generate_random_path() {
    local length="${1:-32}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length" || true
}

# ── Template rendering ──────────────────────────────────────────────
# Replace {{VAR}} placeholders in a template file
# Usage: render_template TEMPLATE_FILE OUTPUT_FILE VAR1=val1 VAR2=val2 ...
render_template() {
    local template="$1"
    local output="$2"
    shift 2

    local content
    content="$(cat "$template")"

    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        content="${content//\{\{${key}\}\}/${val}}"
    done

    printf '%s\n' "$content" > "$output"
}

# ── State persistence (resume support) ──────────────────────────────
# State file tracks completed steps; config file saves user inputs.

STATE_FILE="/root/vpsautodeploy.state"
CONFIG_FILE="/root/vpsautodeploy.conf"
CONFIG_FILENAME="vpsautodeploy.conf"

# Mark a step as completed
mark_done() {
    local step="$1"
    echo "$step" >> "$STATE_FILE"
}

# Check if a step is already completed
is_done() {
    local step="$1"
    [ -f "$STATE_FILE" ] && grep -qFx "$step" "$STATE_FILE"
}

# Save all config variables to file (call after input collection).
# Service parameters only - identity (username, passwords, SSH port) is
# owned by phase0/harden-ssh and detected from the system by phase2.
save_config() {
    cat > "$CONFIG_FILE" << CONF
ACME_EMAIL=$(printf '%q' "$ACME_EMAIL")
DIRECT_DOMAIN=$(printf '%q' "$DIRECT_DOMAIN")
CDN_DOMAIN=$(printf '%q' "$CDN_DOMAIN")
XHTTP_PATH=$(printf '%q' "$XHTTP_PATH")
XUI_PANEL_PATH=$(printf '%q' "$XUI_PANEL_PATH")
XUI_PANEL_PORT=$(printf '%q' "$XUI_PANEL_PORT")
BACKEND_WEB=$(printf '%q' "$BACKEND_WEB")
CONF
    chmod 600 "$CONFIG_FILE"
}

# Load config from file; returns 0 if loaded, 1 if not found.
# Search order: /root/vpsautodeploy.conf, then /home/*/vpsautodeploy.conf
load_config() {
    # Primary location
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    # Scan /home/*/ for uploaded config (user may SCP as non-root)
    for candidate in /home/*/"$CONFIG_FILENAME"; do
        if [ -f "$candidate" ]; then
            msg_info "Found config at $candidate, moving to $CONFIG_FILE"
            mv "$candidate" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            source "$CONFIG_FILE"
            return 0
        fi
    done
    return 1
}

# ── Misc ────────────────────────────────────────────────────────────

# Wait for a file to appear (polling)
wait_for_file() {
    local filepath="$1"
    local msg="${2:-Waiting for $filepath ...}"
    msg_info "$msg"
    while [ ! -f "$filepath" ]; do
        sleep 2
    done
    msg_ok "File detected: $filepath"
}

# Run a command and print status
run_step() {
    local desc="$1"
    shift
    msg_info "$desc"
    if "$@"; then
        msg_ok "$desc"
    else
        die "Failed: $desc"
    fi
}

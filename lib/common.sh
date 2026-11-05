#!/bin/bash
# lib/common.sh - Shared helpers for VPSAutoDeploy. Sourced, never executed.

set -euo pipefail

# ── Messages ────────────────────────────────────────────────────────
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

die() {
    msg_error "$@"
    exit 1
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "This script must be run as root."
    fi
}

# ── Value kinds ─────────────────────────────────────────────────────
# Every value that ends up in a config file is checked against its kind.
# The kinds are strict on purpose: a valid value can never break out of the
# place it is rendered into (a JSON string, an nginx directive, a URL).

valid_value() {
    local kind="$1" v="$2"
    case "$kind" in
        email)    [[ "$v" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ;;
        domain)   [ "${#v}" -le 253 ] && [[ "$v" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] ;;
        port)     [[ "$v" =~ ^[0-9]{1,5}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] ;;
        path)     [[ "$v" =~ ^[A-Za-z0-9_-]{1,128}$ ]] ;;
        word)     [[ "$v" =~ ^[A-Za-z0-9._-]{1,64}$ ]] ;;
        uuid)     [[ "$v" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ;;
        key32)    [[ "$v" =~ ^[A-Za-z0-9_-]{43}$ ]] ;;                 # base64url, 32 bytes (X25519 / ML-DSA-65 seed)
        vlessdec) [[ "$v" =~ ^mlkem768x25519plus\.(native|xorpub|random)\.[0-9]+(-[0-9]+)?s(\.[A-Za-z0-9_-]+)+$ ]] ;;
        shortids) printf '%s' "$v" | jq -e 'type == "array" and length > 0
                    and all(.[]; type == "string" and test("^([0-9a-f]{2}){0,8}$"))' >/dev/null 2>&1 ;;
        *)        die "internal: unknown value kind '$kind'" ;;
    esac
}

describe_kind() {
    case "$1" in
        email)    echo "an email address" ;;
        domain)   echo "a domain name such as a.example.com" ;;
        port)     echo "a port number 1-65535" ;;
        path)     echo "letters, digits, '_' and '-' only (1-128 chars, no slashes)" ;;
        word)     echo "letters, digits, '.', '_' and '-' only (1-64 chars)" ;;
        uuid)     echo "a UUID" ;;
        key32)    echo "a 43-char base64url key (xray x25519 / mldsa65 output)" ;;
        vlessdec) echo "a VLESS Encryption 'decryption' string (mlkem768x25519plus.<mode>.<ticket>s.<key>)" ;;
        shortids) echo 'a JSON array of hex strings, e.g. ["0123ab","cd"]' ;;
        *)        echo "$1" ;;
    esac
}

# Kept for scripts that validate the SSH port (1024-65535) and usernames.
validate_port() {
    local name="$1" val="$2"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1024 ] || [ "$val" -gt 65535 ]; then
        die "$name must be a number between 1024 and 65535. Got: $val"
    fi
}

validate_username() {
    local val="$1"
    [ -n "$val" ] || die "USERNAME cannot be empty."
    if ! [[ "$val" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "${#val}" -gt 32 ]; then
        die "Invalid username '$val'."
    fi
}

# ── KEY=VALUE files ─────────────────────────────────────────────────
# One KEY=VALUE per line; '#' comments and blank lines are ignored. The value
# is everything after the first '=' taken literally (trailing whitespace
# trimmed): no quoting, no expansion, and the file is never sourced.

kv_load() {
    local file="$1"
    local -n _kv_out="$2"
    local line n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            local val="${BASH_REMATCH[2]}"
            val="${val%"${val##*[![:space:]]}"}"
            _kv_out["${BASH_REMATCH[1]}"]="$val"
        else
            die "$file:$n: expected KEY=VALUE, got: $line"
        fi
    done < "$file"
}

# kv_save FILE ARRAY [KEY...]: listed keys first, the rest sorted. Atomic, mode 600.
kv_save() {
    local file="$1"
    local -n _kv_in="$2"
    shift 2
    local tmp k
    local -A seen=()
    tmp="$(mktemp "$(dirname "$file")/.kv.XXXXXX")"
    {
        for k in "$@"; do
            [[ -v _kv_in[$k] ]] || continue
            printf '%s=%s\n' "$k" "${_kv_in[$k]}"
            seen[$k]=1
        done
        for k in $(printf '%s\n' "${!_kv_in[@]}" | sort); do
            [[ -v seen[$k] ]] && continue
            printf '%s=%s\n' "$k" "${_kv_in[$k]}"
        done
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

# ── Templates ───────────────────────────────────────────────────────
#   {{NAME}}          replaced by the value's text
#   "{{NAME:json}}"   the quoted token is replaced by the value as raw JSON
# render_template TEMPLATE OUTPUT MODE ARRAY  (MODE: json|text)
# Fails on a missing value, a value its position cannot carry, a placeholder
# left over, or (json) output that is not JSON. OUTPUT is written atomically.
render_template() {
    local tpl="$1" out="$2" mode="$3"
    local -n _rt_vals="$4"
    local content ph name val tmp
    [ -f "$tpl" ] || die "template not found: $tpl"
    content="$(< "$tpl")"
    while IFS= read -r ph; do
        [ -n "$ph" ] || continue
        name="${ph#\{\{}"
        name="${name%\}\}}"
        if [[ "$name" == *:json ]]; then
            name="${name%:json}"
            [ "$mode" = json ] || die "$tpl: {{$name:json}} is only allowed in JSON templates"
            [[ -v _rt_vals[$name] ]] || die "$tpl: no value for $name"
            val="$(printf '%s' "${_rt_vals[$name]}" | jq -c . 2>/dev/null)" \
                || die "$tpl: $name is not valid JSON: ${_rt_vals[$name]}"
            [[ "$val" == *'{{'* || "$val" == *'}}'* ]] && die "$tpl: $name contains '{{' or '}}'"
            content="${content//"\"$ph\""/"$val"}"
        else
            [[ -v _rt_vals[$name] ]] || die "$tpl: no value for $name"
            val="${_rt_vals[$name]}"
            if [[ "$val" =~ [[:cntrl:]] || "$val" == *'{{'* || "$val" == *'}}'* ]]; then
                die "$tpl: $name contains characters a template cannot carry"
            fi
            if [ "$mode" = json ] && [[ "$val" == *[\"\\]* ]]; then
                die "$tpl: $name contains a quote or backslash"
            fi
            content="${content//"$ph"/"$val"}"
        fi
    done < <(grep -oE '\{\{[A-Z][A-Z0-9_]*(:json)?\}\}' "$tpl" | sort -u)
    if [[ "$content" =~ \{\{[^}]*\}\} ]]; then
        die "$tpl: placeholder left after rendering: ${BASH_REMATCH[0]}"
    fi
    if [ "$mode" = json ]; then
        printf '%s\n' "$content" | jq -e . >/dev/null 2>&1 || die "$tpl: rendered output is not valid JSON"
    fi
    tmp="$(mktemp "$(dirname "$out")/.render.XXXXXX")"
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$out"
}

# ── Random values ───────────────────────────────────────────────────
# head exits after a fixed byte count and tr reads to EOF, so no SIGPIPE.
random_alnum() {
    local n="$1" out=""
    while [ "${#out}" -lt "$n" ]; do
        out+="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    done
    printf '%s' "${out:0:$n}"
}

random_hex() {
    local n="$1"
    od -An -tx1 -N "$(( (n + 1) / 2 ))" /dev/urandom | tr -d ' \n' | head -c "$n"
}

random_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# ── Packages ────────────────────────────────────────────────────────

# install_if_changed SRC DEST [MODE]: succeeds only when DEST was (re)written.
install_if_changed() {
    local src="$1" dest="$2" mode="${3:-644}"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        return 1
    fi
    install -o root -g root -m "$mode" "$src" "$dest"
}
ensure_packages() {
    local missing=() p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    msg_info "Installing: ${missing[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

# ── Downloads ───────────────────────────────────────────────────────
fetch() {
    local url="$1" out="$2"
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 15 -o "$out" "$url"
}

# Tag behind a GitHub "latest" release, so the asset and its checksum file are
# fetched from the same release even if a new one is published in between.
github_latest_tag() {
    local repo="$1" url
    url="$(curl -fsSLI --retry 3 --retry-all-errors --connect-timeout 15 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$repo/releases/latest")" || return 1
    url="${url%/}"
    [[ "$url" == */releases/tag/* ]] || return 1
    printf '%s' "${url##*/releases/tag/}"
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

# ── URLs ────────────────────────────────────────────────────────────
# encodeURIComponent: everything except A-Z a-z 0-9 - _ . ! ~ * ' ( ) is %XX.
urlencode() {
    local s="$1" out="" c i
    local LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~!*\'\(\)-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# ── Interaction ─────────────────────────────────────────────────────
# ASSUME_YES=1 (set by --yes) answers confirmations with yes; prompts that
# need real input fail instead of waiting when there is no terminal.
ASSUME_YES="${ASSUME_YES:-0}"

is_interactive() {
    [ -t 0 ]
}

confirm() {
    local prompt="$1" reply
    if [ "$ASSUME_YES" = 1 ]; then
        msg_info "$prompt [y/N]: y (--yes)"
        return 0
    fi
    is_interactive || die "Need a confirmation but there is no terminal: $prompt (re-run with --yes to accept)"
    read -r -p "$prompt [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

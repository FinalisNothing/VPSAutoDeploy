#!/bin/bash
# lib/engine.sh - The proxy scheme engine. Sourced by phase2-deploy.sh.
#
# A scheme (schemes/<id>/scheme.sh) is one complete way of running the proxy on
# this VPS: the inputs it needs, the guide that walks the user through them,
# the deployment steps, the health checks and the client links. The engine
# knows nothing about any particular scheme. It loads one, collects its
# inputs, runs its steps, and marks what it adds to shared places (firewall
# rules carry the scheme's name), so that switching to another scheme removes
# exactly that and nothing else on the machine.
# The contract a scheme must follow is written down in schemes/README.md.

# shellcheck disable=SC2034 # globals set here are read by phase2-deploy.sh and the schemes
VPSAD_ROOT="${VPSAD_ROOT:?VPSAD_ROOT must point at the repository}"
VPSAD_STATE_DIR="${VPSAD_STATE_DIR:-/etc/vpsautodeploy}"
ENGINE_STATE="$VPSAD_STATE_DIR/engine.state"
CONF_NAME="vpsautodeploy.conf"

for _component in "$VPSAD_ROOT"/components/*/component.sh; do
    # shellcheck source=/dev/null
    source "$_component"
done
unset _component

# ── Engine state ────────────────────────────────────────────────────

engine_init_state() {
    install -d -m 700 "$VPSAD_STATE_DIR" "$VPSAD_STATE_DIR/schemes" "$VPSAD_STATE_DIR/backup"
}

engine_get() {
    local key="$1"
    local -A _st=()
    [ -f "$ENGINE_STATE" ] || return 0
    kv_load "$ENGINE_STATE" _st
    printf '%s' "${_st[$key]:-}"
}

engine_set() {
    local -A _st=()
    [ -f "$ENGINE_STATE" ] && kv_load "$ENGINE_STATE" _st
    while [ $# -ge 2 ]; do
        if [ -n "$2" ]; then _st[$1]="$2"; else unset "_st[$1]"; fi
        shift 2
    done
    kv_save "$ENGINE_STATE" _st ACTIVE_SCHEME ACTIVE_STATE ACTIVATED_AT
}
# ACTIVE_SCHEME is the scheme whose resources are on the machine. ACTIVE_STATE
# is "deploying" from its first step until it was deployed completely, so a
# failed run is resumed by the next one and cleaned up by a switch.

# Copy a file into the state dir under a timestamped name; prints the copy's path.
backup_file() {
    local src="$1" dest
    [ -f "$src" ] || return 0
    install -d -m 700 "$VPSAD_STATE_DIR/backup"
    dest="$VPSAD_STATE_DIR/backup/$(date +%Y%m%d-%H%M%S)$(printf '%s' "$src" | tr '/' '_')"
    cp -p "$src" "$dest"
    printf '%s' "$dest"
}

# ── Scheme discovery ────────────────────────────────────────────────
# Schemes live in schemes/<id>/ of this repository. VPSAD_SCHEME_PATH
# (colon-separated) adds directories for private schemes kept elsewhere.

scheme_search_dirs() {
    printf '%s\n' "$VPSAD_ROOT/schemes"
    local IFS=:
    local d
    for d in ${VPSAD_SCHEME_PATH:-}; do
        [ -n "$d" ] && printf '%s\n' "$d"
    done
}

scheme_ids() {
    local d f
    while IFS= read -r d; do
        for f in "$d"/*/scheme.sh; do
            [ -f "$f" ] && basename "$(dirname "$f")"
        done
    done < <(scheme_search_dirs)
    return 0
}

scheme_path() {
    local id="$1" d
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    while IFS= read -r d; do
        if [ -f "$d/$id/scheme.sh" ]; then
            printf '%s' "$d/$id"
            return 0
        fi
    done < <(scheme_search_dirs)
    return 1
}

# ── Inputs ──────────────────────────────────────────────────────────
# A scheme declares every value it needs in scheme_inputs():
#   input NAME KIND "prompt" [--default V] [--advanced] [--secret] [--optional] [--help TEXT]
# plain      asked when missing
# --default  used when missing; still offered at the prompt
# --advanced never asked; taken from the conf file or the default
# --secret   never asked; empty means "generate during deployment"
#            (ensure_secret), a value from the conf file is imported as is
# --optional may stay empty
# Values come from, in order: the uploaded conf file, the values stored by
# an earlier run, the guide's prompts. KIND is one of valid_value's kinds.

declare -a INPUT_ORDER=()
declare -A INPUT_KIND=() INPUT_PROMPT=() INPUT_DEFAULT=() INPUT_FLAGS=() INPUT_HELP=()
declare -A PARAMS=() CONF_VALUES=()

input() {
    local name="$1" kind="$2" prompt="$3"
    shift 3
    [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "scheme $SCHEME_ID: bad input name '$name'"
    describe_kind "$kind" >/dev/null
    INPUT_ORDER+=("$name")
    INPUT_KIND[$name]="$kind"
    INPUT_PROMPT[$name]="$prompt"
    INPUT_FLAGS[$name]=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --default)  INPUT_DEFAULT[$name]="$2"; shift ;;
            --help)     INPUT_HELP[$name]="$2"; shift ;;
            --advanced|--secret|--optional) INPUT_FLAGS[$name]+=" ${1#--}" ;;
            *) die "scheme $SCHEME_ID: input $name: unknown option $1" ;;
        esac
        shift
    done
}

input_has() {
    [[ " ${INPUT_FLAGS[$1]} " == *" $2 "* ]]
}

# Value of a parameter (inputs and the values a scheme sets itself).
param() {
    [[ -v PARAMS[$1] ]] || die "internal: parameter $1 is not set"
    printf '%s' "${PARAMS[$1]}"
}

params_save() {
    install -d -m 700 "$SCHEME_STATE"
    kv_save "$SCHEME_STATE/params" PARAMS "${INPUT_ORDER[@]}"
}

set_param() {
    PARAMS[$1]="$2"
    params_save
}

check_input_value() {
    local name="$1" val="$2"
    if [ -z "$val" ]; then
        input_has "$name" optional && return 0
        input_has "$name" secret && return 0
        return 1
    fi
    valid_value "${INPUT_KIND[$name]}" "$val"
}

# Ask for an input unless it already has a valid value.
ask() {
    local name="$1" val="${PARAMS[$1]:-}" reply def
    [[ -v INPUT_KIND[$name] ]] || die "internal: ask $name: not declared in scheme_inputs"
    if [ -n "$val" ]; then
        valid_value "${INPUT_KIND[$name]}" "$val" \
            || die "$name='$val' is not $(describe_kind "${INPUT_KIND[$name]}")."
        msg_ok "$name = $(display_value "$name")"
        return 0
    fi
    if input_has "$name" secret || input_has "$name" advanced; then
        return 0
    fi
    def="${INPUT_DEFAULT[$name]:-}"
    if ! is_interactive || [ "$ASSUME_YES" = 1 ]; then
        if [ -n "$def" ]; then
            PARAMS[$name]="$def"
            msg_ok "$name = $def (default)"
            return 0
        fi
        input_has "$name" optional && return 0
        die "$name is required (${INPUT_PROMPT[$name]}). Put $name=... into $CONF_NAME or run interactively."
    fi
    [ -n "${INPUT_HELP[$name]:-}" ] && printf '        %s\n' "${INPUT_HELP[$name]}"
    while :; do
        if [ -n "$def" ]; then
            read -r -p "  ${INPUT_PROMPT[$name]} [$def]: " reply
            reply="${reply:-$def}"
        else
            read -r -p "  ${INPUT_PROMPT[$name]}: " reply
        fi
        if [ -z "$reply" ] && input_has "$name" optional; then
            break
        fi
        if valid_value "${INPUT_KIND[$name]}" "$reply"; then
            PARAMS[$name]="$reply"
            break
        fi
        msg_warn "Not $(describe_kind "${INPUT_KIND[$name]}"). Try again."
    done
}

display_value() {
    local name="$1" val="${PARAMS[$1]:-}"
    if [ -z "$val" ]; then
        input_has "$name" secret && printf '(generated during deployment)' || printf '(empty)'
    elif input_has "$name" secret; then
        printf '(set, %d chars)' "${#val}"
    else
        printf '%s' "$val"
    fi
}

# Generate a secret during deployment if it has no value yet; saved at once,
# so a later failure never loses a generated key.
ensure_secret() {
    local name="$1"
    shift
    [ -n "${PARAMS[$name]:-}" ] && return 0
    local val
    val="$("$@")" || die "generating $name failed"
    valid_value "${INPUT_KIND[$name]}" "$val" || die "generated $name is not $(describe_kind "${INPUT_KIND[$name]}")"
    set_param "$name" "$val"
    msg_ok "Generated $name"
}

# ── Uploaded files ──────────────────────────────────────────────────
# Uploads are only taken from /root and the deploy user's home, must be
# regular files (not symlinks) owned by root or that user, and are judged
# complete by their content, never by their size settling.

uploaded_file() {
    local name="$1" dir f owner
    for dir in /root "${USER_HOME:-}"; do
        [ -n "$dir" ] || continue
        f="$dir/$name"
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        owner="$(stat -c %U "$f")"
        if [ "$owner" != root ] && [ "$owner" != "${USERNAME:-}" ]; then
            msg_warn "Ignoring $f: owned by $owner"
            continue
        fi
        printf '%s' "$f"
        return 0
    done
    return 1
}

# ask_file NAME FILENAME VALIDATOR DESCRIPTION
# Stores the validated content as $SCHEME_STATE/files/NAME (600) and removes
# the upload, so no key is left in a home directory; later runs reuse the
# stored copy instead of asking again.
ask_file() {
    local name="$1" filename="$2" validator="$3" desc="$4"
    local store="$SCHEME_STATE/files/$name" src tmp line choice
    install -d -m 700 "$SCHEME_STATE/files"
    if [ -s "$store" ] && "$validator" "$store"; then
        msg_ok "$desc: using the copy stored by an earlier run"
        return 0
    fi
    src="$(uploaded_file "$filename")" || src=""
    if [ -z "$src" ]; then
        is_interactive && [ "$ASSUME_YES" != 1 ] \
            || die "$desc missing: upload it as ~/$filename (or /root/$filename) and re-run."
        echo ""
        msg_info "$desc is needed."
        echo "  1) Upload it:  scp -P ${SSH_PORT:-22} $filename ${USERNAME:-user}@<VPS_IP>:~/"
        echo "  2) Paste it here"
        read -r -p "Choose [1/2]: " choice
        if [ "$choice" = 2 ]; then
            tmp="$(mktemp)"
            chmod 600 "$tmp"
            msg_info "Paste $filename, then a line containing only EOF:"
            while IFS= read -r line; do
                [ "$line" = EOF ] && break
                printf '%s\n' "$line" >> "$tmp"
            done
            if ! "$validator" "$tmp"; then
                rm -f "$tmp"
                die "$desc: the pasted text is not valid. Re-run and paste it again."
            fi
            install -m 600 "$tmp" "$store"
            rm -f "$tmp"
            msg_ok "$desc stored"
            return 0
        fi
        msg_info "Waiting for ~/$filename (Ctrl+C to abort)..."
        until src="$(uploaded_file "$filename")"; do sleep 2; done
    fi
    # Content decides completeness: keep re-validating while an upload is still running.
    local tries=0
    until "$validator" "$src"; do
        tries=$((tries + 1))
        [ "$tries" -eq 1 ] && msg_info "$src found but not valid yet - waiting for the upload to finish..."
        [ "$tries" -ge 90 ] && die "$desc: $src is still not valid after 3 minutes."
        sleep 2
    done
    install -m 600 "$src" "$store"
    rm -f "$src"
    msg_ok "$desc stored (upload $src removed)"
}

# ── Steps ───────────────────────────────────────────────────────────
# Steps are idempotent: each one checks the machine before acting, so a
# re-run converges instead of trusting a list of "done" markers.

STEP_N=0
CURRENT_STEP=""

step() {
    local id="$1" desc="$2"
    shift 2
    STEP_N=$((STEP_N + 1))
    CURRENT_STEP="$id"
    msg_step "$STEP_N · $desc"
    "$@"
    CURRENT_STEP=""
}

# ── Checks (status / verify) ────────────────────────────────────────

CHECK_FAILS=0
CHECK_WARNS=0

check_ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
check_warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; CHECK_WARNS=$((CHECK_WARNS + 1)); }
check_fail() { printf "  ${RED}✗${NC} %s\n" "$*"; CHECK_FAILS=$((CHECK_FAILS + 1)); }

# Names of the processes listening on proto/port (tcp/443, udp/443).
port_listeners() {
    local proto="${1%/*}" port="${1#*/}" flag
    [ "$proto" = udp ] && flag=-lunp || flag=-ltnp
    ss -H "$flag" "sport = :$port" 2>/dev/null | { grep -o 'users:(("[^"]*"' || true; } \
        | sed 's/users:(("//; s/"$//' | sort -u
}

check_listening() {
    local spec="$1" want="$2" who
    who="$(port_listeners "$spec" | paste -sd, -)"
    if [ -z "$who" ]; then
        check_fail "$spec: nothing listening (expected $want)"
    elif [[ ",$who," == *",$want,"* ]]; then
        check_ok "$spec: $want listening"
    else
        check_fail "$spec: held by $who, expected $want"
    fi
}

check_unix_socket() {
    local path="$1" want="$2"
    if ss -H -xlp 2>/dev/null | awk '{print $5}' | grep -qxF "$path"; then
        check_ok "$path: $want listening"
    else
        check_fail "$path: no listener (expected $want)"
    fi
}

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        check_ok "$svc: active"
    else
        check_fail "$svc: $(systemctl is-active "$svc" 2>/dev/null || true)"
    fi
}

# ── Loading a scheme ────────────────────────────────────────────────

load_scheme() {
    local id="$1" dir
    dir="$(scheme_path "$id")" || die "Unknown scheme '$id'. Available: $(scheme_ids | paste -sd' ' -)"
    SCHEME_ID="$id"
    SCHEME_DIR="$dir"
    SCHEME_STATE="$VPSAD_STATE_DIR/schemes/$id"
    SCHEME_TITLE=""
    SCHEME_SUMMARY=()
    SCHEME_PORTS=()
    SCHEME_COMPONENTS=()
    SCHEME_PROVIDES=()
    INPUT_ORDER=()
    INPUT_KIND=() INPUT_PROMPT=() INPUT_DEFAULT=() INPUT_FLAGS=() INPUT_HELP=()
    PARAMS=()
    # shellcheck source=/dev/null
    source "$dir/scheme.sh"
    [ -n "$SCHEME_TITLE" ] || die "scheme $id: SCHEME_TITLE is empty"
    local fn
    for fn in scheme_inputs scheme_guide scheme_deploy scheme_verify; do
        declare -F "$fn" >/dev/null || die "scheme $id: $fn() is missing"
    done
    scheme_inputs
    if [ -f "$SCHEME_STATE/params" ]; then
        local -A stored=()
        local k
        kv_load "$SCHEME_STATE/params" stored
        for k in "${!stored[@]}"; do PARAMS[$k]="${stored[$k]}"; done
    fi
}

scheme_describe() {
    local line
    printf "  ${CYAN}%s${NC} — %s\n" "$SCHEME_ID" "$SCHEME_TITLE"
    for line in "${SCHEME_SUMMARY[@]}"; do
        printf '      %s\n' "$line"
    done
    [ "${#SCHEME_PORTS[@]}" -gt 0 ] && printf '      Public ports: %s\n' "${SCHEME_PORTS[*]}"
    for line in "${SCHEME_PROVIDES[@]}"; do
        printf '      Provides to local services: %s\n' "$line"
    done
}

list_schemes() {
    local id active state
    active="$(engine_get ACTIVE_SCHEME 2>/dev/null || true)"
    state="$(engine_get ACTIVE_STATE 2>/dev/null || true)"
    echo ""
    while IFS= read -r id; do
        ( load_scheme "$id"; scheme_describe )
        [ "$id" = "$active" ] && printf "      ${GREEN}(%s)${NC}\n" "${state:-active}"
        echo ""
    done < <(scheme_ids)
}

# choose_scheme [DEFAULT_ID]: sets CHOSEN_SCHEME. With a single scheme or a
# default, Enter accepts it.
choose_scheme() {
    local default="${1:-}" ids=() id i reply def_n=""
    mapfile -t ids < <(scheme_ids)
    [ "${#ids[@]}" -gt 0 ] || die "No schemes found under $VPSAD_ROOT/schemes"
    echo ""
    echo "  Available proxy schemes:"
    echo ""
    i=0
    for id in "${ids[@]}"; do
        i=$((i + 1))
        [ "$id" = "$default" ] && def_n="$i"
        printf '  %d)' "$i"
        ( load_scheme "$id"; scheme_describe )
        [ "$id" = "$default" ] && printf "      ${GREEN}(active)${NC}\n"
        echo ""
    done
    [ "${#ids[@]}" -eq 1 ] && def_n=1
    if [ -n "$def_n" ] && { [ "$ASSUME_YES" = 1 ] || ! is_interactive; }; then
        CHOSEN_SCHEME="${ids[$((def_n - 1))]}"
        return 0
    fi
    is_interactive || die "Several schemes available; choose one with --scheme ID or SCHEME= in $CONF_NAME."
    while :; do
        if [ -n "$def_n" ]; then
            read -r -p "Choose [1-${#ids[@]}, Enter = $def_n]: " reply
            reply="${reply:-$def_n}"
        else
            read -r -p "Choose [1-${#ids[@]}]: " reply
        fi
        if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#ids[@]}" ]; then
            CHOSEN_SCHEME="${ids[$((reply - 1))]}"
            return 0
        fi
    done
}

# ── Conf file ───────────────────────────────────────────────────────
# vpsautodeploy.conf (uploaded to /root or the deploy user's home) carries
# SCHEME= plus that scheme's inputs. It is imported once into the scheme's
# state and the upload removed; the state is what later runs read.

load_conf_upload() {
    local f
    f="$(uploaded_file "$CONF_NAME")" || return 1
    kv_load "$f" CONF_VALUES
    CONF_FILE="$f"
    return 0
}

apply_conf_values() {
    local k unknown=()
    for k in "${!CONF_VALUES[@]}"; do
        [ "$k" = SCHEME ] && continue
        if [[ -v INPUT_KIND[$k] ]]; then
            [ -n "${CONF_VALUES[$k]}" ] || continue
            check_input_value "$k" "${CONF_VALUES[$k]}" \
                || die "$CONF_NAME: $k='${CONF_VALUES[$k]}' is not $(describe_kind "${INPUT_KIND[$k]}")."
            PARAMS[$k]="${CONF_VALUES[$k]}"
        else
            unknown+=("$k")
        fi
    done
    [ "${#unknown[@]}" -eq 0 ] || msg_warn "$CONF_NAME: ignoring keys scheme $SCHEME_ID does not declare: ${unknown[*]}"
}

finish_inputs() {
    local name
    for name in "${INPUT_ORDER[@]}"; do
        if [ -z "${PARAMS[$name]:-}" ] && [ -n "${INPUT_DEFAULT[$name]:-}" ] && input_has "$name" advanced; then
            PARAMS[$name]="${INPUT_DEFAULT[$name]}"
        fi
        if [ -z "${PARAMS[$name]:-}" ] && ! input_has "$name" secret && ! input_has "$name" optional; then
            ask "$name"
        fi
        check_input_value "$name" "${PARAMS[$name]:-}" \
            || die "$name is missing or invalid (${INPUT_PROMPT[$name]})."
    done
}

show_inputs() {
    local name
    for name in "${INPUT_ORDER[@]}"; do
        printf '  %-24s %s\n' "$name" "$(display_value "$name")"
    done
}

generate_conf_template() {
    local out="$1" name line flags
    {
        echo "# VPSAutoDeploy configuration for scheme '$SCHEME_ID'"
        echo "# $SCHEME_TITLE"
        for line in "${SCHEME_SUMMARY[@]}"; do echo "#   $line"; done
        echo "#"
        echo "# Format: KEY=VALUE, one per line; the value is taken literally (no quotes)."
        echo "# Upload next to any files the scheme asks for, then run phase2-deploy.sh:"
        echo "#   scp -P <ssh_port> $CONF_NAME <user>@<VPS_IP>:~/"
        echo ""
        echo "SCHEME=$SCHEME_ID"
        for name in "${INPUT_ORDER[@]}"; do
            input_has "$name" secret && continue
            echo ""
            echo "# ${INPUT_PROMPT[$name]} — $(describe_kind "${INPUT_KIND[$name]}")"
            [ -n "${INPUT_HELP[$name]:-}" ] && echo "# ${INPUT_HELP[$name]}"
            flags=""
            input_has "$name" advanced && flags="advanced, "
            if [ -n "${INPUT_DEFAULT[$name]:-}" ]; then
                echo "# (${flags}default: ${INPUT_DEFAULT[$name]})"
            elif input_has "$name" optional; then
                echo "# (${flags}optional)"
            else
                echo "# (required)"
            fi
            echo "$name="
        done
        echo ""
        echo "# ── Secrets ─────────────────────────────────────────────────────"
        echo "# Leave empty to have them generated on the VPS. Fill them in to keep"
        echo "# existing clients working when you move to a new machine."
        for name in "${INPUT_ORDER[@]}"; do
            input_has "$name" secret || continue
            echo "# ${INPUT_PROMPT[$name]} — $(describe_kind "${INPUT_KIND[$name]}")"
            echo "$name="
        done
    } > "$out"
    chmod 600 "$out"
}

# ── Activation, switching, deactivation ─────────────────────────────

# Ports the scheme needs must be free or already held by its own components.
check_port_conflicts() {
    local spec who name bad=0
    for spec in "${SCHEME_PORTS[@]}"; do
        while IFS= read -r who; do
            [ -n "$who" ] || continue
            for name in "${SCHEME_COMPONENTS[@]}"; do
                [ "$who" = "$name" ] && continue 2
            done
            msg_error "$spec is in use by '$who', which this scheme does not manage."
            bad=1
        done < <(port_listeners "$spec")
    done
    [ "$bad" -eq 0 ] || die "Free the ports above first (an old 3x-ui install: systemctl disable --now x-ui)."
}

# Runs in a subshell: loading the old scheme must not touch the new one.
deactivate_active_scheme() {
    local active
    active="$(engine_get ACTIVE_SCHEME)"
    [ -n "$active" ] || return 0
    CURRENT_STEP="deactivate $active"
    (
        load_scheme "$active"
        msg_info "Deactivating scheme '$active'"
        if declare -F scheme_deactivate >/dev/null; then
            scheme_deactivate
        fi
        fw_close_owned
        local c
        for c in "${SCHEME_COMPONENTS[@]}"; do
            if declare -F "${c}_release" >/dev/null; then
                "${c}_release"
            fi
        done
    )
    engine_set ACTIVE_SCHEME "" ACTIVE_STATE "" ACTIVATED_AT ""
    CURRENT_STEP=""
    msg_ok "Scheme '$active' deactivated (its stored inputs are kept for a later switch back)"
}

# What other local services lose when the active scheme is replaced.
warn_lost_provides() {
    local active="$1" line
    local -a old=()
    mapfile -t old < <( load_scheme "$active"; printf '%s\n' "${SCHEME_PROVIDES[@]}" )
    for line in "${old[@]}"; do
        [ -n "$line" ] || continue
        if ! printf '%s\n' "${SCHEME_PROVIDES[@]}" | grep -qxF "$line"; then
            msg_warn "Scheme '$active' provides, and '$SCHEME_ID' does not: $line"
            msg_warn "Local services that rely on it will stop working."
        fi
    done
}

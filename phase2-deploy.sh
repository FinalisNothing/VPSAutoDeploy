#!/bin/bash
# phase2-deploy.sh - Deploy (or switch to) a proxy scheme on the hardened VPS.
# Run after the phase1 kernel reboot: log in as your user, `sudo -i`, cd here.
#
# Earlier phases own identity and login, so this script never asks for them:
#   phase0        created the sudo user, baked the SSH port in at DD time
#   harden-ssh    installed your key, closed password login, set passwords
#   phase1        BBR v3 kernel + qdisc (+ virtio_balloon blacklist)
# The preflight DETECTS the user and SSH port and verifies those contracts.
#
# What gets deployed is a *scheme*: schemes/<id>/ describes one complete way
# of running the proxy - its inputs, a guide that walks you through them,
# the deployment steps, health checks and client links. You choose a scheme
# (or SCHEME= in the conf file); switching to another one later removes what
# the old scheme owned and leaves everything else on the machine alone.
#
# Usage:
#   bash phase2-deploy.sh [--scheme ID] [--yes] [--xray-version V]  deploy / switch
#   bash phase2-deploy.sh --list                     schemes and what they need
#   bash phase2-deploy.sh --status                   observed health (exit 1 on failure)
#   bash phase2-deploy.sh --links                    client share links of the active scheme
#   bash phase2-deploy.sh --update [--xray-version V]  xray-core + geodata, tested first
#   bash phase2-deploy.sh --deactivate [--yes]       remove what the active scheme owns
#   bash phase2-deploy.sh --generate-config [ID] [FILE]  conf template for a scheme
#
# Zero-touch: upload vpsautodeploy.conf (SCHEME= plus the scheme's inputs) and
# any files the scheme asks for to your home directory, then run with --yes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VPSAD_ROOT="$SCRIPT_DIR"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/guide.sh"
source "$SCRIPT_DIR/lib/engine.sh"

usage() {
    sed -n '/^# Usage:/,/^# Zero-touch/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

###############################################################################
# System detection - identity facts are read from the system, never asked for:
#   USERNAME  the phase0 user (sudo -i keeps SUDO_USER; fallback: UID 1000)
#   SSH_PORT  the running sshd's effective port
###############################################################################
detect_system() {
    USERNAME="${SUDO_USER:-}"
    if [ -z "$USERNAME" ] || [ "$USERNAME" = "root" ]; then
        USERNAME="$(getent passwd 1000 2>/dev/null | cut -d: -f1)" || USERNAME=""
    fi
    [ -n "$USERNAME" ] || die "Cannot detect the phase0 user (no SUDO_USER, no UID-1000 account). Log in as your user, then: sudo -i"
    validate_username "$USERNAME"
    USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
    [ -d "$USER_HOME" ] || die "Home directory $USER_HOME of $USERNAME not found."
    id -nG "$USERNAME" | tr ' ' '\n' | grep -qx sudo \
        || die "$USERNAME is not in the sudo group - were phase0 and harden-ssh completed?"
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')" || SSH_PORT=""
    [ -n "$SSH_PORT" ] || die "Cannot read the effective SSH port (sshd -T failed). Is sshd running?"
    validate_port "SSH_PORT (detected)" "$SSH_PORT"
}

# Verify the contracts the earlier phases established.
verify_hardening() {
    local pa cc
    pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')" || pa=""
    if [ "$pa" = "no" ]; then
        msg_ok "sshd: password login closed (harden-ssh contract holds)"
    else
        msg_warn "sshd still accepts passwords (PasswordAuthentication=${pa:-unknown})."
        msg_warn "harden-ssh.sh was not run or was undone. Deploying on an unhardened box is unsafe."
        confirm "Continue anyway?" || die "Aborted. Run: bash harden-ssh.sh"
    fi
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" || cc=""
    if [ "$cc" = "bbr" ]; then
        msg_ok "kernel: BBR active (phase1 contract holds)"
    else
        msg_warn "TCP congestion control is '${cc:-unknown}', not bbr - phase1 missing or its reboot skipped."
        confirm "Continue anyway?" || die "Aborted. Run: bash phase1-kernel.sh"
    fi
}

take_lock() {
    exec 9>/run/vpsautodeploy.lock
    flock -n 9 || die "Another phase2-deploy.sh is running."
}

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -n "${CURRENT_STEP:-}" ]; then
        msg_error "Stopped during step '$CURRENT_STEP'. Fix the cause and run phase2-deploy.sh again:"
        msg_error "steps check the machine before acting, so a re-run continues where this one failed."
    fi
}
trap on_exit EXIT

banner() {
    echo ""
    echo "=========================================="
    echo "  Phase 2: $1"
    echo "=========================================="
}

print_links() {
    local links="$SCHEME_STATE/links.txt"
    declare -F scheme_links >/dev/null || return 0
    install -d -m 700 "$SCHEME_STATE"
    ( umask 077; scheme_links > "$links" )
    echo ""
    msg_info "Client share links (also in $links):"
    echo ""
    cat "$links"
}

###############################################################################
# Commands
###############################################################################

cmd_deploy() {
    require_root
    take_lock
    banner "Proxy scheme deployment"

    msg_step "Preflight"
    detect_system
    msg_ok "User: $USERNAME (home: $USER_HOME)"
    msg_ok "SSH port: $SSH_PORT"
    verify_hardening
    ensure_packages curl jq openssl ca-certificates iproute2 cron
    engine_init_state
    CONF_FILE=""
    if load_conf_upload; then
        msg_ok "Found $CONF_FILE"
    fi

    local active target
    active="$(engine_get ACTIVE_SCHEME)"
    target="${OPT_SCHEME:-${CONF_VALUES[SCHEME]:-}}"
    if [ -z "$target" ]; then
        if [ -n "$active" ] && { [ "$ASSUME_YES" = 1 ] || ! is_interactive; }; then
            target="$active"
        else
            choose_scheme "$active"
            target="$CHOSEN_SCHEME"
        fi
    fi
    load_scheme "$target"

    msg_step "Scheme"
    scheme_describe
    if [ -n "$active" ] && [ "$active" != "$SCHEME_ID" ]; then
        msg_warn "Active scheme is '$active'; it will be deactivated before '$SCHEME_ID' is deployed."
        warn_lost_provides "$active"
    fi

    msg_step "Guide"
    apply_conf_values
    scheme_guide
    finish_inputs
    params_save
    if [ -n "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        msg_info "$CONF_FILE imported into $SCHEME_STATE/params and removed"
    fi
    echo ""
    msg_info "Inputs for '$SCHEME_ID':"
    show_inputs
    echo ""
    confirm "Deploy scheme '$SCHEME_ID' with these values?" || die "Aborted. Inputs are saved; re-run to continue."

    if [ -n "$active" ] && [ "$active" != "$SCHEME_ID" ]; then
        msg_step "Deactivate '$active'"
        deactivate_active_scheme
    fi

    msg_step "Base (independent of the scheme)"
    fw_base "$SSH_PORT"
    fail2ban_base "$SSH_PORT"
    check_port_conflicts

    engine_set ACTIVE_SCHEME "$SCHEME_ID" ACTIVE_STATE deploying ACTIVATED_AT ""
    STEP_N=0
    scheme_deploy

    msg_step "Verify"
    CHECK_FAILS=0 CHECK_WARNS=0
    scheme_verify
    engine_set ACTIVE_STATE active ACTIVATED_AT "$(date -Iseconds)"
    print_links

    echo ""
    if [ "$CHECK_FAILS" -gt 0 ]; then
        msg_warn "Scheme '$SCHEME_ID' is deployed but $CHECK_FAILS check(s) failed - see above."
    else
        msg_ok "Scheme '$SCHEME_ID' deployed and verified."
    fi
    echo ""
    msg_info "Useful commands:"
    echo "  bash phase2-deploy.sh --status     # observed health of everything above"
    echo "  bash phase2-deploy.sh --links      # client links again"
    echo "  bash phase2-deploy.sh --update     # xray-core + geodata, tested before the swap"
    echo "  bash phase2-deploy.sh --list       # other schemes; re-run to switch"
    echo ""
    msg_info "State (keep it - re-runs, switches and links read it): $VPSAD_STATE_DIR/"
    [ "$CHECK_FAILS" -eq 0 ]
}

cmd_status() {
    require_root
    banner "Status"
    CHECK_FAILS=0 CHECK_WARNS=0
    echo ""
    echo "System:"
    local u p pa cc active
    u="${SUDO_USER:-}"
    [ -n "$u" ] || u="$(getent passwd 1000 2>/dev/null | cut -d: -f1)" || u=""
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')" || p=""
    pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')" || pa=""
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" || cc=""
    check_ok "user ${u:-unknown}, sshd port ${p:-unknown}"
    [ "$pa" = no ] && check_ok "sshd: password login closed" || check_fail "sshd: PasswordAuthentication=${pa:-unknown}"
    [ "$cc" = bbr ] && check_ok "TCP congestion control: bbr" || check_warn "TCP congestion control: ${cc:-unknown}"
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        check_ok "ufw active ($(ufw status | grep -c ALLOW) allow rules)"
    else
        check_fail "ufw not active"
    fi
    if systemctl is-active --quiet fail2ban; then
        check_ok "fail2ban: $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
    else
        check_fail "fail2ban not active"
    fi
    echo ""
    echo "Components:"
    [ -x "$XRAY_BIN" ] && check_ok "xray-core v$(xray_installed_version), geodata $(cat "$XRAY_ASSET_DIR/.vpsautodeploy-geodata" 2>/dev/null || echo unknown)" \
        || check_ok "xray-core not installed"
    [ -x "$NGINX_BIN" ] && check_ok "nginx build $(nginx_build_version)" || check_ok "nginx not installed"
    active="$(engine_get ACTIVE_SCHEME)"
    echo ""
    if [ -z "$active" ]; then
        echo "Scheme: none active"
    else
        load_scheme "$active"
        if [ "$(engine_get ACTIVE_STATE)" = active ]; then
            echo "Scheme: $active (since $(engine_get ACTIVATED_AT))"
        else
            echo "Scheme: $active"
            check_fail "the deployment of '$active' did not finish - run phase2-deploy.sh again"
        fi
        scheme_verify
    fi
    echo ""
    if [ "$CHECK_FAILS" -gt 0 ]; then
        msg_error "$CHECK_FAILS check(s) failed, $CHECK_WARNS warning(s)."
        exit 1
    fi
    msg_ok "All checks passed ($CHECK_WARNS warning(s))."
}

cmd_links() {
    require_root
    local active
    active="$(engine_get ACTIVE_SCHEME)"
    [ -n "$active" ] || die "No active scheme."
    load_scheme "$active"
    print_links
}

cmd_update() {
    require_root
    take_lock
    banner "Update xray-core and geodata"
    local active version
    active="$(engine_get ACTIVE_SCHEME)"
    [ -n "$active" ] && load_scheme "$active"
    version="$(xray_resolve_version "${XRAY_VERSION:-${SCHEME_XRAY_VERSION:-latest}}")"
    msg_step "Xray-core v$version"
    if [ "$(xray_installed_version)" = "$version" ]; then
        msg_ok "Already on v$version"
    else
        xray_upgrade "$version"
    fi
    msg_step "Geodata"
    xray_geodata_update
    if [ -n "$active" ]; then
        msg_step "Verify"
        CHECK_FAILS=0 CHECK_WARNS=0
        scheme_verify
        [ "$CHECK_FAILS" -eq 0 ] || exit 1
    fi
}

cmd_deactivate() {
    require_root
    take_lock
    local active
    active="$(engine_get ACTIVE_SCHEME)"
    [ -n "$active" ] || die "No active scheme."
    msg_warn "This stops '$active': its firewall rules are removed, xray stops and nginx keeps serving only sites.d/."
    msg_info "Not touched: SSH, the firewall baseline, fail2ban, certificates and the stored inputs."
    confirm "Deactivate '$active'?" || die "Aborted."
    deactivate_active_scheme
}

cmd_generate_config() {
    local id="${1:-}" out="${2:-}"
    if [ -z "$id" ]; then
        choose_scheme ""
        id="$CHOSEN_SCHEME"
    fi
    load_scheme "$id"
    out="${out:-$CONF_NAME}"
    if [ -e "$out" ]; then
        confirm "$out exists. Overwrite?" || die "Aborted."
    fi
    generate_conf_template "$out"
    msg_ok "Template for '$id' written to $out"
    msg_info "Fill it in, upload it with any files the scheme asks for, then run phase2-deploy.sh:"
    echo "  scp -P <ssh_port> $out <user>@<VPS_IP>:~/$CONF_NAME"
}

###############################################################################
# Arguments
###############################################################################
CMD=deploy
OPT_SCHEME=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --scheme)          OPT_SCHEME="${2:?--scheme needs an id}"; shift ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --xray-version)    export XRAY_VERSION="${2:?--xray-version needs a version or 'latest'}"; shift ;;
        --list)            CMD=list ;;
        --status)          CMD=status ;;
        --links)           CMD=links ;;
        --update)          CMD=update ;;
        --deactivate)      CMD=deactivate ;;
        --generate-config) CMD=generate ;;
        -h|--help)         usage; exit 0 ;;
        -*)                usage; die "Unknown option: $1" ;;
        *)                 POSITIONAL+=("$1") ;;
    esac
    shift
done

case "$CMD" in
    deploy)     cmd_deploy ;;
    list)       list_schemes ;;
    status)     cmd_status ;;
    links)      cmd_links ;;
    update)     cmd_update ;;
    deactivate) cmd_deactivate ;;
    generate)   cmd_generate_config "${POSITIONAL[0]:-}" "${POSITIONAL[1]:-}" ;;
esac

#!/bin/bash
# components/firewall/component.sh - UFW baseline and per-scheme port rules.
#
# The baseline (deny incoming, SSH allowed) belongs to the machine and is
# never removed. A rule a scheme needs is added with the comment
# "vpsautodeploy:<scheme>", and that comment is what ownership means:
# deactivation deletes exactly the rules carrying it. A port someone else
# already allowed (rule without our comment) is used as is and left alone.
#
# Allow rules use "from 0.0.0.0/0", so only IPv4 inbound is whitelisted;
# IPv6 inbound stays denied by the default policy (UFW keeps IPV6=yes).
# (ufw displays such a rule as plain "443/tcp", without the source.)

fw_tag() {
    printf 'vpsautodeploy:%s' "$1"
}

# The IPv4 ALLOW line for proto/port in `ufw status`, if any.
fw_status_line() {
    ufw status 2>/dev/null | awk -v s="$1" '$1 == s && $2 == "ALLOW"'
}

fw_add() {
    local spec="$1" comment="$2"
    ufw allow proto "${spec%/*}" from 0.0.0.0/0 to any port "${spec#*/}" comment "$comment" >/dev/null
}

fw_base() {
    local ssh_port="$1"
    ensure_packages ufw
    ufw default allow outgoing >/dev/null
    ufw default deny incoming >/dev/null
    [ -n "$(fw_status_line "$ssh_port/tcp")" ] || fw_add "tcp/$ssh_port" ssh
    ufw --force enable >/dev/null
    [ -n "$(fw_status_line "$ssh_port/tcp")" ] || die "UFW does not show the SSH rule for $ssh_port/tcp"
    msg_ok "UFW enabled: incoming denied except SSH ($ssh_port/tcp, IPv4)"
}

# fw_open SPEC... (tcp/443 udp/443 ...) for the loaded scheme.
fw_open() {
    local spec line tag
    tag="$(fw_tag "$SCHEME_ID")"
    for spec in "$@"; do
        [[ "$spec" =~ ^(tcp|udp)/[0-9]{1,5}$ ]] || die "bad port spec '$spec'"
        line="$(fw_status_line "${spec#*/}/${spec%/*}")"
        if [ -z "$line" ]; then
            fw_add "$spec" "$tag"
            line="$(fw_status_line "${spec#*/}/${spec%/*}")"
            [ -n "$line" ] || die "UFW does not show the rule just added for $spec"
            msg_ok "UFW allows $spec"
        elif [[ "$line" == *"# $tag" ]]; then
            msg_ok "UFW allows $spec"
        else
            msg_info "UFW already allows $spec through a rule this scheme does not own; left as is"
        fi
    done
}

# Delete every rule tagged with the loaded scheme (numbers shift after each delete).
fw_close_owned() {
    local tag n
    tag="$(fw_tag "$SCHEME_ID")"
    while :; do
        n="$(ufw status numbered 2>/dev/null | sed -n "/# ${tag}\$/{s/^\[ *\([0-9]\+\)\].*/\1/p;q}")"
        [ -n "$n" ] || break
        ufw --force delete "$n" >/dev/null
    done
    msg_ok "UFW rules of $SCHEME_ID removed"
}

#!/bin/bash
# tests/e2e/run.sh - End-to-end test of phase2-deploy.sh in a Debian 13 container.
#
# Needs docker and internet access (GitHub releases, the Debian mirror,
# Cloudflare). Nothing touches a real VPS: DNS and ACME are replaced by a
# local test CA (see fixtures.sh). The run:
#   1. zero-touch deploy of nginx-xray-443-fallback (--yes, conf + uploads)
#   2. --status, then every client link through a real xray client
#   3. a second run converges without changing anything
#   4. switch to the e2e-only scheme: the old scheme's ports, nginx server
#      blocks and xray config are gone, the new one works
#   5. switch back: the same keys and links return, clients work again
#   6. --deactivate leaves only the machine baseline
#
# usage: tests/e2e/run.sh [--keep]   (--keep leaves the container running)
#   ALLOW_NO_WARP=1  tolerate a failed WARP egress check (networks that block
#                    UDP to Cloudflare's WARP endpoint)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NAME=vpsad-e2e
IMAGE=vpsad-e2e:trixie
OUT="$HERE/out"
KEEP=0
[ "${1:-}" = --keep ] && KEEP=1
FAILS=0
mkdir -p "$OUT"

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
in_ct() { docker exec -i "$NAME" bash -c "$1"; }
deploy() {  # deploy LOGNAME ARGS... (as root after `sudo -i` from the test user)
    local log="$OUT/$1.log"
    shift
    docker exec -e SUDO_USER=tester -e VPSAD_SCHEME_PATH=/opt/VPSAutoDeploy/tests/e2e/schemes \
        "$NAME" bash /opt/VPSAutoDeploy/phase2-deploy.sh "$@" > "$log" 2>&1
}
expect() {  # expect DESCRIPTION COMMAND (run inside the container)
    if in_ct "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}
verify_failures() {  # failed checks in a log, minus the ones this network may not support
    local f
    f="$(grep -a '✗' "$1" || true)"
    [ "${ALLOW_NO_WARP:-0}" = 1 ] && f="$(grep -v 'egress via WARP\|does not egress via WARP' <<<"$f" || true)"
    printf '%s' "$f"
}

cleanup() { [ "$KEEP" = 1 ] || docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

echo "== build and start $IMAGE"
docker build -q -t "$IMAGE" "$HERE" >/dev/null || { echo "image build failed"; exit 1; }
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "$REPO:/opt/VPSAutoDeploy:ro" "$IMAGE" >/dev/null || exit 1
for _ in $(seq 1 60); do
    in_ct 'systemctl is-system-running 2>/dev/null' | grep -qE 'running|degraded' && break
    sleep 1
done
in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/fixtures.sh' || { echo "fixtures failed"; exit 1; }

echo "== 1. zero-touch deploy"
if deploy deploy-1 --yes; then pass "deploy exited 0"; else fail "deploy exited non-zero (see $OUT/deploy-1.log)"; fi
v="$(verify_failures "$OUT/deploy-1.log")"
[ -z "$v" ] && pass "all verify checks passed" || fail "verify checks failed: $v"
expect "uploaded conf and origin certificate removed from the home dir" \
    '! ls /home/tester/vpsautodeploy.conf /home/tester/cf-fullchain.pem /home/tester/cf-privkey.pem'
expect "params stored with mode 600" \
    '[ "$(stat -c %a /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/params)" = 600 ]'
expect "xray runs as user xray" '[ "$(ps -o user= -C xray | sort -u)" = xray ]'
expect "WARP outbound uses a kernel TUN (the -test run used the userspace stack)" \
    'grep -q "Using kernel TUN" /var/log/xray/error.log'
expect "ufw: 443/tcp, 80/tcp, 443/udp allowed with the scheme comment" \
    '[ "$(ufw show added | grep -c "vpsautodeploy:nginx-xray-443-fallback")" = 3 ]'
expect "no 3x-ui anywhere" '! systemctl cat x-ui >/dev/null 2>&1 && [ ! -e /etc/x-ui ]'
in_ct 'cat /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' > "$OUT/links-1.txt"
[ "$(grep -c '^vless://' "$OUT/links-1.txt")" = 4 ] && pass "4 client links" || fail "expected 4 client links"

echo "== 2. status and clients"
if deploy status-1 --status; then pass "--status exited 0"; else
    v="$(verify_failures "$OUT/status-1.log")"
    [ -z "$v" ] && pass "--status: only tolerated failures" || fail "--status failed: $v"
fi
if in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/clients.sh /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' \
    > "$OUT/clients-1.log" 2>&1; then pass "all 4 clients connect"; else fail "clients: $(grep FAIL "$OUT/clients-1.log")"; fi
cat "$OUT/clients-1.log"

echo "== 3. re-run converges"
sum_before="$(in_ct 'sha256sum /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/params /usr/local/etc/xray/config.json /nginx/conf/nginx.conf')"
deploy deploy-2 --yes && pass "second run exited 0" || fail "second run exited non-zero"
sum_after="$(in_ct 'sha256sum /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/params /usr/local/etc/xray/config.json /nginx/conf/nginx.conf')"
[ "$sum_before" = "$sum_after" ] && pass "params and configs unchanged by the re-run" || fail "re-run changed params/configs"
grep -q "xray config unchanged" "$OUT/deploy-2.log" && pass "xray not restarted" || fail "xray was re-applied"

echo "== 4. switch to e2e-reality-8443"
deploy deploy-3 --yes --scheme e2e-reality-8443 && pass "switch exited 0" || fail "switch exited non-zero"
expect "old scheme's firewall rules removed" '! ufw show added | grep -q "vpsautodeploy:nginx-xray-443-fallback"'
expect "new scheme's firewall rule added" 'ufw show added | grep -q "vpsautodeploy:e2e-reality-8443"'
expect "nginx kept running, without the old server blocks" \
    'systemctl is-active --quiet nginx && ! ss -Hltn "sport = :80" | grep -q . && ! grep -q direct.test /nginx/conf/nginx.conf'
expect "xray listens on 8443 and not on 443" 'ss -Hltnp "sport = :8443" | grep -q xray && ! ss -Hltn "sport = :443" | grep -q .'
expect "SSH baseline rule kept" 'ufw status | grep -q "^2222/tcp .*ALLOW"'
in_ct 'cat /etc/vpsautodeploy/schemes/e2e-reality-8443/links.txt' > "$OUT/links-e2e.txt"
if in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/clients.sh /etc/vpsautodeploy/schemes/e2e-reality-8443/links.txt' \
    > "$OUT/clients-e2e.log" 2>&1; then pass "e2e scheme client connects"; else fail "e2e client: $(cat "$OUT/clients-e2e.log")"; fi

echo "== 5. switch back"
deploy deploy-4 --yes --scheme nginx-xray-443-fallback && pass "switch back exited 0" || fail "switch back exited non-zero"
in_ct 'cat /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' > "$OUT/links-2.txt"
cmp -s "$OUT/links-1.txt" "$OUT/links-2.txt" && pass "same keys and links as before the switch" || fail "links changed across the switch"
expect "e2e scheme's firewall rule removed" '! ufw show added | grep -q "vpsautodeploy:e2e-reality-8443"'
if in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/clients.sh /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' \
    > "$OUT/clients-2.log" 2>&1; then pass "all 4 clients connect again"; else fail "clients after switch back: $(grep FAIL "$OUT/clients-2.log")"; fi

echo "== 6. deactivate"
deploy deactivate --deactivate --yes && pass "--deactivate exited 0" || fail "--deactivate exited non-zero"
expect "only the SSH rule is left" '[ "$(ufw show added | grep -c "^ufw allow")" = 1 ]'
expect "xray stopped and disabled" '! systemctl is-active --quiet xray && ! systemctl is-enabled --quiet xray'
expect "fail2ban still protects sshd" 'fail2ban-client status sshd >/dev/null'

echo ""
echo "logs: $OUT"
if [ "$FAILS" -eq 0 ]; then echo "E2E: all passed"; else echo "E2E: $FAILS failure(s)"; fi
[ "$FAILS" -eq 0 ]

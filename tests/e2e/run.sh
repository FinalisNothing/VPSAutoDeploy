#!/bin/bash
# tests/e2e/run.sh - End-to-end test of phase2-deploy.sh in a Debian 13 container.
#
# Needs docker and internet access (GitHub releases, the Debian mirror,
# Cloudflare). Nothing touches a real VPS: DNS and ACME are replaced by a
# local test CA (see fixtures.sh). The run:
#   1. zero-touch deploy of nginx-xray-443-fallback (--yes, conf + uploads)
#   2. --status, then every client link through a real xray client
#   3. a second run converges without changing anything
#   4. a custom egress policy is reported until applied, then the switch to
#      the e2e-only scheme: the old scheme's ports, nginx server blocks and
#      xray config are gone, the new one works with the custom egress
#   5. switch back while the e2e scheme is no longer visible (as if removed
#      from the repo): it is still cleaned up; the same keys and links return;
#      without the custom egress file the default policy is back
#   5b. --update to another release and back, clients working afterwards
#   6. --deactivate leaves only the machine baseline
#
# usage: tests/e2e/run.sh [--keep]   (--keep leaves the container running)

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
deploy_repo_only() {  # the same, but the e2e-only scheme is not visible (as if removed from the repo)
    local log="$OUT/$1.log"
    shift
    docker exec -e SUDO_USER=tester "$NAME" bash /opt/VPSAutoDeploy/phase2-deploy.sh "$@" > "$log" 2>&1
}
expect() {  # expect DESCRIPTION COMMAND (run inside the container)
    if in_ct "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
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
v="$(grep -a '✗' "$OUT/deploy-1.log" || true)"
[ -z "$v" ] && pass "all verify checks passed" || fail "verify checks failed: $v"
expect "uploaded conf and origin certificate removed from the home dir" \
    '! ls /home/tester/vpsautodeploy.conf /home/tester/cf-fullchain.pem /home/tester/cf-privkey.pem'
expect "params stored with mode 600" \
    '[ "$(stat -c %a /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/params)" = 600 ]'
expect "xray runs as user xray" '[ "$(ps -o user= -C xray | sort -u)" = xray ]'
expect "xray config = scheme inbounds + default egress (direct first, 5 rules)" \
    'jq -e "(.inbounds | length) == 3 and .outbounds[0].tag == \"direct\" and (.routing.rules | length) == 5" /usr/local/etc/xray/config.json'
expect "rendered default egress kept for reference" '[ -s /etc/vpsautodeploy/egress.default.json ]'
expect "ufw: 443/tcp, 80/tcp, 443/udp allowed with the scheme comment" \
    '[ "$(ufw show added | grep -c "vpsautodeploy:nginx-xray-443-fallback")" = 3 ]'
in_ct 'cat /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' > "$OUT/links-1.txt"
[ "$(grep -c '^vless://' "$OUT/links-1.txt")" = 4 ] && pass "4 client links" || fail "expected 4 client links"

echo "== 2. status and clients"
deploy status-1 --status && pass "--status exited 0" || fail "--status failed: $(grep -a '✗' "$OUT/status-1.log")"
if in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/clients.sh /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' \
    > "$OUT/clients-1.log" 2>&1; then pass "all 4 clients connect"; else fail "clients: $(grep FAIL "$OUT/clients-1.log")"; fi
cat "$OUT/clients-1.log"

echo "== 3. re-run converges"
sum_before="$(in_ct 'sha256sum /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/params /usr/local/etc/xray/config.json /nginx/conf/nginx.conf')"
deploy deploy-2 --yes && pass "second run exited 0" || fail "second run exited non-zero"
sum_after="$(in_ct 'sha256sum /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/params /usr/local/etc/xray/config.json /nginx/conf/nginx.conf')"
[ "$sum_before" = "$sum_after" ] && pass "params and configs unchanged by the re-run" || fail "re-run changed params/configs"
grep -q "xray config unchanged" "$OUT/deploy-2.log" && pass "xray not restarted" || fail "xray was re-applied"

echo "== 4. custom egress, then switch to e2e-reality-8443"
in_ct 'jq ".routing.rules += [{\"domain\": [\"domain:example.org\"], \"outboundTag\": \"blocked\"}]" \
    /etc/vpsautodeploy/egress.default.json > /etc/vpsautodeploy/egress.json'
deploy status-2 --status
grep -q "is not in effect yet" "$OUT/status-2.log" && pass "--status reports the custom egress not applied yet" \
    || fail "--status did not notice the new custom egress"
deploy deploy-3 --yes --scheme e2e-reality-8443 && pass "switch exited 0" || fail "switch exited non-zero"
expect "old scheme's firewall rules removed" '! ufw show added | grep -q "vpsautodeploy:nginx-xray-443-fallback"'
expect "new scheme's firewall rule added" 'ufw show added | grep -q "vpsautodeploy:e2e-reality-8443"'
expect "nginx kept running, without the old server blocks" \
    'systemctl is-active --quiet nginx && ! ss -Hltn "sport = :80" | grep -q . && ! grep -q direct.test /nginx/conf/nginx.conf'
expect "xray listens on 8443 and not on 443" 'ss -Hltnp "sport = :8443" | grep -q xray && ! ss -Hltn "sport = :443" | grep -q .'
expect "SSH baseline rule kept" 'ufw status | grep -q "^2222/tcp .*ALLOW"'
expect "the new scheme runs with the custom egress" \
    'jq -e "[.routing.rules[].domain[]?] | index(\"domain:example.org\")" /usr/local/etc/xray/config.json'
in_ct 'cat /etc/vpsautodeploy/schemes/e2e-reality-8443/links.txt' > "$OUT/links-e2e.txt"
if in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/clients.sh /etc/vpsautodeploy/schemes/e2e-reality-8443/links.txt' \
    > "$OUT/clients-e2e.log" 2>&1; then pass "e2e scheme client connects"; else fail "e2e client: $(cat "$OUT/clients-e2e.log")"; fi

echo "== 5. switch back (the active e2e scheme is no longer in the repository)"
in_ct 'rm /etc/vpsautodeploy/egress.json'
deploy_repo_only deploy-4 --yes --scheme nginx-xray-443-fallback && pass "switch back exited 0" || fail "switch back exited non-zero"
grep -q "is no longer in this repository" "$OUT/deploy-4.log" \
    && pass "a scheme missing from the repo is still deactivated" || fail "missing-scheme fallback not taken"
in_ct 'cat /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' > "$OUT/links-2.txt"
cmp -s "$OUT/links-1.txt" "$OUT/links-2.txt" && pass "same keys and links as before the switch" || fail "links changed across the switch"
expect "e2e scheme's firewall rule removed" '! ufw show added | grep -q "vpsautodeploy:e2e-reality-8443"'
expect "default egress is back" \
    'jq -e "(.routing.rules | length) == 5 and ([.routing.rules[].domain[]?] | index(\"domain:example.org\") | not)" /usr/local/etc/xray/config.json'
if in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/clients.sh /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' \
    > "$OUT/clients-2.log" 2>&1; then pass "all 4 clients connect again"; else fail "clients after switch back: $(grep FAIL "$OUT/clients-2.log")"; fi

echo "== 5b. update: another release, then back to the pinned one"
deploy update-1 --update --xray-version 26.10.21 && pass "--update to 26.10.21 exited 0" || fail "--update to 26.10.21 failed"
expect "xray 26.10.21 is running" '[ "$(xray version | awk "NR==1{print \$2}")" = 26.10.21 ] && systemctl is-active --quiet xray'
deploy update-2 --update && pass "--update back to the pinned version exited 0" || fail "--update back failed"
expect "xray 26.10.31 is running, one rollback version kept" \
    '[ "$(xray version | awk "NR==1{print \$2}")" = 26.10.31 ] && [ "$(ls /usr/local/lib/vpsautodeploy/xray | wc -l)" = 2 ]'
if in_ct 'bash /opt/VPSAutoDeploy/tests/e2e/clients.sh /etc/vpsautodeploy/schemes/nginx-xray-443-fallback/links.txt' \
    > "$OUT/clients-3.log" 2>&1; then pass "all 4 clients connect after the updates"; else fail "clients after update: $(grep FAIL "$OUT/clients-3.log")"; fi

echo "== 6. deactivate"
deploy deactivate --deactivate --yes && pass "--deactivate exited 0" || fail "--deactivate exited non-zero"
expect "only the SSH rule is left" '[ "$(ufw show added | grep -c "^ufw allow")" = 1 ]'
expect "xray stopped and disabled" '! systemctl is-active --quiet xray && ! systemctl is-enabled --quiet xray'
expect "fail2ban still protects sshd" 'fail2ban-client status sshd >/dev/null'

echo ""
echo "logs: $OUT"
if [ "$FAILS" -eq 0 ]; then echo "E2E: all passed"; else echo "E2E: $FAILS failure(s)"; fi
[ "$FAILS" -eq 0 ]

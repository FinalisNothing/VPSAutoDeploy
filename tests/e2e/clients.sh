#!/bin/bash
# tests/e2e/clients.sh LINKS_FILE - runs INSIDE the test container (as root).
# Every share link becomes a real xray client (127.0.0.1 instead of the
# link's host, which has no DNS here); a request through each must succeed.
# The target is an IP literal so the server's egress does not depend on the
# test machine's DNS (a fake-IP resolver would make Freedom refuse it).
set -uo pipefail
links="$1"
port=21080
fail=0
while IFS= read -r link; do
    [[ "$link" == vless://* ]] || continue
    name="${link##*#}"
    cfg="/tmp/client-$port.json"
    python3 /opt/VPSAutoDeploy/tests/e2e/link2client.py "$link" "$port" 127.0.0.1 > "$cfg"
    /usr/local/bin/xray run -c "$cfg" > "/tmp/client-$port.log" 2>&1 &
    pid=$!
    sleep 2
    code="$(curl -sS -o /tmp/client-$port.body -w '%{http_code}' --max-time 25 \
        --socks5-hostname "127.0.0.1:$port" https://1.1.1.1/cdn-cgi/trace 2>/tmp/client-$port.err || true)"
    if [ "$code" = 200 ]; then
        echo "PASS client $name -> HTTP 200 ($(grep '^ip=' /tmp/client-$port.body))"
    else
        echo "FAIL client $name -> HTTP ${code:-none}: $(cat /tmp/client-$port.err)"
        tail -5 "/tmp/client-$port.log"
        fail=1
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    port=$((port + 1))
done < "$links"
exit "$fail"

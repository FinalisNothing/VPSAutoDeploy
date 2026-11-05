#!/bin/bash
# tests/e2e/fixtures.sh - runs INSIDE the test container (as root).
# Stands in for what DNS, ACME and the Cloudflare dashboard provide on a real
# VPS: a 3-level RSA-4096 test CA (the chain exceeds 3500 bytes, which REALITY
# with mldsa65Seed requires from its target), the direct-domain certificate
# where the ACME step expects it, and the CDN "origin certificate" plus the
# conf file uploaded to the user's home.
set -euo pipefail
cd "$(mktemp -d)"

ca_ext="basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign"
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=VPSAD E2E Root" \
    -addext "$ca_ext" -keyout root.key -out root.pem 2>/dev/null
openssl req -newkey rsa:4096 -nodes -subj "/CN=VPSAD E2E Intermediate" -keyout int.key -out int.csr 2>/dev/null
printf '%s\n' "$ca_ext" > int.ext
openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -days 3650 -extfile int.ext -out int.pem 2>/dev/null

leaf() {
    local name="$1"
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$name" > "$name.ext"
    openssl req -newkey rsa:4096 -nodes -subj "/CN=$name" -keyout "$name.key" -out "$name.csr" 2>/dev/null
    openssl x509 -req -in "$name.csr" -CA int.pem -CAkey int.key -CAcreateserial -days 365 -extfile "$name.ext" -out "$name.pem" 2>/dev/null
    cat "$name.pem" int.pem root.pem > "$name.fullchain.pem"
}
leaf direct.test
leaf cdn.test

# The direct domain points at this machine, as its A record would on a VPS.
# cdn.test is left alone: there is no Cloudflare in here, so its checks warn.
ip="$(curl -fsS4 --max-time 10 https://api.ipify.org)"
printf '%s direct.test\n' "$ip" >> /etc/hosts

install -m 644 root.pem /usr/local/share/ca-certificates/vpsad-e2e-root.crt
update-ca-certificates >/dev/null 2>&1

install -d -m 700 /etc/vpsautodeploy /etc/vpsautodeploy/certs /etc/vpsautodeploy/certs/direct.test
install -m 600 direct.test.fullchain.pem /etc/vpsautodeploy/certs/direct.test/fullchain.pem
install -m 600 direct.test.key /etc/vpsautodeploy/certs/direct.test/privkey.pem

install -o tester -g tester -m 600 cdn.test.fullchain.pem /home/tester/cf-fullchain.pem
install -o tester -g tester -m 600 cdn.test.key /home/tester/cf-privkey.pem
cat > /home/tester/vpsautodeploy.conf <<'EOF'
SCHEME=nginx-xray-443-fallback
ACME_EMAIL=e2e@example.com
DIRECT_DOMAIN=direct.test
CDN_DOMAIN=cdn.test
BACKEND_WEB=quarkus.io
EOF
chown tester:tester /home/tester/vpsautodeploy.conf
echo "fixtures ready: chain $(cat direct.test.pem int.pem root.pem | openssl crl2pkcs7 -nocrl -certfile /dev/stdin -outform DER | wc -c) bytes (PKCS7)"

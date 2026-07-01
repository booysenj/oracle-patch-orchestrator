#!/bin/bash
# SSL cert renewal script for insight-patch-ui
# Run as root on the orchestrator server whenever the wildcard cert is reissued.
# Usage: bash renew-ssl.sh /path/to/new-wildcard.pem

set -e

NEW_PEM="$1"
CERT_DIR="/etc/ssl/insight-patch"

if [[ -z "$NEW_PEM" ]]; then
    echo "Usage: bash renew-ssl.sh /path/to/new-wildcard.pem"
    exit 1
fi
if [[ ! -f "$NEW_PEM" ]]; then
    echo "ERROR: $NEW_PEM not found"
    exit 1
fi
if [[ ! -d "$CERT_DIR" ]]; then
    echo "ERROR: $CERT_DIR does not exist — has setup-ssl.sh been run on this host yet?"
    exit 1
fi

echo "=== insight-patch-ui SSL renewal ==="

# Backup current cert/key
TS=$(date +%Y%m%d-%H%M%S)
cp "$CERT_DIR/server.crt" "$CERT_DIR/server.crt.bak-$TS"
cp "$CERT_DIR/server.key" "$CERT_DIR/server.key.bak-$TS"
echo "[1/4] Backed up existing cert/key (.bak-$TS)"

# Extract new cert and key
echo "[2/4] Extracting new cert and key..."
openssl pkey -in "$NEW_PEM" -out "$CERT_DIR/server.key" 2>/dev/null || \
    grep -A 9999 'BEGIN.*PRIVATE KEY' "$NEW_PEM" | grep -B 9999 'END.*PRIVATE KEY' > "$CERT_DIR/server.key"
grep -A 9999 'BEGIN CERTIFICATE' "$NEW_PEM" > "$CERT_DIR/server.crt"

if [[ ! -s "$CERT_DIR/server.key" || ! -s "$CERT_DIR/server.crt" ]]; then
    echo "ERROR: extraction failed — restoring backup"
    cp "$CERT_DIR/server.crt.bak-$TS" "$CERT_DIR/server.crt"
    cp "$CERT_DIR/server.key.bak-$TS" "$CERT_DIR/server.key"
    exit 1
fi
chmod 640 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

# Verify match
CERT_MOD=$(openssl x509 -noout -modulus -in "$CERT_DIR/server.crt" | md5sum)
KEY_MOD=$(openssl rsa -noout -modulus -in "$CERT_DIR/server.key" 2>/dev/null | md5sum || \
          openssl pkey -noout -pubout -in "$CERT_DIR/server.key" | md5sum)
if [[ "$CERT_MOD" != "$KEY_MOD" ]]; then
    echo "ERROR: cert/key mismatch — restoring backup"
    cp "$CERT_DIR/server.crt.bak-$TS" "$CERT_DIR/server.crt"
    cp "$CERT_DIR/server.key.bak-$TS" "$CERT_DIR/server.key"
    exit 1
fi
echo "    cert/key match: OK"
echo "    subject: $(openssl x509 -noout -subject -in "$CERT_DIR/server.crt")"
echo "    expiry:  $(openssl x509 -noout -enddate -in "$CERT_DIR/server.crt")"

# Test and reload nginx (no app restart needed)
echo "[3/4] Testing nginx config..."
nginx -t

echo "[4/4] Reloading nginx..."
systemctl reload nginx

echo ""
echo "=== Done ==="
echo "Old cert/key backed up as .bak-$TS in $CERT_DIR"
echo "Verify: curl -k https://127.0.0.1/api/health"

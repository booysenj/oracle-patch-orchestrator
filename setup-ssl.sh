#!/bin/bash
# SSL setup script for insight-patch-ui
# Run as root on 172.16.36.95
# Usage: bash setup-ssl.sh

set -e

PEM_FILE="/home/devadmin/wildcard-4cgroup.pem-v1"
CERT_DIR="/etc/ssl/insight-patch"
NGINX_CONF="/etc/nginx/conf.d/insight-patch-ui.conf"
APP_HOST="127.0.0.1"
APP_PORT="4000"

echo "=== insight-patch-ui SSL setup ==="

# 1. Install nginx if not present
if ! command -v nginx &>/dev/null; then
    echo "[1/5] Installing nginx..."
    dnf install -y nginx
else
    echo "[1/5] nginx already installed"
fi

# 2. Create cert directory
mkdir -p "$CERT_DIR"
chmod 750 "$CERT_DIR"

# 3. Split the PEM file into cert and key
echo "[2/5] Splitting PEM file..."

# Extract private key (PRIVATE KEY or RSA PRIVATE KEY block)
openssl pkey -in "$PEM_FILE" -out "$CERT_DIR/server.key" 2>/dev/null || \
    grep -A 9999 'BEGIN.*PRIVATE KEY' "$PEM_FILE" | grep -B 9999 'END.*PRIVATE KEY' | head -n -0 > "$CERT_DIR/server.key"

# Extract certificate chain (all CERTIFICATE blocks)
grep -A 9999 'BEGIN CERTIFICATE' "$PEM_FILE" > "$CERT_DIR/server.crt" 2>/dev/null || true

# Verify we got both
if [[ ! -s "$CERT_DIR/server.key" ]]; then
    echo "ERROR: Could not extract private key from $PEM_FILE"
    echo "If the key is in a separate file, copy it to $CERT_DIR/server.key and re-run from step 3."
    exit 1
fi
if [[ ! -s "$CERT_DIR/server.crt" ]]; then
    echo "ERROR: Could not extract certificate from $PEM_FILE"
    exit 1
fi

chmod 640 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"
echo "    cert  -> $CERT_DIR/server.crt"
echo "    key   -> $CERT_DIR/server.key"

# Verify the cert and key match
CERT_MOD=$(openssl x509 -noout -modulus -in "$CERT_DIR/server.crt" | md5sum)
KEY_MOD=$(openssl rsa -noout -modulus -in "$CERT_DIR/server.key" 2>/dev/null | md5sum || \
          openssl pkey -noout -pubout -in "$CERT_DIR/server.key" | md5sum)
if [[ "$CERT_MOD" == "$KEY_MOD" ]]; then
    echo "    cert/key match: OK"
else
    echo "    WARNING: cert modulus does not match key modulus — check the PEM file"
fi

# Show cert info
echo "    subject: $(openssl x509 -noout -subject -in "$CERT_DIR/server.crt" 2>/dev/null)"
echo "    expiry:  $(openssl x509 -noout -enddate -in "$CERT_DIR/server.crt" 2>/dev/null)"

# 4. Write nginx config
echo "[3/5] Writing nginx config..."
cat > "$NGINX_CONF" <<'NGINXEOF'
# insight-patch-ui — SSL reverse proxy
server {
    listen 80;
    server_name _;
    # Redirect HTTP to HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/ssl/insight-patch/server.crt;
    ssl_certificate_key /etc/ssl/insight-patch/server.key;

    # Modern TLS only
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # Proxy to Node app
    location / {
        proxy_pass         http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # WebSocket upgrade (for /ws/logs)
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
NGINXEOF

echo "    written to $NGINX_CONF"

# 5. Test and enable nginx
echo "[4/5] Testing nginx config..."
nginx -t

echo "[5/5] Enabling and starting nginx..."
systemctl enable nginx
systemctl restart nginx

# Also restart Node app to pick up any env changes
systemctl restart insight-patch-ui

echo ""
echo "=== Done ==="
echo "The UI should now be accessible via https://<server-ip>"
echo "HTTP on port 80 redirects to HTTPS automatically."
echo ""
echo "To verify:"
echo "  curl -k https://127.0.0.1/api/health"
echo "  systemctl status nginx"

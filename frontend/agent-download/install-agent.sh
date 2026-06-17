#!/bin/bash
# Insight Patch Agent - Installer
# Usage: curl -s http://<orchestrator>:4000/agent-download/install-agent.sh | \
#          INSIGHT_API_URL=http://<orchestrator>:4000 \
#          INSIGHT_AGENT_TOKEN=<token> \
#          bash

set -e

ORCHESTRATOR_URL="${INSIGHT_API_URL:-http://172.16.36.95:4000}"
AGENT_TOKEN="${INSIGHT_AGENT_TOKEN:-}"
AGENT_DEST="/home/oracle/insight-agent.py"
SERVICE_NAME="insight-agent"
ORACLE_USER="oracle"

if [ -z "$AGENT_TOKEN" ]; then
  echo "[install] ERROR: INSIGHT_AGENT_TOKEN must be set"
  exit 1
fi

HOSTNAME_SHORT=$(hostname -s)

echo "[install] Downloading agent from $ORCHESTRATOR_URL..."
curl -fsSL "$ORCHESTRATOR_URL/agent-download/insight-agent.py" -o "$AGENT_DEST"
chown "$ORACLE_USER:$ORACLE_USER" "$AGENT_DEST"
chmod 750 "$AGENT_DEST"

echo "[install] Writing systemd service..."
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Insight Patch Agent
After=network.target

[Service]
Type=simple
User=oracle
ExecStart=/usr/bin/python3 ${AGENT_DEST}
Restart=always
RestartSec=5
Environment=INSIGHT_API_URL=${ORCHESTRATOR_URL}
Environment=INSIGHT_AGENT_TOKEN=${AGENT_TOKEN}
Environment=INSIGHT_HOSTNAME=${HOSTNAME_SHORT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
sleep 2
systemctl status "$SERVICE_NAME" --no-pager

echo "[install] Agent installed and started on $HOSTNAME_SHORT"
echo "[install] Verify: journalctl -u $SERVICE_NAME -n 20 --no-pager"

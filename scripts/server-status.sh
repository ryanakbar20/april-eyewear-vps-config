#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - REMOTE SERVER HEALTH CHECK & STATUS MONITOR
# Jalankan dari mesin lokal Anda:
#   ./scripts/server-status.sh dev
#   ./scripts/server-status.sh prod
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${CONFIG_DIR}/.env" ]; then
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
fi

TARGET_ENV=${1:-"dev"}

if [ "$TARGET_ENV" = "prod" ]; then
  VPS_IP="${PROD_VPS_IP}"
  VPS_PORT="${PROD_VPS_PORT:-22}"
  VPS_USER="${PROD_VPS_USER:-ubuntu}"
else
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
fi

if [ -z "$VPS_IP" ]; then
  echo "❌ IP VPS untuk ${TARGET_ENV} belum diisi di ${CONFIG_DIR}/.env!"
  exit 1
fi

SSH_CMD="ssh -p ${VPS_PORT} ${VPS_USER}@${VPS_IP}"

echo "=============================================================================="
echo "📊 STATUS SERVER VPS APRIL EYEWEAR [Target: ${TARGET_ENV} (${VPS_IP})]"
echo "=============================================================================="

$SSH_CMD << 'EOF'
echo "🕒 UPTIME & LOAD AVERAGE:"
uptime
echo ""

echo "💾 MEMORY & SWAP USAGE:"
free -h
echo ""

echo "💿 DISK USAGE:"
df -h /
echo ""

echo "🟢 PM2 PROCESS STATUS:"
pm2 status
echo ""

echo "🐘 POSTGRESQL STATUS:"
systemctl is-active postgresql || echo "Postgres inactive!"
echo ""

echo "🌐 NGINX STATUS:"
systemctl is-active nginx || echo "Nginx inactive!"
echo ""

echo "🔌 LISTENING PORTS (3000, 3002, 5432, 80, 443):"
ss -tulpn | grep -E ':3000|:3002|:5432|:80|:443' || true
EOF

echo "=============================================================================="

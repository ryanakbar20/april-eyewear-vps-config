#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - AUTOMATED SSL / HTTPS SETUP SCRIPT
# Memasang sertifikat SSL (Let's Encrypt Certbot atau Cloudflare Origin CA)
#
# Cara pakai:
#   ./scripts/setup-ssl.sh prod letsencrypt admin@aprileyewear.com
#   ./scripts/setup-ssl.sh dev letsencrypt admin@aprileyewear.com
#   ./scripts/setup-ssl.sh prod cloudflare /path/to/cert.pem /path/to/key.key
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${CONFIG_DIR}/.env" ]; then
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
fi

TARGET_ENV=${1:-"prod"}
SSL_TYPE=${2:-"letsencrypt"}

if [ "$TARGET_ENV" = "prod" ]; then
  VPS_IP="${PROD_VPS_IP}"
  VPS_PORT="${PROD_VPS_PORT:-22}"
  VPS_USER="${PROD_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${PROD_VPS_SSH_KEY_PATH}"
  DOMAIN="${PROD_API_DOMAIN:-api.aprileyewear.com}"
else
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${DEV_VPS_SSH_KEY_PATH}"
  DOMAIN="${DEV_API_DOMAIN:-dev-api.aprileyewear.com}"
fi

if [ -z "$VPS_IP" ]; then
  echo "❌ IP VPS untuk ${TARGET_ENV} belum diisi di .env!"
  exit 1
fi

# Resolusi path SSH Private Key
VPS_SSH_KEY="${VPS_SSH_KEY/#\~/$HOME}"
if [ -n "$VPS_SSH_KEY" ] && [[ "$VPS_SSH_KEY" != /* ]]; then
  VPS_SSH_KEY="${CONFIG_DIR}/${VPS_SSH_KEY}"
fi

# Fallback auto-detection jika file key tidak ditemukan
if [ -z "$VPS_SSH_KEY" ] || [ ! -f "$VPS_SSH_KEY" ]; then
  if [ -f "${CONFIG_DIR}/scripts/id_rsa.pem" ]; then
    VPS_SSH_KEY="${CONFIG_DIR}/scripts/id_rsa.pem"
  elif [ -f "${CONFIG_DIR}/id_rsa.pem" ]; then
    VPS_SSH_KEY="${CONFIG_DIR}/id_rsa.pem"
  fi
fi

SSH_KEY_OPT=""
if [ -n "$VPS_SSH_KEY" ] && [ -f "$VPS_SSH_KEY" ]; then
  chmod 600 "$VPS_SSH_KEY" 2>/dev/null || true
  SSH_KEY_OPT="-i ${VPS_SSH_KEY}"
fi

SSH_CMD="ssh -p ${VPS_PORT} ${SSH_KEY_OPT} ${VPS_USER}@${VPS_IP}"
SCP_CMD="scp -P ${VPS_PORT} ${SSH_KEY_OPT}"

echo "=============================================================================="
echo "🔒 Memulai Konfigurasi SSL/HTTPS untuk [${DOMAIN}] di server ${VPS_IP}"
[ -n "$VPS_SSH_KEY" ] && echo "   SSH Key: ${VPS_SSH_KEY}"
echo "   Metode:  ${SSL_TYPE}"
echo "=============================================================================="

if [ "$SSL_TYPE" = "letsencrypt" ]; then
  EMAIL=${3:-"admin@aprileyewear.com"}
  echo "📦 Memasang Certbot dan mengajukan sertifikat Let's Encrypt untuk ${DOMAIN}..."

  $SSH_CMD << EOF
    set -e
    echo "--> 1. Menginstal Certbot Nginx plugin..."
    sudo apt-get update
    sudo apt-get install -y certbot python3-certbot-nginx

    echo "--> 2. Mengajukan sertifikat SSL untuk ${DOMAIN}..."
    sudo certbot --nginx -d ${DOMAIN} \
      --non-interactive \
      --agree-tos \
      --email ${EMAIL} \
      --redirect

    echo "--> 3. Memverifikasi auto-renewal..."
    sudo systemctl status certbot.timer || sudo systemctl enable --now certbot.timer

    echo "--> 4. Reload Nginx..."
    sudo nginx -t && sudo systemctl reload nginx
    echo "✅ Let's Encrypt SSL aktif untuk https://${DOMAIN}"
EOF

elif [ "$SSL_TYPE" = "cloudflare" ]; then
  CERT_FILE=$3
  KEY_FILE=$4

  if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "❌ File sertifikat atau private key tidak ditemukan!"
    echo "Penggunaan: ./scripts/setup-ssl.sh prod cloudflare /path/to/cert.pem /path/to/key.key"
    exit 1
  fi

  echo "📤 Mengirim Cloudflare Origin Certificate ke server..."
  $SCP_CMD "${CERT_FILE}" "${VPS_USER}@${VPS_IP}:/tmp/aprileyewear_origin.pem"
  $SCP_CMD "${KEY_FILE}" "${VPS_USER}@${VPS_IP}:/tmp/aprileyewear_origin.key"

  $SSH_CMD << 'EOF'
    set -e
    echo "--> Memasang sertifikat ke /etc/ssl/..."
    sudo mv /tmp/aprileyewear_origin.pem /etc/ssl/certs/aprileyewear_origin.pem
    sudo mv /tmp/aprileyewear_origin.key /etc/ssl/private/aprileyewear_origin.key
    sudo chmod 644 /etc/ssl/certs/aprileyewear_origin.pem
    sudo chmod 600 /etc/ssl/private/aprileyewear_origin.key

    echo "--> Reload Nginx..."
    sudo nginx -t && sudo systemctl reload nginx
    echo "✅ Cloudflare Origin Certificate berhasil dipasang!"
EOF

else
  echo "❌ Metode SSL tidak dikenal: ${SSL_TYPE}. Gunakan 'letsencrypt' atau 'cloudflare'."
  exit 1
fi

echo "=============================================================================="
echo "🎉 Pengaturan SSL Selesai! Domain: https://${DOMAIN}"
echo "=============================================================================="

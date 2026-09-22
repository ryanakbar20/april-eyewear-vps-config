#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - 1-CLICK REMOTE DEPLOYMENT SCRIPT
# Jalankan dari mesin lokal Anda (Mac / Linux):
# Cara pakai:
#   ./scripts/deploy.sh dev
#   ./scripts/deploy.sh prod
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${CONFIG_DIR}/.." && pwd)"

# Load .env
if [ -f "${CONFIG_DIR}/.env" ]; then
  # Export non-comment lines
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
else
  echo "❌ File .env tidak ditemukan di ${CONFIG_DIR}/.env!"
  exit 1
fi

TARGET_ENV=${1:-"dev"}

if [ "$TARGET_ENV" = "prod" ]; then
  VPS_IP="${PROD_VPS_IP}"
  VPS_PORT="${PROD_VPS_PORT:-22}"
  VPS_USER="${PROD_VPS_USER:-ubuntu}"
  DEPLOY_DIR="${PROD_DEPLOY_DIR:-/var/www/april-eyewear}"
  ECOSYSTEM_FILE="prod/ecosystem.config.js"
  REMOTE_ECOSYSTEM="ecosystem.config.js"
elif [ "$TARGET_ENV" = "dev" ]; then
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
  DEPLOY_DIR="${DEV_DEPLOY_DIR:-/var/www/april-eyewear-dev}"
  ECOSYSTEM_FILE="dev/ecosystem.dev.config.js"
  REMOTE_ECOSYSTEM="ecosystem.dev.config.js"
else
  echo "❌ Lingkungan tidak valid: ${TARGET_ENV}. Gunakan 'prod' atau 'dev'."
  exit 1
fi

if [ -z "$VPS_IP" ]; then
  echo "❌ IP VPS untuk ${TARGET_ENV} belum diisi di ${CONFIG_DIR}/.env!"
  exit 1
fi

SSH_CMD="ssh -p ${VPS_PORT} ${VPS_USER}@${VPS_IP}"

echo "=============================================================================="
echo "🚀 Memulai Deployment April Eyewear [Target: ${TARGET_ENV}]"
echo "   Server: ${VPS_USER}@${VPS_IP}:${VPS_PORT}"
echo "   Path: ${DEPLOY_DIR}"
echo "=============================================================================="

# 1. Build Main Service Secara Lokal
echo "🔨 1. Membangun Main Service secara lokal..."
cd "${ROOT_DIR}/april-eyewear-main-service"
npm ci
npm run build
npx prisma generate

# 2. Build Shipment Service Secara Lokal
echo "🔨 2. Membangun Shipment Service secara lokal..."
cd "${ROOT_DIR}/april-eyewear-shipment-service"
npm ci
npm run build

# 3. Pastikan Direktori Remote Tersedia
echo "📁 3. Menyiapkan folder tujuan di VPS..."
$SSH_CMD "mkdir -p ${DEPLOY_DIR}/april-eyewear-main-service ${DEPLOY_DIR}/april-eyewear-shipment-service /var/log/pm2"

# 4. Sync Main Service Artifacts
echo "📤 4. Mengirim artefak Main Service ke VPS..."
rsync -avz -e "ssh -p ${VPS_PORT}" --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  --exclude 'src' \
  --exclude 'test' \
  "${ROOT_DIR}/april-eyewear-main-service/dist" \
  "${ROOT_DIR}/april-eyewear-main-service/package.json" \
  "${ROOT_DIR}/april-eyewear-main-service/package-lock.json" \
  "${ROOT_DIR}/april-eyewear-main-service/prisma" \
  "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/april-eyewear-main-service/"

# 5. Sync Shipment Service Artifacts
echo "📤 5. Mengirim artefak Shipment Service ke VPS..."
rsync -avz -e "ssh -p ${VPS_PORT}" --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  --exclude 'src' \
  --exclude 'test' \
  "${ROOT_DIR}/april-eyewear-shipment-service/dist" \
  "${ROOT_DIR}/april-eyewear-shipment-service/package.json" \
  "${ROOT_DIR}/april-eyewear-shipment-service/package-lock.json" \
  "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/april-eyewear-shipment-service/"

# 6. Kirim PM2 Ecosystem Config
echo "📤 6. Mengirim file konfigurasi PM2..."
scp -P "${VPS_PORT}" "${CONFIG_DIR}/${ECOSYSTEM_FILE}" "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/${REMOTE_ECOSYSTEM}"

# 7. Eksekusi Remote: Install Dependencies, Migrate, & Reload PM2
echo "⚡ 7. Menginstal dependensi produksi & reload PM2 di server..."
$SSH_CMD << EOF
  set -e
  echo "--> Installing production dependencies on Main Service..."
  cd ${DEPLOY_DIR}/april-eyewear-main-service
  npm install --omit=dev --no-audit --no-fund
  npx prisma migrate deploy

  echo "--> Installing production dependencies on Shipment Service..."
  cd ${DEPLOY_DIR}/april-eyewear-shipment-service
  npm install --omit=dev --no-audit --no-fund

  echo "--> Reloading PM2 services with zero downtime..."
  pm2 reload ${DEPLOY_DIR}/${REMOTE_ECOSYSTEM} --update-env || pm2 start ${DEPLOY_DIR}/${REMOTE_ECOSYSTEM}
  pm2 save
  echo "--> PM2 Status:"
  pm2 status
EOF

echo "=============================================================================="
echo "✅ Deployment ke ${TARGET_ENV} Sukses Berjalan!"
echo "=============================================================================="

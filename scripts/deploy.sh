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
  VPS_SSH_KEY="${PROD_VPS_SSH_KEY_PATH}"
  DEPLOY_DIR="${PROD_DEPLOY_DIR:-/var/www/april-eyewear}"
  ECOSYSTEM_FILE="prod/ecosystem.config.js"
  REMOTE_ECOSYSTEM="ecosystem.config.js"
elif [ "$TARGET_ENV" = "dev" ]; then
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${DEV_VPS_SSH_KEY_PATH}"
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
RSYNC_SSH="ssh -p ${VPS_PORT} ${SSH_KEY_OPT}"
SCP_CMD="scp -P ${VPS_PORT} ${SSH_KEY_OPT}"

echo "=============================================================================="
echo "🚀 Memulai Deployment April Eyewear [Target: ${TARGET_ENV}]"
echo "   Server:  ${VPS_USER}@${VPS_IP}:${VPS_PORT}"
[ -n "$VPS_SSH_KEY" ] && echo "   SSH Key: ${VPS_SSH_KEY}"
echo "   Path:    ${DEPLOY_DIR}"
echo "=============================================================================="

# 0. Sinkronisasi DNS Cloudflare Otomatis (Jika Kredensial Tersedia)
if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
  echo "🌐 0. Memeriksa dan menyinkronkan DNS Cloudflare..."
  bash "${SCRIPT_DIR}/sync-cloudflare-dns.sh" "${TARGET_ENV}" || {
    echo "⚠️  Peringatan: Sinkronisasi DNS Cloudflare gagal, melanjutkan proses deployment aplikasi..."
  }
else
  echo "ℹ️  CLOUDFLARE_API_TOKEN tidak diatur di .env. Melewati sinkronisasi DNS otomatis."
fi

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

# 3. Pastikan Direktori Remote Tersedia & Permission Benar
echo "📁 3. Menyiapkan folder tujuan di VPS..."
$SSH_CMD "sudo mkdir -p ${DEPLOY_DIR} /var/log/pm2 && sudo chown -R ${VPS_USER}:${VPS_USER} ${DEPLOY_DIR} /var/log/pm2 && mkdir -p ${DEPLOY_DIR}/april-eyewear-main-service ${DEPLOY_DIR}/april-eyewear-shipment-service"

# 4. Sync Main Service Artifacts
echo "📤 4. Mengirim artefak Main Service ke VPS..."
rsync -avz -e "${RSYNC_SSH}" --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  "${ROOT_DIR}/april-eyewear-main-service/dist" \
  "${ROOT_DIR}/april-eyewear-main-service/package.json" \
  "${ROOT_DIR}/april-eyewear-main-service/package-lock.json" \
  "${ROOT_DIR}/april-eyewear-main-service/prisma" \
  "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/april-eyewear-main-service/"

# Siapkan .env Main Service di remote
TARGET_MAIN_ENV="${CONFIG_DIR}/${TARGET_ENV}/main.env"
if [ -f "$TARGET_MAIN_ENV" ]; then
  echo "⚙️  Mengunggah .env Main Service dari ${TARGET_ENV}/main.env..."
  $SCP_CMD "$TARGET_MAIN_ENV" "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/april-eyewear-main-service/.env"
else
  REMOTE_HAS_MAIN_ENV=$($SSH_CMD "[ -f ${DEPLOY_DIR}/april-eyewear-main-service/.env ] && echo 'YES' || echo 'NO'")
  if [ "$REMOTE_HAS_MAIN_ENV" = "NO" ]; then
    echo "❌ File konfigurasi ${TARGET_ENV}/main.env tidak ditemukan di lokal dan belum ada di VPS!"
    echo "   Salin ${TARGET_ENV}/main.env.example menjadi ${TARGET_ENV}/main.env dan sesuaikan nilainya."
    exit 1
  else
    echo "ℹ️  Menggunakan .env Main Service yang sudah ada di server."
  fi
fi

# 5. Sync Shipment Service Artifacts
echo "📤 5. Mengirim artefak Shipment Service ke VPS..."
rsync -avz -e "${RSYNC_SSH}" --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  "${ROOT_DIR}/april-eyewear-shipment-service/dist" \
  "${ROOT_DIR}/april-eyewear-shipment-service/package.json" \
  "${ROOT_DIR}/april-eyewear-shipment-service/package-lock.json" \
  "${ROOT_DIR}/april-eyewear-shipment-service/prisma" \
  "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/april-eyewear-shipment-service/"

# Siapkan .env Shipment Service di remote
TARGET_SHIP_ENV="${CONFIG_DIR}/${TARGET_ENV}/shipment.env"
if [ -f "$TARGET_SHIP_ENV" ]; then
  echo "⚙️  Mengunggah .env Shipment Service dari ${TARGET_ENV}/shipment.env..."
  $SCP_CMD "$TARGET_SHIP_ENV" "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/april-eyewear-shipment-service/.env"
else
  REMOTE_HAS_SHIP_ENV=$($SSH_CMD "[ -f ${DEPLOY_DIR}/april-eyewear-shipment-service/.env ] && echo 'YES' || echo 'NO'")
  if [ "$REMOTE_HAS_SHIP_ENV" = "NO" ]; then
    echo "❌ File konfigurasi ${TARGET_ENV}/shipment.env tidak ditemukan di lokal dan belum ada di VPS!"
    echo "   Salin ${TARGET_ENV}/shipment.env.example menjadi ${TARGET_ENV}/shipment.env dan sesuaikan nilainya."
    exit 1
  else
    echo "ℹ️  Menggunakan .env Shipment Service yang sudah ada di server."
  fi
fi

# 6. Kirim PM2 Ecosystem Config & Nginx Config
echo "📤 6. Mengirim file konfigurasi PM2..."
$SCP_CMD "${CONFIG_DIR}/${ECOSYSTEM_FILE}" "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/${REMOTE_ECOSYSTEM}"

if [ "$TARGET_ENV" = "dev" ] && [ -f "${CONFIG_DIR}/dev/nginx-dev.conf" ]; then
  echo "🌐 Mengonfigurasi Nginx Reverse Proxy di server..."
  $SCP_CMD "${CONFIG_DIR}/dev/nginx-dev.conf" "${VPS_USER}@${VPS_IP}:/tmp/nginx-dev.conf"
  $SSH_CMD "sudo mv /tmp/nginx-dev.conf /etc/nginx/sites-available/dev-api.aprileyewear.com && sudo ln -sf /etc/nginx/sites-available/dev-api.aprileyewear.com /etc/nginx/sites-enabled/ && sudo rm -f /etc/nginx/sites-enabled/default && sudo nginx -t && sudo systemctl reload nginx"
fi

# 7. Eksekusi Remote: Install Dependencies, Migrate, & Reload PM2
echo "⚡ 7. Menginstal dependensi produksi, migrasi database & reload PM2 di server..."
$SSH_CMD << EOF
  set -e
  echo "--> Installing production dependencies & migrating Main Service..."
  cd ${DEPLOY_DIR}/april-eyewear-main-service
  npm install --omit=dev --no-audit --no-fund
  npx prisma generate
  npx prisma db push --accept-data-loss

  echo "--> Installing production dependencies & migrating Shipment Service..."
  cd ${DEPLOY_DIR}/april-eyewear-shipment-service
  npm install --omit=dev --no-audit --no-fund
  npx prisma generate
  npx prisma db push --accept-data-loss

  echo "--> Reloading PM2 services with zero downtime..."
  pm2 reload ${DEPLOY_DIR}/${REMOTE_ECOSYSTEM} --update-env || pm2 start ${DEPLOY_DIR}/${REMOTE_ECOSYSTEM}
  pm2 save
  echo "--> PM2 Status:"
  pm2 status
EOF

echo "=============================================================================="
echo "🩺 Memeriksa Status Layanan Pasca-Deploy..."
echo "=============================================================================="
sleep 3
$SSH_CMD "curl -s http://127.0.0.1:3000/api/v1/health || curl -s http://127.0.0.1:3000/ || true"
echo ""

echo "=============================================================================="
echo "✅ Deployment ke ${TARGET_ENV} Sukses Berjalan!"
echo "   Endpoint: http://${VPS_IP}/"
echo "=============================================================================="

if [ -f "${SCRIPT_DIR}/notify.sh" ]; then
  bash "${SCRIPT_DIR}/notify.sh" success "Deployment Berhasil [${TARGET_ENV}]" "Aplikasi April Eyewear (Main & Shipment) berhasil di-deploy ke ${VPS_IP} dan PM2 telah di-reload."
fi

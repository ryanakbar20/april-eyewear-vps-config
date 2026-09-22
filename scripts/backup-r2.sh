#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - CLOUDFLARE R2 DATABASE BACKUP SCRIPT
# Dapat dijalankan langsung di VPS via cron atau secara manual dari lokal:
#   ./scripts/backup-r2.sh prod
#   ./scripts/backup-r2.sh dev
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${CONFIG_DIR}/.env" ]; then
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
fi

TARGET_ENV=${1:-"prod"}

if [ "$TARGET_ENV" = "prod" ]; then
  VPS_IP="${PROD_VPS_IP}"
  VPS_PORT="${PROD_VPS_PORT:-22}"
  VPS_USER="${PROD_VPS_USER:-ubuntu}"
  DB_NAME="${PROD_DB_NAME:-april_eyewear_db}"
else
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
  DB_NAME="${DEV_DB_NAME:-april_dev_db}"
fi

if [ -z "$VPS_IP" ]; then
  echo "❌ IP VPS untuk ${TARGET_ENV} belum diisi di ${CONFIG_DIR}/.env!"
  exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME="${DB_NAME}_${TIMESTAMP}.sql.gz"
SSH_CMD="ssh -p ${VPS_PORT} ${VPS_USER}@${VPS_IP}"

echo "📦 Memulai Backup Database [${DB_NAME}] dari server ${VPS_IP}..."

$SSH_CMD << EOF
  set -e
  mkdir -p /tmp/backups
  echo "--> Dumping database ${DB_NAME}..."
  pg_dump -U postgres ${DB_NAME} | gzip > /tmp/backups/${BACKUP_FILENAME}

  echo "--> Database dump created: /tmp/backups/${BACKUP_FILENAME}"
  ls -lh /tmp/backups/${BACKUP_FILENAME}
EOF

# Jika rclone atau aws cli sudah terpasang, file bisa langsung dipush ke R2
echo "☁️ Backup tersimpan di server. Untuk sinkronisasi otomatis ke R2, pastikan rclone terkonfigurasi di VPS."
echo "✅ Backup Selesai: ${BACKUP_FILENAME}"

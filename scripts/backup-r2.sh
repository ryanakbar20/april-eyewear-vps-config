#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - CLOUDFLARE R2 AUTOMATED DATABASE BACKUP SCRIPT
# Menghasilkan snapshot PostgreSQL, mengunggah ke Cloudflare R2, dan merotasi file lama.
#
# Cara pakai:
#   ./scripts/backup-r2.sh prod
#   ./scripts/backup-r2.sh dev
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env
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

BUCKET="${R2_BUCKET_BACKUP:-april-eyewear-backups}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME="${DB_NAME}_${TIMESTAMP}.sql.gz"
SSH_CMD="ssh -p ${VPS_PORT} ${VPS_USER}@${VPS_IP}"

echo "=============================================================================="
echo "📦 Memulai Backup Database [${DB_NAME}] -> Cloudflare R2 (${BUCKET})"
echo "   Server: ${VPS_USER}@${VPS_IP}:${VPS_PORT}"
echo "=============================================================================="

# Jalankan dump & upload langsung di server target
$SSH_CMD << EOF
  set -e
  mkdir -p /tmp/backups

  # 1. Pastikan rclone terinstall
  if ! command -v rclone &> /dev/null; then
    echo "--> Menginstal rclone untuk sinkronisasi Cloudflare R2..."
    sudo apt-get update && sudo apt-get install -y rclone
  fi

  # 2. Konfigurasi remote r2 secara otomatis jika belum ada
  if [ -n "${R2_ACCESS_KEY_ID}" ] && [ -n "${R2_SECRET_ACCESS_KEY}" ]; then
    echo "--> Menyiapkan koneksi rclone ke Cloudflare R2..."
    rclone config create r2 s3 \
      provider Cloudflare \
      access_key_id "${R2_ACCESS_KEY_ID}" \
      secret_access_key "${R2_SECRET_ACCESS_KEY}" \
      endpoint "${R2_S3_ENDPOINT}" \
      acl private > /dev/null 2>&1 || true
  fi

  # 3. Dump Database PostgreSQL
  echo "--> Dumping database ${DB_NAME}..."
  pg_dump -U postgres ${DB_NAME} | gzip > /tmp/backups/${BACKUP_FILENAME}
  FILESIZE=\$(du -h /tmp/backups/${BACKUP_FILENAME} | cut -f1)
  echo "--> Snapshot berhasil dibuat: ${BACKUP_FILENAME} (\${FILESIZE})"

  # 4. Upload ke Cloudflare R2
  if rclone listremotes | grep -q 'r2:'; then
    echo "--> Mengunggah ${BACKUP_FILENAME} ke r2:${BUCKET}/database/..."
    rclone copy /tmp/backups/${BACKUP_FILENAME} r2:${BUCKET}/database/
    echo "✅ Berhasil terunggah ke Cloudflare R2!"

    # 5. Retensi: Hapus backup di R2 yang lebih lama dari 14 hari
    echo "--> Membersihkan backup di R2 yang lebih dari 14 hari..."
    rclone delete --min-age 14d r2:${BUCKET}/database/ || true
  else
    echo "⚠️ Rclone remote 'r2:' belum terkonfigurasi. File disimpan lokal di /tmp/backups/."
  fi

  # 6. Retensi lokal: Hanya simpan 3 file backup terbaru di disk VPS
  ls -t /tmp/backups/${DB_NAME}_*.sql.gz | tail -n +4 | xargs -r rm -f
EOF

# Kirim notifikasi jika webhook aktif
if [ -f "${SCRIPT_DIR}/notify.sh" ]; then
  bash "${SCRIPT_DIR}/notify.sh" success "Database Backup Berhasil [${TARGET_ENV}]" "Snapshot ${BACKUP_FILENAME} telah diunggah ke Cloudflare R2 (${BUCKET})."
fi

echo "=============================================================================="
echo "🎉 Backup Database Sukses: ${BACKUP_FILENAME}"
echo "=============================================================================="

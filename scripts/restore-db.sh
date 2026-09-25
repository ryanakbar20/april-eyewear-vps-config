#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - DATABASE DISASTER RECOVERY & RESTORE SCRIPT
# Mengembalikan database PostgreSQL dari backup Cloudflare R2 / lokal.
#
# Cara pakai:
#   ./scripts/restore-db.sh prod latest
#   ./scripts/restore-db.sh dev latest
#   ./scripts/restore-db.sh prod /path/to/backup.sql.gz
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment variables
if [ -f "${CONFIG_DIR}/.env" ]; then
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
else
  echo "❌ File .env tidak ditemukan di ${CONFIG_DIR}/.env!"
  exit 1
fi

TARGET_ENV=${1:-"dev"}
BACKUP_SOURCE=${2:-"latest"}

if [ "$TARGET_ENV" = "prod" ]; then
  VPS_IP="${PROD_VPS_IP}"
  VPS_PORT="${PROD_VPS_PORT:-22}"
  VPS_USER="${PROD_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${PROD_VPS_SSH_KEY_PATH}"
  DB_NAME="${PROD_DB_NAME:-april_eyewear_db}"
elif [ "$TARGET_ENV" = "dev" ]; then
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${DEV_VPS_SSH_KEY_PATH}"
  DB_NAME="${DEV_DB_NAME:-april_dev_db}"
else
  echo "❌ Lingkungan target tidak valid: ${TARGET_ENV}. Gunakan 'prod' atau 'dev'."
  exit 1
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
echo "⚠️  PERINGATAN: RESTORE DATABASE AKAN MENIMPA DATA SAAT INI!"
echo "   Target Server: ${VPS_USER}@${VPS_IP}:${VPS_PORT}"
[ -n "$VPS_SSH_KEY" ] && echo "   SSH Key:       ${VPS_SSH_KEY}"
echo "   Database:      ${DB_NAME}"
echo "   Sumber Backup: ${BACKUP_SOURCE}"
echo "=============================================================================="

read -p "Apakah Anda yakin ingin melanjutkan proses restore? (ketik 'YA' untuk konfirmasi): " CONFIRM
if [ "$CONFIRM" != "YA" ]; then
  echo "❌ Operasi dibatalkan oleh pengguna."
  exit 0
fi

echo "🚀 Memulai prosedur pemulihan bencana..."

# 1. Menentukan dan Menyiapkan File Backup di VPS
if [ -f "$BACKUP_SOURCE" ]; then
  echo "📤 Mengunggah file backup lokal (${BACKUP_SOURCE}) ke server..."
  REMOTE_BACKUP_FILE="/tmp/backups/restore_$(basename ${BACKUP_SOURCE})"
  $SSH_CMD "mkdir -p /tmp/backups"
  $SCP_CMD "${BACKUP_SOURCE}" "${VPS_USER}@${VPS_IP}:${REMOTE_BACKUP_FILE}"
else
  # Mengambil snapshot terbaru yang ada di folder /tmp/backups VPS
  REMOTE_BACKUP_FILE=$($SSH_CMD "ls -t /tmp/backups/${DB_NAME}_*.sql.gz 2>/dev/null | head -n 1 || true")
  if [ -z "$REMOTE_BACKUP_FILE" ]; then
    echo "❌ Tidak ditemukan file backup snapshot di /tmp/backups/ pada server ${VPS_IP}!"
    echo "💡 Pastikan Anda telah mengunduh backup dari Cloudflare R2 atau tentukan file lokal."
    exit 1
  fi
  echo "📦 Menggunakan file backup snapshot terbaru di server: ${REMOTE_BACKUP_FILE}"
fi

# 2. Eksekusi Pemulihan di Server
echo "⚡ Mengeksekusi proses restore di server PostgreSQL..."
$SSH_CMD << EOF
  set -e
  echo "--> 1. Menghentikan aplikasi sementara..."
  pm2 stop all || true

  echo "--> 2. Memutuskan seluruh koneksi aktif ke database ${DB_NAME}..."
  sudo -u postgres psql -c "
    SELECT pg_terminate_backend(pid) 
    FROM pg_stat_activity 
    WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" || true

  echo "--> 3. Menghapus dan membuat ulang database ${DB_NAME}..."
  sudo -u postgres dropdb --if-exists ${DB_NAME}
  sudo -u postgres createdb ${DB_NAME} -O postgres

  echo "--> 4. Merestore data dari ${REMOTE_BACKUP_FILE}..."
  gunzip -c ${REMOTE_BACKUP_FILE} | sudo -u postgres psql -d ${DB_NAME} -q

  echo "--> 5. Menjalankan migrasi Prisma terbaru (jika ada skema tertinggal)..."
  if [ -d "/var/www/april-eyewear/april-eyewear-main-service" ]; then
    cd /var/www/april-eyewear/april-eyewear-main-service && npx prisma migrate deploy || true
  elif [ -d "/var/www/april-eyewear-dev/april-eyewear-main-service" ]; then
    cd /var/www/april-eyewear-dev/april-eyewear-main-service && npx prisma migrate deploy || true
  fi

  echo "--> 6. Menyalakan kembali aplikasi di PM2..."
  pm2 restart all
  pm2 status

  echo "--> 7. Verifikasi jumlah tabel yang berhasil dipulihkan:"
  sudo -u postgres psql -d ${DB_NAME} -c "
    SELECT count(*) AS total_tables 
    FROM information_schema.tables 
    WHERE table_schema = 'public';"
EOF

echo "=============================================================================="
echo "✅ PEMULIHAN BENCANA DATABASE SELESAI DENGAN SUKSES!"
echo "   Sistem kembali online dan beroperasi normal."
echo "=============================================================================="

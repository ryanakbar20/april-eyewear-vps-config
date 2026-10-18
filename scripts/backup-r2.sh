#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - MANUAL DATABASE BACKUP (dijalankan dari laptop operator)
#
# Menjalankan skrip backup yang ada DI SERVER (scripts/server-backup-db.sh).
# Logikanya sengaja tidak diduplikasi di sini: cron memakai skrip server yang
# sama, jadi jalur manual dan jalur otomatis tidak mungkin berbeda perilaku.
#
# Cara pakai:
#   ./scripts/backup-r2.sh dev
#   ./scripts/backup-r2.sh prod
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env
if [ -f "${CONFIG_DIR}/.env" ]; then
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
fi

TARGET_ENV=${1:-"dev"}

if [ "$TARGET_ENV" = "prod" ]; then
  VPS_IP="${PROD_VPS_IP}"
  VPS_PORT="${PROD_VPS_PORT:-22}"
  VPS_USER="${PROD_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${PROD_VPS_SSH_KEY_PATH}"
else
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${DEV_VPS_SSH_KEY_PATH}"
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

if [ -z "$VPS_SSH_KEY" ] || [ ! -f "$VPS_SSH_KEY" ]; then
  if [ -f "${SCRIPT_DIR}/id_rsa.pem" ]; then
    VPS_SSH_KEY="${SCRIPT_DIR}/id_rsa.pem"
  elif [ -f "${CONFIG_DIR}/id_rsa.pem" ]; then
    VPS_SSH_KEY="${CONFIG_DIR}/id_rsa.pem"
  fi
fi

SSH_KEY_OPT=""
if [ -n "$VPS_SSH_KEY" ] && [ -f "$VPS_SSH_KEY" ]; then
  chmod 600 "$VPS_SSH_KEY" 2>/dev/null || true
  SSH_KEY_OPT="-i ${VPS_SSH_KEY}"
fi

BUCKET="${R2_BUCKET_BACKUP:-april-eyewear-backups}"
SSH_CMD="ssh -p ${VPS_PORT} ${SSH_KEY_OPT} ${VPS_USER}@${VPS_IP}"
REMOTE_SCRIPT="/home/ubuntu/bin/db-backup.sh"

echo "=============================================================================="
echo "📦 Backup Database [${TARGET_ENV}] via skrip server"
echo "   Server:  ${VPS_USER}@${VPS_IP}:${VPS_PORT}"
echo "   Skrip:   ${REMOTE_SCRIPT}"
echo "   Bucket:  r2:${BUCKET}/database/"
echo "=============================================================================="

if ! $SSH_CMD "test -x ${REMOTE_SCRIPT}"; then
  echo "❌ ${REMOTE_SCRIPT} tidak ada / tidak executable di server."
  echo "   Pasang dulu: scp ${SCRIPT_DIR}/server-backup-db.sh ${VPS_USER}@${VPS_IP}:${REMOTE_SCRIPT}"
  exit 1
fi

OUTPUT="$($SSH_CMD "R2_BUCKET_BACKUP='${BUCKET}' ${REMOTE_SCRIPT}")"
echo "$OUTPUT"

if [ -f "${SCRIPT_DIR}/notify.sh" ]; then
  SUMMARY="$(echo "$OUTPUT" | tail -2 | tr '\n' ' ')"
  bash "${SCRIPT_DIR}/notify.sh" success "Database Backup Berhasil [${TARGET_ENV}]" "${SUMMARY}"
fi

echo "=============================================================================="
echo "🎉 Backup Database [${TARGET_ENV}] Sukses"
echo "=============================================================================="

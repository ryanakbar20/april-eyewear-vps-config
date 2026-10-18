#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - ONE-TIME MIGRATION BASELINE
#
# Untuk database yang SUDAH berisi data tapi belum punya tabel _prisma_migrations
# (artinya schema-nya dulu dibuat dengan `prisma db push`, bukan `migrate`).
#
# Menandai migrasi 0_init sebagai "sudah diterapkan" tanpa menjalankannya, supaya
# `prisma migrate deploy` tidak mencoba membuat ulang tabel yang sudah ada.
#
# Database kosong / baru TIDAK perlu ini - `migrate deploy` langsung menerapkan
# 0_init dari nol.
#
# Cara pakai:
#   ./scripts/baseline-migrations.sh dev
#   ./scripts/baseline-migrations.sh prod
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
  VPS_SSH_KEY="${PROD_VPS_SSH_KEY_PATH}"
  DEPLOY_DIR="${PROD_DEPLOY_DIR:-/var/www/april-eyewear}"
else
  VPS_IP="${DEV_VPS_IP}"
  VPS_PORT="${DEV_VPS_PORT:-22}"
  VPS_USER="${DEV_VPS_USER:-ubuntu}"
  VPS_SSH_KEY="${DEV_VPS_SSH_KEY_PATH}"
  DEPLOY_DIR="${DEV_DEPLOY_DIR:-/var/www/april-eyewear-dev}"
fi

if [ -z "$VPS_IP" ]; then
  echo "❌ IP VPS untuk ${TARGET_ENV} belum diisi di ${CONFIG_DIR}/.env!"
  exit 1
fi

VPS_SSH_KEY="${VPS_SSH_KEY/#\~/$HOME}"
if [ -n "$VPS_SSH_KEY" ] && [[ "$VPS_SSH_KEY" != /* ]]; then
  VPS_SSH_KEY="${CONFIG_DIR}/${VPS_SSH_KEY}"
fi
if [ -z "$VPS_SSH_KEY" ] || [ ! -f "$VPS_SSH_KEY" ]; then
  [ -f "${SCRIPT_DIR}/id_rsa.pem" ] && VPS_SSH_KEY="${SCRIPT_DIR}/id_rsa.pem"
fi

SSH_KEY_OPT=""
[ -n "$VPS_SSH_KEY" ] && [ -f "$VPS_SSH_KEY" ] && SSH_KEY_OPT="-i ${VPS_SSH_KEY}"

SSH_CMD="ssh -p ${VPS_PORT} ${SSH_KEY_OPT} ${VPS_USER}@${VPS_IP}"

echo "=============================================================================="
echo "🏷️  Baseline Migrasi [${TARGET_ENV}] di ${VPS_USER}@${VPS_IP}"
echo "=============================================================================="

$SSH_CMD << EOF
  set -e
  for SERVICE in april-eyewear-main-service april-eyewear-shipment-service; do
    cd "${DEPLOY_DIR}/\${SERVICE}"

    DB_NAME="\$(grep -E '^DATABASE_URL=' .env | head -1 | cut -d= -f2- | tr -d '\"' | sed -E 's#.*/([^/?]+)(\?.*)?#\\1#')"
    HAS_TABLES="\$(sudo -u postgres psql -tAc "select count(*) from information_schema.tables where table_schema='public'" "\$DB_NAME")"
    HAS_MIGRATIONS="\$(sudo -u postgres psql -tAc "select to_regclass('public._prisma_migrations') is not null" "\$DB_NAME")"

    echo "--> \${SERVICE} (db=\${DB_NAME}, tabel=\${HAS_TABLES}, sudah ada _prisma_migrations=\${HAS_MIGRATIONS})"
    if [ "\$HAS_MIGRATIONS" = "t" ]; then
      echo "    Dilewati: database ini sudah memakai riwayat migrasi."
    elif [ "\$HAS_TABLES" -gt 0 ]; then
      echo "    Menandai 0_init sebagai sudah diterapkan (schema lama dari db push)..."
      npx prisma migrate resolve --applied 0_init
    else
      echo "    Dilewati: database kosong, biarkan migrate deploy yang membuat schema."
    fi
  done
EOF

echo "=============================================================================="
echo "✅ Baseline selesai. Lanjutkan dengan deploy (prisma migrate deploy)."
echo "=============================================================================="

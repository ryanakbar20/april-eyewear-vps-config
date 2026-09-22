#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - TELEGRAM & DISCORD NOTIFICATION HELPER
# Mengirimkan pesan status (deploy, backup, error) ke Discord dan Telegram.
#
# Cara pakai:
#   ./scripts/notify.sh success "Database Backup Sukses" "File april_eyewear_db_20260922.sql.gz terunggah ke R2"
#   ./scripts/notify.sh error "Deploy Gagal" "Error saat migrasi Prisma di VPS Prod"
#   ./scripts/notify.sh info "Deploy Dimulai" "Deploying commit 8ced877 ke Prod"
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${CONFIG_DIR}/.env" ]; then
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
fi

STATUS_TYPE=${1:-"info"}
TITLE=${2:-"Notifikasi April Eyewear"}
MESSAGE=${3:-""}
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S WIB")

# Tentukan warna untuk Discord Embed (Hex to Decimal)
if [ "$STATUS_TYPE" = "success" ]; then
  COLOR=3066993   # Hijau (#2ecc71)
  ICON="✅"
elif [ "$STATUS_TYPE" = "error" ]; then
  COLOR=15158332  # Merah (#e74c3c)
  ICON="❌"
else
  COLOR=3447003   # Biru (#3498db)
  ICON="ℹ️"
fi

# 1. Kirim ke Discord Webhook jika ada
if [ -n "$DISCORD_WEBHOOK_URL" ]; then
  PAYLOAD=$(python3 -c "
import json, sys
data = {
    'embeds': [{
        'title': f'$ICON $TITLE',
        'description': '$MESSAGE',
        'color': $COLOR,
        'footer': {'text': 'April Eyewear Infrastructure • $TIMESTAMP'}
    }]
}
print(json.dumps(data))
")
  curl -s -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL" > /dev/null || true
fi

# 2. Kirim ke Telegram jika token dan chat ID ada
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  TG_TEXT="<b>$ICON $TITLE</b>%0A%0A$MESSAGE%0A%0A<i>Waktu: $TIMESTAMP</i>"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${TG_TEXT}" \
    -d "parse_mode=HTML" > /dev/null || true
fi

echo "📢 [$STATUS_TYPE] $TITLE: $MESSAGE"

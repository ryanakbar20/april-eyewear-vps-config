#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - PM2 AUTO-RECOVERY GUARD
#
# Dipasang oleh scripts/deploy.sh ke /home/<user>/bin/pm2-guard.sh dan dijalankan
# cron tiap 2 menit. Memulihkan layanan otomatis:
#   1) Jika ada app PM2 yang tidak online (mis. setelah reboot / daemon mati) -> `pm2 resurrect`.
#   2) Jika health check sebuah app gagal -> `pm2 restart <app>`.
# Quiet saat sehat (log hanya ditulis saat ada tindakan). Opsional kirim notifikasi Discord
# memakai notify.env yang sama dengan uptime-check.
#
# Env yang bisa diatur (diisi deploy.sh lewat baris cron):
#   EXPECTED_APPS, ECOSYSTEM, MAIN_URL, SHIPMENT_URL, NOTIFY_ENV
# ==============================================================================
set -uo pipefail

export PM2_HOME="${PM2_HOME:-$HOME/.pm2}"
export PATH="/usr/bin:/bin:/usr/local/bin:$PATH"

EXPECTED_APPS="${EXPECTED_APPS:-april-main-dev april-shipment-dev}"
MAIN_URL="${MAIN_URL:-http://127.0.0.1:3000/api/v1/health}"
SHIPMENT_URL="${SHIPMENT_URL:-http://127.0.0.1:3002/}"
ECOSYSTEM="${ECOSYSTEM:-/var/www/april-eyewear-dev/ecosystem.dev.config.js}"

NOTIFY_ENV="${NOTIFY_ENV:-$HOME/.config/april/notify.env}"
if [ -f "$NOTIFY_ENV" ]; then
  # shellcheck disable=SC1090
  source "$NOTIFY_ENV"
fi
notify() {
  [ -n "${DISCORD_WEBHOOK_URL:-}" ] || return 0
  curl -s -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"content\": \"$1\"}" "$DISCORD_WEBHOOK_URL" || true
}

LOG() { echo "[$(date '+%F %T')] $*"; }
health_ok() { curl -fsS -m 8 -o /dev/null "$1"; }
online_apps() {
  pm2 jlist 2>/dev/null | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
except Exception:
  d=[]
print("\n".join(p.get("name","") for p in d if p.get("pm2_env",{}).get("status")=="online"))' 2>/dev/null
}

acted=0
ONLINE="$(online_apps)"
missing=0
for app in $EXPECTED_APPS; do
  echo "$ONLINE" | grep -qx "$app" || missing=1
done

if [ "$missing" = "1" ]; then
  LOG "App PM2 tidak online (online: [$(echo $ONLINE | tr '\n' ' ')]) -> resurrect"
  if ! pm2 resurrect >/dev/null 2>&1; then
    LOG "resurrect gagal; mencoba start ecosystem"
    pm2 start "$ECOSYSTEM" --update-env >/dev/null 2>&1 || true
  fi
  sleep 6
  pm2 save >/dev/null 2>&1 || true
  acted=1
  notify "🛠️ AUTO-RECOVERY: PM2 di-resurrect di $(hostname) (ada app yang tidak online)."
fi

if ! health_ok "$MAIN_URL"; then
  LOG "Health main API gagal -> restart main service"
  pm2 restart "$(echo $EXPECTED_APPS | awk '{print $1}')" --update-env >/dev/null 2>&1 || true
  acted=1
fi

if ! health_ok "$SHIPMENT_URL"; then
  LOG "Health shipment gagal -> restart shipment service"
  pm2 restart "$(echo $EXPECTED_APPS | awk '{print $2}')" --update-env >/dev/null 2>&1 || true
  acted=1
fi

if [ "$acted" = "1" ]; then
  sleep 3
  pm2 save >/dev/null 2>&1 || true
  LOG "Auto-recovery selesai."
fi

exit 0

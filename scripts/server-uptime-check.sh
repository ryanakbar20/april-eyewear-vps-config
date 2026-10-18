#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - UPTIME MONITOR
#
# Berjalan DI DALAM VPS lewat cron setiap 5 menit. Memeriksa layanan dari dalam
# (localhost) DAN dari luar (lewat DNS/nginx), lalu mengirim notifikasi ke Discord
# hanya saat berubah status: jatuh, atau pulih kembali.
#
# Hanya memberi tahu saat transisi supaya tidak membanjiri channel; kalau masih
# jatuh, ada pengingat ulang setiap ALERT_REMINDER_SECONDS.
#
# Cara pakai (di server):   /home/ubuntu/bin/uptime-check.sh
# ==============================================================================

set -uo pipefail

STATE_DIR="${STATE_DIR:-/home/ubuntu/.cache/april/uptime-state}"
ALERT_REMINDER_SECONDS="${ALERT_REMINDER_SECONDS:-3600}"
TIMEOUT="${TIMEOUT:-10}"

# URL bisa ditimpa lewat environment supaya perilaku alert bisa diuji tanpa mengganggu layanan.
MAIN_URL="${MAIN_URL:-http://127.0.0.1:3000/api/v1/health}"
SHIPMENT_URL="${SHIPMENT_URL:-http://127.0.0.1:3002/}"
PUBLIC_API_URL="${PUBLIC_API_URL:-https://dev-api.aprileyewear.com/api/v1/health}"
SITE_URL="${SITE_URL:-https://april-eyewear-website.pages.dev/}"

NOTIFY_ENV="${NOTIFY_ENV:-/home/ubuntu/.config/april/notify.env}"
if [ -f "$NOTIFY_ENV" ]; then
  # shellcheck disable=SC1090
  source "$NOTIFY_ENV"
fi

notify() {
  [ -n "${DISCORD_WEBHOOK_URL:-}" ] || return 0
  curl -s -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"content\": \"$1\"}" "$DISCORD_WEBHOOK_URL" || true
}

mkdir -p "$STATE_DIR"
HOSTNAME_SHORT="$(hostname)"

# check <nama> <url> [expect_healthy]
# expect_healthy=1 → selain HTTP 200, payload harus memuat "status":"HEALTHY"
# (health endpoint tetap membalas 200 saat database mati, jadi kode HTTP saja tidak cukup).
check() {
  local name="$1" url="$2" expect_healthy="${3:-0}"
  local body http
  body="$(curl -s -m "$TIMEOUT" -w '\n%{http_code}' "$url" 2>/dev/null)"
  http="$(printf '%s' "$body" | tail -n 1)"
  body="$(printf '%s' "$body" | sed '$d')"

  [ "$http" = "200" ] || return 1
  if [ "$expect_healthy" = "1" ]; then
    printf '%s' "$body" | tr -d ' ' | grep -q '"status":"HEALTHY"' || return 1
  fi
  return 0
}

handle() {
  local name="$1" ok="$2" detail="$3"
  local state_file="${STATE_DIR}/${name}"
  local alert_file="${state_file}.alerted"
  # File state hanya berisi satu kata ("up"/"down"). Jangan menambahkan apa pun di sini: nilai ini
  # dibandingkan langsung, jadi menambahkan timestamp akan membuat perbandingan selalu gagal dan
  # alert terkirim setiap kali cron jalan.
  local previous="up"
  [ -f "$state_file" ] && previous="$(cat "$state_file")"
  local now
  now="$(date +%s)"

  if [ "$ok" = "1" ]; then
    printf 'up' > "$state_file"
    rm -f "$alert_file"
    if [ "$previous" != "up" ]; then
      notify "🟢 **PULIH** — ${name} kembali normal di ${HOSTNAME_SHORT} (${detail})"
      echo "[$(date '+%F %T')] ${name}: UP (sebelumnya DOWN, notifikasi dikirim)"
    else
      echo "[$(date '+%F %T')] ${name}: up"
    fi
    return 0
  fi

  printf 'down' > "$state_file"

  # DOWN: hanya kabari saat transisi, atau saat pengingat jatuh tempo.
  local last_alert=0
  if [ -f "$alert_file" ]; then
    last_alert="$(cat "$alert_file")"
  fi

  if [ "$previous" != "down" ] || [ $((now - last_alert)) -ge "$ALERT_REMINDER_SECONDS" ]; then
    printf '%s' "$now" > "$alert_file"
    notify "🔴 **DOWN** — ${name} tidak sehat di ${HOSTNAME_SHORT} (${detail})"
    echo "[$(date '+%F %T')] ${name}: DOWN (notifikasi dikirim)" >&2
  else
    echo "[$(date '+%F %T')] ${name}: masih DOWN (menunggu jeda pengingat)" >&2
  fi
  return 1
}

problem=0

if check "main-api" "$MAIN_URL" 1; then
  handle "main-api" 1 "database healthy"
else
  handle "main-api" 0 "${MAIN_URL} gagal / database tidak sehat" || problem=1
fi

if check "shipment" "$SHIPMENT_URL" 0; then
  handle "shipment" 1 "respons 200"
else
  handle "shipment" 0 "${SHIPMENT_URL} tidak merespons" || problem=1
fi

if check "public-api" "$PUBLIC_API_URL" 1; then
  handle "public-api" 1 "nginx + TLS + database OK"
else
  handle "public-api" 0 "${PUBLIC_API_URL} gagal dari luar" || problem=1
fi

if check "storefront" "$SITE_URL" 0; then
  handle "storefront" 1 "respons 200"
else
  handle "storefront" 0 "${SITE_URL} tidak merespons" || problem=1
fi

exit "$problem"

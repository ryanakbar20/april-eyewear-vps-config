#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - SERVER-SIDE DATABASE BACKUP
#
# Berjalan DI DALAM VPS (dipanggil cron). Dump setiap database yang dipakai
# service yang ter-deploy, unggah ke Cloudflare R2, lalu rotasi file lama.
#
# Sengaja dijalankan di server, bukan dari laptop operator: backup yang
# bergantung pada laptop yang menyala bukan backup.
#
# Cara pakai (di server):   /home/ubuntu/bin/db-backup.sh
# ==============================================================================

set -euo pipefail

BUCKET="${R2_BUCKET_BACKUP:-april-eyewear-backups}"
WORK_DIR="/tmp/backups"
RETENTION_DAYS=14
LOCAL_KEEP=3
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Kredensial notifikasi disimpan di server, tidak pernah masuk git.
NOTIFY_ENV="/home/ubuntu/.config/april/notify.env"
if [ -f "$NOTIFY_ENV" ]; then
  # shellcheck disable=SC1090
  source "$NOTIFY_ENV"
fi

notify() {
  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    curl -s -H 'Content-Type: application/json' \
      -d "{\"content\": \"$1\"}" "$DISCORD_WEBHOOK_URL" > /dev/null || true
  fi
}

mkdir -p "$WORK_DIR"

# Database ditemukan dari DATABASE_URL tiap service yang ter-deploy, supaya skrip
# yang sama bekerja di host dev maupun produksi tanpa menulis nama DB di kode.
databases=()
for envfile in /var/www/april-eyewear*/april-eyewear-*/.env; do
  [ -f "$envfile" ] || continue
  url="$(grep -E '^DATABASE_URL=' "$envfile" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
  [ -n "$url" ] || continue
  db="${url%%\?*}"
  db="${db##*/}"
  [ -n "$db" ] && databases+=("$db")
done

if [ "${#databases[@]}" -eq 0 ]; then
  echo "Tidak ada DATABASE_URL yang ditemukan di /var/www, memakai nama default."
  databases=("april_dev_db" "april_shipment_db")
fi

mapfile -t databases < <(printf '%s\n' "${databases[@]}" | sort -u)

failed=0
for db in "${databases[@]}"; do
  file="${db}_${TIMESTAMP}.sql.gz"
  echo "[$(date '+%F %T')] dump ${db}..."

  # Peer auth sebagai user OS postgres: socket lokal tidak dikonfigurasi untuk auth password.
  if ! sudo -u postgres pg_dump "$db" | gzip > "${WORK_DIR}/${file}"; then
    echo "[$(date '+%F %T')] GAGAL: dump ${db} error" >&2
    rm -f "${WORK_DIR}/${file}"
    failed=1
    continue
  fi
  size="$(du -h "${WORK_DIR}/${file}" | cut -f1)"

  if rclone listremotes | grep -q '^r2:'; then
    if rclone copy "${WORK_DIR}/${file}" "r2:${BUCKET}/database/"; then
      echo "  -> ${file} (${size}) terunggah ke r2:${BUCKET}/database/"
    else
      echo "  -> GAGAL unggah ${file}" >&2
      failed=1
    fi
  else
    echo "  -> remote 'r2:' belum dikonfigurasi, ${file} hanya tersimpan lokal" >&2
    failed=1
  fi

  # Retensi lokal: sisakan LOCAL_KEEP file terbaru per database.
  ls -t "${WORK_DIR}/${db}"_*.sql.gz 2>/dev/null | tail -n +$((LOCAL_KEEP + 1)) | xargs -r rm -f
done

if rclone listremotes | grep -q '^r2:'; then
  rclone delete --min-age "${RETENTION_DAYS}d" "r2:${BUCKET}/database/" > /dev/null 2>&1 || true
fi

if [ "$failed" -eq 0 ]; then
  echo "[$(date '+%F %T')] backup selesai: ${databases[*]}"
else
  echo "[$(date '+%F %T')] backup selesai DENGAN ERROR" >&2
  notify "⚠️ Backup database GAGAL di $(hostname) pada $(date '+%F %T %Z'). Cek log: /home/ubuntu/logs/db-backup.log"
fi

exit "$failed"

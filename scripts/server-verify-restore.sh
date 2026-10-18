#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - RESTORE DRILL
#
# Mengambil snapshot terbaru dari Cloudflare R2, me-restore-nya ke database
# sementara, lalu membandingkan jumlah tabel dan jumlah baris tabel utama dengan
# database aslinya. Database sementara selalu dihapus di akhir (termasuk saat
# gagal), jadi database asli tidak pernah disentuh.
#
# Cara pakai (di server):
#   /home/ubuntu/bin/verify-restore.sh            # default: april_dev_db
#   /home/ubuntu/bin/verify-restore.sh april_eyewear_db
# ==============================================================================

set -euo pipefail

BUCKET="${R2_BUCKET_BACKUP:-april-eyewear-backups}"
SOURCE_DB="${1:-april_dev_db}"
SCRATCH_DB="restore_drill_$$"
WORK_DIR="$(mktemp -d)"

# Selalu bersihkan, termasuk kalau skrip gagal di tengah jalan.
cleanup() {
  sudo -u postgres dropdb --if-exists "$SCRATCH_DB" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

count_tables() {
  sudo -u postgres psql -tAc \
    "select count(*) from information_schema.tables where table_schema = 'public'" "$1"
}

count_rows() {
  sudo -u postgres psql -tAc "select count(*) from \"$2\"" "$1" 2>/dev/null || echo "n/a"
}

echo "=============================================================================="
echo "🔍 Restore Drill: ${SOURCE_DB}"
echo "=============================================================================="

LATEST="$(rclone lsf --files-only "r2:${BUCKET}/database/" | grep "^${SOURCE_DB}_" | sort | tail -1)"
if [ -z "$LATEST" ]; then
  echo "❌ Tidak ada snapshot '${SOURCE_DB}_*' di r2:${BUCKET}/database/"
  exit 1
fi

echo "Snapshot terbaru : ${LATEST}"
rclone copy "r2:${BUCKET}/database/${LATEST}" "$WORK_DIR/"
echo "Ukuran           : $(du -h "${WORK_DIR}/${LATEST}" | cut -f1)"

echo "--> Restore ke database sementara '${SCRATCH_DB}'..."
sudo -u postgres createdb "$SCRATCH_DB"
gunzip -c "${WORK_DIR}/${LATEST}" | sudo -u postgres psql -q -o /dev/null "$SCRATCH_DB"

TABLES_SRC="$(count_tables "$SOURCE_DB")"
TABLES_DST="$(count_tables "$SCRATCH_DB")"
echo
echo "Jumlah tabel : asli=${TABLES_SRC} restored=${TABLES_DST}"

# Bandingkan tabel dengan baris terbanyak, biar yang benar-benar berisi data ikut diuji.
TABLES="$(sudo -u postgres psql -tAc \
  "select relname from pg_stat_user_tables order by n_live_tup desc limit 6" "$SOURCE_DB")"

MISMATCH=0
echo "Jumlah baris :"
for table in $TABLES; do
  src="$(count_rows "$SOURCE_DB" "$table")"
  dst="$(count_rows "$SCRATCH_DB" "$table")"
  flag="ok"
  if [ "$src" != "$dst" ]; then
    flag="BEDA"
    MISMATCH=1
  fi
  printf '  %-28s asli=%-8s restored=%-8s %s\n' "$table" "$src" "$dst" "$flag"
done

echo
if [ "$TABLES_SRC" != "$TABLES_DST" ]; then
  echo "❌ GAGAL: jumlah tabel berbeda."
  exit 1
fi
if [ "$MISMATCH" -ne 0 ]; then
  echo "❌ GAGAL: ada tabel yang jumlah barisnya berbeda."
  exit 1
fi

echo "✅ Restore drill SUKSES — snapshot ${LATEST} bisa dipulihkan dan datanya utuh."

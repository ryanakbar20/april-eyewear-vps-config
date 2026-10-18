#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - PEMINDAI RAHASIA
#
# Memeriksa file yang DILACAK git (bukan yang di-ignore) pada repo-repo April
# Eyewear untuk mencari kredensial yang tidak seharusnya ikut ter-commit.
#
# Jalankan sebelum rilis, atau setelah menambah variabel lingkungan baru:
#   ./scripts/scan-secrets.sh
#   ./scripts/scan-secrets.sh /path/ke/repo-lain
#
# Exit code 1 kalau ada temuan, supaya bisa dipakai sebagai gerbang otomatis.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${CONFIG_DIR}/.." && pwd)"

REPOS=("$@")
if [ "${#REPOS[@]}" -eq 0 ]; then
  for dir in "$PROJECT_ROOT"/*/; do
    [ -d "${dir}.git" ] && REPOS+=("${dir%/}")
  done
fi

# Pola kredensial nyata. Sengaja spesifik supaya tidak berisik oleh nilai contoh.
HIGH_CONFIDENCE=(
  # Butuh material kunci sungguhan setelah header, supaya placeholder seperti YOUR_DEV_KEY lolos.
  'BEGIN[[:space:]]+(RSA|EC|OPENSSH|PGP)?[[:space:]]*PRIVATE KEY-----?(\\n)?[A-Za-z0-9+/]{40,}'
  'EAA[A-Za-z0-9]{20,}'
  're_[A-Za-z0-9]{24,}'
  'sk_live_[A-Za-z0-9]{16,}'
  'AKIA[0-9A-Z]{16}'
  'cfut_[A-Za-z0-9_-]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'AIza[0-9A-Za-z_-]{30,}'
)

# Nilai panjang setelah nama variabel sensitif. Hanya dipakai untuk file sumber/template; nilai
# contoh seperti "your_password" atau "generated-..." di file *.example tidak dihitung temuan.
GENERIC='(SECRET|TOKEN|PASSWORD|API_KEY|APIKEY|PRIVATE_KEY)[A-Z_]*=[[:space:]]*["'\'']?[A-Za-z0-9/+_-]{32,}'

findings=0
scanned=0

for repo in "${REPOS[@]}"; do
  [ -d "${repo}/.git" ] || continue

  while IFS= read -r file; do
    # Lewati berkas biner dan hasil build/minified yang dipenuhi baris sangat panjang.
    case "$file" in
      *.png|*.jpg|*.jpeg|*.gif|*.webp|*.pdf|*.ico|*.woff|*.woff2|*.ttf|*.lock|package-lock.json) continue ;;
      node_modules/*|dist/*|build/*|coverage/*|*.min.js|*.min.css) continue ;;
    esac
    [ -f "${repo}/${file}" ] || continue
    scanned=$((scanned + 1))

    patterns=("${HIGH_CONFIDENCE[@]}")
    # Aturan generik tidak berlaku untuk dokumentasi/template, yang memang menampilkan contoh.
    case "$file" in
      *.example|*.md|*test*|*spec*) ;;
      *) patterns+=("$GENERIC") ;;
    esac

    for pattern in "${patterns[@]}"; do
      matches="$(grep -nEI -- "$pattern" "${repo}/${file}" 2>/dev/null | head -3)"
      if [ -n "$matches" ]; then
        while IFS= read -r line; do
          line_no="${line%%:*}"
          # Nilai dipotong sebelum ditampilkan - jangan pernah cetak rahasianya ke log.
          masked="$(printf '%s' "$line" | sed -E 's/([A-Za-z0-9/+_-]{6})[A-Za-z0-9/+_-]{16,}/\1…(dipotong)/g' | cut -c1-160)"
          echo "⚠️  ${repo#$PROJECT_ROOT/}/${file}:${line_no} → ${masked#*:*:}"
          findings=$((findings + 1))
        done <<< "$matches"
      fi
    done
  done < <(git -C "$repo" ls-files)
done

echo
echo "=============================================================================="
if [ "$findings" -eq 0 ]; then
  echo "✅ Tidak ada kredensial terdeteksi di ${scanned} file yang dilacak git."
  exit 0
fi
echo "❌ ${findings} temuan di file yang dilacak git."
echo "   Pindahkan nilainya ke file .env (yang di-ignore), rotasi kredensialnya,"
echo "   lalu periksa riwayat git karena nilainya sudah ter-commit."
echo "   Panduan: docs/SECRET-ROTATION.md"
echo "=============================================================================="
exit 1

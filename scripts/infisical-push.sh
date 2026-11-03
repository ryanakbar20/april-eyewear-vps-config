#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - PUSH ENV KE INFISICAL
# Membaca file .env dan menyimpan tiap KEY=VALUE sebagai secret di satu folder
# Infisical. Tanda kutip pembungkus (single/double) dilepas agar nilai tersimpan
# bersih dan `infisical export` menghasilkan file .env yang benar.
#
# Cara pakai:
#   ./scripts/infisical-push.sh <env> <secretPath> <envFile>
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./infisical-lib.sh
. "${SCRIPT_DIR}/infisical-lib.sh"

ENV_NAME="${1:?usage: infisical-push.sh <env> <secretPath> <envFile>}"
SECRET_PATH="${2:?usage: infisical-push.sh <env> <secretPath> <envFile>}"
ENV_FILE="${3:?usage: infisical-push.sh <env> <secretPath> <envFile>}"

if [ ! -f "${ENV_FILE}" ]; then
  echo "❌ File tidak ditemukan: ${ENV_FILE}" >&2
  exit 1
fi

infisical_login
infisical_ensure_path "${ENV_NAME}" "${SECRET_PATH}"

args=()
skipped=0
while IFS= read -r line || [ -n "${line}" ]; do
  line="${line%$'\r'}"
  # Lewati baris kosong dan komentar.
  case "${line}" in
    '' | '#'*) continue ;;
  esac
  # Dukung bentuk "export KEY=VALUE".
  line="${line#export }"
  case "${line}" in
    *=*) ;;
    *) continue ;;
  esac

  key="${line%%=*}"
  val="${line#*=}"
  # Trim spasi di sekitar key.
  key="$(printf '%s' "${key}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "${key}" ] && continue

  # Lepas tanda kutip pembungkus (jika ada) tanpa memproses escape sequences,
  # supaya nilai bertipe literal (mis. FIREBASE_PRIVATE_KEY dengan \n) tetap utuh.
  if [ "${#val}" -ge 2 ]; then
    first="${val:0:1}"
    last="${val: -1}"
    if { [ "${first}" = '"' ] && [ "${last}" = '"' ]; } || { [ "${first}" = "'" ] && [ "${last}" = "'" ]; }; then
      val="${val:1:${#val}-2}"
    fi
  fi

  # Infisical menolak nilai kosong. Untuk dotenv/NestJS, key kosong == key tidak
  # ada, jadi nilai kosong cukup dilewati.
  if [ -z "${val}" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  args+=("${key}=${val}")
done < "${ENV_FILE}"

if [ "${#args[@]}" -eq 0 ]; then
  echo "ℹ️  Tidak ada secret untuk di-push dari ${ENV_FILE}."
  exit 0
fi

infisical secrets set "${args[@]}" \
  --projectId="${INFISICAL_PROJECT_ID}" \
  --env="${ENV_NAME}" \
  --path="${SECRET_PATH}" \
  --silent

echo "✅ Pushed ${#args[@]} secret → ${ENV_NAME}:${SECRET_PATH} (dari ${ENV_FILE}, dilewati: ${skipped:-0} kosong)"

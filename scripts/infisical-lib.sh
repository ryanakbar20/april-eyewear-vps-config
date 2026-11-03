#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - INFISICAL SHARED HELPERS
# Di-source oleh infisical-export.sh, infisical-push.sh, deploy.sh, dll.
# ==============================================================================

INFISICAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFISICAL_CONFIG_DIR="$(cd "${INFISICAL_LIB_DIR}/.." && pwd)"
INFISICAL_BOOTSTRAP="${INFISICAL_BOOTSTRAP:-${INFISICAL_CONFIG_DIR}/.infisical.env}"

if [ -f "${INFISICAL_BOOTSTRAP}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${INFISICAL_BOOTSTRAP}"
  set +a
else
  echo "❌ File bootstrap ${INFISICAL_BOOTSTRAP} tidak ditemukan." >&2
  echo "   Salin .infisical.env.example → .infisical.env dan isi kredensial machine identity." >&2
  exit 1
fi

: "${INFISICAL_HOST:=https://app.infisical.com}"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID belum diisi di .infisical.env}"
: "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID belum diisi di .infisical.env}"
: "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET belum diisi di .infisical.env}"
: "${INFISICAL_DEFAULT_ENV:=dev}"

if ! command -v infisical >/dev/null 2>&1; then
  echo "❌ Infisical CLI tidak ditemukan. Install dengan: npm install -g @infisical/cli" >&2
  exit 1
fi

# Login via machine identity (Universal Auth) dan export INFISICAL_TOKEN.
infisical_login() {
  if [ -n "${INFISICAL_TOKEN:-}" ]; then
    return 0
  fi
  INFISICAL_TOKEN="$(infisical login \
    --method=universal-auth \
    --client-id="${INFISICAL_CLIENT_ID}" \
    --client-secret="${INFISICAL_CLIENT_SECRET}" \
    --plain --silent 2>/dev/null)"
  if [ -z "${INFISICAL_TOKEN}" ]; then
    echo "❌ Gagal login ke Infisical (cek INFISICAL_CLIENT_ID/SECRET)." >&2
    exit 1
  fi
  export INFISICAL_TOKEN
}

# Pastikan folder bertingkat ada (mis. /local/website) pada environment tertentu.
# Membuat tiap level dari atas ke bawah; folder yang sudah ada diabaikan.
infisical_ensure_path() {
  local env_name="$1" secret_path="$2"
  local parent="/"
  local part
  local old_ifs="${IFS}"
  IFS='/'
  for part in ${secret_path#/}; do
    [ -z "${part}" ] && continue
    curl -s -o /dev/null -X POST "${INFISICAL_HOST}/api/v1/folders" \
      -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"workspaceId\":\"${INFISICAL_PROJECT_ID}\",\"environment\":\"${env_name}\",\"name\":\"${part}\",\"path\":\"${parent}\"}" || true
    if [ "${parent}" = "/" ]; then
      parent="/${part}"
    else
      parent="${parent}/${part}"
    fi
  done
  IFS="${old_ifs}"
}

# Tarik folder /infra untuk environment tertentu dan export ke proses sekarang.
# Dipakai semua skrip operasional (deploy, backup, restore, DNS, SSL, status, ...)
# sehingga nilai infra selalu berasal dari Infisical, bukan file lokal.
infisical_load_infra() {
  local env_name="${1:-${INFISICAL_DEFAULT_ENV}}"
  infisical_login
  local tmp_file
  tmp_file="$(mktemp)"
  if ! infisical export \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --env="${env_name}" \
    --path=/infra \
    --format=dotenv > "${tmp_file}" 2>/dev/null; then
    echo "❌ Gagal menarik /infra dari Infisical (env: ${env_name})." >&2
    rm -f "${tmp_file}"
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "${tmp_file}"
  set +a
  rm -f "${tmp_file}"
}

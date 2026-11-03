#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - RENDER ENV DARI INFISICAL
# Menarik secret dari satu folder Infisical dan menulisnya sebagai file .env.
#
# Cara pakai:
#   ./scripts/infisical-export.sh <env> <secretPath> [outputFile]
#
# Contoh:
#   ./scripts/infisical-export.sh dev /main-service /tmp/main.env
#   ./scripts/infisical-export.sh prod /infra            # cetak ke stdout
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./infisical-lib.sh
. "${SCRIPT_DIR}/infisical-lib.sh"

ENV_NAME="${1:?usage: infisical-export.sh <env> <secretPath> [outputFile]}"
SECRET_PATH="${2:-/}"
OUT_FILE="${3:-}"

infisical_login

if [ -n "${OUT_FILE}" ]; then
  mkdir -p "$(dirname "${OUT_FILE}")"
  infisical export \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --env="${ENV_NAME}" \
    --path="${SECRET_PATH}" \
    --format=dotenv > "${OUT_FILE}"
  echo "✅ Rendered ${ENV_NAME}:${SECRET_PATH} → ${OUT_FILE} ($(grep -c '=' "${OUT_FILE}" || true) var)"
else
  infisical export \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --env="${ENV_NAME}" \
    --path="${SECRET_PATH}" \
    --format=dotenv
fi

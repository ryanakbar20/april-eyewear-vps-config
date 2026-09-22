#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - CLOUDFLARE AUTO-DNS SYNC SCRIPT
# Memeriksa, membuat, atau memperbarui DNS A-Record di Cloudflare secara otomatis.
#
# Cara pakai:
#   ./scripts/sync-cloudflare-dns.sh prod
#   ./scripts/sync-cloudflare-dns.sh dev
#   ./scripts/sync-cloudflare-dns.sh <domain> <ip_address> [proxied:true|false]
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env
if [ -f "${CONFIG_DIR}/.env" ]; then
  export $(grep -v '^#' "${CONFIG_DIR}/.env" | xargs)
fi

TARGET_ARG=${1:-"dev"}

if [ "$TARGET_ARG" = "prod" ]; then
  DOMAIN="${PROD_API_DOMAIN:-api.aprileyewear.com}"
  TARGET_IP="${PROD_VPS_IP}"
  PROXIED="true"
elif [ "$TARGET_ARG" = "dev" ]; then
  DOMAIN="${DEV_API_DOMAIN:-dev-api.aprileyewear.com}"
  TARGET_IP="${DEV_VPS_IP}"
  PROXIED="true"
else
  DOMAIN="$1"
  TARGET_IP="$2"
  PROXIED="${3:-true}"
fi

CF_TOKEN="${CLOUDFLARE_API_TOKEN:-$CF_API_TOKEN}"
CF_ZONE_ID="${CLOUDFLARE_ZONE_ID:-$CF_ZONE_ID}"

if [ -z "$CF_TOKEN" ]; then
  echo "⚠️  CLOUDFLARE_API_TOKEN belum diatur di .env! Melewati sinkronisasi DNS otomatis."
  exit 0
fi

if [ -z "$TARGET_IP" ]; then
  echo "❌ Target IP untuk domain ${DOMAIN} belum ditentukan!"
  exit 1
fi

echo "🔍 Memeriksa status DNS Cloudflare untuk: ${DOMAIN} -> ${TARGET_IP} (Proxied: ${PROXIED})..."

# 1. Dapatkan Zone ID jika belum diatur secara eksplisit
if [ -z "$CF_ZONE_ID" ]; then
  # Ekstrak root domain (misal: api.aprileyewear.com -> aprileyewear.com)
  ROOT_DOMAIN=$(echo "$DOMAIN" | awk -F. '{if (NF>2) print $(NF-1)"."$NF; else print $0}')
  
  ZONE_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")

  CF_ZONE_ID=$(python3 -c "
import sys, json
try:
    data = json.loads('''$ZONE_RESP''')
    zones = data.get('result', [])
    if zones:
        print(zones[0]['id'])
    else:
        print('')
except Exception:
    print('')
")

  if [ -z "$CF_ZONE_ID" ]; then
    echo "❌ Gagal mendeteksi Zone ID untuk domain root ${ROOT_DOMAIN}. Pastikan CLOUDFLARE_API_TOKEN memiliki izin 'Zone.Zone:Read' dan 'Zone.DNS:Edit'."
    exit 1
  fi
fi

# 2. Cek apakah DNS A-Record untuk DOMAIN sudah ada
RECORDS_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json")

PARSED_RESULT=$(python3 -c "
import sys, json
try:
    data = json.loads('''$RECORDS_RESP''')
    records = data.get('result', [])
    if records:
        rec = records[0]
        print(f\"{rec['id']}|{rec['content']}|{str(rec.get('proxied', False)).lower()}\")
    else:
        print('NOT_FOUND')
except Exception as e:
    print('ERROR')
")

if [ "$PARSED_RESULT" = "NOT_FOUND" ]; then
  # 3. Buat A-Record baru karena belum ada
  echo "➕ DNS Record ${DOMAIN} belum ditemukan di Cloudflare. Membuat A-Record baru..."
  CREATE_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\": \"A\",
      \"name\": \"${DOMAIN}\",
      \"content\": \"${TARGET_IP}\",
      \"ttl\": 1,
      \"proxied\": ${PROXIED}
    }")

  SUCCESS=$(python3 -c "import json; res=json.loads('''$CREATE_RESP'''); print(res.get('success', False))")
  if [ "$SUCCESS" = "True" ]; then
    echo "✅ Berhasil membuat DNS A-Record: ${DOMAIN} -> ${TARGET_IP} (Cloudflare Proxy Active)"
  else
    echo "❌ Gagal membuat DNS Record di Cloudflare! Response: $CREATE_RESP"
    exit 1
  fi

elif [ "$PARSED_RESULT" = "ERROR" ]; then
  echo "❌ Terjadi error saat membaca response dari Cloudflare API."
  exit 1

else
  # 4. Record sudah ada, periksa apakah IP dan status proxy sudah sesuai
  RECORD_ID=$(echo "$PARSED_RESULT" | cut -d'|' -f1)
  CURRENT_IP=$(echo "$PARSED_RESULT" | cut -d'|' -f2)
  CURRENT_PROXIED=$(echo "$PARSED_RESULT" | cut -d'|' -f3)

  if [ "$CURRENT_IP" = "$TARGET_IP" ] && [ "$CURRENT_PROXIED" = "$PROXIED" ]; then
    echo "✅ DNS A-Record ${DOMAIN} sudah sinkron dengan IP VPS (${TARGET_IP}). Tidak ada perubahan yang diperlukan."
  else
    echo "🔄 IP DNS di Cloudflare (${CURRENT_IP}) berbeda dengan IP VPS (${TARGET_IP}). Memperbarui record..."
    UPDATE_RESP=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${RECORD_ID}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{
        \"type\": \"A\",
        \"name\": \"${DOMAIN}\",
        \"content\": \"${TARGET_IP}\",
        \"ttl\": 1,
        \"proxied\": ${PROXIED}
      }")

    SUCCESS=$(python3 -c "import json; res=json.loads('''$UPDATE_RESP'''); print(res.get('success', False))")
    if [ "$SUCCESS" = "True" ]; then
      echo "✅ Berhasil memperbarui DNS Record: ${DOMAIN} -> ${TARGET_IP} (Cloudflare Proxy Active)"
    else
      echo "❌ Gagal memperbarui DNS Record di Cloudflare! Response: $UPDATE_RESP"
      exit 1
    fi
  fi
fi

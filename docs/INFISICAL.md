# 🔐 Infisical — Sumber Tunggal Env April Eyewear

Sejak migrasi ini, **semua env (local, VPS dev, VPS prod) diambil dari Infisical**.
File `.env` di repo hanya cache/seed, bukan sumber kebenaran.

- **Project:** April Eyewear (`5a7ac71c-3bb3-47d3-b86b-04563dfd08d6`)
- **Environments:** `dev`, `prod` (`staging` tidak dipakai)
- **Host:** `https://app.infisical.com`

---

## 1. Struktur Folder di Infisical

Nilai local dan VPS sengaja dipisah karena berbeda (DB host, port, domain).

| Folder | Environment | Dipakai oleh | Isi |
| :--- | :--- | :--- | :--- |
| `/local/main-service` | dev | `start-services.sh` (lokal) | env localhost main-service |
| `/local/shipment-service` | dev | `start-services.sh` (lokal) | env localhost shipment-service |
| `/local/website` | dev | `start-services.sh` (lokal) | env localhost website |
| `/local/smartfit-kiosk` | dev | `start-services.sh` (lokal) | env localhost kiosk |
| `/main-service` | dev | `deploy.sh dev` | env VPS Dev (main) |
| `/shipment-service` | dev | `deploy.sh dev` | env VPS Dev (shipment) |
| `/website` | dev | build/preview frontend | `VITE_API_BASE_URL` → dev-api |
| `/smartfit-kiosk` | dev | build/preview kiosk | `VITE_API_BASE_URL` → dev-api |
| `/infra` | dev & prod | semua skrip operasional | R2, Cloudflare, GitHub, VPS, DB, alerting |
| `/main-service` | prod | `deploy.sh prod` | env VPS Prod (main) |
| `/shipment-service` | prod | `deploy.sh prod` | env VPS Prod (shipment) |
| `/website` | prod | build produksi | `VITE_API_BASE_URL` → api |
| `/smartfit-kiosk` | prod | build produksi | `VITE_API_BASE_URL` → api |
| `/infra` | prod | `deploy.sh prod` | sama dengan dev `/infra` |

> Nilai **kosong** (`KEY=`) tidak disimpan di Infisical; Infisical menolaknya.
> Untuk dotenv/NestJS, key kosong = key tidak ada, jadi perilakunya sama.

---

## 2. Bootstrap (Kredensial Machine Identity)

Satu-satunya kredensial yang wajib ada di mesin lokal:

```bash
cp .infisical.env.example .infisical.env
# isi INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET (Universal Auth, machine identity)
```

`.infisical.env` **di-ignore git** (`*.env`). Ambil nilainya di
*Infisical → Project → Access → Machine Identities → Universal Auth*.

Prasyarat CLI:

```bash
npm install -g @infisical/cli
```

---

## 3. Skrip

| Perintah | Fungsi |
| :--- | :--- |
| `./scripts/infisical-push.sh <env> <path> <file>` | Push satu file `.env` ke satu folder Infisical |
| `./scripts/infisical-export.sh <env> <path> [out]` | Render folder Infisical → file/stdout (format dotenv) |

Contoh:

```bash
./scripts/infisical-export.sh dev /main-service /tmp/main.env
./scripts/infisical-export.sh prod /infra            # cetak ke stdout
./scripts/infisical-push.sh dev /main-service /path/ke/main.env
```

---

## 4. Cara Local Mengambil Env

`start-services.sh` menarik `/local/<service>` dari Infisical dan menuliskannya ke
`.env` masing-masing service **sebelum** proses dijalankan:

```bash
./start-services.sh              # render otomatis dari Infisical
SKIP_INFISICAL=1 ./start-services.sh   # pakai .env lokal apa adanya
INFISICAL_ENV=dev ./start-services.sh  # ganti environment sumber
```

---

## 5. Cara Deploy (VPS Dev/Prod) Mengambil Env

`scripts/deploy.sh <env>`:

1. Login ke Infisical pakai `.infisical.env`.
2. `infisical_load_infra <env>` → export `/infra` (R2, Cloudflare, VPS IP, DB, webhook).
3. Render `<env>:/main-service` & `<env>:/shipment-service` → `scp` ke `.env` di VPS.
4. Build, rsync, `prisma migrate deploy`, reload PM2.

VPS **tidak** butuh Infisical CLI maupun kredensial — `.env` dikirim dari mesin deployer.
Skrip operasional lain (backup, restore, DNS, SSL, status) juga memuat `/infra` dari
Infisical melalui helper `infisical_load_infra` di `scripts/infisical-lib.sh`.

---

## 6. Menambah / Mengubah Secret

Cara disarankan: ubah langsung di **Infisical UI**, lalu:

```bash
# local
./scripts/infisical-export.sh dev /local/main-service ../april-eyewear-main-service/.env
# atau jalankan ulang ./start-services.sh

# VPS dev/prod
./scripts/deploy.sh dev      # atau prod
```

Butuh menambah/mengganti banyak nilai sekaligus? Cukup:

```bash
./scripts/infisical-push.sh dev /main-service /path/ke/file.env   # per folder
```

Tidak ada lagi file seed `.env` di repo infra — konfigurasi tiap environment
sepenuhnya hidup di Infisical.

---

## 7. Catatan Penting

- **IP Restriction aktif** pada machine identity. Artinya hanya IP yang
  di-*whitelist* (mesin lokal/deployer) yang bisa menarik secret. Karena itu env
  dirender di **mesin deployer** lalu dikirim ke VPS — VPS tidak pernah memanggil
  Infisical langsung.
- **CI/CD GitHub Actions:** workflow yang ada meng-`rsync` artefak build dan
  **tidak** mengunggah `.env`, sehingga env yang sudah ter-deploy (dari `deploy.sh`)
  tetap dipakai. Bila ingin CI menarik langsung dari Infisical, IP runner GitHub
  harus di-*whitelist* (atau IP restriction dimatikan) dan secret
  `INFISICAL_CLIENT_ID/SECRET/PROJECT_ID` didaftarkan di repo masing-masing.
- **Jangan commit** `.infisical.env` maupun `dev/*.env`, `prod/*.env` —
  semuanya sudah di-ignore git. Verifikasi dengan `./scripts/scan-secrets.sh`.

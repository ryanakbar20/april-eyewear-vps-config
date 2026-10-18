# 🕶️ April Eyewear - VPS Infrastructure & Deployment Guide

Repositori ini berisi seluruh konfigurasi infrastruktur, skrip otomasi *provisioning*, manajemen DNS Cloudflare, backup Cloudflare R2, dan alur *deployment zero-downtime* untuk backend **April Eyewear**:
- **Main Service (API Utama & CMS):** [april-eyewear-main-service](https://github.com/ryanakbar20/april-eyewear-main-service.git) *(Port 3000)*
- **Shipment Service (Biteship Integration):** [april-eyewear-shipment-service](https://github.com/ryanakbar20/april-eyewear-shipment-service.git) *(Port 3002)*

---

## 📑 Daftar Isi
1. [Spesifikasi Arsitektur Server](#1-spesifikasi-arsitektur-server)
2. [Prasyarat Sebelum Deploy](#2-prasyarat-sebelum-deploy)
3. [Langkah 1: Menyiapkan File Kredensial (.env)](#langkah-1-menyiapkan-file-kredensial-env)
4. [Langkah 2: Setup VPS Baru (Initial Provisioning)](#langkah-2-setup-vps-baru-initial-provisioning)
5. [Langkah 3: Konfigurasi Awal Database PostgreSQL](#langkah-3-konfigurasi-awal-database-postgresql)
6. [Langkah 4: Deploy Aplikasi ke VPS (1-Click Deploy)](#langkah-4-deploy-aplikasi-ke-vps-1-click-deploy)
7. [Langkah 5: Konfigurasi SSL / HTTPS](#langkah-5-konfigurasi-ssl--https)
8. [Langkah 6: Memastikan Auto-Start Saat Server Reboot](#langkah-6-memastikan-auto-start-saat-server-reboot)
9. [Langkah 7: Otomatisasi Backup Database ke Cloudflare R2](#langkah-7-otomatisasi-backup-database-ke-cloudflare-r2)
10. [Langkah 8: Setup CI/CD Otomatis via GitHub Actions](#langkah-8-setup-cicd-otomatis-via-github-actions)
11. [Langkah 9: Migrasi Database & Versi Node](#langkah-9-migrasi-database--versi-node)
12. [Cheat-Sheet Perintah Operasional Sehari-hari](#cheat-sheet-perintah-operasional-sehari-hari)

---

## 1. Spesifikasi Arsitektur Server

| Lingkungan | Spesifikasi VPS | Mode PM2 | Alokasi RAM per App | Swap Memory | Target Domain |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Production** | 4 vCPU / 4GB RAM | Cluster (`instances: "max"`) | Main: 768MB / Ship: 512MB | **4 GB** | `api.aprileyewear.com` |
| **Development** | 1 vCPU / 1GB RAM | Fork (`instances: 1`) | Main: 256MB / Ship: 180MB | **3 GB** *(Wajib)* | `dev-api.aprileyewear.com` |

> 📘 **Panduan Lengkap Arsitektur:**
> - [Panduan Detail Production (prod/INFRA.MD)](prod/INFRA.MD)
> - [Panduan Detail Development 1GB RAM (dev/INFRA.MD)](dev/INFRA.MD)
> - [Rencana Pemulihan Bencana (RECOVERY_PLAN.MD)](RECOVERY_PLAN.MD)

---

## 2. Prasyarat Sebelum Deploy

Sebelum memulai, pastikan Anda memiliki:
1. **Akses SSH ke VPS** (Ubuntu 22.04 LTS atau 24.04 LTS) dengan akses `sudo`/`root`.
2. **Domain Aktif di Cloudflare** (e.g., `aprileyewear.com`).
3. **Cloudflare API Token** (dengan izin: `Zone.DNS:Edit` & `Zone.Zone:Read`).
4. **Cloudflare R2 Bucket & API Credentials** (untuk cadangan database dan aset media).

---

## Langkah 1: Menyiapkan File Kredensial (`.env`)

Di komputer lokal Anda, salin template `.env.example` menjadi `.env`:

```bash
cd april-eyewear-vps-config
cp .env.example .env
```

Buka `.env` dan lengkapi variabel berikut:
```ini
# 1. Cloudflare R2 (Backup Database)
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_ACCESS_KEY_ID=your_r2_access_key_id
R2_SECRET_ACCESS_KEY=your_r2_secret_access_key
R2_BUCKET_BACKUP=april-eyewear-backups
R2_S3_ENDPOINT=https://your_cloudflare_account_id.r2.cloudflarestorage.com

# 2. Cloudflare DNS Automation
CLOUDFLARE_API_TOKEN=your_cloudflare_dns_token

# 3. Target VPS Production
PROD_VPS_IP=103.xxx.xxx.xxx
PROD_VPS_USER=ubuntu
PROD_VPS_SSH_KEY_PATH=~/.ssh/id_rsa
PROD_DB_PASSWORD=PasswordDatabaseKuat123!

# 4. Target VPS Development
DEV_VPS_IP=103.150.117.15
DEV_VPS_USER=ubuntu
DEV_VPS_SSH_KEY_PATH=./scripts/id_rsa.pem
DEV_DB_PASSWORD=PasswordDatabaseDev123!
```

### Menyiapkan Environment Service (Main & Shipment) untuk Dev & Prod
Setiap service (`main-service` dan `shipment-service`) memiliki variabel kredensial yang berbeda antara **Dev** dan **Prod** (seperti database URL, payment gateway sandbox vs production, biteship API key, dan URL callback).

File konfigurasi disimpan di dalam folder masing-masing lingkungan:

```bash
# 1. Konfigurasi Lingkungan Development (Otomatis dipakai saat ./scripts/deploy.sh dev)
dev/
├── main.env                 # Kredensial aktif Main Service Dev (Auto-deploy ke VPS Dev)
├── main.env.example         # Template acuan variabel Main Service Dev
├── shipment.env             # Kredensial aktif Shipment Service Dev (Auto-deploy ke VPS Dev)
└── shipment.env.example     # Template acuan variabel Shipment Service Dev

# 2. Konfigurasi Lingkungan Production (Otomatis dipakai saat ./scripts/deploy.sh prod)
prod/
├── main.env                 # Salin dari main.env.example dan isi kredensial live produksi
├── main.env.example         # Template acuan variabel Main Service Prod
├── shipment.env             # Salin dari shipment.env.example dan isi kredensial live produksi
└── shipment.env.example     # Template acuan variabel Shipment Service Prod
```

> 🔒 **Keamanan:** File `*.env` di dalam folder `dev/` dan `prod/` sudah otomatis diabaikan oleh `.gitignore` sehingga aman dan tidak akan ter-commit ke GitHub.


---

## Langkah 2: Setup VPS Baru (Initial Provisioning)

Jalankan perintah ini **sekali saja** di VPS baru untuk memasang seluruh kebutuhan sistem:

1. Login via SSH ke VPS (menggunakan file `.pem` jika otentikasi key diaktifkan):
   ```bash
   ssh -i scripts/id_rsa.pem ubuntu@103.150.117.15
   ```

2. Jalankan skrip setup otomatis:
   ```bash
   # Untuk VPS Production:
   curl -fsSL https://raw.githubusercontent.com/ryanakbar20/april-eyewear-vps-config/main/scripts/setup-vps.sh | sudo bash -s prod

   # ATAU untuk VPS Development (1GB RAM):
   curl -fsSL https://raw.githubusercontent.com/ryanakbar20/april-eyewear-vps-config/main/scripts/setup-vps.sh | sudo bash -s dev
   ```

Skrip ini akan secara otomatis:
- Mengupdate paket sistem Ubuntu.
- Membuat dan mengaktifkan **Swap Memory** (4GB untuk Prod, 3GB untuk Dev).
- Menginstall **Node.js 20 LTS**, **PM2** (beserta `pm2-logrotate`), **PostgreSQL 16**, dan **Nginx**.
- Mengaktifkan firewall **UFW** (hanya membuka port SSH 22, HTTP 80, HTTPS 443).

---

## Langkah 3: Konfigurasi Awal Database PostgreSQL

Di dalam VPS, atur password user `postgres` dan buat database:

```bash
# 1. Masuk ke console PostgreSQL
sudo -u postgres psql

# 2. Set password postgres (sesuaikan dengan nilai di .env)
ALTER USER postgres PASSWORD 'PasswordDatabaseKuat123!';

# 3. Buat database
# Untuk Production:
CREATE DATABASE april_eyewear_db;

# ATAU untuk Dev:
CREATE DATABASE april_dev_db;

# 4. Keluar
\q
```

---

## Langkah 4: Deploy Aplikasi ke VPS (1-Click Deploy)

Kembali ke terminal komputer lokal Anda (di folder `april-eyewear-vps-config`):

```bash
# Deploy ke VPS Development:
./scripts/deploy.sh dev

# Deploy ke VPS Production:
./scripts/deploy.sh prod
```

### Apa yang Dilakukan oleh `deploy.sh` Secara Otomatis?
1. **🌐 Cloudflare DNS Auto-Sync:** Memeriksa dan otomatis membuat/mengupdate A-Record DNS di Cloudflare agar mengarah ke IP VPS target.
2. **🔨 Local Build:** Mengompilasi `april-eyewear-main-service` dan `april-eyewear-shipment-service` di komputer lokal (menghindarkan VPS 1GB RAM dari crash *Out Of Memory*).
3. **📤 Rsync Artifacts:** Mengirimkan folder `dist/`, `package.json`, dan skema `prisma/` via SSH.
4. **📦 Remote Install:** Menginstal dependensi produksi saja (`--omit=dev`).
5. **🗄️ Prisma Migrate:** Menjalankan migrasi database PostgreSQL (`npx prisma migrate deploy`).
6. **⚡ PM2 Zero-Downtime Reload:** Me-reload proses tanpa memutus koneksi pengguna aktif.
7. **📢 Notifikasi:** Mengirim kabar sukses/gagal ke Discord atau Telegram Webhook Anda.

---

## Langkah 5: Konfigurasi SSL / HTTPS

Agar API dapat diakses dengan aman melalui protokol `https://`:

### Opsi A: Let's Encrypt (Gratis & Otomatis)
```bash
# Jalankan dari komputer lokal Anda:
./scripts/setup-ssl.sh prod letsencrypt admin@aprileyewear.com
# atau
./scripts/setup-ssl.sh dev letsencrypt admin@aprileyewear.com
```

### Opsi B: Cloudflare Origin Certificate (Disarankan, Masa Berlaku 15 Tahun)
Jika domain Anda diproxy via Cloudflare:
```bash
./scripts/setup-ssl.sh prod cloudflare /path/to/origin-cert.pem /path/to/origin-key.key
```

---

## Langkah 6: Memastikan Auto-Start Saat Server Reboot

Agar seluruh service otomatis bangkit kembali saat VPS di-restart:

1. Di dalam terminal VPS Anda:
   ```bash
   # 1. Simpan daftar proses PM2 aktif
   pm2 save

   # 2. Daftarkan PM2 ke systemd startup
   pm2 startup systemd
   # (Salin dan eksekusi baris perintah 'sudo env PATH=...' yang dimunculkan oleh PM2)

   # 3. Pastikan PostgreSQL dan Nginx aktif saat boot
   sudo systemctl enable postgresql
   sudo systemctl enable nginx
   ```

2. **Uji Coba Simulasi Reboot:**
   ```bash
   sudo reboot
   ```
   Tunggu 1 menit, login kembali, dan cek status:
   ```bash
   pm2 status                          # Harus 'online'
   sudo systemctl status postgresql    # Harus 'active (running)'
   sudo systemctl status nginx         # Harus 'active (running)'
   free -h                             # Swap harus tetap aktif
   ```

---

## Langkah 7: Otomatisasi Backup Database ke Cloudflare R2

Backup berjalan **di dalam VPS** lewat cron, bukan dari laptop operator — script yang bergantung pada
laptop yang menyala bukan backup.

**Kondisi terpasang saat ini (dev):**

| Komponen | Lokasi |
| :--- | :--- |
| Script backup | `/home/ubuntu/bin/db-backup.sh` (sumber: `scripts/server-backup-db.sh`) |
| Jadwal | `crontab -l` → `0 3 * * * ... >> /home/ubuntu/logs/db-backup.log 2>&1` (03:00 WIB) |
| Tujuan | `r2:april-eyewear-backups/database/`, retensi 14 hari; 3 file terbaru disimpan lokal di `/tmp/backups` |
| Kredensial rclone | `~/.config/rclone/rclone.conf` (chmod 600) |
| Webhook alert | `~/.config/april/notify.env` (chmod 600) — dikirim ke Discord kalau backup **GAGAL** |

Script mendeteksi database secara otomatis dari `DATABASE_URL` tiap service yang ter-deploy, jadi
satu script yang sama dipakai di dev dan prod tanpa menulis nama database di dalam kode.

**Pemasangan di VPS baru:**
```bash
scp -i <key> scripts/server-backup-db.sh ubuntu@<ip>:/home/ubuntu/bin/db-backup.sh
ssh -i <key> ubuntu@<ip> 'chmod +x ~/bin/db-backup.sh; mkdir -p ~/logs ~/.config/april'
# daftarkan remote rclone 'r2' (variabel R2_* ada di .env repo ini)
ssh -i <key> ubuntu@<ip> "(crontab -l 2>/dev/null; echo '0 3 * * * /home/ubuntu/bin/db-backup.sh >> /home/ubuntu/logs/db-backup.log 2>&1') | crontab -"
```

**Backup manual** (dari laptop, menjalankan script server yang sama):
```bash
./scripts/backup-r2.sh dev
```

**Membuktikan backup bisa dipulihkan** — jalankan berkala. Backup yang belum pernah di-restore belum
bisa disebut backup:
```bash
ssh -i <key> ubuntu@<ip> '/home/ubuntu/bin/verify-restore.sh april_dev_db'
```
Script ini me-restore snapshot terbaru dari R2 ke database sementara, membandingkan jumlah tabel dan
jumlah baris tabel utama dengan database aslinya, lalu **selalu menghapus** database sementara itu.

**Pemulihan bencana penuh** (menimpa database, minta konfirmasi `YA`):
```bash
./scripts/restore-db.sh dev latest
```
Snapshot diambil dari R2, bukan dari `/tmp` server, sehingga tetap bisa dipakai di VPS yang baru.

---

## Langkah 8: Setup CI/CD Otomatis via GitHub Actions

Jika Anda ingin rilis otomatis terjadi setiap kali Anda melakukan `git push` atau merge pull request:

1. Buka repositori GitHub Anda:
   - `april-eyewear-main-service` > **Settings** > **Secrets and variables** > **Actions**.
2. Daftarkan **Repository Secrets** berikut:
   - `PROD_VPS_IP`: Alamat IP VPS Production.
   - `PROD_SSH_KEY`: Private SSH Key komputer/deployer Anda (isi dari `~/.ssh/id_rsa`).
   - `PROD_VPS_USER`: `ubuntu` (atau user SSH Anda).
   - `PROD_SSH_PORT`: `22`.
   - `DISCORD_WEBHOOK_URL`: (Opsional) URL webhook Discord untuk notifikasi.
3. Salin file template workflow ke repositori service Anda:
   ```bash
   cp .github/workflows/deploy-prod.yml ../april-eyewear-main-service/.github/workflows/
   cp .github/workflows/deploy-prod.yml ../april-eyewear-shipment-service/.github/workflows/
   ```
4. Setiap push ke branch `main` akan otomatis di-*build* dan di-*deploy* ke VPS Production!

---

## Langkah 9: Migrasi Database & Versi Node

### Migrasi database (berversi)
Deploy memakai `prisma migrate deploy` dengan riwayat di `prisma/migrations`. Sebelumnya memakai
`prisma db push --accept-data-loss`, yang bisa menghapus kolom/tabel tanpa peringatan dan tidak punya
jalan kembali.

**Membuat migrasi baru** setelah mengubah `schema.prisma`:
```bash
cd april-eyewear-main-service
npx prisma migrate dev --name nama_perubahan    # di lokal, menghasilkan file migrasi
```
Deploy berikutnya (`./scripts/deploy.sh dev|prod`) akan menerapkannya di server.

**Database yang sudah berisi data tapi belum punya tabel `_prisma_migrations`** (schema lama hasil
`db push`) perlu di-baseline sekali saja:
```bash
./scripts/baseline-migrations.sh dev     # atau prod
```
Database kosong tidak perlu langkah ini — `migrate deploy` membuat semuanya dari nol.

Cek status kapan saja:
```bash
ssh -i <key> ubuntu@<ip> 'cd /var/www/april-eyewear-dev/april-eyewear-main-service && npx prisma migrate status'
```

### Versi Node
API memakai paket yang mensyaratkan **Node >= 22** (`firebase-admin`, `@google-cloud/storage`).
Server dev sudah memakai Node 22 (`node -v` → v22.x). Kalau versi Node turun ke 20, unggah media dan
push notification akan gagal walau build tetap lolos (dulu hanya muncul peringatan `EBADENGINE`).

Setelah mengubah versi Node, `node_modules` wajib dibangun ulang — `bcrypt` adalah native module dan
binary-nya terikat ke ABI Node:
```bash
rm -rf node_modules && npm install --omit=dev
```
Verifikasi cepat bahwa native module sehat: `node -e "require('bcrypt').hash('uji',10).then(h=>console.log(h.length))"`.

---

## Cheat-Sheet Perintah Operasional Sehari-hari

Jalankan perintah ini langsung dari terminal lokal Anda di folder `april-eyewear-vps-config`:

| Kebutuhan | Perintah | Penjelasan |
| :--- | :--- | :--- |
| **Cek Status Server** | `./scripts/server-status.sh prod` | Menampilkan uptime, RAM, Swap, CPU, status PM2, dan port aktif. |
| **Cek Status Dev** | `./scripts/server-status.sh dev` | Memantau konsumsi RAM pada server 1GB. |
| **Deploy Production** | `./scripts/deploy.sh prod` | Build lokal & deploy zero-downtime ke Prod. |
| **Deploy Development** | `./scripts/deploy.sh dev` | Build lokal & deploy mode fork ke Dev. |
| **Cek Healthcheck API** | `curl -s https://api.aprileyewear.com/api/v1/health` | Menampilkan latency database dan status memori backend. |
| **Backup DB ke R2** | `./scripts/backup-r2.sh prod` | Dump PostgreSQL & push ke Cloudflare R2. |
| **Uji Backup Bisa Di-restore** | `./scripts/server-verify-restore.sh` *(di VPS)* | Restore snapshot terbaru ke DB sementara, bandingkan jumlah tabel & baris, lalu hapus DB sementara. |
| **Baseline Migrasi (sekali saja)** | `./scripts/baseline-migrations.sh dev` | Menandai `0_init` sebagai sudah diterapkan pada DB lama hasil `db push`. |
| **Status Migrasi** | `ssh ... 'npx prisma migrate status'` | Memastikan tidak ada migrasi tertunda / drift. |
| **Restore Database** | `./scripts/restore-db.sh prod latest` | Mengembalikan database dari snapshot R2 terbaru. |
| **Sinkronisasi DNS** | `./scripts/sync-cloudflare-dns.sh prod` | Cek dan sinkronkan A-Record domain ke IP VPS di Cloudflare. |
| **Kirim Notifikasi** | `./scripts/notify.sh info "Judul" "Pesan"` | Mengirim broadcast manual ke Discord & Telegram. |

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
11. [Cheat-Sheet Perintah Operasional Sehari-hari](#cheat-sheet-perintah-operasional-sehari-hari)

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

Untuk mencadangkan database secara otomatis setiap hari pukul 02:00 dini hari ke Cloudflare R2:

1. Di dalam VPS Anda, buka crontab:
   ```bash
   crontab -e
   ```

2. Tambahkan baris jadwal berikut:
   ```cron
   0 2 * * * /bin/bash /var/www/april-eyewear/scripts/backup-r2.sh prod >> /var/log/backup.log 2>&1
   ```

3. **Uji Coba Backup Manual:**
   Anda dapat memicu backup kapan saja dari komputer lokal:
   ```bash
   ./scripts/backup-r2.sh prod
   ```

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
| **Restore Database** | `./scripts/restore-db.sh prod latest` | Mengembalikan database dari snapshot R2 terbaru. |
| **Sinkronisasi DNS** | `./scripts/sync-cloudflare-dns.sh prod` | Cek dan sinkronkan A-Record domain ke IP VPS di Cloudflare. |
| **Kirim Notifikasi** | `./scripts/notify.sh info "Judul" "Pesan"` | Mengirim broadcast manual ke Discord & Telegram. |

# Infrastructure Guide: Development VPS Architecture (April Eyewear)

Panduan arsitektur dan konfigurasi infrastruktur VPS **Development / Staging** untuk April Eyewear dengan spesifikasi minimalis hemat biaya: **1 vCPU / 1GB RAM**. Dirancang dengan alokasi memori ketat (*micro-footprint*), optimasi V8 heap, tuning PostgreSQL *low-memory*, dan proteksi swap wajib agar server tetap stabil tanpa terkena OOM (*Out Of Memory*).

---

## 1. Tantangan & Filosofi Arsitektur (1 vCPU / 1GB RAM)

Kapasitas **1GB RAM (1024 MB)** dan **1 Core CPU** sangat terbatas jika harus menjalankan OS, Database PostgreSQL, Nginx, dan 2 microservice NestJS sekaligus.

### Aturan Emas (Golden Rules) Dev VPS:
1. **Dilarang Menjalankan Build di VPS:**
   - Perintah seperti `nest build`, `tsc`, atau `npm install` (lengkap dengan devDependencies) memakan memori 800MB–1.5GB dan **pasti akan di-kill oleh kernel Linux (Error 137 / OOM)** atau membuat sesi SSH terputus (*freeze*).
   - Seluruh build harus dilakukan di **GitHub Actions** atau mesin lokal developer, lalu hanya folder `dist/` dan `package.json` yang dikirim ke VPS via `rsync`.
2. **PM2 Mode Fork (Single Instance):**
   - **Jangan gunakan cluster mode!** Setiap instance cluster membutuhkan runtime V8 tersendiri. Gunakan `instances: 1` dan `exec_mode: "fork"`.
3. **Pembatasan V8 Heap Memory:**
   - Tambahkan flag `--max-old-space-size` pada Node.js agar Garbage Collector bekerja agresif sebelum RAM habis.
4. **Swap Memory 3GB Wajib Aktif:**
   - Swap bertindak sebagai bantalan virtual (*safety cushion*) saat terjadi lonjakan query database atau proses migrasi.

---

## 2. Resource Budgeting (1GB RAM)

| Komponen | Alokasi RAM Fisik | Batas Maksimal RAM | Keterangan |
| :--- | :--- | :--- | :--- |
| **OS Ubuntu Minimal** | ~120 MB | ~150 MB | Systemd, SSH daemon, kernel |
| **Nginx Web Server** | ~30 MB | ~50 MB | 1 worker process, reverse proxy |
| **PostgreSQL 16 (Tuned Low-RAM)** | ~160 MB | ~200 MB | Buffer & cache disesuaikan (shared_buffers 128MB) |
| **PM2 Daemon** | ~40 MB | ~50 MB | Process manager master process |
| **NestJS Main Service** | ~240 MB | ~280 MB | Flag: `--max-old-space-size=256` |
| **NestJS Shipment Service** | ~170 MB | ~200 MB | Flag: `--max-old-space-size=180` |
| **Buffer RAM Bebas** | ~240 MB | - | Ruang bernapas RAM fisik |
| **Total Penggunaan RAM** | **~760 MB / 1024 MB** | **Aman (< 80%)** | Sisanya masuk ke buffer/cache Linux |
| **SWAP Memory (NVMe/SSD)** | **3.0 GB** | **Wajib Aktif** | Mencegah hard crash saat migrasi Prisma |

### Tautan Repositori Layanan:
- **Main Service:** [https://github.com/ryanakbar20/april-eyewear-main-service.git](https://github.com/ryanakbar20/april-eyewear-main-service.git)
- **Shipment Service:** [https://github.com/ryanakbar20/april-eyewear-shipment-service.git](https://github.com/ryanakbar20/april-eyewear-shipment-service.git)

---

## 3. Konfigurasi Swap Memory 3GB (Langkah Wajib Pertama)

Jalankan perintah ini segera setelah VPS baru dibuat:

```bash
# 1. Alokasikan 3GB swap file
sudo fallocate -l 3G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 2. Jadikan permanen setelah reboot
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 3. Setting swappiness untuk 1GB RAM (agresif memanfaatkan swap)
sudo sysctl vm.swappiness=30
sudo sysctl vm.vfs_cache_pressure=50
echo 'vm.swappiness=30' | sudo tee -a /etc/sysctl.conf
echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.conf

# 4. Verifikasi
free -h
```

---

## 4. Konfigurasi PM2 Mode Fork (`ecosystem.dev.config.js`)

Simpan file ini di `/var/www/april-eyewear-dev/ecosystem.dev.config.js`:

```javascript
// /var/www/april-eyewear-dev/ecosystem.dev.config.js
module.exports = {
  apps: [
    {
      name: 'april-main-dev',
      cwd: '/var/www/april-eyewear-dev/april-eyewear-main-service',
      script: 'dist/src/main.js',
      instances: 1,           // Wajib 1 instance untuk 1 vCPU
      exec_mode: 'fork',      // Mode fork hemat memori
      max_memory_restart: '300M', // Auto restart jika menyentuh 300MB
      node_args: '--max-old-space-size=256', // Batasi heap Node.js ke 256MB
      env: {
        NODE_ENV: 'development',
        PORT: 3000,
      },
      error_file: '/var/log/pm2/april-main-dev-error.log',
      out_file: '/var/log/pm2/april-main-dev-out.log',
      merge_logs: true,
      time: true,
    },
    {
      name: 'april-shipment-dev',
      cwd: '/var/www/april-eyewear-dev/april-eyewear-shipment-service',
      script: 'dist/src/main.js',
      instances: 1,           // Wajib 1 instance
      exec_mode: 'fork',      // Mode fork hemat memori
      max_memory_restart: '220M', // Auto restart jika menyentuh 220MB
      node_args: '--max-old-space-size=180', // Batasi heap Node.js ke 180MB
      env: {
        NODE_ENV: 'development',
        PORT: 3002,
      },
      error_file: '/var/log/pm2/april-shipment-dev-error.log',
      out_file: '/var/log/pm2/april-shipment-dev-out.log',
      merge_logs: true,
      time: true,
    },
  ],
};
```

### 4.1 Otomasi Auto-Start Saat Server Reboot (Systemd Persistence)

Pastikan seluruh service dev otomatis bangkit kembali saat VPS 1GB RAM di-restart:

```bash
# 1. Jalankan aplikasi via PM2 Mode Fork
pm2 start /var/www/april-eyewear-dev/ecosystem.dev.config.js

# 2. Simpan daftar proses aktif ke disk
pm2 save

# 3. Generate script systemd startup untuk Ubuntu
pm2 startup systemd
# Catatan: Eksekusi baris perintah 'sudo env PATH=...' yang dimunculkan PM2 di terminal.

# 4. Pastikan PostgreSQL dan Nginx auto-start pada level OS systemd
sudo systemctl enable postgresql
sudo systemctl enable nginx

# 5. Uji Coba Simulasi Reboot
sudo reboot
# Setelah 1-2 menit login kembali, verifikasi status:
# pm2 status                          -> Harus 'online' (2 aplikasi)
# sudo systemctl status postgresql    -> Harus 'active (running)'
# sudo systemctl status nginx         -> Harus 'active (running)'
# free -h                             -> Swap 3GB harus tetap aktif
```

---

## 5. Konfigurasi PostgreSQL Low-Footprint (`postgresql.conf`)

Edit `/etc/postgresql/16/main/postgresql.conf`:

```ini
# /etc/postgresql/16/main/postgresql.conf
listen_addresses = '127.0.0.1'     # Hanya localhost
max_connections = 25              # Sangat penting: jangan biarkan default 100!
shared_buffers = 128MB            # Hemat RAM (12.5% dari 1GB)
effective_cache_size = 256MB
work_mem = 4MB                    # 4MB x 25 connections = ~100MB maks
maintenance_work_mem = 32MB
min_wal_size = 100MB
max_wal_size = 500MB
checkpoint_completion_target = 0.7
wal_buffers = 4MB
default_statistics_target = 50
random_page_cost = 1.1
effective_io_concurrency = 2
```

Restart PostgreSQL:
```bash
sudo systemctl restart postgresql
```

> **Catatan Prisma Client Pool:**
> Pada `.env` dev, batasi connection pool:
> `DATABASE_URL="postgresql://user:pass@localhost:5432/april_dev_db?connection_limit=5&pool_timeout=15"`

---

## 6. Konfigurasi Nginx Dev (`/etc/nginx/sites-available/dev-api.aprileyewear.com`)

Tuned untuk 1 CPU core:

```nginx
# /etc/nginx/nginx.conf (optimasi global)
# worker_processes 1;
# worker_connections 256;

server {
    listen 80;
    server_name dev-api.aprileyewear.com; # Atau gunakan IP VPS: e.g. 103.xxx.xxx.xxx

    # Gzip hemat CPU
    gzip on;
    gzip_comp_level 4;
    gzip_types application/json text/plain text/css application/javascript;

    # 1. Dev Main Service (E-Commerce, CMS, Catalog, Auth)
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts ramah debugging dev
        proxy_connect_timeout 30s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    # 2. Dev Shipment Service (Biteship Testing)
    location /api/v1/shipments/ {
        proxy_pass http://127.0.0.1:3002;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Aktifkan config:
```bash
sudo ln -s /etc/nginx/sites-available/dev-api.aprileyewear.com /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

---

## 7. Strategi Deploy Dev Tanpa Bikin Server Crash

Jangan pernah menjalankan `npm run build` di server ini. Gunakan alur transfer artefak berikut:

### Alur GitHub Actions atau Script Deploy Lokal (`deploy-dev.sh`):

```bash
#!/bin/bash
# Jalankan di laptop developer / GitHub Actions Runner
set -e

VPS_USER="ubuntu"
VPS_HOST="dev-api.aprileyewear.com"
DEST_DIR="/var/www/april-eyewear-dev"

echo "1. Building Main Service locally..."
cd ../april-eyewear-main-service
npm ci
npm run build
npx prisma generate

echo "2. Syncing Main Service to Dev VPS..."
rsync -avz --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  --exclude 'test' \
  dist package.json prisma "${VPS_USER}@${VPS_HOST}:${DEST_DIR}/april-eyewear-main-service/"

echo "3. Building Shipment Service locally..."
cd ../april-eyewear-shipment-service
npm ci
npm run build

echo "4. Syncing Shipment Service to Dev VPS..."
rsync -avz --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  --exclude 'test' \
  dist package.json "${VPS_USER}@${VPS_HOST}:${DEST_DIR}/april-eyewear-shipment-service/"

echo "5. Installing Production Dependencies & Reloading on VPS..."
ssh "${VPS_USER}@${VPS_HOST}" << 'EOF'
  cd /var/www/april-eyewear-dev/april-eyewear-main-service
  npm install --omit=dev --no-audit --no-fund
  npx prisma migrate deploy

  cd /var/www/april-eyewear-dev/april-eyewear-shipment-service
  npm install --omit=dev --no-audit --no-fund

  pm2 reload /var/www/april-eyewear-dev/ecosystem.dev.config.js --update-env
EOF

echo "✅ Dev Deployment Complete!"
```

---

## 8. Monitoring & Troubleshooting Performa Dev VPS

Untuk memastikan penggunaan RAM tidak meluap, gunakan perintah berikut:

```bash
# Pantau penggunaan RAM fisik dan Swap secara real-time
watch -n 2 free -m

# Cek proses Node.js dan penggunaan memori tiap aplikasi
pm2 list
pm2 monit

# Cek apakah pernah terjadi OOM Killer
sudo dmesg -T | grep -i -E 'oom|out of memory|killed process'

# Jika VPS terasa lambat, bersihkan pagecache Linux
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
```

---

## 9. Ringkasan Perbedaan: Production (4 Core / 4GB) vs Dev (1 Core / 1GB)

| Aspek | Production (4 Core / 4GB) | Development (1 Core / 1GB) |
| :--- | :--- | :--- |
| **PM2 Mode** | Cluster (`instances: "max"`) | Fork (`instances: 1`) |
| **Heap Memory per App** | 768MB (Main) / 512MB (Shipment) | 256MB (Main) / 180MB (Shipment) |
| **Postgres Shared Buffers** | 1024 MB (1 GB) | 128 MB |
| **Postgres Max Connections**| 60 koneksi | 25 koneksi |
| **Swap File** | 4 GB | 3 GB (Sangat krusial) |
| **Swappiness** | 10 (Jarang swap) | 30 (Aktif swap sebelum OOM) |
| **Build Proses** | Offload ke GitHub Actions | Offload ke GitHub Actions / Local |
| **SSL / Security** | Full Cloudflare Origin Pull + HSTS | Standard Let's Encrypt / HTTP Dev |

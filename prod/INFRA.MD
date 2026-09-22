# Infrastructure Guide: Production VPS Architecture (April Eyewear)

Panduan arsitektur dan konfigurasi infrastruktur VPS **Production** untuk April Eyewear dengan spesifikasi **4 vCPU / 4GB RAM**. Dirancang dengan prinsip *lean architecture*, efisiensi sumber daya maksimal, proteksi lonjakan trafik (*high-traffic mitigation*), dan ketahanan *zero-downtime*.

---

## 1. Core Architecture Strategy (Production)

- **Platform Target:** VPS Ubuntu 22.04 / 24.04 LTS (4 vCPU, 4GB RAM, SSD/NVMe).
- **Single-Purpose Production:** Lingkungan development, staging, testing, dan mail server internal **dilarang keras** berjalan di VPS ini untuk menghindari *Out Of Memory* (OOM) dan risiko penalti reputasi IP.
- **Frontend Offload (Edge CDN):**
  - Storefront & Admin Website di-*deploy* terpisah di **Cloudflare Pages** (gratis, zero-cost CDN, global caching, instant load time).
- **CI/CD Pipeline Offload:**
  - Proses kompilasi berat (`npm install`, `nest build`, `tsc`, Prisma Client generation) dijalankan di **GitHub Actions Runner**.
  - Hanya artefak siap produksi (`dist/`, `package.json`, `prisma/`, *production dependencies*) yang ditransfer ke VPS via SSH/rsync.
  - Mencegah CPU spike 100% dan OOM saat proses rilis di server produksi.

---

## 2. Resource Budgeting & Service Allocation (4GB RAM)

| Komponen | Alokasi RAM | Target vCPU | Keterangan |
| :--- | :--- | :--- | :--- |
| **OS & Nginx Reverse Proxy** | ~400 MB | 0.5 Core | Ubuntu base + Nginx worker processes + SSL termination |
| **PostgreSQL 16 (Native)** | ~1.2 GB | 1.0 Core | Terpasang langsung (*no Docker overhead*), tuned buffer & cache |
| **NestJS Main Service** | ~800 MB | 1.5 Core | API E-Commerce, CMS, Auth, Catalog, Cart, Order, Inventory |
| **NestJS Shipment Service** | ~600 MB | 1.0 Core | Integrasi Biteship, kalkulasi ongkir, pickup booking, tracking |
| **Buffer Lonjakan Trafik** | ~1.0 GB | Dinamis | Ruang bebas untuk lonjakan query & koneksi bersamaan |
| **SWAP Safety Net** | **4.0 GB** | Disk NVMe | **Wajib aktif** untuk mencegah kernel OOM Killer mematikan PostgreSQL |

### Tautan Repositori Layanan:
- **Main Service:** [https://github.com/ryanakbar20/april-eyewear-main-service.git](https://github.com/ryanakbar20/april-eyewear-main-service.git)
- **Shipment Service:** [https://github.com/ryanakbar20/april-eyewear-shipment-service.git](https://github.com/ryanakbar20/april-eyewear-shipment-service.git)

---

## 3. Konfigurasi Swap Memory (Wajib)

Swap 4GB berfungsi sebagai pengaman kritis (*safety net*) saat terjadi lonjakan memori tak terduga.

```bash
# 1. Buat swap file sebesar 4GB
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 2. Jadikan permanen saat reboot
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 3. Optimasi swappiness (hanya swap jika RAM fisik hampir habis)
sudo sysctl vm.swappiness=10
sudo sysctl vm.vfs_cache_pressure=50
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.conf
```

---

## 4. Konfigurasi PM2 Cluster Mode (`ecosystem.config.js`)

NestJS berjalan menggunakan PM2 Cluster Mode memanfaatkan seluruh 4 vCPU core:

```javascript
// /var/www/april-eyewear/ecosystem.config.js
module.exports = {
  apps: [
    {
      name: 'april-main-service',
      cwd: '/var/www/april-eyewear/april-eyewear-main-service',
      script: 'dist/src/main.js',
      instances: 'max', // Memanfaatkan 4 core vCPU
      exec_mode: 'cluster',
      max_memory_restart: '850M',
      node_args: '--max-old-space-size=768',
      env_production: {
        NODE_ENV: 'production',
        PORT: 3000,
      },
      error_file: '/var/log/pm2/april-main-error.log',
      out_file: '/var/log/pm2/april-main-out.log',
      merge_logs: true,
      time: true,
    },
    {
      name: 'april-shipment-service',
      cwd: '/var/www/april-eyewear/april-eyewear-shipment-service',
      script: 'dist/src/main.js',
      instances: 2, // 2 worker instances untuk webhook & shipment queue
      exec_mode: 'cluster',
      max_memory_restart: '650M',
      node_args: '--max-old-space-size=512',
      env_production: {
        NODE_ENV: 'production',
        PORT: 3002,
      },
      error_file: '/var/log/pm2/april-shipment-error.log',
      out_file: '/var/log/pm2/april-shipment-out.log',
      merge_logs: true,
      time: true,
    },
  ],
};
```

### 4.1 Otomasi Auto-Start Saat Server Reboot (Systemd Persistence)

Agar seluruh service otomatis menyala kembali setelah VPS restart / reboot tanpa intervensi manual:

```bash
# 1. Jalankan aplikasi via PM2
pm2 start /var/www/april-eyewear/ecosystem.config.js

# 2. Simpan daftar proses aktif ke disk
pm2 save

# 3. Generate script systemd startup untuk Ubuntu
pm2 startup systemd
# Catatan: Salin dan jalankan baris perintah 'sudo env PATH=...' yang ditampilkan oleh PM2 di terminal.

# 4. Pastikan PostgreSQL dan Nginx auto-start pada level OS systemd
sudo systemctl enable postgresql
sudo systemctl enable nginx

# 5. Uji Coba Simulasi Reboot
sudo reboot
# Setelah 1-2 menit login kembali, verifikasi status:
# pm2 status                          -> Harus 'online'
# sudo systemctl status postgresql    -> Harus 'active (running)'
# sudo systemctl status nginx         -> Harus 'active (running)'
# free -h                             -> Swap 4GB harus tetap aktif
```

---

## 5. Konfigurasi PostgreSQL Tuning (`postgresql.conf`)

Tuned khusus untuk alokasi RAM 1.2GB pada mesin 4GB RAM:

```ini
# /etc/postgresql/16/main/postgresql.conf
listen_addresses = '127.0.0.1'     # Terisolasi hanya untuk localhost
max_connections = 60              # Dibatasi untuk mencegah OOM
shared_buffers = 1024MB           # 25% dari total RAM fisik
effective_cache_size = 3072MB     # 75% dari total RAM fisik
maintenance_work_mem = 256MB
work_mem = 16MB                   # Dikalikan max_connections agar aman
min_wal_size = 1GB
max_wal_size = 4GB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1            # Optimal untuk SSD/NVMe
effective_io_concurrency = 200
```

> **Catatan Prisma Pool:** Pada `DATABASE_URL`, batasi koneksi pool per instance aplikasi:
> `postgresql://user:password@localhost:5432/april_eyewear_db?connection_limit=15&pool_timeout=20`

---

## 6. Reverse Proxy Nginx & Security Gateway

Konfigurasi Nginx di `/etc/nginx/sites-available/api.aprileyewear.com`:

```nginx
# Rate Limiting Zones
limit_req_zone $binary_remote_addr zone=api_general:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=api_sensitive:10m rate=5r/s;

# Upstream Load Balancing ke PM2 Cluster
upstream main_backend {
    server 127.0.0.1:3000 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

upstream shipment_backend {
    server 127.0.0.1:3002 max_fails=3 fail_timeout=10s;
    keepalive 16;
}

server {
    listen 80;
    listen [::]:80;
    server_name api.aprileyewear.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name api.aprileyewear.com;

    # SSL / TLS Certificate (Let's Encrypt / Cloudflare Origin Cert)
    ssl_certificate /etc/ssl/certs/aprileyewear_origin.pem;
    ssl_certificate_key /etc/ssl/private/aprileyewear_origin.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Cloudflare Authenticated Origin Pull (Opsional tapi disarankan)
    # ssl_client_certificate /etc/nginx/certs/cloudflare.crt;
    # ssl_verify_client on;

    # Security Headers
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types application/json text/plain text/css application/javascript;

    # 1. Main Service (E-Commerce, CMS, Auth, Catalog)
    location / {
        limit_req zone=api_general burst=50 nodelay;

        proxy_pass http://main_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $http_cf_connecting_ip; # Real IP dari Cloudflare
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts
        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }

    # 2. Endpoint Sensitif (Checkout, Payment Callback, Biometric Session)
    location ~* ^/api/v1/(checkout|payments|kiosk/biometrics) {
        limit_req zone=api_sensitive burst=10 nodelay;

        proxy_pass http://main_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $http_cf_connecting_ip;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 3. Shipment Service Reverse Proxy
    location /api/v1/shipments/ {
        limit_req zone=api_general burst=30 nodelay;

        proxy_pass http://shipment_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $http_cf_connecting_ip;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## 7. Keamanan Jaringan & Hardening Server

```bash
# 1. Firewall UFW — Hanya port SSH dan Web yang terbuka
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH Port'
sudo ufw allow 80/tcp comment 'HTTP Nginx'
sudo ufw allow 443/tcp comment 'HTTPS Nginx'
sudo ufw enable

# 2. Rotasi Log PM2 agar disk tidak penuh
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 50M
pm2 set pm2-logrotate:retain 10
pm2 set pm2-logrotate:compress true
```

---

## 8. Disaster Recovery & Database Backup Otomatis

Buat cron job harian backup database ke cloud storage (AWS S3 / Cloudflare R2):

```bash
#!/bin/bash
# /var/www/april-eyewear/scripts/backup-db.sh
BACKUP_DIR="/tmp/db-backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
FILENAME="april_eyewear_db_${TIMESTAMP}.sql.gz"

mkdir -p $BACKUP_DIR
pg_dump -U postgres april_eyewear_db | gzip > "${BACKUP_DIR}/${FILENAME}"

# Unggah ke Cloudflare R2 via rclone / AWS CLI
rclone copy "${BACKUP_DIR}/${FILENAME}" r2:april-eyewear-backups/database/

# Hapus backup lokal
rm -f "${BACKUP_DIR}/${FILENAME}"
```

Tambahkan ke cron (`crontab -e`):
```cron
0 2 * * * /bin/bash /var/www/april-eyewear/scripts/backup-db.sh >> /var/log/backup.log 2>&1
```

---

## 9. Zero-Downtime CI/CD Deployment Flow (GitHub Actions)

```mermaid
flowchart LR
    A[GitHub Push / PR] --> B[GitHub Actions Runner]
    B -->|npm ci & nest build| C[Artifact: dist/ & package.json]
    C -->|rsync via SSH| D[VPS /var/www/april-eyewear/]
    D -->|Prisma Migrate Deploy| E[(PostgreSQL)]
    D -->|pm2 reload ecosystem.config.js| F[PM2 Zero Downtime Reload]
```

Perintah reload di VPS:
```bash
# Reload tanpa memutus koneksi aktif
pm2 reload /var/www/april-eyewear/ecosystem.config.js --update-env
```
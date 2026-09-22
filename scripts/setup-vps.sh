#!/bin/bash
# ==============================================================================
# APRIL EYEWEAR - VPS INITIAL PROVISIONING SCRIPT
# Jalankan langsung di dalam VPS Ubuntu 22.04 / 24.04 LTS (sebagai root / sudo)
# Cara pakai: sudo bash setup-vps.sh [prod|dev]
# ==============================================================================

set -e

ENV_TYPE=${1:-"prod"}

echo "🚀 Memulai Setup VPS April Eyewear [Mode: ${ENV_TYPE}]..."

# 1. Update OS Packages
echo "📦 1. Update OS packages..."
apt-get update && apt-get upgrade -y
apt-get install -y curl wget git ufw htop unzip build-essential rsync

# 2. Setup SWAP Memory
echo "💾 2. Mengatur Swap Memory..."
if [ "$ENV_TYPE" = "dev" ]; then
  SWAP_SIZE="3G"
  SWAPPINESS=30
else
  SWAP_SIZE="4G"
  SWAPPINESS=10
fi

if [ ! -f /swapfile ]; then
  fallocate -l ${SWAP_SIZE} /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=${SWAPPINESS}
  sysctl vm.vfs_cache_pressure=50
  echo "vm.swappiness=${SWAPPINESS}" >> /etc/sysctl.conf
  echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
  echo "✅ Swap ${SWAP_SIZE} aktif!"
else
  echo "ℹ️ Swap file sudah ada, lewati..."
fi

# 3. Install Node.js 20 LTS & PM2
echo "🟢 3. Install Node.js 20 LTS & PM2..."
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
npm install -g pm2
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 50M
pm2 set pm2-logrotate:retain 10

# 4. Install PostgreSQL 16 & Nginx
echo "🐘 4. Install PostgreSQL 16 & Nginx..."
apt-get install -y postgresql postgresql-contrib nginx

# Enable systemd services
systemctl enable postgresql
systemctl start postgresql
systemctl enable nginx
systemctl start nginx

# 5. Buat Folder Aplikasi
if [ "$ENV_TYPE" = "dev" ]; then
  APP_DIR="/var/www/april-eyewear-dev"
else
  APP_DIR="/var/www/april-eyewear"
fi

mkdir -p ${APP_DIR}
mkdir -p /var/log/pm2
chown -R $USER:$USER ${APP_DIR}
chown -R $USER:$USER /var/log/pm2

# 6. Setup Firewall (UFW)
echo "🛡️ 5. Konfigurasi Firewall UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

echo "=============================================================================="
echo "🎉 Setup VPS Selesai! Detail Lingkungan:"
echo "   Mode: ${ENV_TYPE}"
echo "   App Directory: ${APP_DIR}"
echo "   Node Version: $(node -v)"
echo "   NPM Version: $(npm -v)"
echo "   PostgreSQL: Active"
echo "   Nginx: Active"
echo "=============================================================================="

// ==============================================================================
// APRIL EYEWEAR - PRODUCTION PM2 CONFIGURATION (4 Core / 4GB RAM)
// ==============================================================================

module.exports = {
  apps: [
    {
      name: 'april-main-service',
      cwd: '/var/www/april-eyewear/april-eyewear-main-service',
      script: 'dist/src/main.js',
      instances: 'max', // Memanfaatkan seluruh 4 core CPU
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
      wait_ready: true,
      listen_timeout: 10000,
      kill_timeout: 5000,
    },
    {
      name: 'april-shipment-service',
      cwd: '/var/www/april-eyewear/april-eyewear-shipment-service',
      script: 'dist/src/main.js',
      instances: 2, // 2 worker instances untuk webhook & antrean Biteship
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
      wait_ready: true,
      listen_timeout: 10000,
      kill_timeout: 5000,
    },
  ],
};

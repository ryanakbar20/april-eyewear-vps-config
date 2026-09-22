// ==============================================================================
// APRIL EYEWEAR - DEVELOPMENT PM2 CONFIGURATION (1 Core / 1GB RAM)
// ==============================================================================

module.exports = {
  apps: [
    {
      name: 'april-main-dev',
      cwd: '/var/www/april-eyewear-dev/april-eyewear-main-service',
      script: 'dist/src/main.js',
      instances: 1, // Wajib 1 instance (mode fork) untuk 1 CPU core
      exec_mode: 'fork',
      max_memory_restart: '300M',
      node_args: '--max-old-space-size=256', // Batasi heap Node ke 256MB
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
      instances: 1, // Wajib 1 instance (mode fork)
      exec_mode: 'fork',
      max_memory_restart: '220M',
      node_args: '--max-old-space-size=180', // Batasi heap Node ke 180MB
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

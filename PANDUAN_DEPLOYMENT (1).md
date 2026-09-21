# Panduan Lengkap Deployment Otomatis (CI/CD) Menggunakan Docker, GitHub Actions & Portainer

Panduan ini mendokumentasikan arsitektur dan langkah-langkah implementasi deployment otomatis dari proyek ini sehingga dapat diterapkan ke proyek Laravel / web lainnya.

---

## 1. Arsitektur & Alur Kerja Deployment

```
   [Developer / Local]
          │
          ▼ git push origin main
   [GitHub Repository]
          │
          ▼ GitHub Actions Triggered
   ┌─────────────────────────────────────────────────────────────┐
   │ GitHub Actions Workflow:                                    │
   │ 1. Multi-stage build (Vite/Node + Composer + PHP-FPM+Nginx) │
   │ 2. Push image ke Docker Hub & GitHub Container Registry     │
   │ 3. Panggil Webhook Portainer (Auto Redeploy)                │
   └─────────────────────────────────────────────────────────────┘
          │
          ▼ Webhook POST Request
   [Server Production / VPS]
          │
          ▼ Portainer menarik image terbaru (`:latest`)
   [Docker Container Running]
          ├── Nginx (Port 80)
          ├── PHP-FPM 8.3
          ├── Laravel Worker (Queue / Background Jobs)
          └── Auto-run Migrations & Cache Optimization
```

---

## 2. Struktur File yang Perlu Disiapkan

Pada proyek baru, buat file dan folder berikut:

```
proyek-anda/
├── .dockerignore
├── Dockerfile
├── docker-compose.yml
├── docker/
│   ├── entrypoint.sh
│   ├── nginx.conf
│   └── supervisord.conf
└── .github/
    └── workflows/
        └── docker-publish.yml
```

---

## 3. Detail Konfigurasi File

### A. `.dockerignore`
Mencegah file lokal yang tidak perlu masuk ke dalam proses build Docker:
```gitignore
.git
.github
node_modules
vendor
.env
storage/*.key
storage/logs/*
storage/framework/cache/*
storage/framework/sessions/*
storage/framework/views/*
database/*.sqlite
.phpunit.result.cache
npm-debug.log
```

---

### B. `Dockerfile` (Multi-Stage Build)
Menggabungkan frontend (Vite/Node), backend dependency (Composer), dan production image (Alpine + Nginx + PHP-FPM) menjadi satu container yang ringan dan cepat.

```dockerfile
# ==========================================
# STAGE 1: Frontend Build (Node.js + Vite)
# ==========================================
FROM node:20-alpine AS node_builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ==========================================
# STAGE 2: PHP Dependencies (Composer)
# ==========================================
FROM composer:2 AS composer_builder
WORKDIR /app

COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist

COPY . .
RUN composer dump-autoload --optimize --no-dev

# ==========================================
# STAGE 3: Production Image (PHP 8.3 FPM + Nginx)
# ==========================================
FROM php:8.3-fpm-alpine AS app

# Install system dependencies & PHP extensions
RUN apk add --no-cache \
    nginx \
    supervisor \
    curl \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libzip-dev \
    icu-dev \
    oniguruma-dev \
    sqlite-dev \
    tzdata

# Install PHP extensions yang dibutuhkan
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_sqlite \
        pdo_mysql \
        gd \
        zip \
        bcmath \
        opcache \
        intl \
        mbstring \
        exif

WORKDIR /var/www/html

# Salin source code & build artifacts
COPY --chown=www-data:www-data . /var/www/html
COPY --from=composer_builder --chown=www-data:www-data /app/vendor /var/www/html/vendor
COPY --from=node_builder --chown=www-data:www-data /app/public/build /var/www/html/public/build

# Salin konfigurasi Nginx & Supervisor & Entrypoint
COPY docker/nginx.conf /etc/nginx/http.d/default.conf
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/log/supervisor /run/nginx

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

> **Catatan:** Jika proyek Anda menggunakan paket tambahan (misalnya LibreOffice untuk konversi dokumen seperti di proyek ini), tambahkan `libreoffice ttf-dejavu` pada perintah `apk add`.

---

### C. `docker/nginx.conf`
Konfigurasi Nginx untuk me-route request ke PHP-FPM:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name _;
    root /var/www/html/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;
    client_max_body_size 64M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
```

---

### D. `docker/supervisord.conf`
Supervisor bertugas menjalankan PHP-FPM, Nginx, dan Laravel Queue Worker secara bersamaan dalam 1 container:

```ini
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:php-fpm]
command=php-fpm -F
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:laravel-worker]
command=php /var/www/html/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

---

### E. `docker/entrypoint.sh`
Script inisialisasi yang dijalankan setiap kali container dinyalakan. Script ini memastikan permission, migrations, dan cache Laravel berjalan:

```sh
#!/bin/sh
set -e

# Jika menggunakan SQLite, pastikan file database tersedia
if [ "$DB_CONNECTION" = "sqlite" ] || [ -z "$DB_CONNECTION" ]; then
    DB_FILE="${DB_DATABASE:-/var/www/html/database/database.sqlite}"
    mkdir -p "$(dirname "$DB_FILE")"
    if [ ! -f "$DB_FILE" ]; then
        echo "Creating SQLite database file at $DB_FILE..."
        touch "$DB_FILE"
    fi
    chown -R www-data:www-data "$(dirname "$DB_FILE")"
fi

# Pastikan direktori storage tersedia dengan permission yang benar
mkdir -p /var/www/html/storage/app/public \
         /var/www/html/storage/framework/cache/data \
         /var/www/html/storage/framework/sessions \
         /var/www/html/storage/framework/views \
         /var/www/html/storage/logs \
         /var/www/html/bootstrap/cache

chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache

# Buat symlink public/storage jika belum ada
if [ ! -L /var/www/html/public/storage ]; then
    php artisan storage:link --force || true
fi

# Jalankan migration database otomatis
echo "Running database migrations..."
php artisan migrate --force

# Optimasi konfigurasi & rute Laravel
echo "Caching configuration and routes..."
php artisan config:cache
php artisan route:cache
php artisan view:cache

# Jalankan supervisord
echo "Starting Supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
```

---

### F. `.github/workflows/docker-publish.yml` (GitHub Actions CI/CD)
Mengotomatiskan build & push image saat ada merge atau push ke branch `main`:

```yaml
name: Build & Push Docker Image

on:
  push:
    branches:
      - main

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Extract Docker Metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: |
            ${{ secrets.DOCKERHUB_USERNAME }}/<nama-repo-image>
          tags: |
            type=raw,value=latest
            type=sha,prefix=

      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ./Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Trigger Portainer Webhook to Recreate Container
        if: success()
        env:
          PORTAINER_WEBHOOK_URL: ${{ secrets.PORTAINER_WEBHOOK_URL }}
        run: |
          if [ -n "$PORTAINER_WEBHOOK_URL" ]; then
            echo "Triggering Portainer Webhook for auto-recreate..."
            curl -k -X POST "$PORTAINER_WEBHOOK_URL"
            echo "Portainer webhook triggered successfully!"
          else
            echo "PORTAINER_WEBHOOK_URL secret not set. Skipping webhook trigger."
          fi
```

---

### G. `docker-compose.yml` (Deploy di Server)
File compose yang dijalankan di server melalui CLI atau Portainer Stacks:

```yaml
services:
  app:
    image: <username-dockerhub>/<nama-repo-image>:latest
    restart: always
    ports:
      - "8082:80" # Sesuaikan port host yang diinginkan
    environment:
      APP_NAME: "NamaAplikasi"
      APP_ENV: production
      APP_DEBUG: "false"
      APP_KEY: "base64:..." # Generate via php artisan key:generate --show
      APP_URL: "https://aplikasi-anda.com"
      LOG_CHANNEL: stack
      LOG_LEVEL: error
      
      # Opsi A: SQLite
      DB_CONNECTION: sqlite
      DB_DATABASE: /var/www/html/database/database.sqlite
      
      # Opsi B: MySQL / MariaDB (jika menggunakan DB luar/container lain)
      # DB_CONNECTION: mysql
      # DB_HOST: mysql_service_name
      # DB_PORT: 3306
      # DB_DATABASE: db_name
      # DB_USERNAME: db_user
      # DB_PASSWORD: db_password
      
      SESSION_DRIVER: database
      QUEUE_CONNECTION: database
      CACHE_STORE: database
    volumes:
      - sqlite_data:/var/www/html/database
      - storage_data:/var/www/html/storage/app
    healthcheck:
      test: [ "CMD", "curl", "-fsS", "http://localhost/up" ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

volumes:
  sqlite_data:
  storage_data:
```

---

## 4. Langkah-Langkah Mengimplementasikan ke Proyek Baru

### Langkah 1: Siapkan File Konfigurasi
1. Salin folder `docker/`, file `Dockerfile`, `.dockerignore`, `docker-compose.yml`, dan `.github/workflows/docker-publish.yml` ke proyek baru Anda.
2. Ganti `<username-dockerhub>/<nama-repo-image>` dengan nama akun dan repositori image Anda.

### Langkah 2: Setup Docker Hub
1. Buat repositori baru di [hub.docker.com](https://hub.docker.com) (misal: `username/nama-project`).
2. Buat Access Token di Docker Hub:
   - Masuk ke **Account Settings** -> **Security** -> **New Access Token**.
   - Berikan izin `Read, Write`.
   - Simpan token tersebut.

### Langkah 3: Setup GitHub Secrets
Di repositori GitHub proyek Anda:
1. Buka **Settings** -> **Secrets and variables** -> **Actions**.
2. Tambahkan **Repository secrets**:
   - `DOCKERHUB_USERNAME`: Username akun Docker Hub Anda.
   - `DOCKERHUB_TOKEN`: Access token dari langkah 2.
   - `PORTAINER_WEBHOOK_URL`: (Opsional / setelah Portainer dibuat) Webhook URL dari Service/Stack Portainer.

### Langkah 4: Setup di Server (Portainer / Docker Compose)
Jika menggunakan **Portainer**:
1. Buka Portainer -> **Stacks** -> **Add stack**.
2. Beri nama stack (misal: `aplikasi-web`).
3. Tempel isi file `docker-compose.yml` (pastikan `APP_KEY` sudah terisi).
4. Di bagian bawah editor Stack, aktifkan opsi **Service Webhook** / **Webhook** pada service container.
5. Salin URL Webhook yang dihasilkan, lalu masukkan ke GitHub Secrets (`PORTAINER_WEBHOOK_URL`).
6. Klik **Deploy the stack**.

Jika menggunakan **Docker Compose via Terminal Server**:
```bash
# Buat folder proyek di server
mkdir -p /opt/aplikasi && cd /opt/aplikasi

# Simpan docker-compose.yml lalu jalankan
docker compose pull
docker compose up -d
```

### Langkah 5: Setup Reverse Proxy & Domain (Nginx / Nginx Proxy Manager / Cloudflare)
Arahkan domain ke IP VPS dan mapping ke port yang diekspos (`8082`):
Contoh Nginx Host di VPS:
```nginx
server {
    server_name aplikasi-anda.com;

    location / {
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
Lalu pasang SSL gratis menggunakan Certbot:
```bash
certbot --nginx -d aplikasi-anda.com
```

---

## 5. Cara Kerja Alur Update Otomatis (CI/CD)

1. Anda melakukan perubahan koding di local.
2. `git commit -m "fitur baru"` dan `git push origin main`.
3. GitHub Actions otomatis:
   - Mengompilasi Vite assets dan vendor composer.
   - Membangun docker image yang teroptimasi.
   - Mengunggah image ke Docker Hub dengan tag `:latest`.
   - Menembak URL Webhook Portainer Anda.
4. Portainer mendeteksi trigger webhook -> menarik image terbaru -> me-restart container dengan image baru tanpa downtime yang berarti.
5. Saat container menyala, `entrypoint.sh` otomatis menjalankan `migrate` dan memperbarui `cache` Laravel.

# PANDUAN MASTER: Deployment Otomatis (CI/CD) Web ke Portainer via Docker Hub Token

Dokumen ini adalah **template dan panduan standar** untuk men-deploy berbagai proyek web (Landing Page HTML/CSS/JS, Web Prodi, Company Profile, Vite, React, Vue, dll.) ke **Portainer** secara otomatis dan bebas dari masalah *"file too large"*.

---

## 📌 PROMPT SIAP PAKAI UNTUK AI (Tinggal Copas)

Saat Anda membuat proyek web baru dan ingin AI mengonfigurasikannya secara otomatis, **cukup salin prompt berikut ke AI**:

```text
Tolong siapkan konfigurasi deployment Docker dan CI/CD untuk proyek web ini sesuai standar PANDUAN_MASTER_DEPLOYMENT_PORTAINER.md:
- Username Docker Hub : [masukkan_username_dockerhub, misal: alphabloo7]
- Nama Image          : [masukkan_nama_image, misal: web-prodi-pendidikan]
- Port Host di Server : [masukkan_port, misal: 8086]
- Tipe Proyek         : [Pilih: HTML Statis / Vite / React / Vue]

Tolong buatkan:
1. .dockerignore
2. docker/nginx.conf (Gzip, Security Headers, Healthcheck)
3. Dockerfile (Nginx Alpine)
4. docker-compose.yml (Siap copas ke Web Editor Portainer)
5. .github/workflows/docker-publish.yml (Build, push via DOCKERHUB_TOKEN, trigger Portainer Webhook)
```

---

## 1. Arsitektur & Alur Kerja Deployment

```
   [Developer di Komputer Lokal]
                 │
                 ▼ git push origin main
   [GitHub Repository]
                 │
                 ▼ GitHub Actions Otomatis Berjalan (Runner Cloud)
   ┌──────────────────────────────────────────────────────────────────┐
   │ GitHub Actions Workflow:                                         │
   │ 1. Checkout kode                                                 │
   │ 2. Login ke Docker Hub dengan ${{ secrets.DOCKERHUB_TOKEN }}     │
   │ 3. Build image berbasis Nginx Alpine (~15 MB)                    │
   │ 4. Push image ke Docker Hub (:latest)                            │
   │ 5. Panggil URL Webhook Portainer (POST request)                  │
   └──────────────────────────────────────────────────────────────────┘
                 │
                 ▼ Webhook Trigger
   [Server VPS / Portainer]
                 │
                 ▼ Portainer menarik image terbaru (:latest)
   [Container Web Aktif & Terupdate Otomatis Tanpa Downtime]
```

> **Mengapa metode ini bebas dari error *"file too large"* di Portainer?**  
> Portainer di server Anda **tidak perlu mengkloning Git repository atau mem-build kode**. Seluruh proses kompilasi dan build dilakukan oleh cloud GitHub Actions. Server VPS Anda hanya menarik (*pull*) image Docker jadi yang sudah sangat kecil (~15 MB).

---

## 2. Struktur Berkas Standar Proyek

Setiap proyek web yang akan di-deploy harus memiliki struktur berkas berikut di root folder:

```
proyek-web-anda/
├── .dockerignore
├── Dockerfile
├── docker-compose.yml
├── docker/
│   └── nginx.conf
├── .github/
│   └── workflows/
│       └── docker-publish.yml
└── [file source code web: index.html / src / dist / dll]
```

---

## 3. Template Berkas Konfigurasi (Copy-Paste Ready)

### A. `.dockerignore`
Mencegah file lokal dan dokumentasi yang tidak dibutuhkan masuk ke image Docker:

```gitignore
.git
.github
*.md
.vscode
.idea
.DS_Store
Thumbs.db
node_modules
```

---

### B. `docker/nginx.conf`
Konfigurasi Nginx produksi yang dioptimalkan untuk performa tinggi, keamanan, kompresi Gzip, caching aset statis, dan endpoint healthcheck:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;
    charset utf-8;

    # 1. Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # 2. Gzip Compression (Membuat web sangat cepat dibuka)
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    # 3. Routing (Support Single Page Application / SPA)
    location / {
        try_files $uri $uri/ /index.html;
    }

    # 4. Endpoint Healthcheck untuk Docker & Portainer
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "OK\n";
    }

    # 5. Caching Aset Statis (CSS, JS, Gambar, Font)
    location ~* \.(?:css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    # 6. Blokir akses ke hidden files (.git, .env, dll)
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
```

---

### C. `Dockerfile`

#### Opsi 1: Untuk Web Statis Murni (HTML/CSS/JS)
```dockerfile
# Base image Nginx Alpine ultra-ringan (~15 MB)
FROM nginx:alpine

# Install curl untuk Docker healthcheck
RUN apk add --no-cache curl

# Hapus konfigurasi default Nginx
RUN rm -rf /etc/nginx/conf.d/default.conf /usr/share/nginx/html/*

# Salin konfigurasi Nginx kustom
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf

# Salin seluruh aset website ke direktori web root Nginx
COPY . /usr/share/nginx/html/

# Expose port 80
EXPOSE 80

# Healthcheck otomatis
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -fsS http://localhost/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
```

#### Opsi 2: Untuk Web yang Perlu Build (Vite / React / Vue)
```dockerfile
# STAGE 1: Build Frontend
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# STAGE 2: Production Nginx Server
FROM nginx:alpine
RUN apk add --no-cache curl
RUN rm -rf /etc/nginx/conf.d/default.conf /usr/share/nginx/html/*
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist /usr/share/nginx/html/
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -fsS http://localhost/healthz || exit 1
CMD ["nginx", "-g", "daemon off;"]
```

---

### D. `docker-compose.yml`
File ini yang akan **langsung di-paste ke tab Web Editor di Portainer**:

```yaml
services:
  web:
    image: <username-dockerhub>/<nama-image>:latest
    container_name: <nama-container>-web
    restart: always
    ports:
      - "<PORT_HOST>:80" # Contoh: "8085:80" (Ubah port host sesuai server Anda)
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s
```

---

### E. `.github/workflows/docker-publish.yml`
Pipeline GitHub Actions CI/CD otomatis:

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

      - name: Log in to GitHub Container Registry (GHCR)
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Docker Metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: |
            ${{ secrets.DOCKERHUB_USERNAME }}/<nama-image>
            ghcr.io/${{ github.repository }}
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

      - name: Trigger Portainer Webhook for Auto Redeploy
        if: success()
        env:
          PORTAINER_WEBHOOK_URL: ${{ secrets.PORTAINER_WEBHOOK_URL }}
        run: |
          if [ -n "$PORTAINER_WEBHOOK_URL" ]; then
            echo "Menembak Portainer Webhook untuk auto-redeploy..."
            curl -k -X POST "$PORTAINER_WEBHOOK_URL"
            echo "Portainer webhook berhasil dipanggil!"
          else
            echo "PORTAINER_WEBHOOK_URL belum diset pada GitHub Secrets. Melewati pemanggilan webhook."
          fi
```

---

## 4. Langkah Setup Lengkap (Hanya Dilakukan Sekali per Web)

### Langkah 1: Buat Token di Docker Hub
1. Login ke [hub.docker.com](https://hub.docker.com).
2. Klik nama akun (kanan atas) -> **Account Settings** -> **Security**.
3. Klik **New Access Token**.
4. Beri nama deskripsi (misal: `github-actions-token`).
5. Access permissions: **Read, Write**.
6. Klik **Generate Token** lalu simpan token tersebut.

### Langkah 2: Tambahkan Secret di GitHub Repo
Buka repositori GitHub web baru Anda:
1. Masuk ke **Settings** -> **Secrets and variables** -> **Actions**.
2. Klik tombol **New repository secret**:
   - `DOCKERHUB_USERNAME`: Username Docker Hub Anda.
   - `DOCKERHUB_TOKEN`: Access Token dari Langkah 1.

### Langkah 3: Deploy di Portainer (Web Editor)
1. Buka Portainer -> pilih environment Anda -> masuk ke menu **Stacks** -> klik **+ Add stack**.
2. Beri nama stack (misal: `web-prodi-geo`).
3. Pilih tab **Web editor**.
4. Tempel isi file `docker-compose.yml` (pastikan nama image dan port sudah sesuai).
5. Klik **Deploy the stack**.

### Langkah 4: Ambil Webhook URL di Portainer
1. Masuk ke stack yang baru saja dibuat di Portainer.
2. Di bagian konfigurasi service atau editor stack, aktifkan toggle **Service Webhook** / **Webhook**.
3. Portainer akan memunculkan URL Webhook (contoh: `https://portainer.domain.com/api/stacks/webhooks/...`).
4. Salin URL tersebut.
5. Kembali ke GitHub Repo Anda -> **Settings** -> **Secrets and variables** -> **Actions** -> buat secret baru:
   - `PORTAINER_WEBHOOK_URL`: (Tempel URL Webhook Portainer tadi).

### Langkah 5: Setup Reverse Proxy & Domain di VPS
Arahkan domain ke IP VPS dan mapping ke port container Anda (misal `8086`):

```nginx
server {
    listen 80;
    server_name namadomain-prodi.ac.id;

    location / {
        proxy_pass http://127.0.0.1:8086;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Pasang sertifikat SSL gratis:
```bash
sudo certbot --nginx -d namadomain-prodi.ac.id
```

---

## 5. Alur Kerja Harian Developer (Setelah Setup)

Setelah setup selesai, Anda **tidak perlu membuka Portainer atau VPS lagi**.

Setiap kali Anda selesai mengedit web di lokal:
```bash
git add .
git commit -m "update konten website"
git push origin main
```

1. GitHub Actions otomatis mem-build image baru dalam waktu ~10-20 detik.
2. Image `:latest` di-push ke Docker Hub.
3. GitHub Actions memicu Webhook Portainer.
4. Portainer langsung menarik image baru dan me-restart container secara otomatis tanpa downtime!

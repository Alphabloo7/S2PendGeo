# Panduan Deployment S2PendGeo ke Portainer (Menggunakan Token & CI/CD)

Panduan ini mendokumentasikan alur deployment otomatis menggunakan **Docker Hub Access Token**, **GitHub Actions**, dan **Portainer Webhook**.

Dengan alur ini, proses build dilakukan di cloud GitHub Actions, dan Portainer hanya menarik (*pull*) image jadi yang sudah teroptimasi (~15 MB). Anda **tidak akan mengalami error *"file too large"*** di Portainer karena server tidak perlu mengkloning seluruh source code atau melakukan build lokal.

---

## 1. Alur Kerja Deployment (CI/CD)

```
   [Komputer Lokal]
          │
          ▼ git push origin main
   [GitHub Repo: Alphabloo7/S2PendGeo]
          │
          ▼ GitHub Actions Otomatis Dijalankan
   ┌─────────────────────────────────────────────────────────────┐
   │ GitHub Actions Workflow (.github/workflows/docker-publish): │
   │ 1. Login ke Docker Hub dengan DOCKERHUB_TOKEN               │
   │ 2. Build Docker image berbasis Nginx Alpine (~15 MB)        │
   │ 3. Push image ke Docker Hub (tag: :latest)                  │
   │ 4. Panggil Webhook Portainer (Auto Redeploy)                │
   └─────────────────────────────────────────────────────────────┘
          │
          ▼ Webhook POST Trigger
   [Server VPS / Portainer]
          │
          ▼ Portainer menarik image terbaru (:latest)
   [Container Berjalan: s2pendgeo-web] (Port 8085:80)
```

---

## 2. Langkah 1: Buat Access Token di Docker Hub

1. Buka dan login ke [hub.docker.com](https://hub.docker.com).
2. Klik foto profil di pojok kanan atas -> pilih **Account Settings**.
3. Pilih menu **Security** pada bilah samping -> klik **New Access Token**.
4. Beri deskripsi, misalnya: `github-actions-s2pendgeo`.
5. Berikan izin hak akses: **Read, Write**.
6. Klik **Generate Token**, lalu **salin dan simpan token tersebut** (token ini hanya ditampilkan sekali).

---

## 3. Langkah 2: Tambahkan Secrets di GitHub Repository

Buka repositori Anda di [github.com/Alphabloo7/S2PendGeo](https://github.com/Alphabloo7/S2PendGeo):
1. Masuk ke tab **Settings** -> pilih menu samping **Secrets and variables** -> klik **Actions**.
2. Klik tombol hijau **New repository secret**.
3. Tambahkan 2 secret awal:
   - **Nama**: `DOCKERHUB_USERNAME`  
     **Isi**: Username akun Docker Hub Anda (misal: `alphabloo7`).
   - **Nama**: `DOCKERHUB_TOKEN`  
     **Isi**: Access Token yang Anda salin dari Docker Hub pada Langkah 1.

*(Catatan: Secret ke-3 yaitu `PORTAINER_WEBHOOK_URL` akan ditambahkan setelah Anda membuat stack di Portainer pada Langkah 3).*

---

## 4. Langkah 3: Setup Stack di Portainer (Web Editor)

Menggunakan tab **Web editor** di Portainer menjamin **bebas dari masalah "file too large"** karena Portainer hanya bertugas menjalankan container dari image yang sudah jadi.

1. Buka dashboard **Portainer** Anda di browser.
2. Pilih environment Anda (misal: `local` / `primary`).
3. Pada menu samping, klik **Stacks** -> klik **+ Add stack**.
4. Beri nama stack: `s2pendgeo`.
5. Pada bagian **Build method**, pilih tab **Web editor**.
6. Tempel konfigurasi berikut:
   ```yaml
   services:
     s2pendgeo:
       image: alphabloo7/s2pendgeo:latest # Ganti 'alphabloo7' dengan username Docker Hub Anda jika berbeda
       container_name: s2pendgeo-web
       restart: always
       ports:
         - "8085:80" # Port di server VPS
       healthcheck:
         test: ["CMD", "curl", "-fsS", "http://localhost/healthz"]
         interval: 30s
         timeout: 5s
         retries: 3
         start_period: 5s
   ```
   *(Opsional: Jika repository image Anda di Docker Hub bersifat **Private**, tambahkan kredensial registry di menu **Registries** -> **Add registry** -> **Docker Hub** menggunakan username dan token Anda).*
7. Gulir ke bawah, lalu klik tombol **Deploy the stack**.

---

## 5. Langkah 4: Aktifkan Webhook Auto-Redeploy di Portainer

Agar setiap kali ada perubahan kode di GitHub, Portainer otomatis meng-update container tanpa perlu Anda login ke Portainer lagi:

1. Di Portainer, masuk ke stack `s2pendgeo` yang baru Anda buat.
2. Di bagian bawah editor stack (atau pada detail service/container `s2pendgeo`), aktifkan toggle **Service Webhook** atau **Webhook**.
3. Portainer akan menghasilkan URL webhook unik, misalnya:
   `https://portainer.domainanda.com/api/stacks/webhooks/...`
4. Salin URL tersebut.
5. Kembali ke GitHub repo [Alphabloo7/S2PendGeo](https://github.com/Alphabloo7/S2PendGeo) -> **Settings** -> **Secrets and variables** -> **Actions**.
6. Klik **New repository secret**:
   - **Nama**: `PORTAINER_WEBHOOK_URL`
   - **Isi**: URL Webhook yang disalin dari Portainer tadi.

---

## 6. Uji Coba Deployment Otomatis

Sekarang seluruh alur sudah siap! Untuk mengujinya:

1. Di komputer lokal Anda, lakukan commit dan push:
   ```bash
   git add .
   git commit -m "ci: aktifkan docker hub token dan portainer webhook auto redeploy"
   git push origin main
   ```
2. Buka tab **Actions** di GitHub repo Anda.
3. Anda akan melihat workflow `Build & Push Docker Image` berjalan secara otomatis:
   - Mengompilasi dan mengemas landing page ke Nginx Alpine.
   - Mengunggah image ke Docker Hub.
   - Menembak URL webhook Portainer.
4. Portainer di server VPS Anda akan otomatis menarik image baru dan me-restart container dalam hitungan detik!

---

## 7. Setup Domain & SSL (Nginx Reverse Proxy di VPS)

Arahkan domain (misal: `geografi.fkip.uns.ac.id`) ke port `8085`:

```nginx
server {
    listen 80;
    server_name geografi.fkip.uns.ac.id;

    location / {
        proxy_pass http://127.0.0.1:8085;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Lalu jalankan Certbot untuk HTTPS gratis:
```bash
sudo certbot --nginx -d geografi.fkip.uns.ac.id
```

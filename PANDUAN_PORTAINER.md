# Panduan Deploy S2PendGeo ke Portainer

Panduan ini berisi langkah-langkah mudah untuk men-deploy website **S2 Pendidikan Geografi (UNS)** ke server menggunakan **Portainer**.

---

## Pilihan Metode Deployment

Ada 2 cara yang dapat Anda pilih sesuai kenyamanan Anda:

---

### METODE 1: Deploy Langsung via Portainer Stack (Paling Praktis & Cepat)
*Metode ini tidak memerlukan akun Docker Hub atau konfigurasi GitHub Secrets. Portainer akan mengkloning repo GitHub Anda dan mem-build image Docker langsung di server.*

1. Buka dashboard **Portainer** Anda di browser.
2. Masuk ke environment Anda (biasanya `local` atau `primary`).
3. Pada menu samping, klik **Stacks** -> klik tombol **+ Add stack**.
4. Beri nama stack, misalnya: `s2pendgeo`.
5. Di bagian **Build method**, pilih tab **Repository**.
6. Masukkan konfigurasi berikut:
   - **Repository URL**: `https://github.com/Alphabloo7/S2PendGeo.git`
   - **Repository reference**: `refs/heads/main`
   - **Compose path**: `docker-compose.yml`
7. *(Opsional)* Jika repository Anda bersifat privat:
   - Aktifkan toggle **Authentication**.
   - Masukkan **Username** GitHub Anda dan **Personal Access Token (PAT)** sebagai password.
8. *(Opsional)* Aktifkan **Automatic updates**:
   - Pilih **Webhook** untuk mendapatkan URL webhook auto-update, atau
   - Pilih **Polling** (misal per 5 menit) agar Portainer otomatis mengecek commit terbaru di GitHub.
9. Klik tombol **Deploy the stack** di bagian bawah.
10. Tunggu beberapa detik hingga proses build selesai. Website Anda kini sudah berjalan di port `8085`!

---

### METODE 2: Deploy via Docker Hub / GHCR & GitHub Actions (CI/CD Otomatis)
*Metode ini memanfaatkan workflow `.github/workflows/docker-publish.yml` yang otomatis mem-build image setiap kali Anda melakukan `git push origin main`.*

#### 1. Setup GitHub Secrets
Buka repository GitHub Anda `https://github.com/Alphabloo7/S2PendGeo` -> **Settings** -> **Secrets and variables** -> **Actions** -> klik **New repository secret**:
- `DOCKERHUB_USERNAME`: Username Docker Hub Anda.
- `DOCKERHUB_TOKEN`: Access Token dari Docker Hub (Read & Write).
- `PORTAINER_WEBHOOK_URL`: (Didapat setelah membuat stack/service di Portainer).

#### 2. Buat Stack di Portainer (Web Editor)
1. Buka Portainer -> **Stacks** -> **+ Add stack**.
2. Beri nama stack: `s2pendgeo`.
3. Pada tab **Web editor**, tempelkan isi berikut:
   ```yaml
   services:
     s2pendgeo:
       image: ghcr.io/alphabloo7/s2pendgeo:latest # atau username/s2pendgeo:latest dari Docker Hub
       container_name: s2pendgeo-web
       restart: always
       ports:
         - "8085:80"
       healthcheck:
         test: ["CMD", "curl", "-fsS", "http://localhost/healthz"]
         interval: 30s
         timeout: 5s
         retries: 3
   ```
4. Klik **Deploy the stack**.
5. Setelah container aktif, buka detail service/container, aktifkan toggle **Service Webhook**.
6. Salin URL Webhook tersebut dan simpan ke GitHub Secret `PORTAINER_WEBHOOK_URL`.
7. Setiap kali Anda commit & push ke `main`, GitHub Actions akan mem-build image baru dan otomatis menginstruksikan Portainer untuk memperbarui container.

---

## Konfigurasi Domain / Reverse Proxy (Nginx / Cloudflare)

Agar website dapat diakses melalui domain (misal: `geografi.fkip.uns.ac.id` atau `namadomain.com`):

### Jika menggunakan Nginx di VPS Host:
Buat file konfigurasi `/etc/nginx/sites-available/s2pendgeo`:

```nginx
server {
    listen 80;
    server_name geografi.fkip.uns.ac.id; # Ganti dengan domain Anda

    location / {
        proxy_pass http://127.0.0.1:8085;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Aktifkan konfigurasi dan pasang SSL gratis:
```bash
sudo ln -s /etc/nginx/sites-available/s2pendgeo /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d geografi.fkip.uns.ac.id
```

### Jika menggunakan Nginx Proxy Manager (NPM):
1. Buka dashboard NPM -> **Proxy Hosts** -> **Add Proxy Host**.
2. **Domain Names**: masukkan nama domain Anda.
3. **Forward Hostname / IP**: masukkan IP server atau nama service docker.
4. **Forward Port**: `8085`
5. Aktifkan **Block Common Exploits** dan **Websockets Support**.
6. Pada tab **SSL**, pilih **Request a new SSL Certificate** (Let's Encrypt) -> centang **Force SSL** -> klik **Save**.

---

## Ringkasan Port & Endpoint

| Komponen | Port / Path | Keterangan |
|---|---|---|
| Port Host Server | `8085` | Dapat diubah di `docker-compose.yml` |
| Port Internal Container | `80` | Port HTTP Nginx di dalam container |
| Healthcheck Endpoint | `http://localhost:8085/healthz` | Digunakan Docker untuk memantau status container |

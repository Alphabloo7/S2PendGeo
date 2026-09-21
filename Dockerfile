# Menggunakan base image Nginx Alpine yang ultra-ringan (~15 MB)
FROM nginx:alpine

# Install curl untuk keperluan container healthcheck
RUN apk add --no-cache curl

# Bersihkan konfigurasi default dan web root bawaan
RUN rm -rf /etc/nginx/conf.d/default.conf /usr/share/nginx/html/*

# Salin konfigurasi Nginx yang telah dioptimalkan
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf

# Salin seluruh aset website ke direktori web root Nginx
COPY . /usr/share/nginx/html/

# Expose port HTTP
EXPOSE 80

# Healthcheck otomatis
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -fsS http://localhost/healthz || exit 1

# Jalankan Nginx di foreground
CMD ["nginx", "-g", "daemon off;"]

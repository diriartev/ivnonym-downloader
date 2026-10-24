# ==============================================================
# Hardened Minimal Media Downloader Container
# ==============================================================
FROM python:3.12-slim

# Metadatos
LABEL org.opencontainers.image.title="Ivnonym Downloader"
LABEL description="Secure, least-privilege media downloader with FFmpeg, yt-dlp, Node.js and yt-dlp-ejs"

# Variables de entorno seguras
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    CONTAINERIZED=true \
    PORT=5050 \
    DOWNLOAD_DIR=/downloads \
    HOME=/home/appuser

# Instalación mínima de dependencias del sistema y paquetes de aceleración
# DL3008: no se fijan versiones de apt para recibir los parches de seguridad de Debian
# DL3013: yt-dlp va SIEMPRE en su última versión (las plataformas cambian cada semana)
# hadolint ignore=DL3008,DL3013
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    nodejs \
    ca-certificates \
    curl \
    && pip install --no-cache-dir --upgrade pip yt-dlp curl_cffi yt-dlp-ejs requests certifi \
    # pip/setuptools no hacen falta al ejecutar: fuera (menos superficie de ataque)
    && python3 -m pip uninstall -y pip setuptools wheel \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache

# Crear usuario y grupo sin privilegios con UID/GID 1000
RUN groupadd -g 1000 appgroup && \
    useradd -u 1000 -g appgroup -d /home/appuser -m -s /sbin/nologin -c "Unprivileged App User" appuser

# Estructura de directorios y permisos
WORKDIR /app
RUN mkdir -p /downloads /home/appuser/.cache && \
    chown -R appuser:appgroup /app /downloads /home/appuser

# Copiar archivos de la aplicación
COPY --chown=appuser:appgroup server.py /app/server.py
COPY --chown=appuser:appgroup public /app/public

# Establecer permisos estrictos (solo lectura para el código)
RUN chmod 555 /app /app/public && \
    chmod 444 /app/server.py /app/public/* && \
    chmod 775 /downloads /home/appuser/.cache

# Cambiar permanentemente a usuario no privilegiado
USER 1000:1000

# Exponer el puerto de servicio local
EXPOSE 5050

# Verificación de salud interna del contenedor
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5050/api/status', timeout=4)"]

# Comando de inicio
ENTRYPOINT ["python3", "/app/server.py"]

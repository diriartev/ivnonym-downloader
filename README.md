# ⚡ Ivnonym Downloader

Descargador de video y audio **100 % local** (YouTube, TikTok, Instagram, X/Twitter y todo lo que soporte [yt-dlp](https://github.com/yt-dlp/yt-dlp)), con interfaz web y ejecutándose dentro de un contenedor Docker endurecido.

- 🎬 Video MP4 hasta **4K 60 fps** (2160p, 1440p, 1080p, 720p…)
- 🎵 Audio **MP3 320/256/128 kbps**, **M4A** original o **WAV** sin pérdida
- 📊 Vista previa (miniatura, duración, canal, vistas), progreso en tiempo real, velocidad y ETA
- 💾 **Tú eliges dónde guardar cada archivo** con el diálogo "Guardar como". No hay carpetas ni rutas que configurar
- ▶️ Reproductor integrado para ver/escuchar lo descargado
- 🚀 Descarga con fragmentos concurrentes + FFmpeg para unir audio y video sin pérdida

## 🛡️ Seguridad

| Medida | Detalle |
| --- | --- |
| Usuario sin privilegios | Corre con tu propio UID (nunca root) |
| `cap_drop: ALL` | Cero capacidades del kernel |
| `no-new-privileges` | Sin escalamiento de privilegios |
| `read_only: true` | Sistema de archivos del contenedor inmutable |
| `tmpfs` en RAM | `/tmp` con `noexec,nosuid,nodev` |
| Solo localhost | Publicado en `127.0.0.1:5050`, invisible para la red |
| Límites de recursos | CPU, RAM y número de procesos limitados |
| Validación de entrada | Solo URLs `http(s)`, sin CORS (otras webs no pueden usar la API) y textos escapados en la web |
| Sin acceso a tu disco | El contenedor no monta ninguna carpeta tuya; usa un volumen interno que se vacía solo cada 3 h |

## 📋 Requisitos

- Linux con **Docker** y **Docker Compose** (`docker compose version` o `docker-compose --version`)
  - Ubuntu/Debian: `curl -fsSL https://get.docker.com | sudo sh`
- `curl` y `python3` (vienen en casi todas las distros)

## 🚀 Instalación (plug and play)

```bash
# Desde GitHub
git clone https://github.com/diriartev/ivnonym-downloader.git
cd ivnonym-downloader

# (o si te lo pasaron en .zip:  unzip ivnonym-downloader.zip && cd ivnonym-downloader)

bash iniciar.sh
```

`iniciar.sh` hace todo solo:

1. Comprueba Docker. Si tu usuario no está en el grupo `docker`, usa `sudo` y te avisa.
2. Construye la imagen, arranca y abre **http://127.0.0.1:5050**.

## 🎬 Uso

1. Pega el enlace y pulsa **Obtener Video**.
2. Elige calidad o formato y pulsa **Descargar**.
3. Cuando termine, pulsa **💾 Elegir dónde guardar** y escoge la carpeta en el diálogo del sistema.

> El diálogo "Guardar como" funciona en **Chrome, Edge, Brave y Opera**. En **Firefox** se usa la descarga normal; para que pregunte la carpeta, activa *Ajustes → General → Archivos → "Preguntar siempre dónde guardar los archivos"*.

Los archivos quedan disponibles en la web (historial y reproductor) durante 3 horas y después se borran solos. Puedes cambiarlo con `FILE_TTL_HOURS=` en `.env`.

## 🛠️ Comandos

```bash
bash iniciar.sh                    # construir/arrancar y abrir la web
bash estado.sh                     # estado, salud y versión de yt-dlp
bash detener.sh                    # apagar el contenedor

docker compose logs -f             # ver logs en vivo
docker compose build --no-cache    # reconstruir (actualiza yt-dlp a la última versión)
docker compose down -v --rmi local # borrar contenedor, imagen y temporales
```

> 💡 Si una plataforma deja de funcionar, casi siempre es porque yt-dlp necesita actualizarse: `docker compose build --no-cache && bash iniciar.sh`.

## 🩺 Problemas comunes

| Síntoma | Solución |
| --- | --- |
| `permission denied ... docker.sock` | `sudo usermod -aG docker $USER` y cierra/abre sesión (o deja que el script use sudo) |
| `docker: 'compose' is not a docker command` | `sudo apt install docker-compose-plugin` (o `docker-compose-v2`) |
| `port is already allocated` | Cambia `PORT=` en `.env` |
| No sale el diálogo "Guardar como" | Usa Chrome/Edge/Brave, o en Firefox activa "Preguntar siempre dónde guardar" |
| "El archivo ya no está disponible" | Pasaron más de `FILE_TTL_HOURS`; descárgalo de nuevo |

## 🔄 CI/CD (pruebas y publicación automáticas)

Este repo usa [CI Seguro](https://github.com/diriartev/ci-seguro), el pipeline universal de todos mis repos. Cada cambio pasa por el mismo motor (`ci/revisar.sh`), **en tu PC y en GitHub**:

| Etapa | Herramienta | Qué detiene |
| --- | --- | --- |
| 1 · Secretos | gitleaks (todo el historial) | llaves, tokens, contraseñas, aunque se hayan borrado después |
| 2 · Código | ruff + bandit, shellcheck, hadolint, actionlint | bugs y patrones inseguros en Python, Bash, Dockerfile y workflows; acciones sin fijar por hash |
| 3 · Configuración | trivy config | contenedores mal configurados |
| 4 · Dependencias | trivy fs | librerías con vulnerabilidades **críticas** que ya tienen parche |
| 5 · Build | Docker | que la imagen no construya |
| 6 · Pruebas | `ci/pruebas.sh` contra el contenedor endurecido real | funciones rotas y regresiones de seguridad |
| 7 · Vulnerabilidades | trivy image | vulnerabilidades **críticas** con parche disponible |

```bash
bash ci/revisar.sh                # todo el pipeline en local (atajo: bash probar.sh)
bash ci/revisar.sh secretos lint  # solo lo rápido
```

**Publicar una versión** (semi-automático):

```bash
git tag -s v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

GitHub repite todo el CI y **espera tu aprobación** (Actions → *Review deployments*). Después publica la imagen firmada en `ghcr.io`, con SBOM y certificado de procedencia, y crea el Release.

**Usar la imagen publicada** en vez de construirla: en `.env` descomenta `IMAGE=ghcr.io/...:latest` y ejecuta `bash iniciar.sh`. Si tienes [cosign](https://docs.sigstore.dev/cosign/system_config/installation/), verifica la firma automáticamente.

## 📁 Estructura

```
.
├── Dockerfile            # Imagen endurecida (python:3.12-slim + ffmpeg + node + yt-dlp)
├── docker-compose.yml    # Despliegue con todas las medidas de seguridad
├── .env.example          # Opcional: puerto y horas de retención (se copia solo a .env)
├── server.py             # Backend HTTP (solo librería estándar de Python)
├── public/index.html     # Interfaz web
├── _comun.sh             # Detecta Docker/sudo/compose
├── probar.sh             # Atajo a ci/revisar.sh
├── ci/                   # revisar.sh (motor CI Seguro), pruebas.sh (pruebas de este repo)
├── tests/smoke.sh        # Pruebas de funcionamiento y seguridad
├── ruff.toml             # Reglas del linter de Python (bugs + seguridad)
├── SECURITY.md           # Cómo reportar vulnerabilidades
├── .github/workflows/    # ci.yml (cada push) y release.yml (publicar versión)
├── .github/dependabot.yml
└── *.sh                  # Scripts de inicio / estado / parada
```

## ⚖️ Aviso

Úsalo solo con contenido que tengas derecho a descargar y respetando los términos de servicio de cada plataforma.

#!/usr/bin/env python3
"""
==============================================================================
Ivnonym Downloads - Local Media Server (Hardened & Ultra-Optimized)
YouTube, TikTok, Instagram, Twitter, etc.
Soporta: 4K (2160p), 2K (1440p), Full HD (1080p), HD (720p), SD (480p/360p)
         y Audio en MP3 (320kbps / 256kbps / 128kbps), M4A Original y WAV.
==============================================================================
"""

import os
import sys
import json
import uuid
import re
import shutil
import subprocess
import threading
import mimetypes
import time
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, quote

PORT = int(os.environ.get("PORT", 5050))
BASE_DIR = Path(__file__).resolve().parent
PUBLIC_DIR = BASE_DIR / "public"

# Almacén de trabajo DENTRO del contenedor (volumen Docker). El usuario elige
# dónde guardar cada archivo desde el navegador ("Guardar como"), así que aquí
# no hay ninguna ruta del equipo. Los archivos se borran solos pasado FILE_TTL_HOURS.
DOWNLOADS_DIR = Path(os.environ.get("DOWNLOAD_DIR") or "/downloads")
FILE_TTL_SECONDS = float(os.environ.get("FILE_TTL_HOURS", "3")) * 3600

try:
    DOWNLOADS_DIR.mkdir(parents=True, exist_ok=True)
except Exception:
    pass
if not os.access(DOWNLOADS_DIR, os.W_OK):
    print(f"❌ ERROR: no hay permiso de escritura en {DOWNLOADS_DIR}", file=sys.stderr)

# Temporales en disco (no en RAM) para que los videos 4K no llenen la memoria
TEMP_DIR = DOWNLOADS_DIR / ".tmp"
try:
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
except Exception:
    TEMP_DIR = Path("/tmp")  # noqa: S108 - /tmp es un tmpfs privado del contenedor

# Detectar ejecutables
YTDLP_BIN = shutil.which("yt-dlp") or str(Path.home() / ".local" / "bin" / "yt-dlp")
FFMPEG_BIN = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"
NODE_BIN = shutil.which("node") or "/usr/bin/node"

tasks_lock = threading.Lock()
tasks = {}
recent_history = []

def cleanup_old_files():
    """Borra del almacén temporal lo que tenga más de FILE_TTL_SECONDS."""
    while True:
        now = time.time()
        for root, _dirs, files in os.walk(DOWNLOADS_DIR):
            for name in files:
                fp = os.path.join(root, name)
                try:
                    if now - os.path.getmtime(fp) > FILE_TTL_SECONDS:
                        os.remove(fp)
                except OSError:
                    pass
        time.sleep(600)

def get_base_ytdlp_args():
    args = [
        YTDLP_BIN,
        "--newline",
        "--no-playlist",
        "--no-warnings"
    ]
    if os.path.exists(NODE_BIN):
        args.extend(["--no-js-runtimes", "--js-runtimes", f"node:{NODE_BIN}"])
    if os.path.exists(FFMPEG_BIN):
        args.extend(["--ffmpeg-location", FFMPEG_BIN])
    return args

def format_duration(seconds):
    if not seconds:
        return "N/A"
    seconds = int(seconds)
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h:d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"

def format_number(n):
    if not n:
        return "0"
    try:
        n = int(n)
        if n >= 1_000_000:
            return f"{n/1_000_000:.1f}M"
        if n >= 1_000:
            return f"{n/1_000:.1f}K"
        return f"{n:,}"
    except Exception:
        return str(n)

def format_bytes(b):
    if not b or b <= 0:
        return "N/A"
    if b >= 1024 * 1024 * 1024:
        return f"{b / (1024*1024*1024):.2f} GB"
    if b >= 1024 * 1024:
        return f"{b / (1024*1024):.1f} MB"
    if b >= 1024:
        return f"{b / 1024:.0f} KB"
    return f"{b} B"

def format_speed_str(speed_str):
    if not speed_str or speed_str == "NA" or speed_str == "...":
        return "Calculando..."
    s = speed_str.strip()
    s = s.replace("KiB/s", " KB/s").replace("MiB/s", " MB/s").replace("GiB/s", " GB/s")
    return s

def format_eta_str(eta_str):
    if not eta_str or eta_str == "NA" or eta_str == "...":
        return "Calculando..."
    parts = eta_str.strip().split(":")
    try:
        if len(parts) == 2:
            m, s = int(parts[0]), int(parts[1])
            if m == 0:
                return f"{s} seg"
            return f"{m} min {s:02d} seg"
        elif len(parts) == 3:
            h, m, s = int(parts[0]), int(parts[1]), int(parts[2])
            return f"{h}h {m:02d}m"
    except Exception:
        pass
    return eta_str

def parse_media_formats(raw_info):
    """
    Analiza la lista de formatos de yt-dlp y genera opciones estilo SnapYT / Ivnonym Downloads
    tanto para Video (MP4) como para Audio (MP3/M4A/WAV).
    """
    formats = raw_info.get("formats", [])
    duration = raw_info.get("duration") or 0

    # 1. Analizar mejor audio disponible para estimar tamaño combinado
    audio_formats = [f for f in formats if f.get("vcodec") == "none" and f.get("acodec") != "none"]
    best_audio = max(audio_formats, key=lambda f: f.get("abr") or 0) if audio_formats else None
    audio_size = (best_audio.get("filesize") or best_audio.get("filesize_approx") or 0) if best_audio else 0
    if not audio_size and duration and best_audio and best_audio.get("abr"):
        audio_size = int((best_audio["abr"] * 1000 / 8) * duration)

    # 2. Analizar resoluciones de video disponibles
    video_formats = [f for f in formats if f.get("vcodec") != "none" and f.get("height")]
    available_heights = sorted(list(set(f["height"] for f in video_formats)), reverse=True)

    resolution_specs = [
        {"height": 2160, "quality": "2160p", "title": "4K Ultra HD", "badge": "4K UHD", "note": "Máxima resolución"},
        {"height": 1440, "quality": "1440p", "title": "2K Quad HD",  "badge": "2K QHD", "note": "Alta nitidez"},
        {"height": 1080, "quality": "1080p", "title": "1080p Full HD", "badge": "Full HD", "note": "Recomendado (Óptimo)"},
        {"height": 720,  "quality": "720p",  "title": "720p HD",       "badge": "HD",      "note": "Rápido y ligero"},
        {"height": 480,  "quality": "480p",  "title": "480p SD",       "badge": "SD",      "note": "Menor tamaño"},
        {"height": 360,  "quality": "360p",  "title": "360p Ligero",   "badge": "Móvil",   "note": "Descarga instantánea"}
    ]

    video_options = []
    max_video_height = max(available_heights) if available_heights else 1080

    for spec in resolution_specs:
        h = spec["height"]
        if h > max_video_height and h not in available_heights:
            continue

        target_streams = [f for f in video_formats if f["height"] == h]
        if not target_streams:
            sub_matches = [f for f in video_formats if f["height"] < h]
            if not sub_matches:
                continue
            closest_h = max(f["height"] for f in sub_matches)
            target_streams = [f for f in video_formats if f["height"] == closest_h]

        if not target_streams:
            continue

        best_v = max(
            target_streams,
            key=lambda f: (
                1 if f.get("ext") == "mp4" else 0,
                f.get("fps") or 0,
                f.get("filesize") or f.get("filesize_approx") or (f.get("tbr") or 0)
            )
        )

        v_size = best_v.get("filesize") or best_v.get("filesize_approx") or 0
        if not v_size and duration and best_v.get("tbr"):
            v_size = int((best_v["tbr"] * 1000 / 8) * duration)

        total_bytes = (v_size + audio_size) if (v_size > 0) else 0
        fps = best_v.get("fps") or 30
        fps_label = f"{int(fps)}fps" if fps and fps > 30 else ""

        video_options.append({
            "quality": spec["quality"],
            "height": h,
            "title": spec["title"],
            "badge": f"{spec['badge']} {fps_label}".strip(),
            "note": spec["note"],
            "ext": "mp4",
            "fps": fps,
            "estimated_size": format_bytes(total_bytes) if total_bytes > 0 else "Calculando...",
            "estimated_bytes": total_bytes
        })

    if not video_options:
        video_options.append({
            "quality": "1080p",
            "height": 1080,
            "title": "Full HD (Máxima Calidad)",
            "badge": "Full HD",
            "note": "Calidad nativa recomendada",
            "ext": "mp4",
            "fps": 30,
            "estimated_size": format_bytes(audio_size * 4) if audio_size else "~150 MB",
            "estimated_bytes": 0
        })

    def calc_audio_size(kbps):
        if not duration:
            return "N/A"
        return format_bytes(int((kbps * 1000 / 8) * duration))

    audio_options = [
        {
            "quality": "320k",
            "format": "mp3",
            "title": "MP3 320 kbps (Máxima Fidelidad)",
            "badge": "Ultra 320k",
            "note": "Sonido estudio cristalino",
            "ext": "mp3",
            "estimated_size": calc_audio_size(320)
        },
        {
            "quality": "256k",
            "format": "mp3",
            "title": "MP3 256 kbps (Alta Calidad)",
            "badge": "HQ 256k",
            "note": "Excelente relación fidelidad/peso",
            "ext": "mp3",
            "estimated_size": calc_audio_size(256)
        },
        {
            "quality": "128k",
            "format": "mp3",
            "title": "MP3 128 kbps (Estándar / Rápido)",
            "badge": "128k",
            "note": "Descarga ultra ligera",
            "ext": "mp3",
            "estimated_size": calc_audio_size(128)
        },
        {
            "quality": "m4a",
            "format": "m4a",
            "title": "M4A Original (AAC sin recodificar)",
            "badge": "Direct AAC",
            "note": "Pista de audio nativa original",
            "ext": "m4a",
            "estimated_size": format_bytes(audio_size) if audio_size > 0 else calc_audio_size(160)
        },
        {
            "quality": "wav",
            "format": "wav",
            "title": "WAV (Audio Sin Pérdida)",
            "badge": "Lossless WAV",
            "note": "Audio sin compresión",
            "ext": "wav",
            "estimated_size": calc_audio_size(1411) if duration else "~70 MB"
        }
    ]

    return {
        "video_options": video_options,
        "audio_options": audio_options,
        "max_resolution": f"{max_video_height}p"
    }

def is_valid_url(url):
    """Solo acepta enlaces http(s); evita que se cuelen opciones de yt-dlp."""
    parsed = urlparse(url)
    return parsed.scheme in ("http", "https") and bool(parsed.netloc) and not url.startswith("-")

def run_download_thread(task_id, url, mode, quality):
    task = tasks[task_id]
    try:
        task["status"] = "downloading"
        task["message"] = "Conectando y analizando transmisiones de alta velocidad..."

        cmd = get_base_ytdlp_args()

        # Opciones avanzadas de descarga acelerada y progreso estructurado
        cmd.extend([
            "--concurrent-fragments", "5",
            "--paths", f"temp:{TEMP_DIR}",
            "--paths", f"home:{DOWNLOADS_DIR}",
            "--no-mtime",
            # Plantillas estructuradas para progreso en tiempo real
            "--progress-template", "download:PROG|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._percent_str)s",
            "--progress-template", "postprocess:POST|%(progress.status)s",
            # Captura de ruta final sin silenciar la salida
            "--exec", "after_move:echo FINALPATH:{}"
        ])

        if mode == "audio":
            if quality == "320k":
                task["mode_label"] = "Audio MP3 (320 kbps Ultra)"
                cmd.extend(["-x", "--audio-format", "mp3", "--audio-quality", "0", "--embed-thumbnail", "--embed-metadata"])
            elif quality == "256k":
                task["mode_label"] = "Audio MP3 (256 kbps HQ)"
                cmd.extend(["-x", "--audio-format", "mp3", "--audio-quality", "2", "--embed-thumbnail", "--embed-metadata"])
            elif quality == "128k":
                task["mode_label"] = "Audio MP3 (128 kbps)"
                cmd.extend(["-x", "--audio-format", "mp3", "--audio-quality", "5", "--embed-thumbnail", "--embed-metadata"])
            elif quality == "m4a":
                task["mode_label"] = "Audio M4A Original (AAC)"
                cmd.extend(["-x", "--audio-format", "m4a", "--embed-thumbnail", "--embed-metadata"])
            elif quality == "wav":
                task["mode_label"] = "Audio WAV (Lossless)"
                cmd.extend(["-x", "--audio-format", "wav"])
            else:
                task["mode_label"] = "Audio MP3 (320 kbps)"
                cmd.extend(["-x", "--audio-format", "mp3", "--audio-quality", "0", "--embed-thumbnail", "--embed-metadata"])

            out_tmpl = f"%(title).80B [%(id)s] [{quality}].%(ext)s"
            cmd.extend([
                "-o", out_tmpl,
                "--",
                url
            ])

        else: # Video
            h_str = quality.replace("p", "").strip()
            try:
                h_val = int(h_str)
            except Exception:
                h_val = 1080

            task["mode_label"] = f"Video {h_val}p MP4 (Full Calidad)"
            format_spec = f"bestvideo[height<={h_val}]+bestaudio/best[height<={h_val}]/best"

            out_tmpl = f"%(title).80B [%(id)s] [{h_val}p].%(ext)s"
            cmd.extend([
                "-f", format_spec,
                "--merge-output-format", "mp4",
                "--embed-metadata",
                "-o", out_tmpl,
                "--",
                url
            ])

        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"

        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env
        )

        final_path = None
        error_lines = []
        stream_index = 1
        last_stream_destination = ""

        for raw_line in process.stdout:
            line = raw_line.strip()
            if not line:
                continue

            # Detectar FINALPATH emitido por --exec
            if "FINALPATH:" in line:
                final_path = line.split("FINALPATH:", 1)[1].strip()

            # Detectar inicio de una pista (video o audio)
            if "[download] Destination:" in line:
                dest = line.split("Destination:", 1)[1].strip()
                if dest != last_stream_destination:
                    last_stream_destination = dest
                    if ".f" in dest:
                        stream_index = 2

            # Progreso estructurado desde yt-dlp
            if line.startswith("PROG|"):
                parts = line.split("|")
                if len(parts) >= 7:
                    dl_bytes_str = parts[1].strip()
                    tot_bytes_str = parts[2].strip()
                    tot_est_str = parts[3].strip()
                    speed_str = parts[4].strip()
                    eta_str = parts[5].strip()
                    pct_str = parts[6].strip()

                    # Calcular porcentaje numérico del stream actual
                    raw_pct = 0.0
                    if pct_str and pct_str != "NA":
                        try:
                            raw_pct = float(pct_str.replace("%", "").strip())
                        except Exception:
                            pass
                    elif dl_bytes_str.isdigit():
                        dl_b = int(dl_bytes_str)
                        tot_b = int(tot_bytes_str) if tot_bytes_str.isdigit() else (int(tot_est_str) if tot_est_str.isdigit() else 0)
                        if tot_b > 0:
                            raw_pct = (dl_b / tot_b) * 100.0

                    # Ponderación suave para videos con dos pistas (video + audio):
                    if mode == "video":
                        if stream_index == 1:
                            # Descargando video (0% a 88%)
                            mapped_pct = raw_pct * 0.88
                            stage_msg = f"Descargando video: {raw_pct:.1f}%"
                        else:
                            # Descargando audio (88% a 98%)
                            mapped_pct = 88.0 + (raw_pct * 0.10)
                            stage_msg = f"Descargando pista de audio: {raw_pct:.1f}%"
                    else:
                        # Audio directo (0% a 95%)
                        mapped_pct = raw_pct * 0.95
                        stage_msg = f"Descargando audio: {raw_pct:.1f}%"

                    clean_speed = format_speed_str(speed_str)
                    clean_eta = format_eta_str(eta_str)

                    # Formato de tamaño legible
                    dl_b = int(dl_bytes_str) if dl_bytes_str.isdigit() else 0
                    tot_b = int(tot_bytes_str) if tot_bytes_str.isdigit() else (int(tot_est_str) if tot_est_str.isdigit() else 0)
                    if dl_b > 0 and tot_b > 0:
                        size_display = f"{format_bytes(dl_b)} / {format_bytes(tot_b)}"
                    elif tot_b > 0:
                        size_display = f"Total: {format_bytes(tot_b)}"
                    else:
                        size_display = task.get("total_size", "Calculando...")

                    with tasks_lock:
                        task["percent"] = min(98.5, max(0.5, mapped_pct))
                        task["percent_str"] = f"{task['percent']:.1f}%"
                        task["speed"] = clean_speed
                        task["eta"] = clean_eta
                        task["total_size"] = size_display
                        task["status"] = "downloading"
                        task["message"] = f"{stage_msg} a {clean_speed} (Restante: {clean_eta})"

            elif "POST|" in line or "[Merger]" in line:
                with tasks_lock:
                    task["status"] = "processing"
                    task["percent"] = 99.0
                    task["message"] = "Uniendo pistas con FFmpeg en calidad nativa..."

            elif "[ExtractAudio]" in line:
                with tasks_lock:
                    task["status"] = "processing"
                    task["percent"] = 98.5
                    task["message"] = "Extrayendo y codificando audio en alta fidelidad..."

            elif "has already been downloaded" in line:
                with tasks_lock:
                    task["percent"] = 100.0
                    task["message"] = "El archivo ya se encontraba descargado."

            elif "ERROR:" in line or "Error:" in line:
                error_lines.append(line)

        process.wait()

        if process.returncode != 0:
            err_msg = " ".join(error_lines[-3:]) if error_lines else f"Código de salida {process.returncode}"
            with tasks_lock:
                task["status"] = "error"
                task["error_message"] = f"Error en la descarga: {err_msg}"
            return

        # Localizar el archivo resultante
        if not final_path or not os.path.exists(final_path):
            files = [f for f in DOWNLOADS_DIR.glob("*") if f.is_file() and not f.name.startswith(".") and not f.name.endswith(".part") and not f.name.endswith(".ytdl")]
            if files:
                latest = max(files, key=os.path.getmtime)
                final_path = str(latest)

        if final_path and os.path.exists(final_path):
            file_stat = os.stat(final_path)
            file_name = os.path.basename(final_path)
            with tasks_lock:
                task["status"] = "completed"
                task["percent"] = 100.0
                task["percent_str"] = "100%"
                task["message"] = "¡Descarga completada y lista!"
                task["final_path"] = final_path
                task["file_name"] = file_name
                task["file_size_bytes"] = file_stat.st_size
                task["file_size_str"] = format_bytes(file_stat.st_size)
                recent_history.insert(0, {
                    "id": task["id"],
                    "file_name": file_name,
                    "mode_label": task.get("mode_label", "Medio"),
                    "file_size_str": task["file_size_str"],
                    "timestamp": time.time()
                })
        else:
            with tasks_lock:
                task["status"] = "error"
                task["error_message"] = "No se pudo localizar el archivo en la carpeta de descargas."

    except Exception as e:
        with tasks_lock:
            task["status"] = "error"
            task["error_message"] = f"Error del sistema: {str(e)}"

class MediaServerHandler(BaseHTTPRequestHandler):
    def end_headers(self):
        # Sin CORS: la interfaz se sirve desde el mismo origen, asi que
        # ninguna otra web abierta en el navegador puede usar esta API.
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "/index.html":
            index_file = PUBLIC_DIR / "index.html"
            if index_file.exists():
                data = index_file.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)
            else:
                self.send_response(404)
                self.end_headers()
            return

        if path == "/api/status":
            ytdlp_ver = "Desconocido"
            try:
                res = subprocess.run([YTDLP_BIN, "--version"], capture_output=True, text=True, check=True)
                ytdlp_ver = res.stdout.strip()
            except Exception:
                pass

            self.send_json({
                "online": True,
                "ytdlp_version": ytdlp_ver,
                "ffmpeg_available": os.path.exists(FFMPEG_BIN),
                "node_available": os.path.exists(NODE_BIN),
                "file_ttl_hours": FILE_TTL_SECONDS / 3600,
                "containerized": os.path.exists("/.dockerenv") or os.environ.get("CONTAINERIZED") == "true"
            })
            return

        if path == "/api/progress":
            qs = parse_qs(parsed.query)
            task_id = qs.get("id", [None])[0]
            if not task_id or task_id not in tasks:
                self.send_json({"error": "Tarea no encontrada"}, status=404)
                return
            with tasks_lock:
                task_copy = dict(tasks[task_id])
            self.send_json(task_copy)
            return

        if path == "/api/history":
            with tasks_lock:
                hist_copy = list(recent_history[:20])
            self.send_json({"history": hist_copy})
            return

        if path.startswith("/api/file/"):
            task_id = path.replace("/api/file/", "").strip()
            task = tasks.get(task_id)
            if not task or task.get("status") != "completed":
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Archivo no disponible.")
                return

            filepath = task.get("final_path")
            if not filepath or not os.path.exists(filepath):
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Archivo no encontrado en almacenamiento.")
                return

            filename = os.path.basename(filepath)
            filesize = os.path.getsize(filepath)
            mime_type, _ = mimetypes.guess_type(filepath)
            mime_type = mime_type or "application/octet-stream"

            range_header = self.headers.get("Range")
            if range_header and range_header.startswith("bytes="):
                range_match = re.match(r"bytes=(\d+)-(\d*)", range_header)
                if range_match:
                    start = int(range_match.group(1))
                    end = int(range_match.group(2)) if range_match.group(2) else filesize - 1
                    end = min(end, filesize - 1)
                    length = end - start + 1

                    self.send_response(206)
                    self.send_header("Content-Type", mime_type)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{filesize}")
                    self.send_header("Content-Length", str(length))
                    self.send_header("Accept-Ranges", "bytes")
                    self.end_headers()

                    if self.command != "HEAD":
                        with open(filepath, "rb") as f:
                            f.seek(start)
                            chunk_size = 64 * 1024
                            remaining = length
                            while remaining > 0:
                                read_bytes = min(remaining, chunk_size)
                                chunk = f.read(read_bytes)
                                if not chunk:
                                    break
                                self.wfile.write(chunk)
                                remaining -= len(chunk)
                    return

            self.send_response(200)
            self.send_header("Content-Type", mime_type)
            self.send_header("Content-Length", str(filesize))
            self.send_header("Accept-Ranges", "bytes")
            ascii_filename = filename.encode('ascii', 'ignore').decode('ascii').replace('"', '').strip() or "descarga"
            encoded_filename = quote(filename)
            self.send_header("Content-Disposition", f'attachment; filename="{ascii_filename}"; filename*=UTF-8\'\'{encoded_filename}')
            self.end_headers()

            if self.command != "HEAD":
                with open(filepath, "rb") as f:
                    shutil.copyfileobj(f, self.wfile)
            return

        clean_path = path.lstrip("/")
        static_file = PUBLIC_DIR / clean_path
        if static_file.is_file() and static_file.resolve().is_relative_to(PUBLIC_DIR.resolve()):
            mime_type, _ = mimetypes.guess_type(str(static_file))
            mime_type = mime_type or "application/octet-stream"
            data = static_file.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", mime_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception:
            payload = {}

        if path == "/api/info":
            raw_url = payload.get("url", "").strip()
            if not raw_url or not is_valid_url(raw_url):
                self.send_json({"error": "Por favor ingresa una URL válida."}, status=400)
                return

            cmd = get_base_ytdlp_args() + [
                "--dump-single-json",
                "--",
                raw_url
            ]

            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                if proc.returncode != 0:
                    err = proc.stderr.strip() or "Error al analizar el enlace multimedia"
                    clean_err = err.split("ERROR:")[-1].strip() if "ERROR:" in err else err
                    self.send_json({"error": clean_err}, status=400)
                    return

                raw_info = json.loads(proc.stdout)
                formats_data = parse_media_formats(raw_info)

                res = {
                    "id": raw_info.get("id"),
                    "title": raw_info.get("title", "Sin título"),
                    "thumbnail": raw_info.get("thumbnail"),
                    "duration": raw_info.get("duration"),
                    "duration_str": format_duration(raw_info.get("duration")),
                    "uploader": raw_info.get("uploader") or raw_info.get("channel") or raw_info.get("creator") or "Autor desconocido",
                    "channel_url": raw_info.get("channel_url") or raw_info.get("uploader_url"),
                    "view_count": format_number(raw_info.get("view_count")),
                    "upload_date": raw_info.get("upload_date"),
                    "extractor": raw_info.get("extractor_key") or raw_info.get("extractor") or "General",
                    "webpage_url": raw_info.get("webpage_url") or raw_url,
                    "video_options": formats_data["video_options"],
                    "audio_options": formats_data["audio_options"],
                    "max_resolution": formats_data["max_resolution"]
                }
                self.send_json(res)
            except subprocess.TimeoutExpired:
                self.send_json({"error": "Tiempo de espera agotado al conectar con el servidor multimedia."}, status=504)
            except Exception as e:
                self.send_json({"error": f"Error procesando información: {str(e)}"}, status=500)
            return

        if path == "/api/download":
            raw_url = payload.get("url", "").strip()
            mode = payload.get("format", "video") # 'video' o 'audio'
            quality = payload.get("quality", "1080p")
            if not raw_url or not is_valid_url(raw_url):
                self.send_json({"error": "URL requerida (http/https)"}, status=400)
                return

            task_id = str(uuid.uuid4())
            with tasks_lock:
                tasks[task_id] = {
                    "id": task_id,
                    "url": raw_url,
                    "mode": mode,
                    "quality": quality,
                    "status": "queued",
                    "percent": 0.0,
                    "percent_str": "0%",
                    "speed": "Calculando...",
                    "eta": "Calculando...",
                    "total_size": "Calculando...",
                    "message": "En cola...",
                    "final_path": None,
                    "file_name": None,
                    "error_message": None
                }

            worker = threading.Thread(
                target=run_download_thread,
                args=(task_id, raw_url, mode, quality),
                daemon=True
            )
            worker.start()

            self.send_json({
                "success": True,
                "task_id": task_id,
                "message": "Descarga iniciada"
            })
            return


        self.send_response(404)
        self.end_headers()

def main():
    print("=" * 65)
    print("   🛡️ IVNONYM DOWNLOADS - SERVER (HARDENED & OPTIMIZED)")
    print("=" * 65)
    print(f" * Backend:        Python {sys.version.split()[0]}")
    print(f" * yt-dlp:         {YTDLP_BIN}")
    print(f" * FFmpeg:         {FFMPEG_BIN}")
    print(f" * Node.js:        {NODE_BIN}")
    print(f" * Almacén temp.:  {DOWNLOADS_DIR} (se vacía cada {FILE_TTL_SECONDS/3600:g} h)")
    print(f" * Temporal:       {TEMP_DIR}")
    print(f" * Puerto:         {PORT}")
    print(f" * Acceso Web:     http://127.0.0.1:{PORT}")
    print("=" * 65)

    threading.Thread(target=cleanup_old_files, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), MediaServerHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nCerrando servidor...")
        server.server_close()

if __name__ == "__main__":
    main()

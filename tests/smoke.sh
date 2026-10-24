#!/usr/bin/env bash
# Pruebas de humo contra un contenedor YA arrancado.
#   uso: bash tests/smoke.sh http://127.0.0.1:5050 [URL_DE_VIDEO_DE_PRUEBA]
set -uo pipefail
BASE="${1:?Uso: smoke.sh BASE_URL [VIDEO_URL]}"
VIDEO_URL="${2:-}"
FALLOS=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
mal()  { printf '  \033[31m✘\033[0m %s\n' "$1"; FALLOS=$((FALLOS+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else mal "$1"; fi; }
post() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2"; }

echo "▶ Funcionamiento básico"
check "API responde"                       "curl -sf $BASE/api/status | grep -q '\"online\": true'"
check "ffmpeg disponible"                  "curl -sf $BASE/api/status | grep -q '\"ffmpeg_available\": true'"
check "Node.js disponible (retos JS)"      "curl -sf $BASE/api/status | grep -q '\"node_available\": true'"
check "Sirve la interfaz web"              "curl -sf $BASE/ | grep -q 'Ivnonym'"

echo "▶ Seguridad"
check "Sin cabecera CORS (otras webs no pueden usar la API)" \
      "! curl -sI $BASE/ | grep -qi 'access-control-allow-origin'"
check "Rechaza opciones de yt-dlp como URL (--exec)" "[ \"\$(post /api/info '{\"url\":\"--exec=id\"}')\" = 400 ]"
check "Rechaza file:// (lectura de archivos)"        "[ \"\$(post /api/info '{\"url\":\"file:///etc/passwd\"}')\" = 400 ]"
check "Rechaza descargas sin URL válida"             "[ \"\$(post /api/download '{\"url\":\"-o /tmp/x\"}')\" = 400 ]"
check "No permite salir de public/ (path traversal)" \
      "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --path-as-is $BASE/../server.py)\" = 404 ]"
check "No sirve archivos de tareas inexistentes"      "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $BASE/api/file/no-existe)\" = 404 ]"

if [ -n "$VIDEO_URL" ]; then
    echo "▶ Descarga real (audio MP3 desde $VIDEO_URL)"
    ID=$(curl -s -X POST "$BASE/api/download" -H 'Content-Type: application/json' \
         -d "{\"url\":\"$VIDEO_URL\",\"format\":\"audio\",\"quality\":\"128k\"}" \
         | python3 -c 'import sys,json;print(json.load(sys.stdin).get("task_id",""))')
    ESTADO=""
    for _ in $(seq 1 60); do
        ESTADO=$(curl -s "$BASE/api/progress?id=$ID" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))')
        [ "$ESTADO" = completed ] || [ "$ESTADO" = error ] && break
        sleep 2
    done
    check "La descarga termina bien"  "[ '$ESTADO' = completed ]"
    check "El archivo se entrega como descarga (Guardar como)" \
          "curl -sD - -o /dev/null $BASE/api/file/$ID | grep -qi 'content-disposition: attachment'"
    check "El MP3 no está vacío" "[ \$(curl -s $BASE/api/file/$ID | wc -c) -gt 10000 ]"
fi

echo
if [ "$FALLOS" -eq 0 ]; then echo "✅ Todas las pruebas pasaron"; else echo "❌ $FALLOS prueba(s) fallaron"; exit 1; fi

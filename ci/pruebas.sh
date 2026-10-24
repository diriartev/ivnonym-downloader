#!/usr/bin/env bash
# ==============================================================================
#  Pruebas propias de Ivnonym Downloader (las ejecuta ci/revisar.sh, etapa "pruebas").
#  Levanta la app con su docker-compose ENDURECIDO real y prueba la API, incluida
#  una descarga completa de un video generado en el momento (sin internet).
#  Recibe $IMAGEN: la imagen recién construida.
# ==============================================================================
set -euo pipefail
# shellcheck source=../_comun.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_comun.sh"     # Docker/Compose con o sin sudo; se sitúa en la raíz
D=("${DOCKER[@]}")
IMAGEN="${IMAGEN:?falta la variable IMAGEN}"
PUERTO_PRUEBAS="${PUERTO_PRUEBAS:-15050}"
PROYECTO="ivnonym-downloader-ci"
FIX=""

limpiar() {
    IMAGE="$IMAGEN" PORT="$PUERTO_PRUEBAS" "${COMPOSE[@]}" -p "$PROYECTO" down -v --remove-orphans >/dev/null 2>&1 || true
    "${D[@]}" rm -f "$PROYECTO-fixtures" >/dev/null 2>&1 || true
    [ -z "$FIX" ] || rm -rf "$FIX"
}
trap limpiar EXIT
limpiar

IMAGE="$IMAGEN" PORT="$PUERTO_PRUEBAS" "${COMPOSE[@]}" -p "$PROYECTO" up -d --no-build
BASE="http://127.0.0.1:$PUERTO_PRUEBAS"
for _ in $(seq 1 90); do curl -sf "$BASE/api/status" >/dev/null 2>&1 && break; sleep 1; done

# Video de prueba generado en el momento (no depende de YouTube ni de internet)
FIX=$(mktemp -d)
chmod 755 "$FIX"
"${D[@]}" run --rm --user "$(id -u):$(id -g)" --entrypoint ffmpeg -v "$FIX:/out:z" "$IMAGEN" -loglevel error \
    -f lavfi -i testsrc=duration=3:size=320x240:rate=25 -f lavfi -i sine=frequency=440:duration=3 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /out/prueba.mp4 2>/dev/null \
  || "${D[@]}" run --rm --user "$(id -u):$(id -g)" --entrypoint ffmpeg -v "$FIX:/out:z" "$IMAGEN" -loglevel error \
    -f lavfi -i testsrc=duration=3:size=320x240:rate=25 -f lavfi -i sine=frequency=440:duration=3 \
    -c:v mpeg4 -c:a aac -shortest /out/prueba.mp4
chmod 644 "$FIX/prueba.mp4"
"${D[@]}" run -d --name "$PROYECTO-fixtures" --network "${PROYECTO}_default" --network-alias fixtures \
    -v "$FIX:/srv:ro,z" --entrypoint python3 "$IMAGEN" -m http.server 8000 -d /srv >/dev/null
sleep 1
bash tests/smoke.sh "$BASE" "http://fixtures:8000/prueba.mp4"

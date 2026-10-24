#!/usr/bin/env bash
# ==============================================================================
#  EJEMPLO de pruebas propias. Cópialo a ci/pruebas.sh y adáptalo a tu proyecto.
#  revisar.sh lo ejecuta en la etapa "pruebas" (en tu PC y en GitHub) y te pasa:
#    $IMAGEN  -> la imagen Docker recién construida (si el repo tiene Dockerfile)
#  Si este script termina con error, el pipeline se detiene y NO se publica nada.
# ==============================================================================
set -euo pipefail

# --- Ejemplo 1: proyecto Python con pytest (sin Docker) ---
# python3 -m venv /tmp/venv-ci && . /tmp/venv-ci/bin/activate
# pip install -r requirements.txt pytest
# pytest -q

# --- Ejemplo 2: proyecto Node ---
# npm ci && npm test

# --- Ejemplo 3: servicio web en Docker, endurecido, y una petición de prueba ---
# docker run -d --name prueba-ci --read-only --tmpfs /tmp --cap-drop ALL \
#     --security-opt no-new-privileges -p 127.0.0.1:18080:8080 "$IMAGEN"
# trap 'docker rm -f prueba-ci >/dev/null' EXIT
# for _ in $(seq 1 60); do curl -sf http://127.0.0.1:18080/health && break; sleep 1; done
# curl -sf http://127.0.0.1:18080/health | grep -q ok

echo "Sustituye este ejemplo por tus pruebas reales"

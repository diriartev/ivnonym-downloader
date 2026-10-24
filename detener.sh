#!/usr/bin/env bash
# Detiene y elimina el contenedor (tus descargas no se tocan)
set -e
source "$(dirname "${BASH_SOURCE[0]}")/_comun.sh"
"${COMPOSE[@]}" down
echo "✅ Contenedor detenido."

#!/usr/bin/env bash
# Muestra estado, salud y consumo del contenedor
source "$(dirname "${BASH_SOURCE[0]}")/_comun.sh"
"${COMPOSE[@]}" ps
if curl -sf "http://127.0.0.1:$PORT/api/status" >/dev/null 2>&1; then
    echo "🌐 http://127.0.0.1:$PORT"
    curl -s "http://127.0.0.1:$PORT/api/status" | python3 -m json.tool 2>/dev/null || true
else
    echo "🔴 El servicio no responde en http://127.0.0.1:$PORT"
fi

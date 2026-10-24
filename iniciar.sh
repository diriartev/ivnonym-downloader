#!/usr/bin/env bash
# Construye (la primera vez) y arranca el contenedor, y abre la web.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/_comun.sh"

if [[ "${IMAGE:-}" == ghcr.io/* ]]; then
    # Imagen publicada por el pipeline (probada, escaneada y firmada)
    if command -v cosign >/dev/null 2>&1; then
        echo "🔏 Verificando la firma de $IMAGE ..."
        cosign verify "$IMAGE" \
            --certificate-identity-regexp "^https://github.com/diriartev/ivnonym-downloader/.github/workflows/release.yml@refs/tags/" \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null
        echo "✔ Firma válida"
    fi
    "${COMPOSE[@]}" pull
    "${COMPOSE[@]}" up -d --no-build
else
    "${COMPOSE[@]}" up -d --build
fi

echo "Esperando a que responda http://127.0.0.1:$PORT ..."
for _ in {1..60}; do
    if curl -sf "http://127.0.0.1:$PORT/api/status" >/dev/null 2>&1; then
        echo "✅ Ivnonym Downloader activo en http://127.0.0.1:$PORT"
        echo "💾 Al terminar cada descarga, pulsa \"Elegir dónde guardar\"."
        (xdg-open "http://127.0.0.1:$PORT" >/dev/null 2>&1 || true) &
        exit 0
    fi
    sleep 1
done
echo "⚠️  Tardó en responder. Revisa:  ${COMPOSE[*]} logs"
exit 1

#!/usr/bin/env bash
# Funciones compartidas por los scripts. No lo ejecutes directamente.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# --- Docker instalado y accesible (con o sin sudo) ---
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker no está instalado."
    echo "   Ubuntu/Debian:  curl -fsSL https://get.docker.com | sudo sh"
    echo "   Fedora:         sudo dnf install docker-ce docker-compose-plugin  (o moby-engine)"
    exit 1
fi
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    if sudo docker info >/dev/null 2>&1; then
        DOCKER=(sudo docker)
        echo "ℹ️  Usando sudo para Docker. Para no necesitarlo: sudo usermod -aG docker \$USER y reinicia sesión."
    else
        echo "❌ Docker no responde. Arráncalo con:  sudo systemctl enable --now docker"
        exit 1
    fi
fi

# --- Docker Compose v2 (plugin) o v1 (docker-compose) ---
# shellcheck disable=SC2034  # COMPOSE lo usan los scripts que cargan este archivo
if "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    COMPOSE=("${DOCKER[@]}" compose)
elif command -v docker-compose >/dev/null 2>&1; then
    if [ "${DOCKER[0]}" = "sudo" ]; then COMPOSE=(sudo docker-compose); else COMPOSE=(docker-compose); fi
else
    echo "❌ Falta Docker Compose."
    echo "   Ubuntu/Debian:  sudo apt install docker-compose-plugin   (o: sudo apt install docker-compose-v2)"
    exit 1
fi

# --- .env: se crea solo la primera vez ---
if [ ! -f .env ]; then
    cp .env.example .env
    echo "ℹ️  Creado .env a partir de .env.example"
fi
set -a; . ./.env; set +a
PORT="${PORT:-5050}"

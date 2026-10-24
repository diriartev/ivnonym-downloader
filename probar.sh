#!/usr/bin/env bash
# Atajo: el pipeline completo es ci/revisar.sh (CI Seguro, el mismo que corre GitHub).
#   bash probar.sh                 -> todo
#   bash probar.sh secretos lint   -> solo esas etapas
exec bash "$(dirname "${BASH_SOURCE[0]}")/ci/revisar.sh" "$@"

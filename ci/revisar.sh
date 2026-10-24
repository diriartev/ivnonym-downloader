#!/usr/bin/env bash
# ==============================================================================
#  CI Seguro · motor universal de revisión
#  El MISMO script corre en tu PC (bash ci/revisar.sh) y en GitHub Actions.
#  Detecta solo qué hay en el repo (Python, Bash, Docker, workflows, dependencias)
#  y aplica las revisiones que tocan. No lo edites aquí: se actualiza con
#  `git ci-seguro` (reinstala la última versión del kit).
#
#    bash ci/revisar.sh                 -> todas las etapas
#    bash ci/revisar.sh secretos lint   -> solo esas
#    bash ci/revisar.sh info            -> qué detectó (no revisa nada)
#
#  Etapas: secretos lint config deps build pruebas vulnerabilidades
#  Ajustes opcionales del repo: ci/ajustes.conf  ·  Pruebas propias: ci/pruebas.sh
# ==============================================================================
set -euo pipefail
VERSION_KIT="1.0.0"

RAIZ=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$RAIZ"

# --- Herramientas fijadas por digest (nadie puede cambiarlas por detrás) ---
GITLEAKS=zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f      # v8.30.1
RUFF=ghcr.io/astral-sh/ruff@sha256:0f9316141d252f8c4de3fb672e8433c1afbf9adb24b877ae887cffa4012d850c       # 0.17.0
SHELLCHECK=koalaman/shellcheck@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d  # v0.11.0
HADOLINT=hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d      # v2.15.1
TRIVY=aquasec/trivy@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa            # 0.75.0
ACTIONLINT=rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667       # 1.7.12

titulo() { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$*"; }
bien()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
omite()  { printf '\033[2m– %s\033[0m\n' "$*"; }
falla()  { printf '\033[1;31m❌ %s\033[0m\n' "$*"; exit 1; }

# --- Ajustes del repo (ci/ajustes.conf). Se LEEN, no se ejecutan: solo claves conocidas ---
DOCKERFILE="Dockerfile"
CONTEXTO="."
SEVERIDAD_FALLO="CRITICAL"      # nivel que bloquea en deps/vulnerabilidades (CRITICAL o HIGH,CRITICAL)
OMITIR=""                       # etapas a saltar, separadas por espacios (p. ej. "deps")
LIBERAR_ESPACIO="0"             # 1 = en GitHub, liberar disco antes de construir (imágenes grandes)
if [ -f ci/ajustes.conf ]; then
    while IFS='=' read -r clave valor; do
        clave=$(printf '%s' "$clave" | tr -d '[:space:]')
        valor=$(printf '%s' "${valor:-}" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/')
        case "$clave" in
            ''|\#*) ;;
            DOCKERFILE|CONTEXTO|SEVERIDAD_FALLO|OMITIR|LIBERAR_ESPACIO) printf -v "$clave" '%s' "$valor" ;;
            *) echo "⚠️  ci/ajustes.conf: clave desconocida '$clave' (se ignora)" >&2 ;;
        esac
    done < ci/ajustes.conf
fi
case "$SEVERIDAD_FALLO" in CRITICAL|HIGH,CRITICAL) ;; *) falla "SEVERIDAD_FALLO debe ser CRITICAL o HIGH,CRITICAL" ;; esac
case "$DOCKERFILE$CONTEXTO" in *..*|/*) falla "DOCKERFILE y CONTEXTO deben ser rutas dentro del repo" ;; esac

NOMBRE=$(basename "$RAIZ" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._\n-' '-')
IMAGEN="${IMAGEN_PRUEBA:-$NOMBRE:ci}"

# --- Qué contiene el repo (archivos versionados; si no es git, todo el árbol) ---
if git rev-parse --git-dir >/dev/null 2>&1; then
    archivos() { git ls-files -- "$@"; }
else
    archivos() {
        local args=() p
        for p in "$@"; do args+=(-o -path "./$p"); done
        find . -type f \( "${args[@]:1}" \) -not -path './.git/*' | sed 's|^\./||'
    }
fi
mapfile -t PY   < <(archivos '*.py')
mapfile -t SH   < <(archivos '*.sh' '*.bash')
mapfile -t DOCK < <(archivos 'Dockerfile' '*/Dockerfile' 'Dockerfile.*' '*.Dockerfile' '*/*.Dockerfile')
mapfile -t WF   < <(archivos '.github/workflows/*.yml' '.github/workflows/*.yaml')
TIENE_DOCKER=0; [ -f "$DOCKERFILE" ] && TIENE_DOCKER=1

# --- Docker (con o sin sudo) ---
preparar_docker() {
    [ -n "${D+x}" ] && return 0
    command -v docker >/dev/null 2>&1 || falla "Docker no está instalado (las herramientas corren en contenedores)."
    if docker info >/dev/null 2>&1; then D=(docker)
    elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then D=(sudo docker)
    else falla "Docker no responde. Arráncalo con: sudo systemctl enable --now docker"; fi
    YO=(--user "$(id -u):$(id -g)")
    TRIVY_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/trivy"
    mkdir -p "$TRIVY_CACHE"
    # trivy corre con TU usuario (no root) y con espejo de respaldo para su base de datos
    TRIVY_RUN=("${YO[@]}" -e HOME=/tmp -e TRIVY_CACHE_DIR=/cache -v "$TRIVY_CACHE:/cache:z")
    TRIVY_DB=(--db-repository "mirror.gcr.io/aquasec/trivy-db:2,ghcr.io/aquasec/trivy-db:2")
    TRIVY_IGN=()
    if [ -f .trivyignore ]; then TRIVY_IGN=(--ignorefile /repo/.trivyignore); fi
}

etapa_info() {
    echo "kit=$VERSION_KIT"
    echo "nombre=$NOMBRE"
    echo "archivos_python=${#PY[@]}"
    echo "archivos_shell=${#SH[@]}"
    echo "archivos_dockerfile=${#DOCK[@]}"
    echo "archivos_workflow=${#WF[@]}"
    echo "docker=$([ "$TIENE_DOCKER" = 1 ] && echo true || echo false)"
    echo "dockerfile=$DOCKERFILE"
    echo "contexto=$CONTEXTO"
    echo "pruebas_propias=$([ -f ci/pruebas.sh ] && echo true || echo false)"
    echo "liberar_espacio=$LIBERAR_ESPACIO"
}

etapa_secretos() {
    titulo "1. Secretos (gitleaks)"
    preparar_docker
    if git rev-parse --git-dir >/dev/null 2>&1; then
        # TODO el historial: lo que se sube con push son commits, no la carpeta
        "${D[@]}" run --rm "${YO[@]}" -v "$RAIZ:/repo:ro,z" -e GIT_CONFIG_COUNT=1 \
            -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
            "$GITLEAKS" git /repo --no-banner --redact -v \
            || falla "Hay secretos en el historial. Revócalos YA en su servicio y luego límpialos."
    else
        "${D[@]}" run --rm "${YO[@]}" -v "$RAIZ:/repo:ro,z" "$GITLEAKS" dir /repo --no-banner --redact -v \
            || falla "Hay secretos en la carpeta."
    fi
    bien "Sin secretos"
}

etapa_lint() {
    titulo "2. Calidad y seguridad del código"
    preparar_docker
    if [ ${#PY[@]} -gt 0 ]; then
        if [ -f ruff.toml ] || [ -f .ruff.toml ] || grep -qs '^\[tool\.ruff' pyproject.toml; then
            REGLAS=()     # el repo trae su propia configuración
        else
            # Por defecto: errores que rompen el programa (E9, F63, F7, F82) + seguridad (S = bandit)
            REGLAS=(--select "E9,F63,F7,F82,S" --ignore "S101,S104,S110,S311,S603,S607")
        fi
        "${D[@]}" run --rm -v "$RAIZ:/io:ro,z" -w /io "$RUFF" check --no-cache --output-format concise "${REGLAS[@]}" .
        bien "Python: ruff + reglas de seguridad (${#PY[@]} archivos)"
    else omite "Python: no hay archivos .py"; fi

    if [ ${#SH[@]} -gt 0 ]; then
        "${D[@]}" run --rm -v "$RAIZ:/mnt:ro,z" -w /mnt "$SHELLCHECK" -x -S warning "${SH[@]}"
        bien "Bash: shellcheck (${#SH[@]} archivos)"
    else omite "Bash: no hay scripts .sh"; fi

    if [ ${#DOCK[@]} -gt 0 ]; then
        # Se monta el repo para que hadolint lea .hadolint.yaml si existe
        "${D[@]}" run --rm -v "$RAIZ:/repo:ro,z" -w /repo "$HADOLINT" hadolint "${DOCK[@]}"
        bien "Dockerfile: hadolint (${#DOCK[@]} archivos)"
    else omite "Dockerfile: no hay"; fi

    if [ ${#WF[@]} -gt 0 ]; then
        "${D[@]}" run --rm -v "$RAIZ:/repo:ro,z" -w /repo "$ACTIONLINT" -color "${WF[@]}"
        # Cada acción externa debe ir fijada por hash de commit (40 caracteres), no por etiqueta
        SIN_FIJAR=$(grep -nE '^\s*-?\s*uses:\s*[^.#[:space:]][^@[:space:]]*@' "${WF[@]}" \
                    | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' | grep -v 'docker://' || true)
        [ -z "$SIN_FIJAR" ] || { echo "$SIN_FIJAR"; falla "Acciones sin fijar por hash (usa @<sha de 40 caracteres> # vX)"; }
        bien "Workflows: actionlint + acciones fijadas por hash (${#WF[@]} archivos)"
    else omite "Workflows: no hay"; fi
}

etapa_config() {
    titulo "3. Configuración: Docker, compose, Kubernetes, Terraform… (trivy config)"
    preparar_docker
    "${D[@]}" run --rm "${TRIVY_RUN[@]}" -v "$RAIZ:/repo:ro,z" -w /repo "$TRIVY" \
        config --quiet "${TRIVY_IGN[@]}" --severity HIGH,CRITICAL --exit-code 1 /repo \
        || falla "Configuración insegura (arriba el detalle y cómo arreglarla)."
    bien "Sin malas configuraciones graves"
}

etapa_deps() {
    titulo "4. Dependencias con vulnerabilidades conocidas (trivy fs)"
    preparar_docker
    # Lee requirements.txt, package-lock.json, go.sum, Cargo.lock, poetry.lock, composer.lock…
    "${D[@]}" run --rm "${TRIVY_RUN[@]}" -v "$RAIZ:/repo:ro,z" -w /repo "$TRIVY" \
        fs --quiet --scanners vuln --ignore-unfixed "${TRIVY_DB[@]}" "${TRIVY_IGN[@]}" --severity HIGH,CRITICAL --exit-code 0 /repo
    "${D[@]}" run --rm "${TRIVY_RUN[@]}" -v "$RAIZ:/repo:ro,z" -w /repo "$TRIVY" \
        fs --quiet --scanners vuln --ignore-unfixed "${TRIVY_DB[@]}" "${TRIVY_IGN[@]}" --severity "$SEVERIDAD_FALLO" --exit-code 1 /repo >/dev/null \
        || falla "Dependencias con vulnerabilidades $SEVERIDAD_FALLO que YA tienen parche: actualízalas."
    bien "Dependencias sin vulnerabilidades $SEVERIDAD_FALLO parcheables"
}

etapa_espacio() {
    # Solo en GitHub y solo si el repo lo pide (imágenes de varios GB)
    [ "${GITHUB_ACTIONS:-}" = true ] && [ "$LIBERAR_ESPACIO" = 1 ] || return 0
    titulo "Liberar disco del runner"
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL
    docker system prune -af >/dev/null
    df -h /
}

etapa_build() {
    titulo "5. Construir imagen ($IMAGEN)"
    [ "$TIENE_DOCKER" = 1 ] || { omite "No hay $DOCKERFILE: nada que construir"; return 0; }
    [ -z "${IMAGEN_PRUEBA:-}" ] || { omite "Se usa la imagen ya construida $IMAGEN_PRUEBA"; return 0; }
    preparar_docker
    "${D[@]}" build -t "$IMAGEN" -f "$DOCKERFILE" "$CONTEXTO"
    bien "Imagen construida"
}

prueba_generica() {
    # Sin pruebas propias: comprobar que la imagen arranca ENDURECIDA y no se cae
    local c="$NOMBRE-ci-arranque" usuario estado="" salud="" i
    usuario=$("${D[@]}" image inspect -f '{{.Config.User}}' "$IMAGEN")
    case "$usuario" in ''|root|0|0:*|root:*) falla "La imagen corre como root: añade USER en el $DOCKERFILE" ;; esac
    "${D[@]}" rm -f "$c" >/dev/null 2>&1 || true
    trap '"${D[@]}" rm -f "'"$c"'" >/dev/null 2>&1 || true' EXIT
    "${D[@]}" run -d --name "$c" --cap-drop ALL --security-opt no-new-privileges --network none "$IMAGEN" >/dev/null
    for i in $(seq 1 90); do
        estado=$("${D[@]}" inspect -f '{{.State.Status}}' "$c")
        salud=$("${D[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c")
        [ "$estado" = exited ] && break
        [ "$salud" = healthy ] && break
        [ -z "$salud" ] && [ "$i" -ge 10 ] && break       # sin HEALTHCHECK: basta con seguir vivo 10 s
        sleep 1
    done
    if [ "$estado" = exited ] && [ "$("${D[@]}" inspect -f '{{.State.ExitCode}}' "$c")" != 0 ]; then
        "${D[@]}" logs --tail 30 "$c"; falla "El contenedor se cayó al arrancar"
    fi
    if [ "$salud" = unhealthy ]; then "${D[@]}" logs --tail 30 "$c"; falla "El HEALTHCHECK dice que no está sano"; fi
    "${D[@]}" rm -f "$c" >/dev/null; trap - EXIT
    bien "Arranca sin root, sin privilegios y sin red (${salud:-$estado})"
}

etapa_pruebas() {
    titulo "6. Pruebas"
    if [ -f ci/pruebas.sh ]; then
        echo "▶ Pruebas propias del repo (ci/pruebas.sh)"
        IMAGEN="$IMAGEN" bash ci/pruebas.sh || falla "Fallaron las pruebas del repo"
        bien "Pruebas del repo OK"
    elif [ "$TIENE_DOCKER" = 1 ]; then
        preparar_docker
        echo "▶ Prueba genérica de arranque (añade ci/pruebas.sh para pruebas reales)"
        prueba_generica
    else
        omite "Sin pruebas: crea ci/pruebas.sh (ver ci/pruebas.ejemplo.sh)"
    fi
}

etapa_vulnerabilidades() {
    titulo "7. Vulnerabilidades de la imagen (trivy image)"
    [ "$TIENE_DOCKER" = 1 ] || { omite "No hay imagen"; return 0; }
    preparar_docker
    TAR=$(mktemp -p "${TMPDIR:-/tmp}" imagen-XXXX.tar)
    "${D[@]}" save "$IMAGEN" -o "$TAR"
    R=0
    "${D[@]}" run --rm "${TRIVY_RUN[@]}" -v "$TAR:/img.tar:ro,z" -v "$RAIZ:/repo:ro,z" -w /repo "$TRIVY" \
        image --quiet --input /img.tar --scanners vuln --ignore-unfixed "${TRIVY_DB[@]}" "${TRIVY_IGN[@]}" --severity HIGH,CRITICAL --exit-code 0
    "${D[@]}" run --rm "${TRIVY_RUN[@]}" -v "$TAR:/img.tar:ro,z" -v "$RAIZ:/repo:ro,z" -w /repo "$TRIVY" \
        image --quiet --input /img.tar --scanners vuln --ignore-unfixed "${TRIVY_DB[@]}" "${TRIVY_IGN[@]}" --severity "$SEVERIDAD_FALLO" --exit-code 1 >/dev/null || R=$?
    rm -f "$TAR"
    [ $R -eq 0 ] || falla "La imagen tiene vulnerabilidades $SEVERIDAD_FALLO con parche disponible"
    bien "Imagen sin vulnerabilidades $SEVERIDAD_FALLO parcheables"
}

TODAS=(secretos lint config deps build pruebas vulnerabilidades)
ETAPAS=("$@")
[ ${#ETAPAS[@]} -eq 0 ] && ETAPAS=("${TODAS[@]}")
[ "${ETAPAS[0]}" = info ] && { etapa_info; exit 0; }
printf '\033[1m🛡  CI Seguro %s · repo: %s\033[0m\n' "$VERSION_KIT" "$NOMBRE"
for e in "${ETAPAS[@]}"; do
    declare -F "etapa_$e" >/dev/null || falla "Etapa desconocida: $e  (válidas: ${TODAS[*]})"
    if [[ " $OMITIR " == *" $e "* ]]; then omite "Etapa '$e' omitida por ci/ajustes.conf"; continue; fi
    "etapa_$e"
done
printf '\n\033[1;32m🎉 Todo OK: %s\033[0m\n' "${ETAPAS[*]}"

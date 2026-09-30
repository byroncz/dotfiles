#!/usr/bin/env bash
# Prueba de host/devkit.sh sin Docker y sin tocar el Mac: un doble de `docker`
# responde por el contenedor y la prueba comprueba qué queda en el contexto de
# build. Cubre lo que arregla DEVKIT-30: en modo dev el contexto se rearma desde
# el workspace antes de construir, fuera de modo dev no se toca, y cuando el
# contenedor no responde se avisa y se sigue con la copia que hay. También
# cubre `devkit code` (DEVKIT-51), `devkit awake` con un doble de caffeinate
# (DEVKIT-66), con un doble de `curl`, la resolución de
# devkit/vscode/extensions.toml contra Open VSX (DEVKIT-67), y el chequeo de
# engines.vscode contra la versión de openvscode-server del Dockerfile, con
# reintentos ante un 5xx (DEVKIT-73).
# Sale con 1 si algún caso falla.
# Uso: bash devkit-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVKIT="$HERE/devkit.sh"
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVKIT_TEST_LOG="$TMP/docker.log"; : > "$DEVKIT_TEST_LOG"
# DEVKIT-258: el doble de curl arma el tarball de `update` con devkit/host/devkit.sh
# igual a $DEVKIT, para que el escenario por defecto (bin/devkit al día) no dispare
# el refresco. No se exporta $DEVKIT tal cual (podría chocar con algo del entorno
# real); un nombre propio evita esa ambigüedad.
export DEVKIT_TEST_HOST_SCRIPT="$DEVKIT"

# --- Doble de curl -----------------------------------------------------------
# Solo responde la API de Open VSX que usa resolve_extensions, con
# `-o <archivo> -w '%{http_code}'` como el real: escribe el cuerpo en el
# archivo y el código HTTP en stdout, para poder distinguir un 404
# (`DEVKIT_TEST_CURL_404=1`) de un 200 (H4, DEVKIT-67). `DEVKIT_TEST_CURL_503=1`
# simula un Open VSX caído que sí responde, distinto del Mac sin red (H8,
# DEVKIT-67). Cualquier otra URL (por ejemplo la descarga de una etiqueta en
# `update`, que estos escenarios no ejercitan) sale en 0 sin cuerpo.
# `DEVKIT_TEST_CURL_DOWN=1` simula el Mac sin red: imprime 000 (lo que el
# curl real escribe con -w al no poder conectar) y sale con 7, como el curl
# real.
#
# DEVKIT-73: el cuerpo de "/latest" también lleva "engines.vscode"
# (`DEVKIT_TEST_OVX_ENGINE`, por defecto compatible) y, si se declara,
# "allVersions" (`DEVKIT_TEST_OVX_ALLVERSIONS`, el contenido de ese objeto
# JSON) para el recorrido de `ultima_compatible`. Una URL de versión exacta
# (no "/latest") responde con el motor de `DEVKIT_TEST_OVX_ENGINE_<versión>`
# (puntos por guiones bajos) o 404 si no se declaró ninguno para esa versión,
# así una prueba solo declara los motores que espera que se consulten.
# `DEVKIT_TEST_CURL_503_COUNT=<n>` simula un Open VSX que se recupera: cuenta
# los intentos que --retry haría (1 + el valor de --retry) y responde 503
# mientras no los supere, 200 en cuanto los supera; sirve para probar tanto
# la recuperación (falla menos veces de las que se reintenta) como que se
# rinde (falla siempre, igual que `DEVKIT_TEST_CURL_503`, con la ventaja de
# demostrar que el número de intentos sí importa).
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'FIN'
#!/bin/sh
echo "curl $*" >> "$DEVKIT_TEST_LOG"
[ "${DEVKIT_TEST_CURL_DOWN:-0}" = 1 ] && { printf '000'; exit 7; }
out=""; prev=""; retry=0
for a; do
  [ "$prev" = -o ] && out="$a"
  [ "$prev" = --retry ] && retry="$a"
  prev="$a"; url="$a"
done
case "$url" in
  https://open-vsx.org/api/*/latest)
    if [ "${DEVKIT_TEST_CURL_404:-0}" = 1 ]; then
      [ -n "$out" ] && : > "$out"
      printf '404'
    elif [ -n "${DEVKIT_TEST_CURL_503_COUNT:-}" ]; then
      intentos=$((retry + 1))
      if [ "$intentos" -gt "$DEVKIT_TEST_CURL_503_COUNT" ]; then
        body="{\"version\":\"${DEVKIT_TEST_OVX_VERSION:-9.9.9}\",\"engines\":{\"vscode\":\"${DEVKIT_TEST_OVX_ENGINE:-^1.0.0}\"}}"
        if [ -n "$out" ]; then printf '%s' "$body" > "$out"; printf '200'; else printf '%s' "$body"; fi
      else
        [ -n "$out" ] && : > "$out"
        printf '503'
      fi
    elif [ "${DEVKIT_TEST_CURL_503:-0}" = 1 ]; then
      [ -n "$out" ] && : > "$out"
      printf '503'
    else
      allv="${DEVKIT_TEST_OVX_ALLVERSIONS:-}"
      body="{\"version\":\"${DEVKIT_TEST_OVX_VERSION:-9.9.9}\",\"engines\":{\"vscode\":\"${DEVKIT_TEST_OVX_ENGINE:-^1.0.0}\"}${allv:+,\"allVersions\":{$allv}}}"
      if [ -n "$out" ]; then printf '%s' "$body" > "$out"; printf '200'; else printf '%s' "$body"; fi
    fi ;;
  https://open-vsx.org/api/*)
    ver="${url##*/}"
    clave="$(printf '%s' "$ver" | tr '.' '_')"
    eval "engine=\"\${DEVKIT_TEST_OVX_ENGINE_${clave}:-}\""
    if [ -z "$engine" ]; then
      [ -n "$out" ] && : > "$out"
      printf '404'
    else
      body="{\"version\":\"$ver\",\"engines\":{\"vscode\":\"$engine\"}}"
      if [ -n "$out" ]; then printf '%s' "$body" > "$out"; printf '200'; else printf '%s' "$body"; fi
    fi ;;
  # `devkit update` descarga la etiqueta destino con `curl -fsSL ... | tar
  # -xz`, sin `-o`: el doble arma al vuelo un tarball mínimo con un `devkit/`
  # (Dockerfile y vscode/extensions.toml) y lo imprime a stdout.
  https://github.com/*/archive/refs/tags/*.tar.gz)
    work="$(mktemp -d)"
    mkdir -p "$work/repo/devkit/vscode" "$work/repo/devkit/host"
    printf 'ARG OPENVSCODE_VERSION=1.109.5\n' > "$work/repo/devkit/Dockerfile"
    printf '"Anthropic.claude-code" = "latest"\n' > "$work/repo/devkit/vscode/extensions.toml"
    # DEVKIT-258: devkit/host/devkit.sh de la etiqueta destino, igual al devkit.sh
    # bajo prueba salvo que un caso agregue una marca (DEVKIT_TEST_TARBALL_HOST_MARCA)
    # para simular una release que sí lo cambió.
    cp "$DEVKIT_TEST_HOST_SCRIPT" "$work/repo/devkit/host/devkit.sh"
    [ -n "${DEVKIT_TEST_TARBALL_HOST_MARCA:-}" ] && printf '%s\n' "$DEVKIT_TEST_TARBALL_HOST_MARCA" >> "$work/repo/devkit/host/devkit.sh"
    # H8, DEVKIT-258: compose.yaml de la etiqueta destino, solo si el caso lo
    # declara (DEVKIT_TEST_TARBALL_COMPOSE), para comparar contra el template
    # recién bajado y no contra el viejo.
    [ -n "${DEVKIT_TEST_TARBALL_COMPOSE:-}" ] && printf '%s\n' "$DEVKIT_TEST_TARBALL_COMPOSE" > "$work/repo/devkit/compose.yaml"
    tar -C "$work" -czf - repo
    rm -rf "$work" ;;
  *) [ -n "$out" ] && : > "$out" ;;
esac
FIN
chmod +x "$TMP/bin/curl"

# --- Doble de docker --------------------------------------------------------
# Registra cada llamada en $DEVKIT_TEST_LOG y responde lo mínimo que devkit.sh
# necesita. `DEVKIT_TEST_WS` es el /workspace del contenedor y
# `DEVKIT_TEST_DOWN=1` simula un contenedor que todavía no existe.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'FIN'
#!/bin/sh
echo "docker $*" >> "$DEVKIT_TEST_LOG"
case "${1:-}" in
  compose)
    # DEVKIT-258 (H1): simula un `compose up` que falla a mitad de `update`,
    # para comprobar que el refresco de bin/devkit no se salta con `set -eu`.
    [ "${DEVKIT_TEST_COMPOSE_FAIL:-0}" = 1 ] && exit 1
    exit 0 ;;
  inspect)
    # DEVKIT-159: wait_ready pide dos formatos distintos: Running (true/false,
    # como ya usaba `devkit awake`) y, solo cuando el contenedor no corre,
    # Status (el texto del estado real, DEVKIT_TEST_DOWN_STATUS por defecto
    # "Exited") para el mensaje.
    case "$3" in
      *State.Status*) echo "${DEVKIT_TEST_DOWN_STATUS:-Exited}"; exit 0 ;;
      # DEVKIT-159 (H3): wait_ready pide el arranque del contenedor actual para
      # no leer logs de un arranque anterior con --since.
      *State.StartedAt*) echo "${DEVKIT_TEST_STARTED_AT:-2024-01-01T00:00:00.000000000Z}"; exit 0 ;;
      *)
        [ "${DEVKIT_TEST_DOWN:-0}" = 1 ] && { echo false; exit 0; }
        echo true; exit 0 ;;
    esac ;;
  logs)
    # DEVKIT-159: wait_ready muestra la última línea [devkit] mientras espera.
    printf '%s\n' "${DEVKIT_TEST_LOGS_CONTENT:-[devkit] arrancando}"
    exit 0 ;;
  wait) echo 0; exit 0 ;;
  cp)
    [ "${DEVKIT_TEST_DOWN:-0}" = 1 ] && exit 1
    case "$2" in
      *:/workspace/devkit/.) cp -R "$DEVKIT_TEST_WS/devkit/." "$3" || exit 1 ;;
      # DEVKIT-258 (H2): `update` en modo dev copia solo host/devkit.sh del
      # workspace vivo, sin rearmar todo el contexto de build.
      *:/workspace/devkit/host/devkit.sh) cp "$DEVKIT_TEST_WS/devkit/host/devkit.sh" "$3" || exit 1 ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
  exec)
    shift
    while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
    shift   # nombre del contenedor
    # Un contenedor "caído" empieza a responder en cuanto compose lo levanta:
    # así el caso de la copia vieja no cuelga el `exec` final, igual que en
    # un recreate de verdad.
    if [ "${DEVKIT_TEST_DOWN:-0}" = 1 ] && ! grep -q 'up -d' "$DEVKIT_TEST_LOG"; then
      exit 1
    fi
    case "$*" in
      "test -d /workspace/devkit") [ -d "$DEVKIT_TEST_WS/devkit" ]; exit $? ;;
      "cat /workspace/.devkit/devkit.toml") cat "$DEVKIT_TEST_WS/.devkit/devkit.toml" 2>/dev/null; exit $? ;;
      "cat /run/devkit/vscode-token") printf '%s' "${DEVKIT_TEST_TOKEN:-}"; exit 0 ;;
      # DEVKIT-138: `devkit-run.sh --agentes-vivos` vía sh -c, no el alias
      # devkit-run (ver el comentario de agentes_vivos en devkit.sh).
      *devkit-run.sh*--agentes-vivos*)
        printf '%s\n' "${DEVKIT_TEST_AGENTES_VIVOS:-sin agentes vivos}"; exit 0 ;;
      # DEVKIT-182: `devkit proxy` lee .devkit/devkit.toml de una rama en
      # origin sin clonarla de nuevo. El doble de "origin" es un directorio de
      # archivos <rama>.toml ($DEVKIT_TEST_ORIGIN_DIR); sin archivo para esa
      # rama, `fetch` falla como con una rama que no existe de verdad.
      # El fetch corre vía `sh -c '...' sh <rama>` para cargar /run/devkit/env
      # antes (H1): tras los shift de arriba, $4=sh y $5=<rama>.
      *"/run/devkit/env"*"fetch -q origin"*)
        ref="$5"
        [ -f "$DEVKIT_TEST_ORIGIN_DIR/$ref.toml" ] || exit 1
        exit 0 ;;
      "git -C /workspace show origin/"*":.devkit/devkit.toml")
        rest="${*#git -C /workspace show origin/}"
        ref="${rest%:.devkit/devkit.toml}"
        [ -f "$DEVKIT_TEST_ORIGIN_DIR/$ref.toml" ] || exit 1
        cat "$DEVKIT_TEST_ORIGIN_DIR/$ref.toml"; exit 0 ;;
      # DEVKIT-183: mostrar_fuente_toml pide el commit corto de origin/<rama>
      # antes de recrear. Mismo doble de "origin" que el show de arriba: sin
      # archivo para esa rama, falla igual que un rev-parse contra una rama
      # que no llegó a origin.
      "git -C /workspace rev-parse --short origin/"*)
        ref="${*#git -C /workspace rev-parse --short origin/}"
        [ -f "$DEVKIT_TEST_ORIGIN_DIR/$ref.toml" ] || exit 1
        printf 'abc1234'; exit 0 ;;
      # H6, DEVKIT-258: en modo dev, refresh_host_devkit solo refresca
      # bin/devkit si la rama viva del workspace es main. "main" por
      # defecto, para no tener que declararla en cada escenario dev que no
      # ejercita esta guarda.
      "git -C /workspace rev-parse --abbrev-ref HEAD")
        printf '%s' "${DEVKIT_TEST_WS_BRANCH:-main}"; exit 0 ;;
      # DEVKIT-159: wait_ready sondea el marcador de arranque. Sin ningún
      # DEVKIT_TEST_READY_* aparece listo de inmediato (el comportamiento de
      # siempre); DEVKIT_TEST_READY_NEVER=1 simula un contenedor que nunca
      # termina de arrancar (para el caso "límite alcanzado");
      # DEVKIT_TEST_READY_AFTER=<n> simula que el marcador aparece recién en
      # el intento <n>, con un contador en un archivo porque cada llamada es
      # un proceso nuevo del doble.
      "test -f /run/devkit/ready")
        [ "${DEVKIT_TEST_READY_NEVER:-0}" = 1 ] && exit 1
        if [ -n "${DEVKIT_TEST_READY_AFTER:-}" ]; then
          contador="$(dirname "$DEVKIT_TEST_LOG")/ready-counter"
          n=$(( $(cat "$contador" 2>/dev/null || echo 0) + 1 ))
          echo "$n" > "$contador"
          [ "$n" -ge "$DEVKIT_TEST_READY_AFTER" ] && exit 0
          exit 1
        fi
        exit 0 ;;
      *) exit 0 ;;   # zsh, ...
    esac ;;
esac
exit 0
FIN
chmod +x "$TMP/bin/docker"
# El shim del proxy (DEVKIT-259, más abajo) necesita el curl real: el doble
# de abajo solo entiende la API de Open VSX y de GitHub.
REAL_CURL="$(command -v curl)"
export PATH="$TMP/bin:$PATH"

# --- Escenario y ejecución --------------------------------------------------
# escenario <versión de .env>: deja ~/.devkit y el workspace del contenedor en
# su estado inicial. El contexto de build del Mac lleva MARCA-VIEJA y un archivo
# que el workspace ya no tiene; el workspace lleva MARCA-NUEVA.
escenario() {
  rm -rf "$TMP/root" "$TMP/ws" "$TMP/origin"
  rm -f "$TMP/ready-counter"
  mkdir -p "$TMP/root/bin" "$TMP/root/p/template/marca" "$TMP/root/p/template/host" \
           "$TMP/root/p/template/vscode" "$TMP/ws/devkit/marca" "$TMP/ws/devkit/host" \
           "$TMP/ws/devkit/vscode" "$TMP/origin"
  echo MARCA-VIEJA > "$TMP/root/p/template/marca/archivo.txt"
  echo sobra       > "$TMP/root/p/template/obsoleto.txt"
  echo MARCA-NUEVA > "$TMP/ws/devkit/marca/archivo.txt"
  printf 'name: devkit-p\n' > "$TMP/ws/devkit/compose.yaml"
  cp "$TMP/ws/devkit/compose.yaml" "$TMP/root/p/template/compose.yaml"
  cp "$TMP/ws/devkit/compose.yaml" "$TMP/root/p/compose.yaml"
  cp "$DEVKIT" "$TMP/ws/devkit/host/devkit.sh"
  cp "$DEVKIT" "$TMP/root/p/template/host/devkit.sh"
  cp "$DEVKIT" "$TMP/root/bin/devkit"
  # DEVKIT-73: resolve_extensions lee la versión del editor de este ARG, la
  # misma fuente que el Dockerfile de verdad.
  printf 'ARG OPENVSCODE_VERSION=1.109.5\n' > "$TMP/ws/devkit/Dockerfile"
  cp "$TMP/ws/devkit/Dockerfile" "$TMP/root/p/template/Dockerfile"
  printf '"Anthropic.claude-code" = "latest"\n' > "$TMP/ws/devkit/vscode/extensions.toml"
  cp "$TMP/ws/devkit/vscode/extensions.toml" "$TMP/root/p/template/vscode/extensions.toml"
  mkdir -p "$TMP/ws/.devkit"
  printf '[devkit]\ntemplate = "%s"\nproject  = "TEST"\n' "$1" > "$TMP/ws/.devkit/devkit.toml"
  printf 'DEVKIT_PROJECT=p\nDEVKIT_VERSION=%s\n' "$1" > "$TMP/root/p/.env"
  # DEVKIT-270: recreate/rebuild/update leen apt, domains y extensions de
  # origin/<rama>, no del checkout vivo: por defecto origin/main lleva lo mismo
  # que el workspace, y el caso que quiera otra cosa escribe su propio archivo.
  cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
}

# corre <comando> [caído] [token] [extra]: ejecuta `devkit <comando> p
# [extra]` contra el doble, respondiendo "si" a la confirmación. `extra`
# (DEVKIT-138) es para "--force". Deja la salida en $OUT.
OUT="$TMP/salida"
corre() {
  : > "$DEVKIT_TEST_LOG"
  printf 'si\n' | env DEVKIT_HOME="$TMP/root" DEVKIT_TEST_WS="$TMP/ws" \
    DEVKIT_TEST_LOG="$DEVKIT_TEST_LOG" DEVKIT_TEST_DOWN="${2:-0}" \
    DEVKIT_TEST_TOKEN="${3:-}" DEVKIT_TEST_ORIGIN_DIR="$TMP/origin" \
    sh "$DEVKIT" "$1" p ${4:-} >"$OUT" 2>&1
  ESTADO=$?
}

# --- Comprobaciones ---------------------------------------------------------
check() {  # check <nombre> <esperado> <obtenido>
  if [ "$2" = "$3" ]; then
    printf 'ok   %-58s %s\n' "$1" "$3"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$1" "$2" "${3:-<vacío>}"
    fail=1
  fi
}
check_salida() {  # check_salida <nombre> <patrón>
  if grep -qE "$2" "$OUT"; then
    printf 'ok   %-58s %s\n' "$1" "$(grep -oE "$2" "$OUT" | head -1)"
  else
    printf 'FAIL %-58s no aparece /%s/ en la salida\n' "$1" "$2"
    fail=1
  fi
}
check_docker() {  # check_docker <nombre> <si|no> <patrón>
  local got=no
  grep -qE "$3" "$DEVKIT_TEST_LOG" && got=si
  check "$1" "$2" "$got"
}
marca() { cat "$TMP/root/p/template/marca/archivo.txt" 2>/dev/null; }

# open_doble <rc|ausente>: pone (o quita) un doble de `open` en el PATH de la
# prueba, para ejercitar la rama de `devkit code` que usa `open` de verdad en
# vez de caer al respaldo por no encontrarlo (DEVKIT-51).
open_doble() {
  if [ "$1" = "ausente" ]; then
    rm -f "$TMP/bin/open"
  else
    cat >"$TMP/bin/open" <<FIN
#!/bin/sh
echo "open \$*" >> "$DEVKIT_TEST_LOG"
exit $1
FIN
    chmod +x "$TMP/bin/open"
  fi
}

# --- Zona horaria del Mac (DEVKIT-64) ----------------------------------------
# detectar_tz lee DEVKIT_LOCALTIME_FILE en vez de /etc/localtime real (que en
# esta máquina no es un Mac): un symlink a `.../zoneinfo/<Zona>` como el que
# arma macOS, y su ausencia, que es lo que ve un Linux sin ese enlace.
env_tz() { sed -n 's/^DEVKIT_TZ=//p' "$TMP/root/p/.env" | tail -1; }

escenario dev
ln -sfn /var/db/timezone/zoneinfo/America/Bogota "$TMP/localtime-mac"
DEVKIT_LOCALTIME_FILE="$TMP/localtime-mac" corre up
check        "up detecta la zona del Mac" America/Bogota "$(env_tz)"
check        "up detecta la zona del Mac: no avisa" no \
             "$(grep -q 'no se pudo detectar la zona' "$OUT" && echo si || echo no)"

escenario dev
DEVKIT_LOCALTIME_FILE="$TMP/no-existe" corre up
check        "sin zona detectable: usa UTC" UTC "$(env_tz)"
check_salida "sin zona detectable: avisa en la consola del Mac" "no se pudo detectar la zona horaria"

escenario dev
ln -sfn /var/db/timezone/zoneinfo/America/Bogota "$TMP/localtime-mac"
DEVKIT_LOCALTIME_FILE="$TMP/localtime-mac" corre recreate
check        "recreate también escribe DEVKIT_TZ" America/Bogota "$(env_tz)"

escenario dev
ln -sfn /var/db/timezone/zoneinfo/America/Bogota "$TMP/localtime-mac"
DEVKIT_LOCALTIME_FILE="$TMP/localtime-mac" corre rebuild
check        "rebuild también escribe DEVKIT_TZ" America/Bogota "$(env_tz)"

escenario dev
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
ln -sfn /var/db/timezone/zoneinfo/America/Bogota "$TMP/localtime-mac"
DEVKIT_LOCALTIME_FILE="$TMP/localtime-mac" corre update
check        "update también escribe DEVKIT_TZ" America/Bogota "$(env_tz)"
check        "update también escribe DEVKIT_TZ: termina bien" 0 "$ESTADO"

# --- Modo dev, contenedor arriba --------------------------------------------
escenario dev; corre recreate
check        "recreate en dev trae el contexto del workspace" MARCA-NUEVA "$(marca)"
check        "recreate en dev deja de arrastrar lo que se borró" no \
             "$([ -e "$TMP/root/p/template/obsoleto.txt" ] && echo si || echo no)"
check_salida "recreate en dev lo dice" "contexto de build actualizado desde el workspace"
check_docker "recreate en dev copia desde el contenedor" si 'docker cp devkit-p:/workspace/devkit/\.'
check        "recreate en dev termina bien" 0 "$ESTADO"

escenario dev; corre rebuild
check        "rebuild en dev trae el contexto del workspace" MARCA-NUEVA "$(marca)"
check_docker "rebuild en dev construye desde cero" si 'build --no-cache'

escenario dev; corre up
check        "up en dev trae el contexto del workspace" MARCA-NUEVA "$(marca)"

# --- Modo dev, contenedor que no responde -----------------------------------
escenario dev; corre recreate 1
check        "sin contenedor se conserva la copia que hay" MARCA-VIEJA "$(marca)"
check_salida "sin contenedor se avisa" "el contenedor no responde"
check_docker "sin contenedor no se intenta la copia" no 'docker cp'
check_docker "sin contenedor se construye igual" si 'up -d'
check        "sin contenedor no falla" 0 "$ESTADO"

escenario dev; corre up 1
check        "primer up sin contenedor conserva la copia" MARCA-VIEJA "$(marca)"
check_salida "primer up sin contenedor avisa" "el contenedor no responde"
check        "primer up sin contenedor no falla" 0 "$ESTADO"

# --- Guarda de agentes vivos (DEVKIT-138) ------------------------------------
# `devkit-run --agentes-vivos`, consultado antes de destruir nada, decide si
# recreate/rebuild se niegan: con algún agente vivo abortan con el listado y
# la sugerencia de pausar el bucle, sin tocar el contexto de build ni
# reconstruir; --force salta la guarda; sin contenedor que responda (los dos
# escenarios de arriba, con DEVKIT_TEST_DOWN=1) la guarda ni se consulta.
#
# DEVKIT-138 H4: sin DEVKIT_TEST_AGENTES_VIVOS, el doble de `docker exec`
# responde "sin agentes vivos" por defecto -esa respuesta, no la falta de
# contenedor, es lo que hacía pasar los dos escenarios de arriba, aunque la
# guarda sí se hubiera consultado. Este caso fija DEVKIT_TEST_AGENTES_VIVOS
# con un agente vivo y confirma que recreate sigue igual: el contenedor caído
# hace que `docker exec` falle antes de llegar a esa respuesta, así que la
# guarda de verdad no se consulta.
escenario dev
export DEVKIT_TEST_AGENTES_VIVOS="$(printf '4242\tDEVKIT-46\ttask-fix')"
corre recreate 1
unset DEVKIT_TEST_AGENTES_VIVOS
check        "sin contenedor con agente vivo: la guarda ni se consulta" 0 "$ESTADO"
check_docker "sin contenedor con agente vivo: recreate igual reconstruye" si 'up -d --build --force-recreate'

escenario dev
export DEVKIT_TEST_AGENTES_VIVOS="$(printf '4242\tDEVKIT-46\ttask-fix')"
corre recreate
unset DEVKIT_TEST_AGENTES_VIVOS
check        "agente vivo: recreate se niega" 1 "$ESTADO"
check_salida "agente vivo: lista el agente en el aviso" "DEVKIT-46.*task-fix"
check_salida "agente vivo: sugiere pausar el bucle" "devkit-run --pausa"
check_docker "agente vivo: recreate no reconstruye" no 'up -d --build --force-recreate'
check        "agente vivo: no toca el contexto de build" MARCA-VIEJA "$(marca)"

escenario dev
export DEVKIT_TEST_AGENTES_VIVOS="$(printf '4242\tDEVKIT-46\ttask-fix')"
corre rebuild
unset DEVKIT_TEST_AGENTES_VIVOS
check        "agente vivo: rebuild también se niega" 1 "$ESTADO"
check_docker "agente vivo: rebuild no reconstruye" no 'build --no-cache'

escenario dev; corre recreate
check        "sin agentes vivos: recreate sigue" 0 "$ESTADO"
check_docker "sin agentes vivos: recreate reconstruye" si 'up -d --build --force-recreate'

escenario dev
export DEVKIT_TEST_AGENTES_VIVOS="$(printf '4242\tDEVKIT-46\ttask-fix')"
corre recreate 0 "" --force
unset DEVKIT_TEST_AGENTES_VIVOS
check        "--force: recreate sigue con un agente vivo" 0 "$ESTADO"
check_docker "--force: recreate igual reconstruye" si 'up -d --build --force-recreate'

# --- Fuente de .devkit/devkit.toml antes de recrear/actualizar (DEVKIT-183) -
# mostrar_fuente_toml dice de qué origin/<rama> sale el .devkit/devkit.toml
# tras recrear (no el checkout vivo: /workspace no es un volumen y se pierde,
# DEVKIT-183) y la lista de domains/apt que sync_toml_env va a escribir en
# .env desde el checkout vivo. Si el checkout vivo difiere de origin/main,
# además avisa con el diff. El doble de "origin" es el mismo
# $TMP/origin/<rama>.toml que usa `devkit proxy`.
escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
corre recreate
check_salida "toml limpio: dice de dónde sale tras recrear" "se clona de nuevo desde origin/main @abc1234"
check        "toml limpio: no avisa de diferencias" no \
             "$(grep -q 'difiere de origin/main' "$OUT" && echo si || echo no)"
check        "toml limpio: recreate termina bien" 0 "$ESTADO"
check_docker "toml limpio: recreate igual reconstruye" si 'up -d --build --force-recreate'

escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["c.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
corre recreate
check_salida "toml sucio: avisa que difiere de origin/main" "difiere de origin/main"
check_salida "toml sucio: muestra el diff del campo domains" 'domains: checkout vivo "c\.com" -> origin/main "a\.com"'
check_salida "toml sucio: recuerda el camino correcto" "devkit proxy p --ref <rama>"
check        "toml sucio: igual recrea si se confirma" 0 "$ESTADO"
check_docker "toml sucio: igual reconstruye" si 'up -d --build --force-recreate'

# H3, DEVKIT-183: rebuild pasa por confirm_recreate igual que recreate, pero
# hasta ahora ningún caso lo ejercitaba con el toml sucio.
escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["c.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
corre rebuild
check_salida "rebuild con toml sucio avisa que difiere de origin/main" "difiere de origin/main"
check_docker "rebuild con toml sucio igual reconstruye desde cero" si 'build --no-cache'

# --- recreate/rebuild/update leen origin/<rama>, no el checkout vivo (DEVKIT-270) -
# Un PR -0 (dk --declarar) no hace pull en /workspace: con una card en curso el
# checkout vivo es la rama de la card, con otra lista que la de main. apt,
# domains y extensions van a .env desde origin/<rama> (la fuente que se
# reclona), no del checkout vivo.
env_de() { sed -n "s/^$1=//p" "$TMP/root/p/.env" | tail -1; }
toml_card='[devkit]\ntemplate = "dev"\nproject  = "TEST"\napt = ["jq"]\ndomains = ["card.com"]\nextensions = ["ms.card@1.0.0"]\n'
toml_main='[devkit]\ntemplate = "dev"\nproject  = "TEST"\napt = ["curl"]\ndomains = ["a.com"]\nextensions = ["ms.main@1.0.0", "ms.otra@2.0.0"]\n'
export DEVKIT_TEST_OVX_ENGINE_1_0_0="^1.0.0" DEVKIT_TEST_OVX_ENGINE_2_0_0="^1.0.0"

escenario dev
printf "$toml_card" > "$TMP/ws/.devkit/devkit.toml"
printf "$toml_main" > "$TMP/origin/main.toml"
corre recreate
check        "recreate con checkout vivo en rama de card: termina bien" 0 "$ESTADO"
check        "recreate: apt sale de origin/main, no del checkout vivo" curl "$(env_de DEVKIT_EXTRA_APT)"
check        "recreate: domains salen de origin/main" a.com "$(env_de DEVKIT_ALLOW_DOMAINS)"
check        "recreate: extensions salen de origin/main" "ms.main@1.0.0 ms.otra@2.0.0" "$(env_de DEVKIT_PROJECT_EXTENSIONS)"
check_salida "recreate: dice de dónde salen domains" 'domains que se van a escribir en \.env \(de origin/main\): a\.com'
check_salida "recreate: avisa que extensions difiere" 'extensions: checkout vivo "ms\.card@1\.0\.0" -> origin/main "ms\.main@1\.0\.0 ms\.otra@2\.0\.0"'

escenario dev
printf "$toml_card" > "$TMP/ws/.devkit/devkit.toml"
printf "$toml_main" > "$TMP/origin/main.toml"
corre rebuild
check        "rebuild con checkout vivo en rama de card: domains de origin/main" a.com "$(env_de DEVKIT_ALLOW_DOMAINS)"
check        "rebuild: extensions de origin/main" "ms.main@1.0.0 ms.otra@2.0.0" "$(env_de DEVKIT_PROJECT_EXTENSIONS)"

escenario 0.1.0
printf "$toml_card" | sed 's/"dev"/"0.2.0"/' > "$TMP/ws/.devkit/devkit.toml"
printf "$toml_main" | sed 's/"dev"/"0.2.0"/' > "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check        "update con checkout vivo en rama de card: apt de origin/main" curl "$(env_de DEVKIT_EXTRA_APT)"
check        "update: extensions de origin/main" "ms.main@1.0.0 ms.otra@2.0.0" "$(env_de DEVKIT_PROJECT_EXTENSIONS)"

# Si origin/<rama> no se lee, recreate se detiene antes de recrear y no toca
# .env: seguir con la lista del checkout vivo es el error que corrige esta card.
escenario dev
printf "$toml_card" > "$TMP/ws/.devkit/devkit.toml"
rm -f "$TMP/origin/main.toml"
printf 'DEVKIT_ALLOW_DOMAINS=previo.com\n' >> "$TMP/root/p/.env"
corre recreate
check        "origin/<rama> ilegible: recreate se detiene" 1 "$ESTADO"
check_salida "origin/<rama> ilegible: lo explica" "no se pudo leer \.devkit/devkit\.toml de origin/main"
check        "origin/<rama> ilegible: no toca .env" previo.com "$(env_de DEVKIT_ALLOW_DOMAINS)"
check_docker "origin/<rama> ilegible: no recrea" no 'force-recreate'
check        "origin/<rama> ilegible: no pide confirmar una destrucción" no \
             "$(grep -q 'Escribe "si"' "$OUT" && echo si || echo no)"

# update lee origin antes de tocar nada: con origin/<rama> ilegible sale con 1
# sin bajar el tarball ni cambiar DEVKIT_VERSION, para que el siguiente
# `update` no crea que ya está al día con la imagen vieja (H1, revisión del
# PR 157).
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
rm -f "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check        "update con origin/<rama> ilegible: se detiene" 1 "$ESTADO"
check_salida "update con origin/<rama> ilegible: lo explica" "no se pudo leer \.devkit/devkit\.toml de origin/main"
check        "update con origin/<rama> ilegible: DEVKIT_VERSION intacta" 0.1.0 "$(env_de DEVKIT_VERSION)"
check        "update con origin/<rama> ilegible: no baja el template" no \
             "$(grep -q 'actualizando template' "$OUT" && echo si || echo no)"

# DEVKIT-271: la versión destino de update también sale de origin/<rama>. Con el
# checkout vivo en una rama de card que aún declara la versión vieja y un PR de
# template-update ya mergeado en origin/main, update actualiza a la nueva y no
# responde "ya en <vieja>".
escenario 0.1.0
printf '[devkit]\ntemplate = "0.1.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check        "update con checkout vivo en template viejo y origin/main en el nuevo: termina bien" 0 "$ESTADO"
check_salida "update toma la versión destino de origin/main" "actualizando template 0\.1\.0 -> 0\.2\.0"
check        "update toma la versión destino de origin/main: DEVKIT_VERSION" 0.2.0 "$(env_de DEVKIT_VERSION)"
check        "update toma la versión destino de origin/main: no dice 'ya en'" no \
             "$(grep -q '^ya en ' "$OUT" && echo si || echo no)"

# Al revés: el checkout vivo ya declara la nueva (card que sube template) pero
# origin/main aún la vieja: no hay nada que actualizar.
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "0.1.0"\nproject  = "TEST"\n' > "$TMP/origin/main.toml"
corre update
check_salida "update con checkout vivo adelantado a origin/main: ya está al día" "ya en 0\.1\.0"
check        "update con checkout vivo adelantado a origin/main: DEVKIT_VERSION intacta" 0.1.0 "$(env_de DEVKIT_VERSION)"

# Con la rama fijada al instanciar (DEVKIT_REPO_REF), lee esa rama y no main.
escenario dev
printf 'DEVKIT_REPO_REF=rama-x\n' > "$TMP/root/p/devkit.env"
printf "$toml_card" > "$TMP/ws/.devkit/devkit.toml"
printf "$toml_main" > "$TMP/origin/main.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains = ["x.com"]\n' > "$TMP/origin/rama-x.toml"
corre recreate
check        "DEVKIT_REPO_REF: domains de origin/<esa rama>" x.com "$(env_de DEVKIT_ALLOW_DOMAINS)"
unset DEVKIT_TEST_OVX_ENGINE_1_0_0 DEVKIT_TEST_OVX_ENGINE_2_0_0


# H1, DEVKIT-183: up no llama a sync_toml_env (no escribe domains/apt en
# .env), así que muestra la lista que ya hay en .env -la que compose usa de
# verdad-, no la del checkout vivo. Se ve igual con el contenedor caído,
# porque se lee del Mac sin pasar por Docker.
escenario dev
printf 'DEVKIT_ALLOW_DOMAINS=b.com\nDEVKIT_EXTRA_APT=jq\n' >> "$TMP/root/p/.env"
corre up
check_salida "up muestra los domains efectivos de .env" 'domains que va a usar compose \(de \.env\): b\.com'
check_salida "up muestra el apt efectivo de .env" 'apt que va a usar compose \(de \.env\): jq'

escenario dev
printf 'DEVKIT_ALLOW_DOMAINS=b.com\nDEVKIT_EXTRA_APT=jq\n' >> "$TMP/root/p/.env"
corre up 1
check_salida "up sin contenedor igual muestra los domains efectivos" 'domains que va a usar compose \(de \.env\): b\.com'
check        "up sin contenedor no falla" 0 "$ESTADO"

escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\ndomains  = ["c.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check_salida "update con toml sucio avisa antes de actualizar" "difiere de origin/main"
check_salida "update con toml sucio sigue tras confirmar" "actualizando template"
check        "update con toml sucio termina bien" 0 "$ESTADO"

escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check        "update con toml limpio no avisa" no \
             "$(grep -q 'difiere de origin/main' "$OUT" && echo si || echo no)"
check_salida "update con toml limpio sigue de largo" "actualizando template"

# H2, DEVKIT-183: si el proyecto ya está en la versión destino (o en modo
# dev), update sale sin recrear nada; el aviso y la confirmación no deben
# pedirse antes de llegar a esa salida.
escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["c.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
corre update
check_salida "update en dev con toml sucio manda a recreate sin pedir confirmar" "usa 'devkit recreate p'"
check        "update en dev con toml sucio no avisa del diff" no \
             "$(grep -q 'difiere de origin/main' "$OUT" && echo si || echo no)"

# --- devkit proxy (DEVKIT-182) ------------------------------------------------
# Aplica al proxy los domains de una rama sin esperar el merge. El doble de
# "origin" es $TMP/origin/<rama>.toml (ver el doble de `docker exec` arriba).
env_domains() { sed -n 's/^DEVKIT_ALLOW_DOMAINS=//p' "$TMP/root/p/.env" | tail -1; }

escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["c.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
corre proxy
check        "proxy sin --ref: termina bien" 0 "$ESTADO"
check        "proxy sin --ref: une el checkout actual con main" "a.com c.com" "$(env_domains)"
check_docker "proxy sin --ref: recrea el proxy" si 'up -d --force-recreate proxy'
check_docker "proxy sin --ref: no reconstruye nada" no 'build'
check_docker "proxy sin --ref: no recrea todo el stack (solo proxy)" no 'up -d --build --force-recreate$'
check_salida "proxy sin --ref: imprime la lista resultante" 'dominios aplicados al proxy: a\.com c\.com'

escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["c.com"]\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["b.com"]\n' > "$TMP/origin/rama-x.toml"
corre proxy 0 "" "--ref rama-x"
check        "proxy --ref: termina bien" 0 "$ESTADO"
check        "proxy --ref: une los domains de la rama con main, sin el checkout actual" \
             "a.com b.com" "$(env_domains)"
check_docker "proxy --ref: carga /run/devkit/env antes de fetch (H1)" si '/run/devkit/env'

escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
mkdir -p "$TMP/origin/feat"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["d.com"]\n' > "$TMP/origin/feat/X-1-algo.toml"
corre proxy 0 "" "--ref feat/X-1-algo"
check        "proxy --ref con slash: termina bien" 0 "$ESTADO"
check        "proxy --ref con slash: une los domains de la rama con main" \
             "a.com d.com" "$(env_domains)"

escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\ndomains  = ["a.com"]\n' > "$TMP/origin/main.toml"
printf 'DEVKIT_ALLOW_DOMAINS=previo.com\n' >> "$TMP/root/p/.env"
corre proxy 0 "" "--ref no-existe"
check        "proxy --ref inexistente: se detiene" 1 "$ESTADO"
check_salida "proxy --ref inexistente: lo explica" "no existe la rama 'no-existe' en origin"
check        "proxy --ref inexistente: no toca .env" "previo.com" "$(env_domains)"
check_docker "proxy --ref inexistente: no recrea el proxy" no 'force-recreate proxy'

escenario dev
corre proxy 1
check        "proxy con el contenedor apagado: se detiene" 1 "$ESTADO"
check_salida "proxy con el contenedor apagado: lo explica" "devkit-p no responde"
check_docker "proxy con el contenedor apagado: no recrea el proxy" no 'force-recreate proxy'

escenario dev
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
printf '[devkit]\ntemplate = "dev"\nproject  = "TEST"\n' > "$TMP/origin/main.toml"
corre proxy
check        "proxy sin domains declarados: no falla" 0 "$ESTADO"
check        "proxy sin domains declarados: deja la lista vacía" "" "$(env_domains)"

# --- Fuera de modo dev ------------------------------------------------------
escenario 0.1.0; corre recreate
check        "con versión etiquetada el contexto no cambia" MARCA-VIEJA "$(marca)"
check_docker "con versión etiquetada no se copia nada" no 'docker cp'
check_docker "con versión etiquetada se construye igual" si 'up -d'

escenario 0.1.0; corre rebuild
check        "rebuild etiquetado no cambia el contexto" MARCA-VIEJA "$(marca)"
check_docker "rebuild etiquetado no copia nada" no 'docker cp'

# --- update en modo dev -----------------------------------------------------
escenario dev; corre update
check_salida "update en dev manda a recreate" "usa 'devkit recreate p'"
check        "update en dev no toca el contexto" MARCA-VIEJA "$(marca)"
check_docker "update en dev no construye" no 'compose'

# DEVKIT-258 (H2): antes de esta card, `update` en modo dev solo mandaba a
# `recreate` y nunca tocaba bin/devkit: el aviso "'devkit update p' lo
# refresca" no tenía remedio real en este modo. Ahora sí, leído directo del
# workspace vivo del contenedor -no de $dir/template, que en dev solo se
# rearma en up/recreate/rebuild- sin tocar el contexto de build.
escenario dev; echo '# workspace nuevo' >> "$TMP/ws/devkit/host/devkit.sh"; corre update
check_salida "update en dev refresca bin/devkit" "devkit: comando devkit actualizado a dev"
check        "update en dev deja bin/devkit igual al workspace vivo" si \
             "$(cmp -s "$TMP/ws/devkit/host/devkit.sh" "$TMP/root/bin/devkit" && echo si || echo no)"
check        "update en dev con refresco sigue sin tocar el contexto de build" MARCA-VIEJA "$(marca)"
check_docker "update en dev con refresco no construye" no 'compose'
check        "update en dev con refresco termina bien" 0 "$ESTADO"

# DEVKIT-258 (H1): con etiqueta y ya en la versión destino, `update` salía
# con "ya en $target" sin tocar bin/devkit nunca: un proyecto que no corriera
# un update a una versión distinta se quedaba para siempre con el binario
# con el que se instaló. Ahora, aunque no haya nada que bajar, igual
# refresca bin/devkit contra el template ya instalado.
escenario 0.1.0; echo '# línea de más' >> "$TMP/root/bin/devkit"; corre update
check_salida "update ya en la versión destino: refresca bin/devkit" "devkit: comando devkit actualizado a 0\.1\.0"
check        "update ya en la versión destino: deja bin/devkit igual al template instalado" si \
             "$(cmp -s "$TMP/root/p/template/host/devkit.sh" "$TMP/root/bin/devkit" && echo si || echo no)"
check_salida "update ya en la versión destino: sigue diciendo que ya estaba en esa versión" "ya en 0\.1\.0"
check_docker "update ya en la versión destino no construye" no 'compose'
check        "update ya en la versión destino: termina bien" 0 "$ESTADO"

# --- update con compose.yaml sin EXTENSIONS (H2, DEVKIT-67) -----------------
# compose.yaml del Mac de antes de DEVKIT-67 no declara EXTENSIONS: el
# build seguiría sin avisar y sin extensiones. `update` debe detenerse antes
# de descargar la etiqueta.
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
corre update
check        "update con compose.yaml sin EXTENSIONS se detiene" 1 "$ESTADO"
check_salida "update con compose.yaml sin EXTENSIONS lo explica" "no declara EXTENSIONS"
check_docker "update con compose.yaml sin EXTENSIONS no descarga la etiqueta" no 'archive/refs/tags'

escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check_salida "update con compose.yaml al día no se detiene por EXTENSIONS" "actualizando template"

# --- Avisos de los archivos del Mac -----------------------------------------
escenario dev; echo 'name: otro' > "$TMP/root/p/compose.yaml"; corre recreate
check_salida "compose.yaml del Mac desincronizado" "compose.yaml difiere del template"
check_salida "compose.yaml desincronizado en dev: el remedio es --ref" "reinstala con new-project\.sh p --ref <rama>"

# H8, DEVKIT-258: desde esta card el aviso también corre con etiqueta; ahí
# reinstalar con --ref pasaría el proyecto a modo dev.
escenario 0.1.0; echo 'name: otro' > "$TMP/root/p/compose.yaml"; corre up
check_salida "compose.yaml desincronizado con etiqueta: el remedio es --version" "reinstala con new-project\.sh p --version 0\.1\.0"
check        "compose.yaml desincronizado con etiqueta: no manda a --ref" no \
             "$(grep -q 'new-project.sh p --ref' "$OUT" && echo si || echo no)"

# H8, DEVKIT-258: en update, compose.yaml se compara contra el template de la
# etiqueta destino, no contra el que había antes de bajarla.
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
cp "$TMP/root/p/compose.yaml" "$TMP/root/p/template/compose.yaml"
export DEVKIT_TEST_TARBALL_COMPOSE="name: devkit-p-0.2.0"
corre update
unset DEVKIT_TEST_TARBALL_COMPOSE
check_salida "update: avisa de un compose.yaml que cambió en la etiqueta destino" \
             "compose.yaml difiere del template; reinstala con new-project\.sh p --version 0\.2\.0"

escenario dev; echo '# línea de más' >> "$TMP/root/bin/devkit"; corre recreate
check_salida "comando devkit desincronizado" "el comando devkit difiere del template"

escenario dev; corre recreate
check        "con todo al día no se avisa de nada" no \
             "$(grep -q 'difiere del template' "$OUT" && echo si || echo no)"

# DEVKIT-258: antes de esta card, `up` nunca llamaba a warn_host_stale (solo
# corría dentro de sync_dev_template, en modo dev) y en un proyecto con
# etiqueta nadie se enteraba de un bin/devkit viejo hasta reinstalar a mano.
# Ahora corre también ahí, y en cualquier modo, con el remedio real.
escenario dev; echo '# línea de más' >> "$TMP/root/bin/devkit"; corre up
check_salida "comando devkit desincronizado: up también avisa" "el comando devkit difiere del template"
check_salida "comando devkit desincronizado: el remedio es 'devkit update', no reinstalar" \
             "el comando devkit difiere del template; 'devkit update p' lo refresca"

escenario 0.1.0; echo '# línea de más' >> "$TMP/root/bin/devkit"; corre up
check_salida "comando devkit desincronizado con etiqueta: up también avisa" "el comando devkit difiere del template"

# --- devkit update refresca bin/devkit (DEVKIT-258) --------------------------
# Antes, `update` bajaba el template pero nunca tocaba bin/devkit: el host
# quedaba en la versión del primer `new-project.sh` para siempre. Ahora, si
# el host/devkit.sh de la etiqueta que acaba de bajar difiere del bin/devkit
# instalado, lo copia a bin/devkit.new y lo renombra encima al terminar.
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
export DEVKIT_TEST_TARBALL_HOST_MARCA="# marca-de-la-release-0.2.0"
corre update
unset DEVKIT_TEST_TARBALL_HOST_MARCA
check        "bin/devkit viejo: update lo deja igual al host/devkit.sh que acaba de bajar" si \
             "$(cmp -s "$TMP/root/p/template/host/devkit.sh" "$TMP/root/bin/devkit" && echo si || echo no)"
check        "bin/devkit viejo: le llega la marca de la release nueva" si \
             "$(grep -q 'marca-de-la-release-0.2.0' "$TMP/root/bin/devkit" && echo si || echo no)"
check_salida "bin/devkit viejo: avisa a qué versión quedó" "devkit: comando devkit actualizado a 0\.2\.0"
check        "bin/devkit viejo: no deja bin/devkit.new suelto" no \
             "$([ -e "$TMP/root/bin/devkit.new" ] && echo si || echo no)"
check        "bin/devkit viejo: queda ejecutable" si \
             "$([ -x "$TMP/root/bin/devkit" ] && echo si || echo no)"
check        "bin/devkit viejo: update termina bien" 0 "$ESTADO"

# Si bin/devkit ya viene desincronizado de antes (una release anterior a esta
# card, que nunca lo refrescó), update ya no repite a mitad de su propia
# ejecución el aviso "'devkit update p' lo refresca" (H5, DEVKIT-258: ese
# aviso, corriendo ya dentro de update, solo confundía) y de todas formas
# deja bin/devkit al día al terminar.
escenario 0.1.0
echo '# quedó de una release vieja, antes de DEVKIT-258' >> "$TMP/root/bin/devkit"
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check        "bin/devkit ya venía viejo: update no repite el aviso confuso a mitad de camino" no \
             "$(grep -q "el comando devkit difiere del template; 'devkit update p' lo refresca" "$OUT" && echo si || echo no)"
check        "bin/devkit ya venía viejo: igual queda al día tras actualizar" si \
             "$(cmp -s "$TMP/root/p/template/host/devkit.sh" "$TMP/root/bin/devkit" && echo si || echo no)"
check_salida "bin/devkit ya venía viejo: confirma el refresco" "devkit: comando devkit actualizado a 0\.2\.0"

# bin/devkit ya al día: update no dice nada de "actualizado" ni lo toca.
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check        "bin/devkit ya al día: update no dice que lo actualizó" no \
             "$(grep -q 'comando devkit actualizado' "$OUT" && echo si || echo no)"
check        "bin/devkit ya al día: update termina bien" 0 "$ESTADO"

# DEVKIT-258 (H1): si `compose up` falla a mitad de update, con `set -eu` el
# script corta ahí mismo. El refresco de bin/devkit no debe saltarse: el
# trap EXIT que arma refresh_host_devkit ya quedó registrado antes de
# invocar compose.
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
export DEVKIT_TEST_TARBALL_HOST_MARCA="# marca-de-la-release-0.2.0"
export DEVKIT_TEST_COMPOSE_FAIL=1
corre update
unset DEVKIT_TEST_TARBALL_HOST_MARCA DEVKIT_TEST_COMPOSE_FAIL
check        "compose falla: update igual refresca bin/devkit" si \
             "$(cmp -s "$TMP/root/p/template/host/devkit.sh" "$TMP/root/bin/devkit" && echo si || echo no)"
check_salida "compose falla: igual avisa a qué versión quedó" "devkit: comando devkit actualizado a 0\.2\.0"
check        "compose falla: update termina con error" 1 "$ESTADO"

# --- bin/devkit es un solo comando para todos los proyectos (H6, DEVKIT-258) -
# Antes, refresh_host_devkit y warn_host_stale solo miraban si el archivo
# difería del template de un proyecto, sin saber qué versión quedó instalada
# de verdad: con dos proyectos en versiones distintas en el mismo Mac, el más
# viejo bajaba de versión el comando global y el más nuevo lo subía de
# vuelta, sin fin. $TMP/root/bin/devkit.version simula lo que otro proyecto
# ya dejó instalado.
escenario 0.1.0
echo '# línea de más' >> "$TMP/root/bin/devkit"
printf '1.2.0\n' > "$TMP/root/bin/devkit.version"
corre update
check        "otro proyecto ya dejó bin/devkit en 1.2.0: update del más viejo no lo toca" no \
             "$(grep -q 'comando devkit actualizado' "$OUT" && echo si || echo no)"
check        "otro proyecto ya dejó bin/devkit en 1.2.0: bin/devkit sigue con su marca" si \
             "$(grep -q 'línea de más' "$TMP/root/bin/devkit" && echo si || echo no)"
check        "otro proyecto ya dejó bin/devkit en 1.2.0: update del más viejo termina bien" 0 "$ESTADO"

escenario 0.1.0
echo '# línea de más' >> "$TMP/root/bin/devkit"
printf '1.2.0\n' > "$TMP/root/bin/devkit.version"
corre up
check        "otro proyecto ya dejó bin/devkit en 1.2.0: up del más viejo no pide bajarlo" no \
             "$(grep -q 'el comando devkit difiere del template' "$OUT" && echo si || echo no)"

escenario 0.1.0
echo '# línea de más' >> "$TMP/root/bin/devkit"
printf 'dev\n' > "$TMP/root/bin/devkit.version"
corre update
check        "bin/devkit instalado por un proyecto en dev: update con etiqueta no lo baja" no \
             "$(grep -q 'comando devkit actualizado' "$OUT" && echo si || echo no)"
# H10, DEVKIT-258: pero no calla: dice quién mantiene el comando.
check_salida "bin/devkit instalado por un proyecto en dev: update con etiqueta lo avisa" \
             "lo instaló un proyecto en modo dev y p \(0\.1\.0\) no lo reemplaza"

escenario 0.1.0
echo '# línea de más' >> "$TMP/root/bin/devkit"
printf 'dev\n' > "$TMP/root/bin/devkit.version"
corre up
check_salida "bin/devkit instalado por un proyecto en dev: up con etiqueta lo avisa" \
             "corre 'devkit update <proyecto-dev>' con ese workspace en main"
check        "bin/devkit instalado por un proyecto en dev: up no manda a 'devkit update p'" no \
             "$(grep -q "'devkit update p' lo refresca" "$OUT" && echo si || echo no)"

# Con una etiqueta instalada (no dev) que gana, el aviso de dev no aparece.
escenario 0.1.0
echo '# línea de más' >> "$TMP/root/bin/devkit"
printf '1.2.0\n' > "$TMP/root/bin/devkit.version"
corre up
check        "bin/devkit en una etiqueta más nueva: no habla de modo dev" no \
             "$(grep -q 'lo instaló un proyecto en modo dev' "$OUT" && echo si || echo no)"

# H9, DEVKIT-258: el camino positivo con devkit.version presente. Instalada
# 0.1.0 y update a 0.2.0 por el camino de descarga: refresca, y el trap deja
# devkit.version en la versión destino.
escenario 0.1.0
printf '0.1.0\n' > "$TMP/root/bin/devkit.version"
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
export DEVKIT_TEST_TARBALL_HOST_MARCA="# marca-de-la-release-0.2.0"
corre update
unset DEVKIT_TEST_TARBALL_HOST_MARCA
check        "instalada 0.1.0, update a 0.2.0: refresca bin/devkit" si \
             "$(grep -q 'marca-de-la-release-0.2.0' "$TMP/root/bin/devkit" && echo si || echo no)"
check        "instalada 0.1.0, update a 0.2.0: devkit.version queda en 0.2.0" 0.2.0 \
             "$(cat "$TMP/root/bin/devkit.version" 2>/dev/null)"

# H9, DEVKIT-258: el camino de descarga tampoco baja un comando más nuevo.
# Instalada 1.2.0 y update a 0.2.0, con una etiqueta que sí trae otro
# host/devkit.sh: bin/devkit y devkit.version no cambian.
escenario 0.1.0
printf '1.2.0\n' > "$TMP/root/bin/devkit.version"
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
export DEVKIT_TEST_TARBALL_HOST_MARCA="# marca-de-la-release-0.2.0"
corre update
unset DEVKIT_TEST_TARBALL_HOST_MARCA
check        "instalada 1.2.0, update a 0.2.0 por descarga: no lo actualiza" no \
             "$(grep -q 'comando devkit actualizado' "$OUT" && echo si || echo no)"
check        "instalada 1.2.0, update a 0.2.0 por descarga: bin/devkit no cambia" si \
             "$(cmp -s "$DEVKIT" "$TMP/root/bin/devkit" && echo si || echo no)"
check        "instalada 1.2.0, update a 0.2.0 por descarga: devkit.version sigue en 1.2.0" 1.2.0 \
             "$(cat "$TMP/root/bin/devkit.version" 2>/dev/null)"
check        "instalada 1.2.0, update a 0.2.0 por descarga: termina bien" 0 "$ESTADO"

# En dev, el refresco solo sigue al workspace vivo si su rama es main: una
# rama de card sin mergear no debe instalarse como el comando global.
escenario dev
echo '# workspace nuevo' >> "$TMP/ws/devkit/host/devkit.sh"
export DEVKIT_TEST_WS_BRANCH="fix/DEVKIT-999-algo"
corre update
unset DEVKIT_TEST_WS_BRANCH
check        "dev en una rama de card: update no instala su devkit.sh como comando global" no \
             "$(grep -q 'comando devkit actualizado' "$OUT" && echo si || echo no)"
check        "dev en una rama de card: bin/devkit no cambia" si \
             "$(cmp -s "$DEVKIT" "$TMP/root/bin/devkit" && echo si || echo no)"
check        "dev en una rama de card: update termina bien" 0 "$ESTADO"

# dev en main sigue ganando aunque otro proyecto ya haya dejado una versión
# con etiqueta más nueva instalada: dev sigue el main de este repo.
escenario dev
echo '# workspace nuevo' >> "$TMP/ws/devkit/host/devkit.sh"
printf '9.9.9\n' > "$TMP/root/bin/devkit.version"
corre update
check_salida "dev en main gana aunque haya una etiqueta más nueva instalada" "devkit: comando devkit actualizado a dev"

# --- Resolución de extensiones del editor ------------------------------------
# resolve_extensions: "latest" se resuelve contra Open VSX y queda en .env y
# extensions.lock; una versión fija no vuelve a resolverse contra la API,
# pero desde DEVKIT-73 sí se consulta para comprobar engines.vscode contra el
# editor; sin red se usa la última resolución guardada con aviso; sin red y
# sin resolución previa el comando se detiene sin construir.
env_ext() { sed -n 's/^DEVKIT_EXTENSIONS=//p' "$TMP/root/p/.env" | tail -1; }
lock_ext() { tr '\n' ' ' < "$TMP/root/p/extensions.lock" 2>/dev/null | sed 's/ *$//'; }

export DEVKIT_TEST_OVX_VERSION=2.1.270
escenario dev; corre recreate
check        "latest resuelto: queda en .env" "Anthropic.claude-code=2.1.270" "$(env_ext)"
check        "latest resuelto: queda en extensions.lock" "Anthropic.claude-code=2.1.270" "$(lock_ext)"
check_docker "latest resuelto: consulta Open VSX" si 'curl -sS -o .* -w %\{http_code\} .*https://open-vsx\.org/api/Anthropic/claude-code/latest'
check        "latest resuelto: motor compatible no avisa" no \
             "$(grep -q 'exige VS Code' "$OUT" && echo si || echo no)"
check        "latest resuelto: termina bien" 0 "$ESTADO"
unset DEVKIT_TEST_OVX_VERSION

escenario dev
printf '"Anthropic.claude-code" = "1.2.3"\n' > "$TMP/ws/devkit/vscode/extensions.toml"
cp "$TMP/ws/devkit/vscode/extensions.toml" "$TMP/root/p/template/vscode/extensions.toml"
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^1.0.0"
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_2_3
check        "versión fija: queda en .env tal cual" "Anthropic.claude-code=1.2.3" "$(env_ext)"
check_docker "versión fija: sí consulta Open VSX para comprobar el motor" si \
  'curl -sS -o .* -w %\{http_code\} .*https://open-vsx\.org/api/Anthropic/claude-code/1\.2\.3'
check        "versión fija compatible: termina bien" 0 "$ESTADO"

escenario dev; printf 'Anthropic.claude-code=9.9.8\n' > "$TMP/root/p/extensions.lock"
export DEVKIT_TEST_CURL_DOWN=1
corre recreate
unset DEVKIT_TEST_CURL_DOWN
check_salida "sin red con resolución previa: avisa" \
  'sin red para Open VSX; se usa la última versión resuelta de Anthropic\.claude-code \(9\.9\.8\)'
check        "sin red con resolución previa: usa la versión guardada" "Anthropic.claude-code=9.9.8" "$(env_ext)"
check_docker "sin red con resolución previa: igual construye" si 'up -d'
check        "sin red con resolución previa: termina bien" 0 "$ESTADO"

escenario dev; rm -f "$TMP/root/p/extensions.lock"
export DEVKIT_TEST_CURL_DOWN=1
corre recreate
unset DEVKIT_TEST_CURL_DOWN
check_salida "sin red sin resolución previa: lo explica" "sin red y sin resolución previa"
check        "sin red sin resolución previa: se detiene" 1 "$ESTADO"
check_docker "sin red sin resolución previa: no construye" no 'up -d'

escenario dev
export DEVKIT_TEST_CURL_404=1
corre recreate
unset DEVKIT_TEST_CURL_404
check_salida "404 de Open VSX: lo explica" "no existe en Open VSX"
check        "404 de Open VSX: se detiene" 1 "$ESTADO"
check_docker "404 de Open VSX: no construye" no 'up -d'

escenario dev; printf 'Anthropic.claude-code=9.9.8\n' > "$TMP/root/p/extensions.lock"
export DEVKIT_TEST_CURL_503=1
corre recreate
unset DEVKIT_TEST_CURL_503
check_salida "503 de Open VSX: lo distingue de sin red" "Open VSX respondió 503; se usa la última versión resuelta de Anthropic\.claude-code \(9\.9\.8\)"
check        "503 de Open VSX: termina bien" 0 "$ESTADO"

escenario dev; rm -f "$TMP/root/p/extensions.lock"
export DEVKIT_TEST_CURL_503=1
corre recreate
unset DEVKIT_TEST_CURL_503
check_salida "503 de Open VSX sin resolución previa: lo distingue de sin red" "Open VSX respondió 503 y sin resolución previa"
check        "503 de Open VSX sin resolución previa: se detiene" 1 "$ESTADO"

# --- Chequeo de motor (engines.vscode) contra el editor (DEVKIT-73) ---------
# La imagen de prueba trae openvscode-server 1.109.5 (ARG del Dockerfile que
# escribe `escenario`). "^2.0.0" no lo admite; "^1.0.0" sí.
escenario dev
export DEVKIT_TEST_OVX_ENGINE="^2.0.0"
export DEVKIT_TEST_OVX_ALLVERSIONS='"9.9.9":"https://open-vsx.org/api/Anthropic/claude-code/9.9.9","9.9.8":"https://open-vsx.org/api/Anthropic/claude-code/9.9.8"'
export DEVKIT_TEST_OVX_ENGINE_9_9_9="^2.0.0"
export DEVKIT_TEST_OVX_ENGINE_9_9_8="^1.0.0"
corre recreate
check_salida "latest incompatible con fallback: avisa y dice cuál usa" \
  'exige VS Code \^2\.0\.0; la imagen lleva 1\.109\.5; se usa 9\.9\.8 \(VS Code \^1\.0\.0\)'
check        "latest incompatible con fallback: usa la versión que sí calza" \
  "Anthropic.claude-code=9.9.8" "$(env_ext)"
check        "latest incompatible con fallback: termina bien" 0 "$ESTADO"
unset DEVKIT_TEST_OVX_ENGINE_9_9_9 DEVKIT_TEST_OVX_ENGINE_9_9_8

escenario dev
export DEVKIT_TEST_OVX_ENGINE="^2.0.0"
export DEVKIT_TEST_OVX_ALLVERSIONS='"9.9.9":"https://open-vsx.org/api/Anthropic/claude-code/9.9.9"'
export DEVKIT_TEST_OVX_ENGINE_9_9_9="^2.0.0"
corre recreate
check_salida "latest incompatible sin ninguna que calce: lo explica" \
  "exige VS Code \^2\.0\.0; la imagen lleva 1\.109\.5 y no hay ninguna versión publicada que calce"
check        "latest incompatible sin ninguna que calce: se detiene" 1 "$ESTADO"
check_docker "latest incompatible sin ninguna que calce: no construye" no 'up -d'
unset DEVKIT_TEST_OVX_ENGINE_9_9_9 DEVKIT_TEST_OVX_ENGINE DEVKIT_TEST_OVX_ALLVERSIONS

escenario dev
printf '"Anthropic.claude-code" = "1.2.3"\n' > "$TMP/ws/devkit/vscode/extensions.toml"
cp "$TMP/ws/devkit/vscode/extensions.toml" "$TMP/root/p/template/vscode/extensions.toml"
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^2.0.0"
export DEVKIT_TEST_OVX_ENGINE="^1.0.0"
export DEVKIT_TEST_OVX_ALLVERSIONS='"1.2.3":"https://open-vsx.org/api/Anthropic/claude-code/1.2.3","1.2.2":"https://open-vsx.org/api/Anthropic/claude-code/1.2.2"'
export DEVKIT_TEST_OVX_ENGINE_1_2_2="^1.0.0"
corre recreate
check_salida "versión fija incompatible: se detiene antes del build" \
  'Anthropic\.claude-code 1\.2\.3 exige VS Code \^2\.0\.0; la imagen lleva 1\.109\.5'
check_salida "versión fija incompatible: sugiere una que sí calza" \
  "sugerencia: 1\.2\.2 sí calza con VS Code 1\.109\.5"
check        "versión fija incompatible: se detiene" 1 "$ESTADO"
check_docker "versión fija incompatible: no construye" no 'up -d'
unset DEVKIT_TEST_OVX_ENGINE_1_2_3 DEVKIT_TEST_OVX_ENGINE DEVKIT_TEST_OVX_ALLVERSIONS DEVKIT_TEST_OVX_ENGINE_1_2_2

escenario dev
printf '"Anthropic.claude-code" = "1.2.3"\n' > "$TMP/ws/devkit/vscode/extensions.toml"
cp "$TMP/ws/devkit/vscode/extensions.toml" "$TMP/root/p/template/vscode/extensions.toml"
export DEVKIT_TEST_OVX_ENGINE_1_2_3="~1.2.3"
corre recreate
check_salida "rango de motor desconocido: avisa y no rechaza" \
  'declara engines\.vscode "~1\.2\.3", un formato que no reconozco; se instala sin verificar'
check        "rango de motor desconocido: igual se instala" \
  "Anthropic.claude-code=1.2.3" "$(env_ext)"
check        "rango de motor desconocido: termina bien" 0 "$ESTADO"
unset DEVKIT_TEST_OVX_ENGINE_1_2_3

# --- Reintentos ante un 5xx de Open VSX (DEVKIT-73) --------------------------
# Con --retry 5 (6 intentos en total), un Open VSX que solo falla en el
# primero se recupera solo; devkit.sh no ve más que el 200 final.
escenario dev; export DEVKIT_TEST_CURL_503_COUNT=1
corre recreate
unset DEVKIT_TEST_CURL_503_COUNT
check        "503 una vez y luego 200: se recupera sin avisar de sin red" no \
             "$(grep -qE 'sin red|Open VSX respondió' "$OUT" && echo si || echo no)"
check        "503 una vez y luego 200: resuelve normal" "Anthropic.claude-code=9.9.9" "$(env_ext)"
check        "503 una vez y luego 200: termina bien" 0 "$ESTADO"
check_docker "503 una vez y luego 200: construye" si 'up -d'

# Si el número de intentos de --retry no alcanza a que Open VSX se recupere,
# se comporta como un 503 persistente (H8, DEVKIT-67): se distingue de "sin
# red" y, sin resolución previa, se detiene nombrando a Open VSX.
escenario dev; export DEVKIT_TEST_CURL_503_COUNT=999
corre recreate
unset DEVKIT_TEST_CURL_503_COUNT
check_salida "503 persistente tras reintentar: nombra a Open VSX" "Open VSX respondió 503"
check        "503 persistente tras reintentar: se detiene" 1 "$ESTADO"

# --- ARG OPENVSCODE_VERSION ausente del Dockerfile ---------------------------
escenario dev; printf '' > "$TMP/ws/devkit/Dockerfile"; cp "$TMP/ws/devkit/Dockerfile" "$TMP/root/p/template/Dockerfile"
corre recreate
check_salida "sin ARG OPENVSCODE_VERSION: lo explica" "no se encontró ARG OPENVSCODE_VERSION"
check        "sin ARG OPENVSCODE_VERSION: se detiene" 1 "$ESTADO"

# --- Línea inválida en extensions.toml (H5, DEVKIT-67) -----------------------
# Una línea que no calza con "id" = "versión" (comilla simple, sin comillas,
# sangría...) se ignoraba en silencio y la extensión desaparecía sin aviso.
escenario dev
printf '"Anthropic.claude-code" = "1.2.3"\n  '"'"'ms.otra'"'"' = '"'"'1.0.0'"'"'\n' > "$TMP/ws/devkit/vscode/extensions.toml"
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^1.0.0"
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_2_3
check_salida "línea inválida de extensions.toml avisa" 'no calzan con'
check        "línea inválida no impide construir con la extensión válida" \
             "Anthropic.claude-code=1.2.3" "$(env_ext)"
check        "línea inválida: termina bien" 0 "$ESTADO"

# --- Línea válida con comentario al final (H9, DEVKIT-67) --------------------
# El `sed` que extrae ya toleraba un comentario al final de la línea; la
# validación no, y avisaba "se ignoran" de una línea que sí se usaba.
escenario dev
printf '"Anthropic.claude-code" = "1.2.3"  # fija\n' > "$TMP/ws/devkit/vscode/extensions.toml"
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^1.0.0"
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_2_3
check        "línea con comentario al final no avisa" no \
             "$(grep -q 'no calzan con' "$OUT" && echo si || echo no)"
check        "línea con comentario al final se usa igual" \
             "Anthropic.claude-code=1.2.3" "$(env_ext)"

# --- extensions de .devkit/devkit.toml (DEVKIT-181) --------------------------
# `extensions` en .devkit/devkit.toml se suma a devkit/vscode/extensions.toml
# del template, el mismo patrón que `apt` y `domains`. sync_toml_env (que
# corre antes que resolve_extensions en recreate/rebuild/update) la deja
# cruda en DEVKIT_PROJECT_EXTENSIONS; resolve_extensions la une, resolviendo
# todo contra Open VSX igual que antes.
escenario dev
printf 'extensions = ["ms.otra@1.0.0"]\n' | tee -a "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml" >/dev/null
export DEVKIT_TEST_OVX_ENGINE_1_0_0="^1.0.0"
export DEVKIT_TEST_OVX_VERSION=2.1.270
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_0_0 DEVKIT_TEST_OVX_VERSION
check        "unión: incluye la del proyecto y la del template resuelta" \
             "ms.otra=1.0.0 Anthropic.claude-code=2.1.270" "$(env_ext)"
check        "unión: termina bien" 0 "$ESTADO"

escenario dev
printf 'extensions = ["Anthropic.claude-code@1.2.3"]\n' | tee -a "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml" >/dev/null
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^1.0.0"
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_2_3
check        "duplicado: gana la versión del proyecto" \
             "Anthropic.claude-code=1.2.3" "$(env_ext)"
check_docker "duplicado: no consulta el /latest del template para esa id" no \
             'open-vsx\.org/api/Anthropic/claude-code/latest'
check        "duplicado: termina bien" 0 "$ESTADO"

# Open VSX no distingue mayúsculas en el id: un duplicado con otra
# capitalización también debe deduplicarse a favor del proyecto (H2, DEVKIT-181).
escenario dev
printf 'extensions = ["anthropic.claude-code@1.2.3"]\n' | tee -a "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml" >/dev/null
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^1.0.0"
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_2_3
check        "duplicado con otra capitalización: gana la versión del proyecto" \
             "anthropic.claude-code=1.2.3" "$(env_ext)"
check_docker "duplicado con otra capitalización: no consulta el /latest del template" no \
             'open-vsx\.org/api/Anthropic/claude-code/latest'
check        "duplicado con otra capitalización: termina bien" 0 "$ESTADO"

escenario dev
printf 'extensions = ["ms.rota@9.9.9"]\n' | tee -a "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml" >/dev/null
corre recreate
check_salida "404 de una extensión del proyecto: lo explica y nombra el origen" \
             'extensión ms\.rota 9\.9\.9 no existe en Open VSX \(404\) \(declarada en el proyecto\)'
check        "404 de una extensión del proyecto: se detiene" 1 "$ESTADO"
check_docker "404 de una extensión del proyecto: no construye" no 'up -d'

# Elemento inválido en extensions del proyecto: se avisa y se ignora, sin
# impedir que las extensiones válidas (del proyecto y del template) resuelvan
# (H4, DEVKIT-181).
escenario dev
printf 'extensions = ["sinpunto", "ms.valida@1.0.0"]\n' | tee -a "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml" >/dev/null
export DEVKIT_TEST_OVX_ENGINE_1_0_0="^1.0.0"
export DEVKIT_TEST_OVX_VERSION=2.1.270
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_0_0 DEVKIT_TEST_OVX_VERSION
check_salida "elemento inválido de extensions del proyecto avisa" \
             'extensions de \.devkit/devkit\.toml tiene elementos que no calzan'
check        "elemento inválido no impide construir con las válidas" \
             "ms.valida=1.0.0 Anthropic.claude-code=2.1.270" "$(env_ext)"
check        "elemento inválido: termina bien" 0 "$ESTADO"

# Motor incompatible de una extensión fija del proyecto: se detiene y nombra
# el origen, igual que el 404 de arriba (H5, DEVKIT-181).
escenario dev
printf 'extensions = ["ms.vieja@1.2.3"]\n' | tee -a "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml" >/dev/null
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^2.0.0"
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_2_3
check_salida "motor incompatible de una extensión del proyecto nombra el origen" \
             'ms\.vieja 1\.2\.3 exige VS Code \^2\.0\.0; la imagen lleva 1\.109\.5 \(declarada en el proyecto\)'
check        "motor incompatible de una extensión del proyecto: se detiene" 1 "$ESTADO"
check_docker "motor incompatible de una extensión del proyecto: no construye" no 'up -d'

# "latest" declarado por el proyecto, sin @versión: se resuelve contra Open
# VSX igual que "latest" del template (H5, DEVKIT-181).
escenario dev
printf 'extensions = ["ms.nueva"]\n' | tee -a "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml" >/dev/null
export DEVKIT_TEST_OVX_ENGINE="^1.0.0"
export DEVKIT_TEST_OVX_VERSION=3.0.0
corre recreate
unset DEVKIT_TEST_OVX_ENGINE DEVKIT_TEST_OVX_VERSION
check        "latest del proyecto sin versión se resuelve" \
             "ms.nueva=3.0.0 Anthropic.claude-code=3.0.0" "$(env_ext)"
check        "latest del proyecto sin versión: termina bien" 0 "$ESTADO"

# `update` corre sync_toml_env antes de resolve_extensions: sin ese orden,
# DEVKIT_PROJECT_EXTENSIONS quedaría con el valor de antes (o vacío) y la
# extensión declarada en .devkit/devkit.toml no llegaría a la imagen
# (H5, DEVKIT-181).
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\nextensions = ["ms.nueva@1.0.0"]\n' > "$TMP/ws/.devkit/devkit.toml"
cp "$TMP/ws/.devkit/devkit.toml" "$TMP/origin/main.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
export DEVKIT_TEST_OVX_ENGINE_1_0_0="^1.0.0"
export DEVKIT_TEST_OVX_VERSION=2.1.270
corre update
unset DEVKIT_TEST_OVX_ENGINE_1_0_0 DEVKIT_TEST_OVX_VERSION
check        "update resuelve las extensions del proyecto (sync_toml_env corre antes)" \
             "ms.nueva=1.0.0 Anthropic.claude-code=2.1.270" "$(env_ext)"
check        "update con extensions del proyecto: termina bien" 0 "$ESTADO"

# --- case dentro de $( ) sin "(" de apertura (DEVKIT-265) --------------------
# El bash 3.2 de macOS (/bin/sh del Mac) cuenta paréntesis al leer $( ... ) y
# el ")" de un patrón sin "(" cierra la sustitución antes de tiempo. Dash, con
# el que corre esta suite, no falla, así que sin esta comprobación el error solo
# aparecería en el Mac. Imprime "archivo:línea: línea" por cada patrón sin "(".
# El detector reconoce el patrón por su posición, no por su forma (H1 de la
# revisión): es el primer texto tras `case ... in` y tras cada `;;` o `;&`, sea
# una palabra, un texto con comillas o espacios, o `a | b`, y esté en la línea
# del `case` o en una posterior. Lleva la profundidad de `$(` y `(` de una
# línea a otra: una sustitución que abre a mitad de línea o con un comentario
# al final también cuenta, y el `case` puede ir en la misma línea.
cat > "$TMP/case_sin_par.awk" <<'AWK'
BEGIN { depth = 0; st = 0; ncase = 0; hd = "" }
FNR == 1 { depth = 0; st = 0; ncase = 0; hd = "" }
# Cuerpo de un heredoc: es texto, no código.
hd != "" { l = $0; sub(/^\t+/, "", l); if (l == hd) hd = ""; next }
{
  linea = $0; n = length(linea); q = ""; i = 1
  while (i <= n) {
    c = substr(linea, i, 1); d = substr(linea, i + 1, 1)
    ant = (i == 1) ? " " : substr(linea, i - 1, 1)
    resto = substr(linea, i)
    if (c == "\\") { i += 2; continue }
    if (q == "\047") { if (c == "\047") q = ""; i++; continue }
    if (q == "\"") {
      if (c == "\"") q = ""
      else if (c == "$" && d == "(") { depth++; qs[depth] = q; q = ""; i++ }
      i++; continue
    }
    # st 2: se espera un patrón (tras `in` o tras `;;`).
    if (st == 2) {
      if (c ~ /[[:space:]]/) { i++; continue }
      if (c == "#") break
      if (resto ~ /^esac([[:space:];)&|]|$)/) { ncase--; st = 0; i += 4; continue }
      if (c == "(") { st = 3; pdepth = depth; i++; continue }
      if (cdepth[ncase] > 0) print FILENAME ":" FNR ": " linea
      st = 3; pdepth = depth
    }
    if (c == "\"" || c == "\047") { q = c; i++; continue }
    if (c == "$" && d == "(") { depth++; qs[depth] = ""; i += 2; continue }
    if (c == "(") { depth++; qs[depth] = ""; i++; continue }
    if (c == ")") {
      if (st == 3 && depth == pdepth) { st = 0; i++; continue }
      if (depth > 0) { q = qs[depth]; depth-- }
      i++; continue
    }
    if (st == 3) { i++; continue }
    if (c == "#" && ant ~ /[[:space:]]/) break
    if (c == ";" && (d == ";" || d == "&") && ncase > 0) {
      st = 2; i += 2
      if (substr(linea, i, 1) == "&") i++
      continue
    }
    if (ant ~ /[[:space:];(&|{]/) {
      if (st == 0 && resto ~ /^case([[:space:]]|$)/) { ncase++; cdepth[ncase] = depth; st = 1; i += 4; continue }
      if (st == 0 && ncase > 0 && resto ~ /^esac([[:space:];)&|]|$)/) { ncase--; i += 4; continue }
      if (st == 1 && resto ~ /^in([[:space:]]|$)/) { st = 2; i += 2; continue }
    }
    i++
  }
  if (match(linea, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z_0-9]*/)) {
    h = substr(linea, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["\047]?/, "", h); hd = h
  }
}
AWK
case_sin_parentesis() {  # case_sin_parentesis <archivo>...
  awk -f "$TMP/case_sin_par.awk" "$@"
}
cat > "$TMP/case_malo.sh" <<'FIXTURE'
x="$(
  printf '%s\n' a | while IFS= read -r i; do
    case "$i" in
      *@*) echo con ;;
      (*)  echo sin ;;
    esac
  done
)"
FIXTURE
# Formas que el detector anterior no veía (H1): cada patrón sin "(" cuenta una.
cat > "$TMP/case_malo_forma.sh" <<'FIXTURE'
x="$(
  printf '%s\n' a | while IFS= read -r i; do
    case "$i" in
      *" $(echo x) "*) echo a ;;
      "a b") echo b ;;
      a | b) echo c ;;
      (*) echo d ;;
    esac
  done
)"
y="$(case "$1" in -*) shift ;; *) break ;; esac)"
z="$(printf a | while read -r i; do
  case "$i" in
    a) echo ;;
  esac
done
)"
w="$(  # comentario
  case "$1" in
    a) echo ;;
  esac
)"
FIXTURE
cat > "$TMP/case_bueno.sh" <<'FIXTURE'
x="$(
  printf '%s\n' a | while IFS= read -r i; do
    case "$i" in
      (*@*) echo con ;;
      (*)   echo sin ;;
    esac
  done
)"
y="$(case "$1" in (-*) shift ;; (*) break ;; esac)"
z="$(  # comentario
  case "$1" in
    ("a b") echo ;;
    (a | b) echo ;;
    (*" $(echo x) "*) echo ;;
  esac
)"
case "$x" in
  *) echo fuera de $( ) no importa ;;
esac
w="$(date)" ; case "$w" in a) echo ${#w} ;; *) echo $# ;; esac
FIXTURE
check "case sin \"(\" dentro de \$( ): el detector lo encuentra" 1 \
      "$(case_sin_parentesis "$TMP/case_malo.sh" | wc -l | tr -d ' ')"
check "case sin \"(\" con espacios, comillas, misma línea o \$( sin cerrar: el detector los encuentra" 7 \
      "$(case_sin_parentesis "$TMP/case_malo_forma.sh" | wc -l | tr -d ' ')"
check "case con \"(\" dentro de \$( ) o fuera de él: el detector calla" 0 \
      "$(case_sin_parentesis "$TMP/case_bueno.sh" | wc -l | tr -d ' ')"
sin_par="$(case_sin_parentesis "$HERE/devkit.sh" "$HERE/../../new-project.sh")"
check "devkit.sh y new-project.sh: ningún case en \$( ) sin \"(\" (bash 3.2)" "" "$sin_par"
[ -z "$sin_par" ] || printf '%s\n' "$sin_par" | sed 's/^/     /'

# --- devkit code -------------------------------------------------------------
escenario dev; corre code 0 secreto123
check        "code con token termina bien" 0 "$ESTADO"
check_salida "code con token imprime la URL" "http://127\.0\.0\.1:3000/\?tkn=secreto123"

escenario dev; corre code
check        "code sin token falla" 1 "$ESTADO"
check_salida "code sin token lo explica" "sin token de VS Code"

# `open` presente: no se imprime la URL cuando `open` la abre bien.
open_doble 0
escenario dev; corre code 0 secreto123
check        "code con open que abre bien termina en 0" 0 "$ESTADO"
check        "code con open que abre bien no imprime la URL" no \
             "$(grep -q 'tkn=secreto123' "$OUT" && echo si || echo no)"

open_doble 1
escenario dev; corre code 0 secreto123
check        "code con open que falla termina en 0" 0 "$ESTADO"
check_salida "code con open que falla igual imprime la URL" "http://127\.0\.0\.1:3000/\?tkn=secreto123"

open_doble ausente

# --- wait_ready (DEVKIT-159) --------------------------------------------------
# `devkit code`/`devkit shell` esperan el arranque hasta 10 min mostrando el
# avance, en vez de rendirse a los 120 s con puntos que no dicen nada; y
# cortan antes del límite si el contenedor no está corriendo, en vez de
# esperar a uno muerto.

# El marcador tarda en aparecer (arranque en frío): sigue esperando, muestra
# la última línea [devkit] del log mientras tanto, y continúa en cuanto
# aparece.
escenario dev
export DEVKIT_TEST_WAIT_SLEEP=0 DEVKIT_TEST_READY_AFTER=3 COLUMNS=200 \
  DEVKIT_TEST_LOGS_CONTENT='[devkit] restaurando sandbox.local desde Dropbox'
corre code 0 secreto123
unset DEVKIT_TEST_WAIT_SLEEP DEVKIT_TEST_READY_AFTER COLUMNS DEVKIT_TEST_LOGS_CONTENT
check        "wait_ready: espera y sigue en cuanto aparece el marcador" 0 "$ESTADO"
check_salida "wait_ready: muestra la última línea [devkit] del log mientras espera" \
             "restaurando sandbox\.local desde Dropbox"
check_salida "wait_ready: tras esperar, code igual imprime la URL" \
             "http://127\.0\.0\.1:3000/\?tkn=secreto123"
check_docker "wait_ready: consulta docker logs del arranque actual mientras espera" si \
             '^docker logs --since [^[:space:]]+ devkit-p$'

# La línea de avance se recorta al ancho de la terminal: con un prefijo de
# ~47 columnas y una línea real de entrypoint.sh de más de 200 caracteres, no
# debe pasar de 80 columnas ni saltar de fila (H1, DEVKIT-159).
escenario dev
export DEVKIT_TEST_WAIT_SLEEP=0 DEVKIT_TEST_READY_AFTER=3 COLUMNS=80 \
  DEVKIT_TEST_LOGS_CONTENT="[devkit] $(printf 'x%.0s' $(seq 1 200))"
corre code 0 secreto123
unset DEVKIT_TEST_WAIT_SLEEP DEVKIT_TEST_READY_AFTER COLUMNS DEVKIT_TEST_LOGS_CONTENT
esc="$(printf '\033')"
mas_larga="$(grep -o $'\r[^\r]*' "$OUT" | tr -d '\r' | sed "s/${esc}\\[K\$//" | awk '{ print length }' | sort -rn | head -1)"
check "wait_ready: recorta la línea de avance al ancho de la terminal" 79 "${mas_larga:-0}"

# El servicio `dev` corre con tty: true, así que docker logs devuelve cada
# línea terminada en \r\n. Si no se limpia ese \r, printf '\r%s\033[K' vuelve
# a la columna 0 con él y \033[K borra la fila entera: el avance queda en
# blanco durante toda la espera (H4, DEVKIT-159).
escenario dev
export DEVKIT_TEST_WAIT_SLEEP=0 DEVKIT_TEST_READY_AFTER=3 COLUMNS=200 \
  DEVKIT_TEST_LOGS_CONTENT="$(printf '\033[1;34m[devkit]\033[0m restaurando sandbox\r')"
corre code 0 secreto123
unset DEVKIT_TEST_WAIT_SLEEP DEVKIT_TEST_READY_AFTER COLUMNS DEVKIT_TEST_LOGS_CONTENT
check_salida "wait_ready: quita el \\r final bajo tty antes de imprimir el avance" \
             $'restaurando sandbox\033\\[K'

# El contenedor no está corriendo: corta de inmediato con el estado real, sin
# esperar el límite.
escenario dev
export DEVKIT_TEST_DOWN_STATUS=Exited
corre shell 1
unset DEVKIT_TEST_DOWN_STATUS
check        "wait_ready: contenedor no corriendo corta antes del límite" 1 "$ESTADO"
check_salida "wait_ready: nombra el estado y manda a levantarlo" \
             "el contenedor devkit-p no está corriendo \(estado Exited\); levántalo con 'devkit up p'"
check_docker "wait_ready: contenedor no corriendo no abre un shell" no 'exec -it devkit-p zsh'

# El marcador nunca aparece: corta al llegar al límite, no antes ni después.
escenario dev
export DEVKIT_TEST_WAIT_MAX=2 DEVKIT_TEST_WAIT_SLEEP=0 DEVKIT_TEST_READY_NEVER=1
corre shell
unset DEVKIT_TEST_WAIT_MAX DEVKIT_TEST_WAIT_SLEEP DEVKIT_TEST_READY_NEVER
check        "wait_ready: si el marcador nunca aparece corta en el límite" 1 "$ESTADO"
check_salida "wait_ready: al llegar al límite manda a los logs" \
             "el arranque no terminó en 2 s; mira 'devkit logs p'"
check_docker "wait_ready: al llegar al límite sigue viendo el contenedor corriendo" si \
             '^docker inspect -f \{\{\.State\.Running\}\} devkit-p$'

# --- devkit awake ------------------------------------------------------------
# caffeinate_doble <presente|ausente>: el doble registra la llamada y ejecuta lo
# que envuelve, como el de verdad; así se ve que `docker wait` corre dentro de
# la aserción y no antes ni después (DEVKIT-66).
caffeinate_doble() {
  if [ "$1" = "ausente" ]; then
    rm -f "$TMP/bin/caffeinate"
  else
    cat >"$TMP/bin/caffeinate" <<'FIN'
#!/bin/sh
echo "caffeinate $*" >> "$DEVKIT_TEST_LOG"
[ "$1" = -i ] && shift
exec "$@"
FIN
    chmod +x "$TMP/bin/caffeinate"
  fi
}

caffeinate_doble presente
escenario dev; corre awake
check        "awake con contenedor vivo termina bien" 0 "$ESTADO"
check_docker "awake envuelve docker wait en caffeinate -i" si '^caffeinate -i docker wait devkit-p$'
check_docker "awake espera al contenedor" si '^docker wait devkit-p$'
check_salida "awake dice cómo soltarlo" "Ctrl-C para soltar"

escenario dev; corre awake 1
check        "awake sin contenedor falla" 1 "$ESTADO"
check_salida "awake sin contenedor lo explica" "no está corriendo"
check_docker "awake sin contenedor no llama a caffeinate" no '^caffeinate'

caffeinate_doble ausente
escenario dev; corre awake
check        "awake sin caffeinate falla" 1 "$ESTADO"
check_salida "awake sin caffeinate lo explica" "solo funciona en macOS"
check_docker "awake sin caffeinate no espera al contenedor" no 'docker wait'

corre nada
check_salida "la ayuda lista awake" "devkit awake <proyecto>"

# --- Shim del proxy: cookie, endpoint de la clave y WebSocket (DEVKIT-259) --
# A diferencia de todo lo anterior, esto no dobla `docker`: corre el shim de
# verdad (devkit/proxy/proxy-shim.sh) con socat real contra dobles de dev (un
# HTTP mínimo y el endpoint de dígesto de dev:$DIGEST_PORT), en puertos altos
# propios. Nunca toca el proxy real del contenedor. Puertos derivados del PID
# para no chocar entre corridas concurrentes.
if ! command -v socat >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1 \
    || ! command -v timeout >/dev/null 2>&1 || ! command -v mkfifo >/dev/null 2>&1; then
  echo "skip shim: falta socat, sha256sum, timeout o mkfifo"
# El shim corre por su shebang #!/bin/bash y usa ${x,,} (bash 4+). En macOS
# /bin/bash es 3.2: sin este guard, los casos fallarían con "bad
# substitution" en vez de saltarse (DEVKIT-259, H10). Alpine trae bash 5.
elif ! /bin/bash -c 'x=A; : "${x,,}"' 2>/dev/null; then
  echo "skip shim: /bin/bash < 4"
else
  base=$((21000 + ($$ % 400) * 10))
  shim_port=$base
  dev_port=$((base + 1))
  digest_port=$((base + 2))
  ws_port=$((base + 3))
  SHIM="$HERE/../proxy/proxy-shim.sh"
  sw="$TMP/shim"
  mkdir -p "$sw"
  printf 'token-de-prueba-devkit-259' > "$sw/token"
  digest_esperado="$(sha256sum "$sw/token" | cut -c1-64)"

  cat > "$sw/dev_http.sh" <<'FIN'
#!/bin/bash
read -r reqline
path="${reqline#* }"; path="${path%% *}"
while IFS= read -r l; do l="${l%$'\r'}"; [ -z "$l" ] && break; done
# La raíz imita a Node con httpAllowHalfOpen=false (DEVKIT-259, H1 y H9): si
# el shim cierra su lado de escritura (EOF) antes de la respuesta, no
# responde. Solo si la espera se agota (código >128) sigue y responde.
if [ "$path" = / ]; then
  read -r -t 1.5 _
  [ $? -gt 128 ] || exit 0
fi
body="cuerpo-$path"
len=${#body}
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "$len" "$body"
FIN
  # dev:$DIGEST_PORT no se dobla: corre el mismo script que lanza
  # entrypoint.sh, para que un error en él haga fallar la suite (DEVKIT-259,
  # H8).
  DIGEST="$HERE/../scripts/vscode-secret-digest.sh"
  cat > "$sw/dev_ws.sh" <<'FIN'
#!/bin/bash
read -r reqline
while IFS= read -r l; do l="${l%$'\r'}"; [ -z "$l" ] && break; done
printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
while IFS= read -r -t 5 frame; do printf 'ECHO:%s\n' "$frame"; done
FIN
  chmod +x "$sw/dev_http.sh" "$sw/dev_ws.sh"

  shim_pids=()
  socat TCP-LISTEN:$dev_port,fork,reuseaddr "EXEC:$sw/dev_http.sh" >"$sw/dev_http.log" 2>&1 & shim_pids+=("$!")
  socat TCP-LISTEN:$digest_port,fork,reuseaddr "EXEC:$DIGEST $sw/token" >"$sw/dev_digest.log" 2>&1 & shim_pids+=("$!")
  socat TCP-LISTEN:$ws_port,fork,reuseaddr "EXEC:$sw/dev_ws.sh" >"$sw/dev_ws.log" 2>&1 & shim_pids+=("$!")
  sleep 0.3
  env DEVKIT_SHIM_UPSTREAM=127.0.0.1 DEVKIT_SHIM_UPSTREAM_PORT="$dev_port" DEVKIT_SHIM_DIGEST_PORT="$digest_port" \
    socat TCP-LISTEN:$shim_port,fork,reuseaddr "EXEC:$SHIM" >"$sw/shim.log" 2>&1 & shim_pids+=("$!")
  sleep 0.3

  "$REAL_CURL" -s --max-time 4 -D "$sw/root.hdr" "http://127.0.0.1:$shim_port/" -o "$sw/root.body"
  check_hdr() { grep -qE "$2" "$1" && printf 'ok   %-58s\n' "$3" || { printf 'FAIL %-58s no aparece /%s/ en %s\n' "$3" "$2" "$1"; fail=1; }; }
  check_hdr "$sw/root.hdr" "^Set-Cookie: vscode-secret-key-path=/devkit/secret-key; Path=/; SameSite=Lax" \
    "shim: la raíz agrega la cookie del almacén de secretos"
  check "shim: la raíz conserva el cuerpo de dev" "cuerpo-/" "$(cat "$sw/root.body")"

  "$REAL_CURL" -s --max-time 4 -D "$sw/asset.hdr" "http://127.0.0.1:$shim_port/assets/foo.js" -o "$sw/asset.body"
  check "shim: un asset pasa transparente" "cuerpo-/assets/foo.js" "$(cat "$sw/asset.body")"
  if grep -qi '^Set-Cookie:' "$sw/asset.hdr"; then
    printf 'FAIL %-58s trae Set-Cookie, solo la raíz debería\n' "shim: un asset no agrega la cookie"; fail=1
  else
    printf 'ok   %-58s\n' "shim: un asset no agrega la cookie"
  fi

  "$REAL_CURL" -s --max-time 4 -X POST -H "Cookie: vscode-tkn=token-de-prueba-devkit-259" \
    "http://127.0.0.1:$shim_port/devkit/secret-key" -o "$sw/key1.bin"
  check "shim: la clave mide 32 bytes" "32" "$(wc -c < "$sw/key1.bin")"
  check "shim: la clave es el SHA-256 del token" "$digest_esperado" "$(od -An -tx1 "$sw/key1.bin" | tr -d ' \n')"

  # Sonda del criterio 2 (DEVKIT-259, H2): guarda un secreto cifrado con la
  # clave que entregó el shim y lo lee de nuevo tras una recarga (otra
  # petición de la clave al mismo shim) y tras un recreate (shim y dígesto
  # relanzados, más abajo). Es un doble del workbench, no su cifrado interno,
  # que además mezcla una clave propia del navegador: prueba la parte que
  # agrega este PR, que la clave del servidor no cambie y que con ella se
  # recupere lo guardado.
  sonda_iv=000102030405060708090a0b0c0d0e0f
  sonda_leer() { # $1: archivo con la clave; imprime el secreto descifrado
    openssl enc -d -aes-256-cbc -K "$(od -An -tx1 "$1" | tr -d ' \n')" -iv "$sonda_iv" \
      -in "$sw/secreto.enc" 2>/dev/null
  }
  if command -v openssl >/dev/null 2>&1; then
    printf 'sesion-github-de-prueba' | openssl enc -aes-256-cbc \
      -K "$(od -An -tx1 "$sw/key1.bin" | tr -d ' \n')" -iv "$sonda_iv" -out "$sw/secreto.enc"
    "$REAL_CURL" -s --max-time 4 -X POST -H "Cookie: vscode-tkn=token-de-prueba-devkit-259" \
      "http://127.0.0.1:$shim_port/devkit/secret-key" -o "$sw/key_recarga.bin"
    check "sonda: el secreto se recupera tras recargar" "sesion-github-de-prueba" "$(sonda_leer "$sw/key_recarga.bin")"
  else
    echo "skip sonda: falta openssl"
  fi

  # H4, DEVKIT-259: sin la cookie de sesión, o con una que no coincide con el
  # token de conexión, dev nunca entrega el dígesto y el shim responde 403.
  "$REAL_CURL" -s --max-time 4 -X POST "http://127.0.0.1:$shim_port/devkit/secret-key" \
    -D "$sw/key_sin_cookie.hdr" -o "$sw/key_sin_cookie.bin"
  check_hdr "$sw/key_sin_cookie.hdr" "^HTTP/1\.1 403 Forbidden" "shim: sin cookie de sesión, 403"
  check "shim: sin cookie de sesión, cuerpo vacío" "0" "$(wc -c < "$sw/key_sin_cookie.bin")"

  "$REAL_CURL" -s --max-time 4 -X POST -H "Cookie: vscode-tkn=otro-token" \
    "http://127.0.0.1:$shim_port/devkit/secret-key" -D "$sw/key_mal.hdr" -o "$sw/key_mal.bin"
  check_hdr "$sw/key_mal.hdr" "^HTTP/1\.1 403 Forbidden" "shim: cookie de sesión que no coincide, 403"

  # DEVKIT-263: con más de una cookie el bucle del encabezado Cookie no
  # terminaba (un espacio inicial sobrevivía en cookie_rest) y la petición
  # quedaba colgada con el bash al 100 % de CPU. El navegador ya manda dos
  # desde el 302 del token, porque el shim siembra la segunda. Cada caso
  # exige 200 con timeout 5, y al final que no quede ningún shim vivo. Se busca
  # por la ruta del shim de este checkout ($SHIM), no por el nombre, y solo los
  # procesos bash, no el socat que escucha (su línea también la trae): en un host
  # con Docker nativo el shim real del proxy también se ve desde aquí.
  shim_vivos() { pgrep -f -- "^/bin/bash $SHIM" 2>/dev/null | wc -l | tr -d ' '; }
  cookie_caso() { # $1: nombre, $2: método, $3: ruta, $4: encabezado Cookie
    local codigo
    codigo="$("$REAL_CURL" -s --max-time 5 -o /dev/null -w '%{http_code}' -X "$2" -H "Cookie: $4" \
      "http://127.0.0.1:$shim_port$3")"
    check "$1" "200" "$codigo"
  }
  tkn="vscode-tkn=token-de-prueba-devkit-259"
  sk="vscode-secret-key-path=/devkit/secret-key"
  cookie_caso "shim: GET / con vscode-tkn y otra cookie" GET / "$tkn; $sk"
  cookie_caso "shim: GET / con la otra cookie primero" GET / "$sk; $tkn"
  cookie_caso "shim: POST clave con vscode-tkn y otra cookie" POST /devkit/secret-key "$tkn; $sk"
  cookie_caso "shim: POST clave con la otra cookie primero" POST /devkit/secret-key "$sk; $tkn"
  cookie_caso "shim: GET / con tres cookies" GET / "a=1; $tkn; $sk"
  cookie_caso "shim: POST clave con tres cookies" POST /devkit/secret-key "a=1; $sk; $tkn"
  sleep 0.3
  vivos="$(shim_vivos)"
  [ "$vivos" = 0 ] || pkill -f -- "^/bin/bash $SHIM" 2>/dev/null
  check "shim: ninguna petición con cookies deja un shim vivo" "0" "$vivos"

  # DEVKIT-264: con EXEC a secas (socketpair) y socat 1.8.1.3 (alpine, OrbStack)
  # el socat interno del shim no lee la petición hasta que el cliente cierra la
  # conexión, y el navegador nunca la cierra: la pestaña queda cargando. En
  # Ubuntu (socat 1.8.0.x) con socketpair pasa, así que ningún caso de arriba
  # lo vio: curl y `printf | socat` cierran su lado de escritura al terminar de
  # enviar. Este caso es el único que lo atrapa. Lanza el shim con la misma
  # línea de socat que devkit/proxy/entrypoint.sh (,pipes incluido: NO se quita
  # por "redundante", falla en OrbStack) y un cliente que envía GET y mantiene
  # la conexión abierta 3 s; la respuesta debe llegar en menos de 2 s. Usa un
  # asset y no la raíz: el doble de dev espera 1,5 s antes de responder la
  # raíz, y eso dejaría poco margen sobre el umbral.
  prod_port=$((base + 4))
  env DEVKIT_SHIM_UPSTREAM=127.0.0.1 DEVKIT_SHIM_UPSTREAM_PORT="$dev_port" DEVKIT_SHIM_DIGEST_PORT="$digest_port" \
    socat TCP-LISTEN:$prod_port,fork,reuseaddr,bind=0.0.0.0 EXEC:$SHIM,pipes >"$sw/shim_prod.log" 2>&1 & shim_pids+=("$!")
  sleep 0.3
  rm -f "$sw/abierta.out"
  ( printf 'GET /assets/foo.js HTTP/1.1\r\nHost: x\r\n\r\n'; sleep 3 ) \
    | socat -t 1 - TCP:127.0.0.1:$prod_port | head -n 1 > "$sw/abierta.out" &
  abierta_pid=$!
  for _ in $(seq 20); do [ -s "$sw/abierta.out" ] && break; sleep 0.1; done
  check "shim: responde con la conexión del cliente abierta (<2 s)" "HTTP/1.1 200 OK" \
    "$(tr -d '\r' < "$sw/abierta.out")"
  wait "$abierta_pid" 2>/dev/null

  # Recreate (proxy y dev, sin volumen propio): otro shim y otro endpoint de
  # dígesto, mismo token en dev, misma clave. Prueba que se deriva de nuevo y
  # no se cachea (DEVKIT-259).
  kill "${shim_pids[3]}" "${shim_pids[1]}" 2>/dev/null
  sleep 0.2
  socat TCP-LISTEN:$digest_port,fork,reuseaddr "EXEC:$DIGEST $sw/token" >"$sw/dev_digest2.log" 2>&1 & shim_pids[1]="$!"
  env DEVKIT_SHIM_UPSTREAM=127.0.0.1 DEVKIT_SHIM_UPSTREAM_PORT="$dev_port" DEVKIT_SHIM_DIGEST_PORT="$digest_port" \
    socat TCP-LISTEN:$shim_port,fork,reuseaddr "EXEC:$SHIM" >"$sw/shim2.log" 2>&1 & shim_pids[3]="$!"
  sleep 0.3
  "$REAL_CURL" -s --max-time 4 -X POST -H "Cookie: vscode-tkn=token-de-prueba-devkit-259" \
    "http://127.0.0.1:$shim_port/devkit/secret-key" -o "$sw/key2.bin"
  check "shim: recreate deriva la misma clave" "$digest_esperado" "$(od -An -tx1 "$sw/key2.bin" | tr -d ' \n')"
  if [ -s "$sw/secreto.enc" ]; then
    check "sonda: el secreto se recupera tras recreate" "sesion-github-de-prueba" "$(sonda_leer "$sw/key2.bin")"
  fi

  # WebSocket: sube, y lo que el navegador mande después del upgrade llega a
  # dev y su eco vuelve, todo en la misma conexión (prueba el relé de dos vías
  # de DEVKIT-259, no solo el intercambio de un tiro de arriba).
  mkfifo "$sw/ws_in"
  ( printf 'GET /ws HTTP/1.1\r\nHost: h\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n'
    sleep 0.3; printf 'hola\n'; sleep 0.3; printf 'mundo\n'; sleep 1 ) > "$sw/ws_in" &
  ws_writer=$!
  env DEVKIT_SHIM_UPSTREAM=127.0.0.1 DEVKIT_SHIM_UPSTREAM_PORT="$ws_port" DEVKIT_SHIM_DIGEST_PORT="$digest_port" \
    timeout 4 bash "$SHIM" < "$sw/ws_in" > "$sw/ws.out" 2>"$sw/ws.err"
  kill "$ws_writer" 2>/dev/null
  check_hdr "$sw/ws.out" "^HTTP/1\.1 101 Switching Protocols" "shim: el upgrade de WebSocket pasa (101)"
  check_hdr "$sw/ws.out" "^ECHO:hola$" "shim: un frame del navegador llega a dev y su eco vuelve"
  check_hdr "$sw/ws.out" "^ECHO:mundo$" "shim: un segundo frame en la misma conexión también llega"

  for p in "${shim_pids[@]}"; do kill "$p" 2>/dev/null; done
fi

exit $fail

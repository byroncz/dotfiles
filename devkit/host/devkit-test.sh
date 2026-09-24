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
    mkdir -p "$work/repo/devkit/vscode"
    printf 'ARG OPENVSCODE_VERSION=1.109.5\n' > "$work/repo/devkit/Dockerfile"
    printf '"Anthropic.claude-code" = "latest"\n' > "$work/repo/devkit/vscode/extensions.toml"
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
  compose) exit 0 ;;
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

# --- update con compose.yaml sin EXTENSIONS (H2, DEVKIT-67) -----------------
# compose.yaml del Mac de antes de DEVKIT-67 no declara EXTENSIONS: el
# build seguiría sin avisar y sin extensiones. `update` debe detenerse antes
# de descargar la etiqueta.
escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
corre update
check        "update con compose.yaml sin EXTENSIONS se detiene" 1 "$ESTADO"
check_salida "update con compose.yaml sin EXTENSIONS lo explica" "no declara EXTENSIONS"
check_docker "update con compose.yaml sin EXTENSIONS no descarga la etiqueta" no 'archive/refs/tags'

escenario 0.1.0
printf '[devkit]\ntemplate = "0.2.0"\nproject  = "TEST"\n' > "$TMP/ws/.devkit/devkit.toml"
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
corre update
check_salida "update con compose.yaml al día no se detiene por EXTENSIONS" "actualizando template"

# --- Avisos de los archivos del Mac -----------------------------------------
escenario dev; echo 'name: otro' > "$TMP/root/p/compose.yaml"; corre recreate
check_salida "compose.yaml del Mac desincronizado" "compose.yaml difiere del template"

escenario dev; echo '# línea de más' >> "$TMP/root/bin/devkit"; corre recreate
check_salida "comando devkit desincronizado" "el comando devkit difiere del template"

escenario dev; corre recreate
check        "con todo al día no se avisa de nada" no \
             "$(grep -q 'difiere del template' "$OUT" && echo si || echo no)"

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
printf 'extensions = ["ms.otra@1.0.0"]\n' >> "$TMP/ws/.devkit/devkit.toml"
export DEVKIT_TEST_OVX_ENGINE_1_0_0="^1.0.0"
export DEVKIT_TEST_OVX_VERSION=2.1.270
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_0_0 DEVKIT_TEST_OVX_VERSION
check        "unión: incluye la del proyecto y la del template resuelta" \
             "ms.otra=1.0.0 Anthropic.claude-code=2.1.270" "$(env_ext)"
check        "unión: termina bien" 0 "$ESTADO"

escenario dev
printf 'extensions = ["Anthropic.claude-code@1.2.3"]\n' >> "$TMP/ws/.devkit/devkit.toml"
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
printf 'extensions = ["anthropic.claude-code@1.2.3"]\n' >> "$TMP/ws/.devkit/devkit.toml"
export DEVKIT_TEST_OVX_ENGINE_1_2_3="^1.0.0"
corre recreate
unset DEVKIT_TEST_OVX_ENGINE_1_2_3
check        "duplicado con otra capitalización: gana la versión del proyecto" \
             "anthropic.claude-code=1.2.3" "$(env_ext)"
check_docker "duplicado con otra capitalización: no consulta el /latest del template" no \
             'open-vsx\.org/api/Anthropic/claude-code/latest'
check        "duplicado con otra capitalización: termina bien" 0 "$ESTADO"

escenario dev
printf 'extensions = ["ms.rota@9.9.9"]\n' >> "$TMP/ws/.devkit/devkit.toml"
corre recreate
check_salida "404 de una extensión del proyecto: lo explica y nombra el origen" \
             'extensión ms\.rota 9\.9\.9 no existe en Open VSX \(404\) \(declarada en el proyecto\)'
check        "404 de una extensión del proyecto: se detiene" 1 "$ESTADO"
check_docker "404 de una extensión del proyecto: no construye" no 'up -d'

# Elemento inválido en extensions del proyecto: se avisa y se ignora, sin
# impedir que las extensiones válidas (del proyecto y del template) resuelvan
# (H4, DEVKIT-181).
escenario dev
printf 'extensions = ["sinpunto", "ms.valida@1.0.0"]\n' >> "$TMP/ws/.devkit/devkit.toml"
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
printf 'extensions = ["ms.vieja@1.2.3"]\n' >> "$TMP/ws/.devkit/devkit.toml"
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
printf 'extensions = ["ms.nueva"]\n' >> "$TMP/ws/.devkit/devkit.toml"
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
printf 'name: devkit-p\n    args:\n      EXTENSIONS: x\n' > "$TMP/root/p/compose.yaml"
export DEVKIT_TEST_OVX_ENGINE_1_0_0="^1.0.0"
export DEVKIT_TEST_OVX_VERSION=2.1.270
corre update
unset DEVKIT_TEST_OVX_ENGINE_1_0_0 DEVKIT_TEST_OVX_VERSION
check        "update resuelve las extensions del proyecto (sync_toml_env corre antes)" \
             "ms.nueva=1.0.0 Anthropic.claude-code=2.1.270" "$(env_ext)"
check        "update con extensions del proyecto: termina bien" 0 "$ESTADO"

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

exit $fail

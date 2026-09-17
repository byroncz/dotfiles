#!/usr/bin/env bash
# Prueba de host/devkit.sh sin Docker y sin tocar el Mac: un doble de `docker`
# responde por el contenedor y la prueba comprueba qué queda en el contexto de
# build. Cubre lo que arregla DEVKIT-30: en modo dev el contexto se rearma desde
# el workspace antes de construir, fuera de modo dev no se toca, y cuando el
# contenedor no responde se avisa y se sigue con la copia que hay. También
# cubre `devkit code` (DEVKIT-51), `devkit awake` con un doble de caffeinate
# (DEVKIT-66) y, con un doble de `curl`, la resolución de
# devkit/vscode/extensions.toml contra Open VSX (DEVKIT-67).
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
# Solo responde la API "latest" de Open VSX que usa resolve_extensions;
# cualquier otra URL (por ejemplo la descarga de una etiqueta en `update`, que
# estos escenarios no ejercitan) sale en 0 sin cuerpo. `DEVKIT_TEST_CURL_DOWN=1`
# simula el Mac sin red.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'FIN'
#!/bin/sh
echo "curl $*" >> "$DEVKIT_TEST_LOG"
[ "${DEVKIT_TEST_CURL_DOWN:-0}" = 1 ] && exit 7
for a; do url="$a"; done
case "$url" in
  https://open-vsx.org/api/*/latest) printf '{"version":"%s"}' "${DEVKIT_TEST_OVX_VERSION:-9.9.9}" ;;
  *) exit 0 ;;
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
    [ "${DEVKIT_TEST_DOWN:-0}" = 1 ] && { echo false; exit 0; }
    echo true; exit 0 ;;
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
      *) exit 0 ;;   # test -f ready, zsh, ...
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
  rm -rf "$TMP/root" "$TMP/ws"
  mkdir -p "$TMP/root/bin" "$TMP/root/p/template/marca" "$TMP/root/p/template/host" \
           "$TMP/root/p/template/vscode" "$TMP/ws/devkit/marca" "$TMP/ws/devkit/host" \
           "$TMP/ws/devkit/vscode"
  echo MARCA-VIEJA > "$TMP/root/p/template/marca/archivo.txt"
  echo sobra       > "$TMP/root/p/template/obsoleto.txt"
  echo MARCA-NUEVA > "$TMP/ws/devkit/marca/archivo.txt"
  printf 'name: devkit-p\n' > "$TMP/ws/devkit/compose.yaml"
  cp "$TMP/ws/devkit/compose.yaml" "$TMP/root/p/template/compose.yaml"
  cp "$TMP/ws/devkit/compose.yaml" "$TMP/root/p/compose.yaml"
  cp "$DEVKIT" "$TMP/ws/devkit/host/devkit.sh"
  cp "$DEVKIT" "$TMP/root/p/template/host/devkit.sh"
  cp "$DEVKIT" "$TMP/root/bin/devkit"
  printf '"Anthropic.claude-code" = "latest"\n' > "$TMP/ws/devkit/vscode/extensions.toml"
  cp "$TMP/ws/devkit/vscode/extensions.toml" "$TMP/root/p/template/vscode/extensions.toml"
  mkdir -p "$TMP/ws/.devkit"
  printf '[devkit]\ntemplate = "%s"\nproject  = "TEST"\n' "$1" > "$TMP/ws/.devkit/devkit.toml"
  printf 'DEVKIT_PROJECT=p\nDEVKIT_VERSION=%s\n' "$1" > "$TMP/root/p/.env"
}

# corre <comando> [caído]: ejecuta `devkit <comando> p` contra el doble,
# respondiendo "si" a la confirmación. Deja la salida en $OUT.
OUT="$TMP/salida"
corre() {
  : > "$DEVKIT_TEST_LOG"
  printf 'si\n' | env DEVKIT_HOME="$TMP/root" DEVKIT_TEST_WS="$TMP/ws" \
    DEVKIT_TEST_LOG="$DEVKIT_TEST_LOG" DEVKIT_TEST_DOWN="${2:-0}" \
    DEVKIT_TEST_TOKEN="${3:-}" \
    sh "$DEVKIT" "$1" p >"$OUT" 2>&1
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
# extensions.lock; una versión fija no consulta la API; sin red se usa la
# última resolución guardada con aviso; sin red y sin resolución previa el
# comando se detiene sin construir.
env_ext() { sed -n 's/^DEVKIT_EXTENSIONS=//p' "$TMP/root/p/.env" | tail -1; }
lock_ext() { tr '\n' ' ' < "$TMP/root/p/extensions.lock" 2>/dev/null | sed 's/ *$//'; }

export DEVKIT_TEST_OVX_VERSION=2.1.270
escenario dev; corre recreate
check        "latest resuelto: queda en .env" "Anthropic.claude-code=2.1.270" "$(env_ext)"
check        "latest resuelto: queda en extensions.lock" "Anthropic.claude-code=2.1.270" "$(lock_ext)"
check_docker "latest resuelto: consulta Open VSX" si 'curl -fsSL https://open-vsx\.org/api/Anthropic/claude-code/latest'
check        "latest resuelto: termina bien" 0 "$ESTADO"

escenario dev
printf '"Anthropic.claude-code" = "1.2.3"\n' > "$TMP/ws/devkit/vscode/extensions.toml"
cp "$TMP/ws/devkit/vscode/extensions.toml" "$TMP/root/p/template/vscode/extensions.toml"
corre recreate
check        "versión fija: queda en .env tal cual" "Anthropic.claude-code=1.2.3" "$(env_ext)"
check_docker "versión fija: no consulta Open VSX" no 'open-vsx\.org'
unset DEVKIT_TEST_OVX_VERSION

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

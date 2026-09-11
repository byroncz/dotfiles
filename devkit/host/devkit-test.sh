#!/usr/bin/env bash
# Prueba de host/devkit.sh sin Docker y sin tocar el Mac: un doble de `docker`
# responde por el contenedor y la prueba comprueba qué queda en el contexto de
# build. Cubre lo que arregla DEVKIT-30: en modo dev el contexto se rearma desde
# el workspace antes de construir, fuera de modo dev no se toca, y cuando el
# contenedor no responde se avisa y se sigue con la copia que hay.
# Sale con 1 si algún caso falla.
# Uso: bash devkit-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVKIT="$HERE/devkit.sh"
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVKIT_TEST_LOG="$TMP/docker.log"; : > "$DEVKIT_TEST_LOG"

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
    # así el caso de la copia vieja no cuelga el attach del final, igual que en
    # un recreate de verdad.
    if [ "${DEVKIT_TEST_DOWN:-0}" = 1 ] && ! grep -q 'up -d' "$DEVKIT_TEST_LOG"; then
      exit 1
    fi
    case "$*" in
      "test -d /workspace/devkit") [ -d "$DEVKIT_TEST_WS/devkit" ]; exit $? ;;
      "cat /workspace/devkit.toml") cat "$DEVKIT_TEST_WS/devkit.toml" 2>/dev/null; exit $? ;;
      *) exit 0 ;;   # test -f ready, tmux new-session, ...
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
  mkdir -p "$TMP/root/bin" "$TMP/root/p/template/nvim" "$TMP/root/p/template/host" \
           "$TMP/ws/devkit/nvim" "$TMP/ws/devkit/host"
  echo MARCA-VIEJA > "$TMP/root/p/template/nvim/init.lua"
  echo sobra       > "$TMP/root/p/template/obsoleto.txt"
  echo MARCA-NUEVA > "$TMP/ws/devkit/nvim/init.lua"
  printf 'name: devkit-p\n' > "$TMP/ws/devkit/compose.yaml"
  cp "$TMP/ws/devkit/compose.yaml" "$TMP/root/p/template/compose.yaml"
  cp "$TMP/ws/devkit/compose.yaml" "$TMP/root/p/compose.yaml"
  cp "$DEVKIT" "$TMP/ws/devkit/host/devkit.sh"
  cp "$DEVKIT" "$TMP/root/p/template/host/devkit.sh"
  cp "$DEVKIT" "$TMP/root/bin/devkit"
  printf '[devkit]\ntemplate = "%s"\nproject  = "TEST"\n' "$1" > "$TMP/ws/devkit.toml"
  printf 'DEVKIT_PROJECT=p\nDEVKIT_VERSION=%s\n' "$1" > "$TMP/root/p/.env"
}

# corre <comando> [caído]: ejecuta `devkit <comando> p` contra el doble,
# respondiendo "si" a la confirmación. Deja la salida en $OUT.
OUT="$TMP/salida"
corre() {
  : > "$DEVKIT_TEST_LOG"
  printf 'si\n' | env DEVKIT_HOME="$TMP/root" DEVKIT_TEST_WS="$TMP/ws" \
    DEVKIT_TEST_LOG="$DEVKIT_TEST_LOG" DEVKIT_TEST_DOWN="${2:-0}" \
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
marca() { cat "$TMP/root/p/template/nvim/init.lua" 2>/dev/null; }

# --- Modo dev, contenedor arriba --------------------------------------------
escenario dev; corre recreate
check        "recreate en dev trae el nvim/ del workspace" MARCA-NUEVA "$(marca)"
check        "recreate en dev deja de arrastrar lo que se borró" no \
             "$([ -e "$TMP/root/p/template/obsoleto.txt" ] && echo si || echo no)"
check_salida "recreate en dev lo dice" "contexto de build actualizado desde el workspace"
check_docker "recreate en dev copia desde el contenedor" si 'docker cp devkit-p:/workspace/devkit/\.'
check        "recreate en dev termina bien" 0 "$ESTADO"

escenario dev; corre rebuild
check        "rebuild en dev trae el nvim/ del workspace" MARCA-NUEVA "$(marca)"
check_docker "rebuild en dev construye desde cero" si 'build --no-cache'

escenario dev; corre up
check        "up en dev trae el nvim/ del workspace" MARCA-NUEVA "$(marca)"

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

# --- Avisos de los archivos del Mac -----------------------------------------
escenario dev; echo 'name: otro' > "$TMP/root/p/compose.yaml"; corre recreate
check_salida "compose.yaml del Mac desincronizado" "compose.yaml difiere del template"

escenario dev; echo '# línea de más' >> "$TMP/root/bin/devkit"; corre recreate
check_salida "comando devkit desincronizado" "el comando devkit difiere del template"

escenario dev; corre recreate
check        "con todo al día no se avisa de nada" no \
             "$(grep -q 'difiere del template' "$OUT" && echo si || echo no)"

exit $fail

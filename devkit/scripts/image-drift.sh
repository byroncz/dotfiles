#!/bin/sh
# ---------------------------------------------------------------------------
#  devkit: qué del template solo entra por imagen y ya no coincide con ella.
#
#    image-drift.sh <dir del template> <copia de la imagen>
#    image-drift.sh --test
#
#  `entrypoint.sh` la usa en modo dev para avisar cuándo hace falta un
#  `devkit recreate`. El arranque relee del workspace `entrypoint.sh` y
#  `scripts/`, así que un cambio ahí se prueba con solo recrear el contenedor;
#  `Dockerfile`, `nvim/`, `tmux/`, `zsh/` y `proxy/` se congelan en la imagen
#  cuando se construye, y hasta que no se reconstruye siguen siendo los de
#  antes. Esa asimetría es la que engañaba en DEVKIT-30.
#
#  Imprime un nombre por línea y sale con 0 aunque haya diferencias: es una
#  sonda del arranque, no una compuerta que deba tumbarlo.
# ---------------------------------------------------------------------------
set -u

# Lo que el Dockerfile copia a la imagen o usa para construirla. Única fuente
# de esta lista: si el Dockerfile copia algo nuevo, se añade aquí.
ITEMS='Dockerfile nvim tmux zsh proxy'

drift() {  # drift <dir del template> <copia de la imagen>
  for item in $ITEMS; do
    [ -e "$1/$item" ] || continue                      # no está en el template
    [ -e "$2/$item" ] || { printf '%s\n' "$item"; continue; }  # imagen sin él
    diff -rq "$1/$item" "$2/$item" >/dev/null 2>&1 || printf '%s\n' "$item"
  done
}

# --- Autoprueba --------------------------------------------------------------
if [ "${1:-}" = "--test" ]; then
  fail=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  # Un template y una imagen idénticos, más lo que solo vive en el workspace.
  base() {
    rm -rf "$tmp/ws" "$tmp/img"
    mkdir -p "$tmp/ws/nvim" "$tmp/ws/tmux" "$tmp/ws/zsh" "$tmp/ws/proxy" "$tmp/ws/scripts" "$tmp/ws/agents"
    echo FROM debian > "$tmp/ws/Dockerfile"
    echo 'vim.o.x=1' > "$tmp/ws/nvim/init.lua"
    echo 'set -g x'  > "$tmp/ws/tmux/tmux.conf"
    echo 'alias v=nvim' > "$tmp/ws/zsh/zshrc"
    echo 'allow a.com'  > "$tmp/ws/proxy/allowlist.base"
    echo 'echo hola'    > "$tmp/ws/scripts/watch.sh"
    echo 'skills'       > "$tmp/ws/agents/notion.json"
    echo 'arranque'     > "$tmp/ws/entrypoint.sh"
    mkdir -p "$tmp/img"
    for i in Dockerfile nvim tmux zsh proxy; do cp -R "$tmp/ws/$i" "$tmp/img/$i"; done
  }

  check() {  # check <nombre> <esperado> <obtenido>
    if [ "$2" = "$3" ]; then
      printf 'ok   %-52s %s\n' "$1" "${3:-<vacío>}"
    else
      printf 'FAIL %-52s esperado "%s", obtenido "%s"\n' "$1" "$2" "$3"
      fail=1
    fi
  }
  got() { drift "$tmp/ws" "$tmp/img" | tr '\n' ' ' | sed 's/ *$//'; }

  base
  check "imagen al día" "" "$(got)"

  base; echo 'FROM debian:trixie' > "$tmp/ws/Dockerfile"
  check "Dockerfile cambiado" "Dockerfile" "$(got)"

  base; echo 'vim.o.x=2' > "$tmp/ws/nvim/init.lua"
  check "archivo dentro de un directorio" "nvim" "$(got)"

  base; echo 'export X=1' > "$tmp/ws/zsh/extra.zsh"
  check "archivo nuevo en el workspace" "zsh" "$(got)"

  base; echo 'allow b.com' > "$tmp/ws/proxy/allowlist.base"; echo 'vim.o.x=2' > "$tmp/ws/nvim/init.lua"
  check "dos a la vez, en el orden de la lista" "nvim proxy" "$(got)"

  base; rm -rf "$tmp/img/proxy"
  check "la imagen no trae el directorio" "proxy" "$(got)"

  base; rm -rf "$tmp/ws/tmux"
  check "el template ya no trae el directorio" "" "$(got)"

  # Lo que el arranque relee del workspace no cuenta: cambiarlo no pide un
  # recreate, y avisar de ello sería ruido en cada sesión.
  base; echo 'echo adios' > "$tmp/ws/scripts/watch.sh"; echo 'otro' > "$tmp/ws/entrypoint.sh"
  echo 'cambio' > "$tmp/ws/agents/notion.json"
  check "scripts, entrypoint y agents no cuentan" "" "$(got)"

  exit $fail
fi

# --- Uso normal --------------------------------------------------------------
[ $# -eq 2 ] || { echo "uso: image-drift.sh <dir del template> <copia de la imagen>" >&2; exit 2; }
drift "$1" "$2"

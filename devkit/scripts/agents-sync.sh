#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  devkit: funde el AGENTS.md de un proyecto con una versión nueva de
#  AGENTS.template.md, conservando lo que el proyecto agregó bajo el
#  marcador `## Reglas del proyecto` (ver AGENTS.template.md).
#
#    agents-sync.sh <plantilla renderizada> <AGENTS.md del proyecto>
#    agents-sync.sh --test
#
#  `template-update` la usa al subir de versión. Si el AGENTS.md del proyecto
#  tiene el marcador, imprime en stdout el resultado fundido y sale 0: todo
#  lo de arriba del marcador viene de la plantilla nueva, todo lo de abajo
#  viene tal cual del AGENTS.md actual. Si los dos archivos ya son iguales,
#  no imprime nada y sale 1: nada que hacer. Si el AGENTS.md del proyecto no
#  tiene el marcador (proyectos de antes de esta convención), no imprime
#  nada y sale 2: quien llama muestra el diff en el PR y deja la fusión al
#  humano, sin tocar el archivo.
# ---------------------------------------------------------------------------
set -u

MARKER='## Reglas del proyecto'

sync_agents() {  # sync_agents <plantilla renderizada> <AGENTS.md actual>
  local tpl=$1 cur=$2
  cmp -s "$tpl" "$cur" && return 1
  grep -qxF "$MARKER" "$cur" || return 2
  awk -v m="$MARKER" '$0==m{exit} {print}' "$tpl"
  awk -v m="$MARKER" 'f{print} $0==m{f=1; print}' "$cur"
  return 0
}

# --- Autoprueba --------------------------------------------------------------
if [ "${1:-}" = "--test" ]; then
  fail=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  check() {  # check <nombre> <esperado> <obtenido>
    if [ "$2" = "$3" ]; then
      printf 'ok   %s\n' "$1"
    else
      printf 'FAIL %-45s esperado "%s", obtenido "%s"\n' "$1" "$2" "$3"
      fail=1
    fi
  }

  printf '# DEVKIT\n\nnombre viejo\n\n%s\n<!-- comentario -->\n' "$MARKER" > "$tmp/tpl_vieja"
  printf '# DEVKIT\n\nnombre NUEVO\n\n%s\n<!-- comentario -->\n' "$MARKER" > "$tmp/tpl_nueva"
  printf '# DEVKIT\n\nnombre viejo\n\n%s\n<!-- comentario -->\n\n## Reglas propias\n\n- cosa del proyecto\n' \
    "$MARKER" > "$tmp/agents_con_marcador"
  printf '# DEVKIT\n\nnombre viejo\n\nsin marcador\n' > "$tmp/agents_sin_marcador"
  cp "$tmp/tpl_vieja" "$tmp/agents_igual"

  out="$(sync_agents "$tmp/tpl_nueva" "$tmp/agents_con_marcador")"; rc=$?
  check "con marcador: código de salida" "0" "$rc"
  check "con marcador: toma el cambio del template" "1" "$(grep -c 'nombre NUEVO' <<<"$out")"
  check "con marcador: no arrastra el nombre viejo" "0" "$(grep -c 'nombre viejo' <<<"$out")"
  check "con marcador: conserva la sección propia" "1" "$(grep -c 'cosa del proyecto' <<<"$out")"

  out="$(sync_agents "$tmp/tpl_nueva" "$tmp/agents_sin_marcador")"; rc=$?
  check "sin marcador: código de salida" "2" "$rc"
  check "sin marcador: no imprime nada" "" "$out"

  out="$(sync_agents "$tmp/tpl_vieja" "$tmp/agents_igual")"; rc=$?
  check "iguales: código de salida" "1" "$rc"
  check "iguales: no imprime nada" "" "$out"

  exit $fail
fi

# --- Uso real ------------------------------------------------------------------
[ $# -eq 2 ] || { echo "uso: agents-sync.sh <plantilla renderizada> <AGENTS.md>" >&2; exit 2; }
sync_agents "$1" "$2"

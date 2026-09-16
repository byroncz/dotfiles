#!/usr/bin/env bash
# Bloquea una card (DEVKIT-55): `Estado` = `Bloqueada` y un comentario con el
# estado del que viene y el motivo. Reemplaza a la skill task-block, que corría
# un agente entero solo porque el contenedor no hablaba con Notion desde bash.
#
# Uso:
#   task-block.sh <Clave> <motivo...>
#
# Lo llaman `watch.sh` (tres ciclos sin OK), `devkit-run` (barrera de pregunta
# abierta de DEVKIT-50) y cualquier skill que necesite al humano, por ruta:
#   "${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh" DEVKIT-7 "Qué intenté: ... Qué necesito: ..."
# El motivo es la petición concreta al humano: quien llama la redacta, este
# script no la interpreta.
#
# Si el workspace está en la rama de la card con cambios sin commit, los
# guarda con un commit `wip(<Clave>): ...` y push, para no perder trabajo, como
# hacía la skill. Solo si nadie más ocupa el workspace (`skill.lock` libre o
# tomado por quien llama, que se declara con DEVKIT_LOCK_HELD=1).
#
# Idempotente: una card ya `Bloqueada` no se toca ni se vuelve a comentar.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
LOCK="${DEVKIT_LOCK:-$RUN_DIR/skill.lock}"

clave="${1:-}"
shift 2>/dev/null
motivo="$*"
if [ -z "$clave" ] || [ -z "$motivo" ]; then
  echo "uso: task-block.sh <Clave> <motivo...>" >&2
  exit 64
fi

card=$("$NOTION" card "$clave") || { echo "task-block: no pude leer $clave en Notion" >&2; exit 1; }
id=$(jq -r .id <<<"$card")
anterior=$(jq -r '.estado // "sin estado"' <<<"$card")

if [ "$anterior" = "Bloqueada" ]; then
  echo "task-block: $clave ya estaba Bloqueada; no se repite el comentario"
  exit 0
fi

"$NOTION" set "$id" Estado=Bloqueada || { echo "task-block: no pude cambiar el Estado de $clave" >&2; exit 1; }
# Línea para `devkit-run --estado` (DEVKIT-57): muestra el lanzamiento como
# `bloqueada` con este motivo, sin consultar Notion. En una sola línea, cortada
# por caracteres y no por bytes (`cut -c`), para no partir un acento.
motivo_en_linea=$(printf '%s' "$motivo" | tr '\n' ' ')
printf '%s task-block.sh %s Bloqueada desde %s: %s\n' "$(date -u +%FT%TZ)" "$clave" "$anterior" \
  "${motivo_en_linea:0:300}" \
  >>"${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}" 2>/dev/null
"$NOTION" comentar "$id" "Bloqueada desde $anterior.
$motivo" || echo "task-block: $clave quedó Bloqueada pero no pude comentar el motivo" >&2

# Trabajo sin guardar en la rama de la card.
guardar_wip() {
  local rama
  rama=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
  case "$rama" in *"$clave"-*|*"$clave") ;; *) return 0 ;; esac
  [ -n "$(git -C "$WS" status --porcelain 2>/dev/null)" ] || return 0
  git -C "$WS" add -A \
    && git -C "$WS" commit -q -m "wip($clave): guardar avance antes de bloquear" \
    && git -C "$WS" push -q origin "$rama" \
    && echo "task-block: avance sin commit guardado como wip en $rama"
}
if [ "${DEVKIT_LOCK_HELD:-}" = 1 ]; then
  guardar_wip
else
  exec 9>"$LOCK"
  if flock -n 9; then
    guardar_wip
    flock -u 9
  else
    echo "task-block: otra skill ocupa el workspace; no se guarda wip"
  fi
fi

echo "task-block: $clave Bloqueada desde $anterior"

#!/usr/bin/env bash
# Bloquea una card (DEVKIT-55): `Estado` = `Bloqueada` y un comentario con el
# estado del que viene y el motivo. Reemplaza a la skill task-block, que corría
# un agente entero solo porque el contenedor no hablaba con Notion desde bash.
#
# Uso:
#   task-block.sh [--pr <url>] <Clave> <motivo...>
#
# Lo llaman `watch.sh` (tres ciclos sin OK), `devkit-run` (barrera de pregunta
# abierta de DEVKIT-50) y cualquier skill que necesite al humano, por ruta:
#   "${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh" DEVKIT-7 "Qué intenté: ... Qué necesito: ..."
# El motivo es la petición concreta al humano: quien llama la redacta, este
# script no la interpreta.
#
# --pr <url> (DEVKIT-246, H1 de pr-review #133): quien ya conoce la URL del PR
# sin depender de Notion -`block_pr` en watch.sh, que la tiene desde el propio
# `gh pr view` del ciclo- la pasa aquí para que el marcador se publique antes
# de leer la card. Sin esto, el marcador solo salía si `notion.sh card`
# respondía y la card tenía la propiedad `PR`: un fallo de Notion, o una card
# sin esa propiedad todavía, dejaba al bucle sin marcador y sin nada que lo
# detenga.
#
# Si el workspace está en la rama de la card con cambios sin commit, los
# guarda con un commit `wip(<Clave>): ...` y push, para no perder trabajo, como
# hacía la skill. Solo si nadie más ocupa el workspace (`skill.lock` libre o
# tomado por quien llama, que se declara con DEVKIT_LOCK_HELD=1).
#
# Idempotente: una card ya `Bloqueada` no se toca ni se vuelve a comentar.
#
# DEVKIT_HALLAZGO_TITULO (DEVKIT-184): si llega no vacía, además de bloquear
# crea una card de hallazgo en el proyecto DEVKIT (resuelto por su Código en
# Proyectos, no el de la Clave que se bloquea) con ese título, Tipo `bug` y
# Estado `Por refinar`, con el motivo en el cuerpo bajo "Detectado en
# <Clave>". Así el reporte de un problema del template (dominio del proxy,
# scope del token, cualquier otro) cae en el Kanban de DEVKIT, no en el del
# proyecto donde se detectó -antes había que reasignarlo a mano (DEVKIT-180 a
# 183). Si la Clave bloqueada ya es de DEVKIT, no tiene sentido duplicarla:
# se omite. Si ya hay una card sin Hecha con ese mismo título en DEVKIT (el
# mismo bloqueo repetido, u otra card u otro proyecto con el mismo hallazgo),
# tampoco se crea otra: se comenta en la que ya existe (H2, DEVKIT-184). Un
# fallo al crear o comentar el hallazgo no revierte el bloqueo ya hecho, solo
# avisa por stderr: quien bloquea a un humano no debe quedar sin respuesta
# por un problema aparte al crear el reporte.
#
# Marcador en el PR (DEVKIT-246): `decide` en watch.sh no consulta Notion, solo
# lee el PR -así que un bloqueo que solo cambia el Estado en Notion (todo lo
# que no sea el bloqueo por tres ciclos de `block_pr`: aprobación humana de
# task-fix, dominio bloqueado, pregunta abierta, un humano a mano) es invisible
# para el bucle, que puede relanzar pr-review o task-fix sobre una card ya
# Bloqueada. Con la URL del PR -la que llega por `--pr`, la propiedad `PR` de
# la card, o `gh pr view` de la rama actual si está vacía y coincide con la
# Clave- se publica el mismo marcador `<!-- devkit-block sha=<head> -->` que
# antes solo dejaba `block_pr`, para el head vigente del PR y solo si sigue
# `OPEN` (H3 de pr-review #133: un PR cerrado sin merge no necesita marcador,
# nadie lo va a leer). Sin PR, se comporta como antes: solo Notion.
#
# Idempotente contra el head, pero no a ciegas (H2 de pr-review #133): si el
# último devkit-block del PR ya es del head vigente, se busca el mismo caso
# que `$resumed` calcula en el DECIDE de watch.sh -¿hay un devkit-fix
# posterior a ese bloqueo?-. Sin ninguno, el bloqueo sigue en pie y no se
# repite. Con uno, alguien ya retomó ese bloqueo (un comentario humano que
# fix-humano atendió) y, si esta llamada vuelve a bloquear sin que el head
# haya cambiado, es un bloqueo nuevo: se publica otro marcador, o `decide`
# vería el bloqueo viejo como vigente y relanzaría pr-review sobre una card
# que en Notion ya está Bloqueada de nuevo.
#
# Va antes del `set` de Notion cuando llega `--pr`: es lo que detiene al
# bucle aunque falle Notion o la card no tenga la propiedad PR todavía (mismo
# motivo que tenía `block_pr`). Sin `--pr`, se publica después de comprobar
# que la card no esté ya Bloqueada ni Hecha, como antes de DEVKIT-246.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
LOCK="${DEVKIT_LOCK:-$RUN_DIR/skill.lock}"

pr_explicito=""
if [ "${1:-}" = --pr ]; then
  pr_explicito="${2:-}"
  shift 2 2>/dev/null
fi

clave="${1:-}"
shift 2>/dev/null
motivo="$*"
if [ -z "$clave" ] || [ -z "$motivo" ]; then
  echo "uso: task-block.sh [--pr <url>] <Clave> <motivo...>" >&2
  exit 64
fi

# publicar_marcador_bloqueo <motivo> [pr]: sin el segundo argumento, usa la
# propiedad PR de la card ya leída en $card (o, si esa variable no existe
# todavía, la rama actual) en vez de la URL explícita.
publicar_marcador_bloqueo() {
  local motivo=$1 pr=${2:-} rama pr_json numero head repetido
  if [ -z "$pr" ] && [ -n "${card:-}" ]; then
    pr=$(jq -r '.pr // ""' <<<"$card")
  fi
  if [ -z "$pr" ]; then
    rama=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null) || rama=""
    case "$rama" in
      *"$clave"-*|*"$clave") pr=$("$GH" pr view "$rama" --json url 2>/dev/null | jq -r '.url // empty') ;;
    esac
  fi
  [ -n "$pr" ] || return 0
  pr_json=$("$GH" pr view "$pr" --json number,headRefOid,comments,state 2>/dev/null) \
    || { echo "task-block: no pude leer el PR $pr para el marcador devkit-block" >&2; return 0; }
  if [ "$(jq -r '.state // ""' <<<"$pr_json")" != OPEN ]; then
    echo "task-block: el PR $pr no está abierto; no se publica el marcador devkit-block"
    return 0
  fi
  numero=$(jq -r '.number // empty' <<<"$pr_json")
  head=$(jq -r '.headRefOid // empty' <<<"$pr_json")
  [ -n "$numero" ] && [ -n "$head" ] || return 0
  repetido=$(jq -r --arg head "$head" '
    def markers($re): [ .[] | . as $x | ($x.body // "" | capture($re)) | . + {at: $x.createdAt} ];
    (.comments // []) as $c
    | ($c | markers("<!-- devkit-block sha=(?<sha>[0-9a-f]+) -->") | sort_by(.at) | last) as $block
    | ($c | markers("<!-- devkit-fix sha=(?<sha>[0-9a-f]+) review=(?<review>[0-9a-f]+)(?<manual> manual=1)? -->")) as $fixes
    | if $block == null or $block.sha != $head then "no"
      elif ([$fixes[] | select(.at > $block.at)] | length) > 0 then "no"
      else "si"
      end
  ' <<<"$pr_json")
  if [ "$repetido" = si ]; then
    echo "task-block: el PR $pr ya tiene el marcador devkit-block para $head; no se repite"
    return 0
  fi
  "$GH" pr comment "$numero" --body "<!-- devkit-block sha=$head -->
$motivo. La card pasa a Bloqueada y el bucle no toca este PR hasta que decidas.
Para retomar: mueve la card a Revisión automática y comenta aquí qué hacer. El bucle lanza task-fix con tu comentario y el conteo de ciclos vuelve a cero." >/dev/null 2>&1 \
    && echo "task-block: marcador devkit-block publicado en $pr" \
    || echo "task-block: no pude publicar el marcador devkit-block en $pr" >&2
}

if [ -n "$pr_explicito" ]; then
  publicar_marcador_bloqueo "$motivo" "$pr_explicito"
fi

card=$("$NOTION" card "$clave") || { echo "task-block: no pude leer $clave en Notion" >&2; exit 1; }
id=$(jq -r .id <<<"$card")
anterior=$(jq -r '.estado // "sin estado"' <<<"$card")

if [ "$anterior" = "Bloqueada" ]; then
  echo "task-block: $clave ya estaba Bloqueada; no se repite el comentario"
  exit 0
fi

# DEVKIT-76: una card ya Hecha (cerrada, mergeada y documentada) no se mueve
# a Bloqueada por un relanzamiento de más, sea automático (`forzar_task_block`
# en devkit-run.sh) o a mano. Mismo motivo que ahí: nadie va a leer ese
# bloqueo porque la card ya está resuelta.
if [ "$anterior" = "Hecha" ]; then
  echo "task-block: $clave ya está Hecha; no se bloquea" >&2
  exit 1
fi

# Marcador en el PR (DEVKIT-246): ver la nota del encabezado. Sin --pr, la
# card no está Bloqueada ni Hecha a esta altura, así que se publica ahora,
# antes del `set` de Notion, con la propiedad PR de la card ya leída.
[ -n "$pr_explicito" ] || publicar_marcador_bloqueo "$motivo"

"$NOTION" set "$id" Estado=Bloqueada || { echo "task-block: no pude cambiar el Estado de $clave" >&2; exit 1; }
# Línea para `devkit-run --estado` (DEVKIT-57): muestra el lanzamiento como
# `bloqueada` con este motivo, sin consultar Notion. En una sola línea, cortada
# por caracteres y no por bytes (`cut -c`), para no partir un acento.
motivo_en_linea=$(printf '%s' "$motivo" | tr '\n' ' ')
printf '%s task-block.sh %s Bloqueada desde %s: %s\n' "$(date +%FT%T%:z)" "$clave" "$anterior" \
  "${motivo_en_linea:0:300}" \
  >>"${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}" 2>/dev/null
"$NOTION" comentar "$id" "Bloqueada desde $anterior.
$motivo" || echo "task-block: $clave quedó Bloqueada pero no pude comentar el motivo" >&2

# Card de hallazgo en DEVKIT (DEVKIT-184): ver la nota del encabezado.
if [ -n "${DEVKIT_HALLAZGO_TITULO:-}" ]; then
  codigo_origen=${clave%-*}
  if [ "$codigo_origen" = DEVKIT ]; then
    echo "task-block: $clave ya es de DEVKIT; no se duplica el hallazgo"
  else
    existente=$("$NOTION" buscar-titulo DEVKIT "$DEVKIT_HALLAZGO_TITULO" 2>/dev/null)
    if [ -n "$existente" ]; then
      "$NOTION" comentar "$(jq -r .id <<<"$existente")" "Detectado también en $clave: $motivo" \
        && echo "task-block: ya había un hallazgo en DEVKIT ($(jq -r .clave <<<"$existente")); se agregó un comentario" \
        || echo "task-block: $clave quedó Bloqueada pero no pude comentar el hallazgo existente en DEVKIT" >&2
    else
      hallazgo=$(printf '## Objetivo\nRevisar y corregir el hallazgo detectado en %s (proyecto %s).\n\n## Criterios de aceptación\n- Por definir al refinar la card.\n\n## Notas\nDetectado en %s al bloquear la card:\n%s' \
          "$clave" "$codigo_origen" "$clave" "$motivo" \
        | "$NOTION" crear-tarea DEVKIT "$DEVKIT_HALLAZGO_TITULO" bug media) \
        && echo "task-block: hallazgo creado en DEVKIT: $(jq -r .url <<<"$hallazgo")" \
        || echo "task-block: $clave quedó Bloqueada pero no pude crear el hallazgo en DEVKIT" >&2
    fi
  fi
fi

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

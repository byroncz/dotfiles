#!/usr/bin/env bash
# Cierra una card cuyo PR ya se mergeó (DEVKIT-55). Hace lo mismo que la skill
# task-close a la que reemplaza, en bash y en segundos: `Hecha`, `Cierre`,
# comentario con el enlace a la entrada de Documentación, marcador
# `devkit-closed` en el PR, cierre de la Épica si era la última hija y
# lanzamiento de la siguiente hija con `task-next.sh` (DEVKIT-56), que también
# llama watch.sh cuando el revisor da OK.
#
# Uso:
#   task-close.sh <Clave> [URL o número del PR]
#
# La entrada de Documentación ya no se escribe aquí: la escribe la skill
# `task-document` cuando `pr-review` da OK, antes del merge, para que refleje
# lo que se revisó. Si al cerrar no existe (un merge manual antes de que el
# bucle documentara, por ejemplo), se lanza `task-document` para que la
# escriba igual.
#
# Idempotente: una card ya `Hecha` solo recibe el marcador en el PR si le
# falta. La Épica y la siguiente hija se atienden solo en la ejecución que
# pasa la card a `Hecha`, igual que la skill: repetirlas podría lanzar dos
# veces la misma hija.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
DEVKIT_RUN="${DEVKIT_RUN_BIN:-$HERE/devkit-run.sh}"
TASK_NEXT="${DEVKIT_TASK_NEXT_BIN:-$HERE/task-next.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
LOCK="${DEVKIT_LOCK:-$RUN_DIR/skill.lock}"
WATCH_LOG="${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}"
HOY="${DEVKIT_HOY:-$(date +%F)}"
PS_BIN="${DEVKIT_PS_BIN:-ps}"
# Lo que este script lance (task-document, la siguiente hija vía task-next.sh)
# aparece en `devkit-run --estado` con origen `task-close` (DEVKIT-57).
export DEVKIT_ORIGEN=task-close

say() { printf 'task-close: %s\n' "$*"; }

clave="${1:-}"
pr_arg="${2:-}"
if [ -z "$clave" ]; then
  echo "uso: task-close.sh <Clave> [URL o número del PR]" >&2
  exit 64
fi
codigo=${clave%-*}

card=$("$NOTION" card "$clave") || { say "no pude leer $clave en Notion"; exit 1; }
id=$(jq -r .id <<<"$card")
estado=$(jq -r '.estado // ""' <<<"$card")
nivel=$(jq -r '.nivel // ""' <<<"$card")

clave_de() { jq -r --arg c "$codigo" '"\($c)-\(.numero)"' <<<"$1"; }

# ¿Hay un task-document vivo para la Clave? El bucle lo lanza con
# `devkit-run.sh --sync` y un lanzamiento manual con `--worker`; en ambos la
# línea del proceso trae "/task-document <Clave>". Sin esta guarda, un merge
# aprobado mientras task-document escribe la entrada lanzaba un segundo
# `claude -p` y comentaba en la card que faltaba la entrada (DEVKIT-55, H3).
documentando() {  # documentando <Clave>
  "$PS_BIN" -eo args= 2>/dev/null | grep -qE -- "(--sync|--worker|claude -p) /task-document $1( |$)"
}

# --- Épica -----------------------------------------------------------------
# Regla de DEVKIT-44: solo se cierra si todas sus hijas están Hecha, la Épica
# está En progreso y tiene Criterios de aceptación de verdad. Cerrar sin el
# chequeo dejó DEVKIT-19 en Hecha con todo su contenido sin ejecutar.
cerrar_epica() {  # cerrar_epica <page_id> <Clave>
  local eid=$1 eclave=$2 epica hijas pendientes criterios
  epica=$("$NOTION" pagina "$eid") || { say "no pude leer la Épica $eclave"; return 1; }
  if [ "$(jq -r .estado <<<"$epica")" = "Hecha" ]; then
    say "la Épica $eclave ya está Hecha"
    return 0
  fi
  hijas=$("$NOTION" hijas "$eid") || { say "no pude leer las hijas de $eclave"; return 1; }
  pendientes=$(jq -r --arg c "$codigo" '[.[] | select(.estado != "Hecha") | "\($c)-\(.numero) (\(.estado))"] | join(", ")' <<<"$hijas")
  if [ -n "$pendientes" ]; then
    say "la Épica $eclave tiene hijas sin cerrar: $pendientes"
    return 2
  fi
  criterios=$("$NOTION" criterios "$eid") || criterios=""
  if [ "$(jq -r .estado <<<"$epica")" != "En progreso" ] || [ -z "$criterios" ] \
     || printf '%s' "$criterios" | grep -qiE 'pendientes? de definir'; then
    "$NOTION" comentar "$eid" "Sus hijas terminaron, pero la Épica no se cierra: le falta estar En progreso o tener Criterios de aceptación definidos (regla de DEVKIT-44)."
    say "la Épica $eclave no cumple la regla de cierre de DEVKIT-44; comentado"
    return 0
  fi
  "$NOTION" set "$eid" Estado=Hecha "Cierre=$HOY" || return 1
  "$NOTION" comentar "$eid" "Cerrada: todas sus hijas están Hecha. La entrada de Documentación consolidada la escribe task-document."
  "$DEVKIT_RUN" task-document "$eclave" >/dev/null 2>&1 \
    && say "Épica $eclave Hecha; lanzado task-document para la entrada consolidada" \
    || say "Épica $eclave Hecha; no pude lanzar task-document"
}

if [ "$nivel" = "Épica" ]; then
  cerrar_epica "$id" "$clave"
  rc=$?
  [ "$rc" -eq 2 ] && rc=0
  exit "$rc"
fi

# --- PR y merge ------------------------------------------------------------
pr=${pr_arg:-$(jq -r '.pr // ""' <<<"$card")}
if [ -z "$pr" ]; then
  "$NOTION" comentar "$id" "task-close: la card no tiene PR registrado y no recibí uno; no se puede cerrar."
  say "$clave sin PR; comentado en la card"
  exit 1
fi
if ! pr_json=$("$GH" pr view "$pr" --json state,mergeCommit,url,number,comments,headRefOid,body,reviews 2>/dev/null); then
  say "gh no pudo leer el PR $pr"
  exit 1
fi
if [ "$(jq -r .state <<<"$pr_json")" != "MERGED" ]; then
  say "PR no mergeado: $pr"
  exit 0
fi
sha=$(jq -r '.mergeCommit.oid // ""' <<<"$pr_json")
pr_url=$(jq -r .url <<<"$pr_json")
pr_num=$(jq -r .number <<<"$pr_json")

# --- Marcas de modelo (DEVKIT-58) ------------------------------------------
# Este script es bash y no usa modelo, así que no tiene marca propia: copia al
# comentario de cierre la de quien implementó (cuerpo del PR, la escribe
# task-submit) y la del último informe de pr-review. Así la card dice con qué
# modelo y esfuerzo se produjo lo que se mergeó sin abrir el PR. Una marca que
# falta se dice como tal, no se deduce de roles.toml: el rol dice qué se
# pretendía lanzar, no qué corrió.
marca() {  # marca <verbo> <texto>: última línea "<verbo> con ..." del texto
  printf '%s\n' "$2" | tr -d '\r' | grep -oE "$1 con [^,]+, esfuerzo .+" | tail -1 | sed -E 's/[[:space:].]+$//'
}
marca_impl=$(marca Implementado "$(jq -r '.body // ""' <<<"$pr_json")")
marca_rev=$(marca Revisado "$(jq -r '[(.reviews // [])[] | select(.body | test("<!-- devkit-review "))] | sort_by(.submittedAt) | last | .body // ""' <<<"$pr_json")")
marcas="${marca_impl:-Implementado: sin marca en el PR}. ${marca_rev:-Revisado: sin marca en el último informe}. Cierre sin modelo (task-close.sh)."

# --- Card ------------------------------------------------------------------
transicion=0
doc_url=""
if [ "$estado" != "Hecha" ]; then
  props=(Estado=Hecha "Cierre=$HOY")
  [ -n "$(jq -r '.pr // ""' <<<"$card")" ] || props+=("PR=$pr_url")
  "$NOTION" set "$id" "${props[@]}" || { say "no pude pasar $clave a Hecha"; exit 1; }
  transicion=1
  if doc=$("$NOTION" documentacion "$id" "$clave"); then
    doc_url=$(jq -r .url <<<"$doc")
    "$NOTION" comentar "$id" "Cerrada. Documentación: $doc_url. $marcas"
  elif documentando "$clave"; then
    "$NOTION" comentar "$id" "Cerrada. La entrada de Documentación la está escribiendo task-document. $marcas"
    say "$clave sin entrada de Documentación todavía; task-document ya corre, no se relanza"
  else
    "$NOTION" comentar "$id" "Cerrada. Falta la entrada de Documentación: se lanza task-document para escribirla. $marcas"
    "$DEVKIT_RUN" task-document "$clave" >/dev/null 2>&1 \
      && say "$clave sin entrada de Documentación; lanzado task-document" \
      || say "$clave sin entrada de Documentación y no pude lanzar task-document"
  fi
  say "$clave Hecha"
else
  say "$clave ya estaba Hecha"
  doc=$("$NOTION" documentacion "$id" "$clave") && doc_url=$(jq -r .url <<<"$doc")
fi

# --- Marcador en el PR -----------------------------------------------------
# Mismo patrón que `DECIDE_MERGED` en watch.sh, sha incluido: un marcador sin
# sha lo ignora el bucle, y este chequeo tampoco lo da por publicado.
if [ -z "$sha" ]; then
  say "el PR $pr_url no trae merge commit; no publico el marcador"
elif [ "$(jq '[.comments[] | select(.body | test("<!-- devkit-closed sha=[0-9a-f]+ -->"))] | length' <<<"$pr_json")" -eq 0 ]; then
  cuerpo="<!-- devkit-closed sha=$sha -->"
  [ -z "$doc_url" ] || cuerpo="$cuerpo
Documentación: $doc_url"
  "$GH" pr comment "$pr_num" --body "$cuerpo" >/dev/null && say "marcador devkit-closed publicado en #$pr_num"
fi

# --- Limpieza local --------------------------------------------------------
# Solo con el workspace libre: el bucle de merges corre en paralelo con las
# skills, y un `git switch` en medio de un task-start le movería la rama.
# Antes de DEVKIT-63 esta sección callaba cuando no actuaba (candado ocupado,
# árbol sucio, `git switch`/`pull` fallidos): el 2026-09-16, tras DEVKIT-58,
# el candado ocupado por el `task-start` de la siguiente hija -el bucle de
# merges corre aparte del principal a propósito, sin compartir `skill.lock`
# (ver watch.sh)- hizo que `flock -n` fallara aquí sin dejar rastro, y el
# workspace quedó en la rama recién mergeada. `no_limpia` deja el motivo en
# watch.log en los tres casos en que no toca nada, para que ese silencio no
# se repita.
no_limpia() {  # no_limpia <motivo>
  printf '%s task-close.sh %s no limpia el workspace: %s\n' "$(date +%FT%T%:z)" "$clave" "$1" >> "$WATCH_LOG"
}
exec 9>"$LOCK"
if flock -n 9; then
  rama=$(jq -r '.rama // ""' <<<"$card" | sed -E 's#^.*/tree/##')
  if [ -n "$rama" ] && git -C "$WS" show-ref --verify --quiet "refs/heads/$rama"; then
    if [ "$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$rama" ]; then
      if [ -z "$(git -C "$WS" status --porcelain 2>/dev/null)" ]; then
        if git -C "$WS" switch -q main && git -C "$WS" pull -q --ff-only >/dev/null 2>&1; then
          say "workspace de vuelta en main"
        else
          no_limpia "git switch/pull a main falló"
        fi
      else
        no_limpia "árbol sucio"
      fi
    fi
    # `-d` no sirve tras un squash merge: la rama no queda como ancestro de
    # main. Se fuerza solo si su punta es el head que se mergeó, así un
    # commit local que no llegó al PR no se pierde.
    if [ "$(git -C "$WS" rev-parse "refs/heads/$rama" 2>/dev/null)" = "$(jq -r '.headRefOid // ""' <<<"$pr_json")" ]; then
      git -C "$WS" branch -q -D "$rama" 2>/dev/null && say "rama local $rama eliminada"
    else
      say "rama local $rama con commits que no están en el PR; no se borra"
    fi
  fi
  flock -u 9
else
  no_limpia "candado ocupado"
fi
exec 9>&-

[ "$transicion" = 1 ] || exit 0

# --- Épica y siguiente hija ------------------------------------------------
padre=$(jq -r '.padre[0] // ""' <<<"$card")
[ -n "$padre" ] || exit 0
hijas=$("$NOTION" hijas "$padre") || { say "no pude leer las hijas de la Épica"; exit 1; }

if [ "$(jq '[.[] | select(.estado != "Hecha")] | length' <<<"$hijas")" -eq 0 ]; then
  epica=$("$NOTION" pagina "$padre") || { say "no pude leer la Épica"; exit 1; }
  cerrar_epica "$padre" "$(clave_de "$epica")"
  exit $?
fi

# La siguiente hija la elige task-next.sh, el mismo que llama watch.sh al OK
# del revisor (DEVKIT-56). Su última línea es la de este cierre.
"$TASK_NEXT" "$clave" | sed 's/^task-next: /task-close: /'
exit "${PIPESTATUS[0]}"

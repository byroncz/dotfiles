#!/usr/bin/env bash
# Cierra una card cuyo PR ya se mergeó (DEVKIT-55). Hace lo mismo que la skill
# task-close a la que reemplaza, en bash y en segundos: `Hecha`, `Cierre`,
# comentario con el enlace a la entrada de Documentación, marcador
# `devkit-closed` en el PR, cierre de la Épica si era la última hija y
# lanzamiento de la siguiente card de la cola con `cola.sh` (DEVKIT-56,
# generalizado por DEVKIT-120), que también llama watch.sh al OK del
# revisor y en cada pasada del sondeo sin nada en curso.
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
# falta. La Épica se cierra solo en la ejecución que pasa la card a `Hecha`,
# igual que la skill: repetirlo podría cerrarla dos veces. La siguiente
# card de la cola no necesita esa guarda aparte: `cola.sh` ya trae la suya
# (ver `lanzar_cola`).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
DEVKIT_RUN="${DEVKIT_RUN_BIN:-$HERE/devkit-run.sh}"
COLA="${DEVKIT_COLA_BIN:-$HERE/cola.sh}"
TASK_DOCUMENT="${DEVKIT_TASK_DOCUMENT_BIN:-$HERE/task-document.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
LOCK="${DEVKIT_LOCK:-$RUN_DIR/skill.lock}"
WATCH_LOG="${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}"
HOY="${DEVKIT_HOY:-$(date +%F)}"
# Lo que este script lance (task-document, la siguiente card vía cola.sh)
# aparece en `devkit-run --estado` con origen `task-close` (DEVKIT-57).
export DEVKIT_ORIGEN=task-close

say() { printf 'task-close: %s\n' "$*"; }

# La siguiente card de la cola del proyecto, en bash (DEVKIT-120). Misma
# función que `lanzar_cola` en watch.sh, duplicada porque los scripts no se
# importan entre sí (mismo patrón que `costos_log_candidata`, DEVKIT-89): se
# llama siempre que esta card pasa a Hecha, tenga o no Épica, cierre o no la
# Épica -cola.sh mira el proyecto entero, no solo las hermanas de una Épica.
# Idempotente: `cola.sh` (sin argumento) no devuelve nada si ya hay una card
# `En progreso` o `Revisión automática` en el proyecto, o un `task-start`
# vivo para una card en `Lista` -la guarda vive en cola.sh, no aquí.
lanzar_cola() {  # lanzar_cola <n>
  local n=$1 siguiente out rc estado sucio otros motivo
  siguiente=$("$COLA" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s ALARMA: cola-%s no pudo leer la cola (rc=%s): %s\n' \
      "$(date +%FT%T%:z)" "$n" "$rc" "$(printf '%s' "$siguiente" | tail -1 | cut -c1-160)" >>"$WATCH_LOG"
    return
  fi
  [ -n "$siguiente" ] || return 0
  # Mismo chequeo que watch.sh (DEVKIT-120, H1): sin él, un archivo sin
  # commit o un `claude -p` ajeno hacía fallar `task-start` de la siguiente
  # card justo después de cerrar esta.
  sucio=$(git -C "$WS" status --porcelain --untracked-files=all 2>/dev/null)
  if [ -n "$sucio" ]; then
    motivo="workspace sucio: $(printf '%s' "$sucio" | tr '\n' ' ')"
  elif ! otros=$("$DEVKIT_RUN" --otros-agentes 2>&1); then
    motivo="otro agente: $(printf '%s' "$otros" | tr '\n' ' ')"
  fi
  if [ -n "${motivo:-}" ]; then
    printf '%s cola-%s espera: %s\n' "$(date +%FT%T%:z)" "$n" "$motivo" >>"$WATCH_LOG"
    return 0
  fi
  out=$("$DEVKIT_RUN" task-start "$siguiente" 2>&1)
  rc=$?
  printf '%s\n' "$out" >"$RUN_DIR/cola-$n.log"
  estado=terminado
  [ "$rc" -eq 0 ] || estado="falló (rc=$rc)"
  printf '%s cola-%s %s: bash, lanzada la siguiente card: task-start %s :: %s\n' \
    "$(date +%FT%T%:z)" "$n" "$estado" "$siguiente" "$(printf '%s' "$out" | tail -1 | cut -c1-160)" >>"$WATCH_LOG"
  [ "$rc" -eq 0 ] || printf '%s ALARMA: cola-%s terminó con error (rc=%s); ver %s/cola-%s.log\n' \
    "$(date +%FT%T%:z)" "$n" "$rc" "$RUN_DIR" "$n" >>"$WATCH_LOG"
}

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

# --- Card ------------------------------------------------------------------
transicion=0
doc_url=""
if [ "$estado" != "Hecha" ]; then
  # --- Costo de la card (DEVKIT-89) ------------------------------------------
  # Misma cuenta que la fila TOTAL de `devkit-run --costos <Clave>`: turnos,
  # costo y minutos ya sumados en costos.log más el número de revisiones
  # (lanzamientos de pr-review). Solo lo que ya está en el log; nunca se
  # estima. Solo se calcula aquí, no en la card "ya Hecha": ese caso no
  # comenta nada y no debe lanzar `devkit-run` de más.
  costo_linea=""
  if totales=$("$DEVKIT_RUN" --costos-totales "$clave" 2>/dev/null) && [ -n "$totales" ]; then
    IFS=$'\t' read -r c_turnos c_costo c_min c_rev <<<"$totales"
    costo_linea=" Costo: $c_turnos turnos, $c_costo USD, $c_min min, $c_rev revisiones."
  fi
  marcas="${marca_impl:-Implementado: sin marca en el PR}. ${marca_rev:-Revisado: sin marca en el último informe}. Cierre sin modelo (task-close.sh).$costo_linea"

  props=(Estado=Hecha "Cierre=$HOY")
  [ -n "$(jq -r '.pr // ""' <<<"$card")" ] || props+=("PR=$pr_url")
  "$NOTION" set "$id" "${props[@]}" || { say "no pude pasar $clave a Hecha"; exit 1; }
  transicion=1

  # task-document.sh es idempotente (DEVKIT-92): con la entrada ya escrita
  # para el head vigente no hace nada y sale con 0, así que se llama siempre,
  # sin comprobar antes si hace falta. Esto reemplaza el segundo lanzamiento
  # del agente que pedía DEVKIT-84: si el OK del revisor ya la escribió, este
  # paso es gratis; si el head cambió después (o el merge llegó antes de que
  # el bucle documentara), la escribe ahora.
  doc_out=$("$TASK_DOCUMENT" "$clave" "$pr_url" 2>&1); doc_rc=$?
  if doc=$("$NOTION" documentacion "$id" "$clave"); then
    doc_url=$(jq -r .url <<<"$doc")
    "$NOTION" comentar "$id" "Cerrada. Documentación: $doc_url. $marcas"
  else
    "$NOTION" comentar "$id" "Cerrada. Falta la entrada de Documentación: task-document.sh no pudo escribirla. $marcas"
    say "$clave sin entrada de Documentación: $doc_out"
  fi
  [ "$doc_rc" -eq 0 ] || say "task-document.sh terminó con error (rc=$doc_rc): $doc_out"
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

# --- Épica, si la card pertenece a una --------------------------------------
padre=$(jq -r '.padre[0] // ""' <<<"$card")
epica_rc=0
if [ -n "$padre" ]; then
  hijas=$("$NOTION" hijas "$padre") || { say "no pude leer las hijas de la Épica"; exit 1; }
  if [ "$(jq '[.[] | select(.estado != "Hecha")] | length' <<<"$hijas")" -eq 0 ]; then
    epica=$("$NOTION" pagina "$padre") || { say "no pude leer la Épica"; exit 1; }
    cerrar_epica "$padre" "$(clave_de "$epica")"
    epica_rc=$?
    [ "$epica_rc" -eq 2 ] && epica_rc=0
  fi
fi

# --- La siguiente card de la cola (DEVKIT-119/DEVKIT-120) -------------------
# cola.sh mira el proyecto entero, no solo las hermanas de la Épica de esta
# card: se llama siempre que una card pasa a Hecha, cierre o no una Épica y
# tenga o no una. Antes de DEVKIT-120 esto se saltaba sin Épica (`exit 0`) y
# dejaba de intentarlo si la Épica ya cerraba: con la cola del proyecto
# entero, en los dos casos puede haber otra card lista para arrancar.
lanzar_cola "$pr_num"
exit "$epica_rc"

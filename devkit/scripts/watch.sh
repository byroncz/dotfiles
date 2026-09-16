#!/usr/bin/env bash
# Bucle del contenedor. Cada 5 min mira los PRs cuyo título empieza por una
# Clave del proyecto (CODIGO-n) y lanza la skill que toca, en modo headless:
#
#   PR abierto, head sin marcador devkit-review            -> pr-review
#   último marcador CAMBIOS para el head, sin respuesta     -> task-fix
#   último marcador CAMBIOS para el head, respuesta sin push -> pr-review de nuevo
#   último marcador OK y comentario humano posterior        -> task-fix "<texto>"
#   último marcador OK para el head, sin devkit-doc del head -> task-document
#   3 ciclos revisor -> corrector sin OK                    -> task-block.sh
#   PR mergeado, sin marcador devkit-closed                 -> task-close.sh
#
# task-block.sh y task-close.sh son bash contra la API de Notion (DEVKIT-55),
# no skills: no gastan modelo ni esperan el candado de `claude -p`. Los PRs
# mergeados los atiende un segundo bucle, cada DEVKIT_WATCH_MERGED_INTERVAL
# segundos (30 por defecto), para que una card quede cerrada y la siguiente
# hija lanzada en menos de un minuto desde el merge, en vez de esperar el
# intervalo de 5 min y la skill que esté corriendo.
#
# El estado del ciclo vive en GitHub, en los marcadores de reviews y
# comentarios del PR (<!-- devkit-review -->, <!-- devkit-fix -->,
# <!-- devkit-doc -->, <!-- devkit-block -->, <!-- devkit-closed -->): un
# rebuild no lo pierde.
# /run/devkit/launched (tmpfs) solo evita relanzar lo mismo dentro de una vida
# del contenedor; cada skill es idempotente, así que repetir tras un rebuild no
# daña, pero cuesta dinero y tiempo: por eso el cierre también deja marcador.
#
# Si un `claude -p` muere porque se agotó la cuota de la suscripción, el bucle
# lo anota, espera a que la ventana se reinicie y relanza la misma skill con el
# mismo prompt, en segundo plano. Ver "Cuota agotada" más abajo.
#
# /run/devkit/poke: `task-submit` y `task-fix` lo tocan (`touch`) como último
# paso, para no dejar el ciclo revisar → corregir → revisar esperando el
# intervalo completo sin que nadie trabaje. El bucle duerme en tramos de 5 s y
# sale antes si el archivo aparece; al despertar lo borra y sigue con la
# consulta a GitHub. Quien lo toca no decide nada, solo adelanta el reloj.
#
# Uso de prueba: `bash watch.sh --decide < pr.json` imprime la decisión para
# el JSON de `gh pr view <N> --json headRefOid,reviews,comments`, y
# `bash watch.sh --decide-merged < pr.json` la del PR mergeado, para el JSON
# de `gh pr view <N> --json comments`. Los hooks `--quota-hit`, `--quota-reset`
# y `--run-skill` prueban el relanzamiento por cuota agotada; ver watch-test.sh.
#
# Monitoreo mínimo sin modelo (DEVKIT-46): cuatro alarmas en bash, todas como
# líneas "ALARMA: ..." en watch.log, sin costo de tokens: skill que terminó
# con error, skill de más de `DEVKIT_WATCH_SKILL_TIMEOUT` segundos corriendo
# (1200 por defecto), `result` que termina en pregunta en vez de un estado
# observable, y rama de una card sin PR y sin `claude -p` vivo hace más de
# `DEVKIT_WATCH_ORPHAN_AGE` segundos (1800 por defecto). `bash watch.sh
# --agentes-vivos` lista PID, Clave y paso de cada skill en curso. El hook
# `--orphan-branch <edad> <tiene PR: si|no> <skill viva: si|no>` prueba la
# cuarta alarma sin git ni gh; ver watch-test.sh.
set -u
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
LAUNCHED="$RUN_DIR/launched"
POKE="$RUN_DIR/poke"
LOCK="$RUN_DIR/skill.lock"
WATCH_LOG_FILE="${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}"
INTERVAL="${DEVKIT_WATCH_INTERVAL:-300}"
MAX_CYCLES="${DEVKIT_WATCH_MAX_CYCLES:-3}"
# `devkit-run.sh` es el único punto de lanzamiento (DEVKIT-45): resuelve
# modelo y esfuerzo por rol desde `devkit/agents/roles.toml` y corre
# `claude -p`; `run_skill` sigue dueño del candado, la cuota agotada y el
# registro en watch.log.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVKIT_RUN="${DEVKIT_RUN_BIN:-$SCRIPTS_DIR/devkit-run.sh}"
QUOTA_RETRIES="${DEVKIT_WATCH_QUOTA_RETRIES:-3}"
QUOTA_WAIT="${DEVKIT_WATCH_QUOTA_WAIT:-1800}"
QUOTA_MIN_WAIT="${DEVKIT_WATCH_QUOTA_MIN_WAIT:-60}"
QUOTA_MAX_WAIT="${DEVKIT_WATCH_QUOTA_MAX_WAIT:-86400}"
# Monitoreo mínimo sin modelo (DEVKIT-46): cuatro alarmas en bash, todas como
# líneas "ALARMA: ..." en watch.log. `SKILL_TIMEOUT`/`SKILL_POLL` gobiernan la
# alarma de skill lenta; `ORPHAN_MAX_AGE`, la de rama huérfana.
SKILL_TIMEOUT="${DEVKIT_WATCH_SKILL_TIMEOUT:-1200}"
SKILL_POLL="${DEVKIT_WATCH_SKILL_POLL:-5}"
ORPHAN_MAX_AGE="${DEVKIT_WATCH_ORPHAN_AGE:-1800}"
# Cierre y bloqueo en bash (DEVKIT-55). MERGED_INTERVAL es el tick del bucle de
# PRs mergeados: una consulta liviana a GitHub (una lista de PRs) cada 30 s
# cabe de sobra en el límite de 5000 peticiones por hora del token.
TASK_CLOSE="${DEVKIT_TASK_CLOSE_BIN:-$SCRIPTS_DIR/task-close.sh}"
TASK_BLOCK="${DEVKIT_TASK_BLOCK_BIN:-$SCRIPTS_DIR/task-block.sh}"
MERGED_INTERVAL="${DEVKIT_WATCH_MERGED_INTERVAL:-30}"

# Decisión sobre un PR abierto. Entrada: el JSON de gh pr view. Salida: una
# línea con cuatro campos separados por tabulador (acción, head, referencia,
# extra), nunca vacíos ("-" si no aplica):
#   revisar    <head> <sha del marcador anterior o el propio head> -
#   fix        <head> <sha del marcador CAMBIOS>      -
#   fix-humano <head> <fecha del último comentario>   <texto en base64>
#   documentar <head> OK                              -
#   bloquear   <head> <ciclos sin OK>                 -
#   bloqueado  <head> <fecha del bloqueo>             -
#   nada       <head> <veredicto vigente>             -
# Los marcadores se reconocen por su texto, no por su autor: así valen aunque
# el informe lo haya publicado el humano desde otra sesión. Lo humano es todo
# lo que no lleva marcador, no lo firma la cuenta máquina y llega después del
# último marcador; los approve no cuentan (los cierra el auto-merge).
# Un bloqueo manda hasta que aparece un devkit-fix posterior a él: esa
# respuesta del corrector (al comentario humano) reanuda el ciclo y el head
# nuevo vuelve a la rama normal (revisar). Los casos están en watch-test.sh.
# `revisar` también sale cuando el último informe es CAMBIOS para el head
# vigente y el corrector ya respondió sin empujar commits (descartó todo o
# solo comentó, DEVKIT-22): la referencia es igual al head y le dice a
# `pr-review` que ese sha ya tiene respuesta y debe juzgarla, no responder
# "ya revisado" y salir. Sin esa respuesta, sigue siendo `fix` (pendiente).
# `documentar` sale cuando el último informe es OK para el head vigente y no
# hay marcador `devkit-doc` de ese mismo head (DEVKIT-55): la entrada de
# Documentación se escribe al aprobar, no al cerrar. Si la card vuelve atrás
# y un head nuevo recibe otro OK, falta el marcador de ese head y task-document
# corre de nuevo sobre la misma entrada. Un comentario humano manda sobre
# documentar: primero se corrige.
DECIDE='
def markers($re; $ts):
  [ .[] | . as $x | ($x.body // "" | capture($re)) | . + {at: $x[$ts]} ];

.headRefOid as $head
| (.reviews | markers("<!-- devkit-review sha=(?<sha>[0-9a-f]+) verdict=(?<verdict>OK|CAMBIOS) -->"; "submittedAt")
   | sort_by(.at)) as $reviews
| (.comments | markers("<!-- devkit-fix sha=(?<sha>[0-9a-f]+) review=(?<review>[0-9a-f]+) -->"; "createdAt")) as $fixes
| (.comments | markers("<!-- devkit-block sha=(?<sha>[0-9a-f]+) -->"; "createdAt") | sort_by(.at)) as $blocks
| (.comments | markers("<!-- devkit-doc sha=(?<sha>[0-9a-f]+) -->"; "createdAt")) as $docs
| ($reviews | last) as $last
| (($blocks | last | .at) // "") as $block_at
| ($block_at != "" and ([$fixes[] | select(.at > $block_at)] | length) > 0) as $resumed
| ($block_at != "" and $last != null and $block_at > $last.at and ($resumed | not)) as $blocked
| (([$reviews[] | select(.verdict == "OK") | .at] | max) // "") as $ok_at
| ([$ok_at, $block_at] | max) as $reset_at
| ([$reviews[] | select(.verdict == "CAMBIOS" and .at > $reset_at)] | length) as $cambios
| (([$reviews[].at, $fixes[].at, $blocks[].at] | max) // "") as $bot_at
| ([ (.reviews[] | select(.state != "APPROVED" and .state != "DISMISSED")
       | {body, at: .submittedAt, login: .author.login}),
     (.comments[] | {body, at: .createdAt, login: .author.login}) ]
   | map(select(.login != $bot
                and ((.body // "") | test("<!-- devkit-") | not)
                and ((.body // "") | gsub("\\s"; "") != "")
                and .at > $bot_at))
   | sort_by(.at)) as $human
| (if $last != null then
     [$fixes[] | select(.review == $last.sha and .at > $last.at)] | length
   else 0 end) as $fix_after
| ($last != null and $last.verdict == "CAMBIOS" and $last.sha == $head
   and $fix_after == 0) as $pending_fix
| ($last != null and $last.verdict == "CAMBIOS" and $last.sha == $head
   and $fix_after > 0) as $fix_responded
| ($human | map(.body) | join("\n\n") | @base64) as $human_text
| (($human | last | .at) // "-") as $human_at
| if $blocked then
    (if ($human | length) > 0 then ["fix-humano", $head, $human_at, $human_text]
     else ["bloqueado", $head, $block_at, "-"] end)
  elif ($human | length) > 0 and $last != null and $last.verdict == "OK" and $last.sha == $head then
    ["fix-humano", $head, $human_at, $human_text]
  elif $cambios >= $max and ($pending_fix | not) then
    ["bloquear", $head, ($cambios | tostring), "-"]
  elif $last == null or $last.sha != $head then
    ["revisar", $head, ($last.sha // "-"), "-"]
  elif $pending_fix then
    ["fix", $head, $last.sha, "-"]
  elif $fix_responded then
    ["revisar", $head, $last.sha, "-"]
  elif $last.verdict == "OK" and ([$docs[] | select(.sha == $head)] | length) == 0 then
    ["documentar", $head, "OK", "-"]
  else
    ["nada", $head, $last.verdict, "-"]
  end
| @tsv
'

decide() {  # decide <login de la cuenta máquina>  (JSON por stdin)
  jq -r --arg bot "$1" --argjson max "$MAX_CYCLES" "$DECIDE"
}

# Decisión sobre un PR ya mergeado. Entrada: el JSON de
# `gh pr view <N> --json comments`. Salida: una línea con dos campos separados
# por tabulador, nunca vacíos:
#   cerrar  -                       (no hay marcador: hay que lanzar task-close)
#   cerrada <sha del merge commit>  (task-close ya terminó sobre este PR)
# El marcador es lo que sobrevive a un `devkit recreate`: `launched` vive en
# tmpfs y nace vacío, así que sin él el bucle relanzaba task-close sobre cada
# PR mergeado en las últimas 48 h, con card ya en Hecha (DEVKIT-24). Como el
# resto de la familia, se reconoce por su texto y no por su autor.
DECIDE_MERGED='
[ (.comments // [])[]
  | (.body // "" | capture("<!-- devkit-closed sha=(?<sha>[0-9a-f]+) -->")) ]
| if length > 0 then ["cerrada", (last | .sha)] else ["cerrar", "-"] end
| @tsv
'

decide_merged() {  # (JSON por stdin)
  jq -r "$DECIDE_MERGED"
}

if [ "${1:-}" = "--decide" ]; then
  decide "${DEVKIT_WATCH_BOT:-$(gh api user --jq .login 2>/dev/null)}"
  exit $?
fi

if [ "${1:-}" = "--decide-merged" ]; then
  decide_merged
  exit $?
fi

cd "$WS" 2>/dev/null || exit 0
mkdir -p "$RUN_DIR"
touch "$LAUNCHED"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# `cuota:<clave>` es la misma entrada, reescrita mientras la skill espera a que
# se reinicie la cuota (DEVKIT-27): para el bucle cuenta como lanzada, así que
# no nace una segunda copia en paralelo, y el relanzamiento la restituye al
# despertar. La carrera entre el bucle y el relanzamiento al reescribir el
# archivo es inocua: lo peor que pasa es repetir o perder una línea, y toda
# skill es idempotente.
launched() { grep -qxF "$1" "$LAUNCHED" || grep -qxF "cuota:$1" "$LAUNCHED"; }
paused() { grep -qxF "cuota:$1" "$LAUNCHED"; }
mark() { echo "$1" >> "$LAUNCHED"; }
unmark() { grep -vxF "$1" "$LAUNCHED" > "$LAUNCHED.tmp" 2>/dev/null; mv "$LAUNCHED.tmp" "$LAUNCHED"; }

# Duerme hasta completar $1 segundos, en tramos de 5, o hasta que aparezca
# $POKE. Lo borra al despertar, antes de que el bucle vuelva a consultar
# GitHub, para que un aviso llegado durante la consulta no se pierda.
sleep_or_poke() {
  local total=$1 waited=0 step
  while [ "$waited" -lt "$total" ]; do
    [ -e "$POKE" ] && break
    step=$(( total - waited < 5 ? total - waited : 5 ))
    sleep "$step"
    waited=$((waited + step))
  done
  rm -f "$POKE"
}

# Estado en el que quedó el trabajo tras un `claude -p`. Notion no se consulta
# desde bash, así que se registra solo lo observable en git y GitHub: la rama en
# la que quedó el workspace, sus commits sobre main y su PR. La línea no afirma
# en qué Estado quedó la card, que solo lo sabe Notion; "rama de card sin PR" es
# la señal de que la ejecución pudo cortarse, y quien lea el log decide.
work_state() {
  local branch key ahead pr prs
  branch=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null)
  # HEAD desprendido va aparte: no se sabe qué rama se estaba trabajando, así
  # que tampoco se puede afirmar que no haya card en progreso.
  if [ "$branch" = "HEAD" ]; then
    log "  estado: workspace en HEAD desprendido, estado desconocido"
    return
  fi
  if [ -z "$branch" ] || [ "$branch" = "main" ]; then
    log "  estado: workspace en '${branch:-?}', ninguna card en progreso"
    return
  fi
  key=$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  ahead=$(git -C "$WS" rev-list --count "main..$branch" 2>/dev/null) || ahead="?"
  # El código de salida distingue "gh no respondió" de "no hay PR": sin esa
  # comprobación, un fallo de token o de red se leería como una rama sin PR.
  if prs=$(gh pr list --head "$branch" --state all --limit 1 --json number,state \
             --jq '.[] | "PR #\(.number) \(.state)"' 2>/dev/null); then
    pr="${prs:-rama de card sin PR}"
  else
    pr="PR desconocido: gh no respondió"
  fi
  log "  estado: ${key:-sin Clave} en $branch, $ahead commits sobre main, $pr"
}

# --- Cuota agotada de la suscripción (DEVKIT-27) ----------------------------
# Un `claude -p` que se queda sin cuota muere con rc distinto de cero y deja el
# aviso del límite en su log. El agente ya no puede reaccionar (sin cuota no
# habla con el modelo, así que ninguna skill sirve, `task-block` incluida);
# quien reacciona es este bucle, que es bash y sobrevive: anota la pausa, espera
# a que la ventana se reinicie y relanza la misma skill con el mismo prompt y
# los mismos flags. No se toca Notion ni el PR: una card puede morir antes de
# tener PR y el mecanismo debe valer igual para todas.

# Formas conocidas del aviso. Claude Code no ofrece comando ni endpoint para
# consultar la cuota desde un script, ni hook para este fallo: el texto del log
# es lo único legible. Si aparece una forma nueva, se añade aquí y se cubre con
# un caso en watch-test.sh.
QUOTA_RE='usage limit reached|limit will reset|(hit|reached) your (usage |session |weekly |5-hour )*limit|(session|weekly|5-hour|five-hour|opus) limit reached'

quota_hit() { grep -qiE "$QUOTA_RE" "$1" 2>/dev/null; }

# Hora en que se reinicia la cuota. Lee el texto del log por stdin e imprime el
# epoch en segundos; no imprime nada si no encuentra ninguna hora, y entonces
# quien llama usa la espera fija.
quota_reset_epoch() {
  local text stamp frag tz day hhmm hh mm ampm spec now target
  text=$(tr '\n' ' ' | tr -s ' ')

  # 1. Forma legible por máquina: `Claude AI usage limit reached|1757558400`,
  #    el epoch en segundos (o en milisegundos, de ahí los 13 dígitos).
  stamp=$(printf '%s' "$text" | grep -oiE 'usage limit reached\|[0-9]{9,13}' | head -1)
  if [ -n "$stamp" ]; then
    stamp=${stamp##*|}
    [ "${#stamp}" -ge 12 ] && stamp=$((stamp / 1000))
    printf '%s' "$stamp"
    return 0
  fi

  # 2. Forma para el humano: "resets 3pm (America/Los_Angeles)", "your limit
  #    will reset at 10:30am", "weekly limit reached ∙ resets Feb 3 at 10am".
  frag=$(printf '%s' "$text" | grep -oiE 'reset[s]?[^.;]{0,60}' | head -1)
  [ -n "$frag" ] || return 1
  tz=$(printf '%s' "$frag" | grep -oE '[A-Za-z]+/[A-Za-z_]+' | head -1)
  day=$(printf '%s' "$frag" | grep -oiE '(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* [0-9]{1,2}' | head -1)
  hhmm=$(printf '%s' "$frag" | grep -oiE '[0-9]{1,2}(:[0-9]{2})? ?(am|pm)' | head -1)
  if [ -n "$hhmm" ]; then
    ampm=$(printf '%s' "$hhmm" | grep -oiE 'am|pm' | tr '[:upper:]' '[:lower:]')
    mm=$(printf '%s' "$hhmm" | grep -oE ':[0-9]{2}' | tr -d ':')
    hh=$(printf '%s' "$hhmm" | grep -oE '^[0-9]{1,2}')
    hh=$((10#$hh % 12))
    [ "$ampm" = "pm" ] && hh=$((hh + 12))
  else
    hhmm=$(printf '%s' "$frag" | grep -oE '[0-9]{1,2}:[0-9]{2}' | head -1)
    [ -n "$hhmm" ] || return 1
    hh=${hhmm%%:*}
    mm=${hhmm##*:}
  fi
  spec=$(printf '%02d:%02d' "$((10#$hh))" "$((10#${mm:-0}))")
  [ -n "$day" ] && spec="$day $spec"
  # Sin zona en el mensaje se usa la del contenedor: es la única disponible y
  # una hora mal interpretada solo alarga o acorta la espera, nunca pierde el
  # relanzamiento, que además está acotado por QUOTA_MIN_WAIT y QUOTA_MAX_WAIT.
  if [ -n "$tz" ]; then
    target=$(TZ="$tz" date -d "$spec" +%s 2>/dev/null) || return 1
  else
    target=$(date -d "$spec" +%s 2>/dev/null) || return 1
  fi
  [ -n "$target" ] || return 1
  now=$(date +%s)
  # "3pm" sin fecha y ya pasado es el de mañana.
  if [ -z "$day" ] && [ "$target" -le "$now" ]; then
    target=$((target + 86400))
  fi
  printf '%s' "$target"
}

# Pausa por cuota agotada: anota hasta cuándo y relanza al reanudarse. La
# espera corre en segundo plano para que el bucle siga atendiendo otros PRs; el
# candado de run_skill impide que el relanzamiento coincida con otra skill.
quota_pause() {  # quota_pause <nombre> <prompt> <clave de launched o -> <intento> <log>
  local name=$1 prompt=$2 key=$3 attempt=$4 logf=$5 epoch now wait until
  if [ "$key" != "-" ] && paused "$key"; then
    log "cuota agotada: $name ya tiene un relanzamiento programado; no se duplica"
    return
  fi
  if [ "$attempt" -ge "$QUOTA_RETRIES" ]; then
    log "cuota agotada: $name sin más intentos (tope de $QUOTA_RETRIES); no se relanza, ver $logf"
    return
  fi
  now=$(date +%s)
  epoch=$(quota_reset_epoch < "$logf")
  if [ -n "$epoch" ]; then
    wait=$((epoch - now))
  else
    wait=$QUOTA_WAIT
    log "cuota agotada: $name sin hora de reinicio legible en el aviso; espera fija de ${QUOTA_WAIT}s"
  fi
  [ "$wait" -lt "$QUOTA_MIN_WAIT" ] && wait=$QUOTA_MIN_WAIT
  [ "$wait" -gt "$QUOTA_MAX_WAIT" ] && wait=$QUOTA_MAX_WAIT
  until=$(date -u -d "@$((now + wait))" +%FT%TZ)
  if [ "$key" != "-" ]; then unmark "$key"; mark "cuota:$key"; fi
  log "cuota agotada: $name en pausa hasta $until (intento $((attempt + 1)) de $QUOTA_RETRIES)"
  (
    sleep "$wait"
    if [ "$key" != "-" ]; then unmark "cuota:$key"; mark "$key"; fi
    log "cuota reanudada: relanzando $name"
    run_skill "$name" "$prompt" "$key" "$((attempt + 1))"
  ) &
}

# Alarma 1 de 4 (DEVKIT-46): mientras el `claude -p` de un skill corre en
# segundo plano, avisa una sola vez si supera SKILL_TIMEOUT segundos. Sondea
# cada SKILL_POLL segundos con `kill -0`; ambos son configurables para que la
# prueba no tenga que esperar 20 minutos de verdad.
watch_long_running() {  # watch_long_running <nombre> <pid>
  local name=$1 pid=$2 waited=0 alarmed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$SKILL_POLL"
    waited=$((waited + SKILL_POLL))
    if [ "$alarmed" -eq 0 ] && [ "$waited" -ge "$SKILL_TIMEOUT" ]; then
      log "ALARMA: $name lleva $((waited / 60)) min corriendo (límite ${SKILL_TIMEOUT}s)"
      alarmed=1
    fi
  done
}

# run_skill <nombre del log> <prompt> [clave de launched] [intento]. Lanza el
# prompt con `devkit-run.sh --sync`, que resuelve modelo y esfuerzo por rol y
# corre `claude -p`; la última línea de su JSON trae costo, tokens y turnos,
# que es la medida de cada ciclo. Al terminar se registra el estado del
# trabajo, para que un corte sea visible, y si el corte fue por cuota se
# programa el relanzamiento.
run_skill() {
  local name=$1 prompt=$2 key=${3:--} attempt=${4:-1} logf rc summary modelo esfuerzo presupuesto skill_pid watcher_pid resultado
  logf="$RUN_DIR/$name.log"
  # Un solo `claude -p` a la vez: desde DEVKIT-27 un relanzamiento por cuota
  # puede despertar mientras el bucle atiende otro PR, y dos agentes sobre el
  # mismo workspace se pisarían la rama.
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log "$name espera: otra skill ocupa el workspace"
    flock 9
  fi
  read -r modelo esfuerzo presupuesto < <("$DEVKIT_RUN" --rol "$prompt")
  "$DEVKIT_RUN" --sync "$prompt" >"$logf" 2>&1 &
  skill_pid=$!
  watch_long_running "$name" "$skill_pid" &
  watcher_pid=$!
  wait "$skill_pid"
  rc=$?
  kill "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
  flock -u 9
  exec 9>&-
  summary=$("$DEVKIT_RUN" --resumen "$logf" "$modelo" "$esfuerzo" "$presupuesto")
  if [ $rc -eq 0 ]; then
    log "$name terminado: $summary"
    # Alarma 2 de 4: un `result` que termina en pregunta es la card en curso
    # cortando en seco en vez de resolver en un estado observable (AGENTS.md).
    resultado=$(tail -1 "$logf" 2>/dev/null | jq -r '.result // ""' 2>/dev/null)
    if printf '%s' "$resultado" | grep -qE '\?[[:space:]]*$'; then
      log "ALARMA: $name terminó con una pregunta abierta en vez de un estado observable"
    fi
  else
    # Alarma 3 de 4: cualquier skill que termina con error.
    log "ALARMA: $name terminó con error (rc=$rc): $summary; ver $logf"
  fi
  work_state
  if [ $rc -ne 0 ] && quota_hit "$logf"; then
    quota_pause "$name" "$prompt" "$key" "$attempt" "$logf"
  fi
  return $rc
}

# Costo total del ciclo de un PR: suma "costo=" de todas sus líneas en
# watch.log (pr-review-<n>-*, task-fix-<n>-*, task-document-<n>-*, task-block-<n>,
# task-close-<n>), no solo el último task-close, porque el mismo PR pudo
# pasar por varias rondas de revisión y corrección. Se imprime al cerrar.
cycle_cost() {  # cycle_cost <num> [archivo de log, para la prueba]
  local num=$1 file=${2:-$WATCH_LOG_FILE}
  # `(-[0-9A-Za-z]+)*` en vez de `?`: task-fix-<n>-humano-<fecha> tiene dos
  # segmentos de sufijo, no uno.
  grep -E " (pr-review|task-fix|task-document|task-block|task-close)-$num(-[0-9A-Za-z]+)* (terminado|falló)" "$file" 2>/dev/null \
    | grep -oE 'costo=[0-9.]+' | cut -d= -f2 \
    | awk '{s+=$1} END{printf "%.4f", s+0}'
}

# Clave del título del PR, solo si es de este proyecto y no es la -0.
key_of() {  # key_of <título> <código>
  local key
  key=$(printf '%s' "$1" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  [ -n "$key" ] || return 1
  [ -z "$2" ] || [ "${key%%-*}" = "$2" ] || return 1
  [ "${key##*-}" != "0" ] || return 1
  printf '%s' "$key"
}

# Alarma 4 de 4 (DEVKIT-46): decisión pura, sin git ni gh, para que
# watch-test.sh la pruebe con datos sintéticos. `check_orphan_branch` reúne
# los tres datos (edad del último commit, si ya tiene PR, si una skill sigue
# viva) y llama a esta función.
orphan_branch_alarm() {  # orphan_branch_alarm <edad en segundos> <tiene PR: si|no> <skill viva: si|no>
  local age=$1 has_pr=$2 skill_alive=$3
  [ "$age" -ge "$ORPHAN_MAX_AGE" ] || return 1
  [ "$has_pr" = "no" ] || return 1
  [ "$skill_alive" = "no" ] || return 1
  return 0
}

# Sesión interactiva viva sobre este workspace (DEVKIT-46, H4 de la revisión):
# un humano trabajando a mano sobre una card `En progreso` (permitido por
# AGENTS.md) no toca `skill.lock` -ese candado es solo de `run_skill`-, así
# que sin esta señal la rama se ve huérfana aunque alguien la esté usando. Se
# reconoce por un `claude` sin `-p` (la TUI, no un `claude -p` headless) cuyo
# `cwd` es este mismo workspace: el host puede tener sesiones abiertas sobre
# otros proyectos, que no cuentan.
interactive_session_alive() {
  local pid cwd
  for pid in $(ps -eo pid=,comm= 2>/dev/null | awk '$2 == "claude" {print $1}'); do
    ps -p "$pid" -o args= 2>/dev/null | grep -qE '(^| )-p( |$)' && continue
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || continue
    [ "$cwd" = "$WS" ] || continue
    return 0
  done
  return 1
}

# Rama en la que quedó el workspace, sin PR y sin ningún `claude -p` vivo hace
# más de ORPHAN_MAX_AGE segundos: la señal de que una ejecución se cortó a
# medias y nadie la está retomando. "Skill viva" se lee del candado de
# run_skill, no de la lista de procesos: si nadie tiene `skill.lock`, no hay
# un `claude -p` en curso sobre este workspace. Una sesión interactiva viva
# (ver interactive_session_alive) cuenta igual, aunque no toque el candado.
#
# La edad se mide desde la última señal de actividad, no solo desde el
# último commit: una rama recién creada por task-start hereda el timestamp
# del último commit de main (que puede ser viejo) y `exec >"$LOCK"` en
# run_skill actualiza el mtime del candado cada vez que una skill lo toma o
# lo suelta, así que sirve de proxy de "hace cuánto corrió algo aquí". Si la
# rama todavía no tiene commits propios sobre main, es demasiado pronto para
# medir: se sale sin evaluar la alarma (DEVKIT-46, H3 de la revisión).
check_orphan_branch() {
  local branch key committed lock_mtime last_activity now age has_pr skill_alive prs head_commit merge_base
  branch=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null) || return
  case "$branch" in HEAD|main|"") return ;; esac
  head_commit=$(git -C "$WS" rev-parse HEAD 2>/dev/null) || return
  merge_base=$(git -C "$WS" merge-base HEAD main 2>/dev/null) || merge_base=""
  [ "$head_commit" != "$merge_base" ] || return
  committed=$(git -C "$WS" log -1 --format=%ct 2>/dev/null) || return
  last_activity=$committed
  if [ -f "$LOCK" ]; then
    lock_mtime=$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null) || lock_mtime=0
    [ "$lock_mtime" -le "$last_activity" ] || last_activity=$lock_mtime
  fi
  now=$(date +%s)
  age=$((now - last_activity))
  exec 8>"$LOCK"
  if flock -n 8; then skill_alive=no; flock -u 8; else skill_alive=si; fi
  exec 8>&-
  if [ "$skill_alive" = no ] && interactive_session_alive; then skill_alive=si; fi
  if prs=$(gh pr list --head "$branch" --state all --limit 1 --json number --jq 'length' 2>/dev/null); then
    { [ "${prs:-0}" -gt 0 ] 2>/dev/null && has_pr=si; } || has_pr=no
  else
    return  # gh no respondió: se reintenta en la vuelta siguiente
  fi
  key=$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  if orphan_branch_alarm "$age" "$has_pr" "$skill_alive"; then
    log "ALARMA: rama $branch (${key:-sin Clave}) sin PR y sin skill viva hace $((age / 60)) min"
  fi
}

# Comando que lista los agentes vivos con su Clave y su paso (DEVKIT-46,
# contenido de DEVKIT-19). Un agente vivo es un `devkit-run.sh --worker` en
# curso: su línea de proceso trae "--worker /<skill> <Clave> ...", que es el
# mismo prompt que arma `devkit-run` (skill.sh y devkit-run.sh comparten esa
# forma). No depende de watch.sh: un `devkit-run` lanzado a mano también sale.
agentes_vivos() {
  local lineas
  lineas=$(ps -eo pid=,args= 2>/dev/null | grep -- '--worker' | grep -v grep)
  if [ -z "$lineas" ]; then
    echo "sin agentes vivos"
    return 0
  fi
  printf '%s\n' "$lineas" | while IFS= read -r linea; do
    local pid args paso clave
    pid=$(printf '%s' "$linea" | awk '{print $1}')
    args=$(printf '%s' "$linea" | cut -d' ' -f2-)
    paso=$(printf '%s' "$args" | grep -oE -- '--worker[[:space:]]+/[a-zA-Z-]+' | grep -oE '/[a-zA-Z-]+$' | tr -d '/')
    clave=$(printf '%s' "$args" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
    printf '%s\t%s\t%s\n' "$pid" "${clave:-?}" "${paso:-?}"
  done
  return 0
}

# Código del proyecto. Se relee en cada vuelta: en un proyecto nuevo,
# .devkit/devkit.toml arranca con `project = "PROJ"` y project-init lo corrige
# después, sin reiniciar el contenedor.
project_code() {
  [ -f "$WS/.devkit/devkit.toml" ] || return 0
  sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/.devkit/devkit.toml" | head -1
}

# Bloqueo por tres ciclos sin OK, en bash (DEVKIT-55). Primero el marcador en
# el PR: es lo que detiene al bucle aunque falle Notion. Luego la card.
block_pr() {  # block_pr <num> <Clave> <url> <head> <ciclos>
  local num=$1 key=$2 url=$3 head=$4 ciclos=$5 out rc estado
  log "PR #$num ($key) $ciclos ciclos sin OK: bloqueando con task-block.sh"
  gh pr comment "$num" --body "<!-- devkit-block sha=$head -->
Tres ciclos de revisión y corrección sin veredicto OK. La card pasa a Bloqueada y el bucle no toca este PR hasta que decidas.
Para retomar: mueve la card a Revisión automática y comenta aquí qué hacer. El bucle lanza task-fix con tu comentario y el conteo de ciclos vuelve a cero." >/dev/null 2>&1 \
    || log "PR #$num: no se pudo publicar el marcador devkit-block"
  out=$("$TASK_BLOCK" "$key" "Tres ciclos de revisión y corrección sin veredicto OK en el PR $url; el bucle no lo toca hasta que decidas." 2>&1)
  rc=$?
  printf '%s\n' "$out" >"$RUN_DIR/task-block-$num.log"
  estado=terminado
  [ "$rc" -eq 0 ] || estado="falló (rc=$rc)"
  log "task-block-$num $estado: bash :: $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  [ "$rc" -eq 0 ] || log "ALARMA: task-block-$num terminó con error (rc=$rc); ver $RUN_DIR/task-block-$num.log"
}

# Cierre de un PR mergeado, en bash (DEVKIT-55). La línea de resumen dice
# cuántos segundos pasaron desde el merge hasta que la card quedó cerrada:
# es la medida del criterio "menos de un minuto".
close_pr() {  # close_pr <num> <Clave> <url> <mergedAt>
  local num=$1 key=$2 url=$3 merged_at=$4 out rc estado desde
  log "PR #$num mergeado ($key): cerrando con task-close.sh"
  out=$("$TASK_CLOSE" "$key" "$url" 2>&1)
  rc=$?
  printf '%s\n' "$out" >"$RUN_DIR/task-close-$num.log"
  desde=$(( $(date +%s) - $(date -d "$merged_at" +%s 2>/dev/null || date +%s) ))
  estado=terminado
  [ "$rc" -eq 0 ] || estado="falló (rc=$rc)"
  log "task-close-$num $estado: bash, cerrado ${desde}s después del merge :: $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  [ "$rc" -eq 0 ] || log "ALARMA: task-close-$num terminó con error (rc=$rc); ver $RUN_DIR/task-close-$num.log"
  log "PR #$num ($key) costo total del ciclo: \$$(cycle_cost "$num") USD"
}

# Una pasada sobre los PRs mergeados en las últimas 48 h.
check_merged_prs() {
  local code
  code=$(project_code)
  gh pr list --state merged --limit 30 --json number,title,url,mergedAt \
    --jq '[.[] | select(.mergedAt > (now - 172800 | todate))] | sort_by(.mergedAt)
           | .[] | "\(.number)\t\(.url)\t\(.mergedAt)\t\(.title)"' 2>/dev/null \
  | while IFS=$'\t' read -r num url merged_at title; do
      key=$(key_of "$title" "$code") || continue
      launched "cerrar:$num" && continue
      IFS=$'\t' read -r action ref < <(
        gh pr view "$num" --json comments 2>/dev/null | decide_merged
      )
      # Sin decisión, gh no respondió: no se registra nada y se reintenta en
      # la vuelta siguiente. Registrarlo aquí perdería el cierre.
      [ -n "${action:-}" ] || continue
      if [ "$action" = "cerrada" ]; then
        # Se registra igual: evita una consulta a GitHub cada vuelta.
        mark "cerrar:$num"
        log "PR #$num mergeado ($key) ya cerrado en ${ref:0:7}: se omite"
        continue
      fi
      # Se registra antes de cerrar: si falla, el humano lo repite con
      # `devkit-run task-close <Clave>`; task-close.sh es idempotente.
      mark "cerrar:$num"
      close_pr "$num" "$key" "$url" "$merged_at"
    done
}

# Hooks de prueba, sin GitHub y sin gastar cuota:
#   --quota-hit             rc 0 si el texto por stdin es un aviso de límite
#   --quota-reset           imprime el epoch de reinicio que lee de ese texto
#   --run-skill <n> <p>     una ejecución de run_skill, esperando su relanzamiento
#   --cycle-cost <n> <log>  el costo total del ciclo de un PR, desde un log dado
#   --merged-once           una pasada del bucle de PRs mergeados
#   --block-pr <num> <Clave> <url> <head> <ciclos>
#                           el bloqueo por tres ciclos sin OK
# Los tres primeros se apoyan en DEVKIT_CLAUDE_BIN y DEVKIT_RUN_DIR; los dos
# últimos, en un `gh` de mentira en PATH y DEVKIT_TASK_CLOSE_BIN o
# DEVKIT_TASK_BLOCK_BIN. Ver watch-test.sh.
case "${1:-}" in
  --quota-hit)
    QHIT_TMP=$(mktemp) && cat >"$QHIT_TMP"
    quota_hit "$QHIT_TMP"; QHIT_RC=$?
    rm -f "$QHIT_TMP"
    exit $QHIT_RC
    ;;
  --quota-reset)
    quota_reset_epoch
    exit 0
    ;;
  --run-skill)
    run_skill "${2:-prueba}" "${3:-/noop}" "${4:--}"
    wait
    exit 0
    ;;
  --cycle-cost)
    cycle_cost "${2:-}" "${3:-}"
    exit 0
    ;;
  --orphan-branch)
    if orphan_branch_alarm "${2:-0}" "${3:-no}" "${4:-si}"; then echo si; else echo no; fi
    exit 0
    ;;
  --agentes-vivos)
    agentes_vivos
    exit 0
    ;;
  --merged-once)
    check_merged_prs
    exit 0
    ;;
  --block-pr)
    block_pr "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    exit 0
    ;;
esac

log "vigilancia iniciada (cada ${INTERVAL}s, guardia de ${MAX_CYCLES} ciclos; PRs mergeados cada ${MERGED_INTERVAL}s)"

# Bucle de PRs mergeados, aparte del principal (DEVKIT-55): el principal
# queda esperando mientras corre una skill (pr-review, task-fix), que puede
# tardar veinte minutos, y un merge en ese rato no se cerraría hasta que
# terminara. Este no toma `skill.lock`: task-close.sh solo toca Notion y
# GitHub, y su limpieza de git espera a tener el workspace libre.
if [ -d .git ] && [ -n "${GH_TOKEN:-}" ]; then
  ( while true; do check_merged_prs; sleep "$MERGED_INTERVAL"; done ) &
  MERGED_PID=$!
  trap 'kill "$MERGED_PID" 2>/dev/null' EXIT
fi

while true; do
  CODE=$(project_code)
  if [ -d .git ] && [ -n "${GH_TOKEN:-}" ]; then
    BOT="$(gh api user --jq .login 2>/dev/null)"
    log "consultando GitHub"
    check_orphan_branch

    # --- PRs abiertos: revisar, corregir, documentar o bloquear ------------
    gh pr list --state open --limit 30 --json number,title,url \
      --jq '.[] | "\(.number)\t\(.url)\t\(.title)"' 2>/dev/null \
    | while IFS=$'\t' read -r num url title; do
        key=$(key_of "$title" "$CODE") || continue
        [ -n "$BOT" ] || { log "PR #$num: sin login de la cuenta máquina; se omite"; continue; }
        IFS=$'\t' read -r action head ref extra < <(
          gh pr view "$num" --json headRefOid,reviews,comments 2>/dev/null | decide "$BOT"
        )
        [ -n "${action:-}" ] || continue
        short=${head:0:7}
        case "$action" in
          revisar)
            # La clave incluye $ref: cuando el head no cambia pero el
            # corrector ya respondió sin empujar commits (DEVKIT-22), $ref
            # es igual al head y $head:$ref difiere de la marca que dejó el
            # primer "revisar" de ese mismo head (donde $ref era el sha
            # anterior o "-"). Sin $ref, `launched` daría por hecho que ese
            # head ya se lanzó y el segundo aviso se perdería.
            launched "revisar:$num:$head:$ref" && continue
            mark "revisar:$num:$head:$ref"
            if [ "$ref" = "$head" ]; then
              log "PR #$num ($key) head $short con respuesta sin push: lanzando pr-review otra vez"
            else
              log "PR #$num ($key) head $short sin informe: lanzando pr-review"
            fi
            run_skill "pr-review-$num-$short" "/pr-review $num" "revisar:$num:$head:$ref"
            ;;
          fix)
            launched "fix:$num:$ref" && continue
            mark "fix:$num:$ref"
            log "PR #$num ($key) CAMBIOS en $short: lanzando task-fix"
            run_skill "task-fix-$num-$short" "/task-fix $key" "fix:$num:$ref"
            ;;
          fix-humano)
            launched "fix-humano:$num:$ref" && continue
            mark "fix-humano:$num:$ref"
            text=$(printf '%s' "$extra" | base64 -d 2>/dev/null)
            log "PR #$num ($key) comentario humano de $ref: lanzando task-fix"
            # La fecha del comentario en el nombre: un PR puede recibir varios
            # comentarios humanos y cada ejecución conserva su log.
            run_skill "task-fix-$num-humano-${ref//[^0-9A-Za-z]/}" "/task-fix $key $text" "fix-humano:$num:$ref"
            ;;
          documentar)
            launched "documentar:$num:$head" && continue
            mark "documentar:$num:$head"
            log "PR #$num ($key) OK en $short: lanzando task-document"
            run_skill "task-document-$num-$short" "/task-document $key $num" "documentar:$num:$head"
            ;;
          bloquear)
            launched "bloquear:$num:$head" && continue
            mark "bloquear:$num:$head"
            block_pr "$num" "$key" "$url" "$head" "$ref"
            ;;
          bloqueado|nada) ;;
          *) log "PR #$num: decisión desconocida '$action'" ;;
        esac
      done
  fi
  sleep_or_poke "$INTERVAL"
done

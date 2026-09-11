#!/usr/bin/env bash
# Bucle del contenedor. Cada 5 min mira los PRs cuyo título empieza por una
# Clave del proyecto (CODIGO-n) y lanza la skill que toca, en modo headless:
#
#   PR abierto, head sin marcador devkit-review            -> pr-review
#   último marcador CAMBIOS para el head, sin respuesta     -> task-fix
#   último marcador OK y comentario humano posterior        -> task-fix "<texto>"
#   3 ciclos revisor -> corrector sin OK                    -> task-block
#   PR mergeado, sin marcador devkit-closed                 -> task-close
#
# El estado del ciclo vive en GitHub, en los marcadores de reviews y
# comentarios del PR (<!-- devkit-review -->, <!-- devkit-fix -->,
# <!-- devkit-block -->, <!-- devkit-closed -->): un rebuild no lo pierde.
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
set -u
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
LAUNCHED="$RUN_DIR/launched"
POKE="$RUN_DIR/poke"
LOCK="$RUN_DIR/skill.lock"
INTERVAL="${DEVKIT_WATCH_INTERVAL:-300}"
MAX_CYCLES="${DEVKIT_WATCH_MAX_CYCLES:-3}"
# El binario del agente sale a una variable para que watch-test.sh pueda
# sustituirlo por un doble y probar el relanzamiento sin gastar cuota.
CLAUDE_BIN="${DEVKIT_CLAUDE_BIN:-claude}"
QUOTA_RETRIES="${DEVKIT_WATCH_QUOTA_RETRIES:-3}"
QUOTA_WAIT="${DEVKIT_WATCH_QUOTA_WAIT:-1800}"
QUOTA_MIN_WAIT="${DEVKIT_WATCH_QUOTA_MIN_WAIT:-60}"
QUOTA_MAX_WAIT="${DEVKIT_WATCH_QUOTA_MAX_WAIT:-86400}"

# Decisión sobre un PR abierto. Entrada: el JSON de gh pr view. Salida: una
# línea con cuatro campos separados por tabulador (acción, head, referencia,
# extra), nunca vacíos ("-" si no aplica):
#   revisar    <head> <sha del marcador anterior o -> -
#   fix        <head> <sha del marcador CAMBIOS>      -
#   fix-humano <head> <fecha del último comentario>   <texto en base64>
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
DECIDE='
def markers($re; $ts):
  [ .[] | . as $x | ($x.body // "" | capture($re)) | . + {at: $x[$ts]} ];

.headRefOid as $head
| (.reviews | markers("<!-- devkit-review sha=(?<sha>[0-9a-f]+) verdict=(?<verdict>OK|CAMBIOS) -->"; "submittedAt")
   | sort_by(.at)) as $reviews
| (.comments | markers("<!-- devkit-fix sha=(?<sha>[0-9a-f]+) review=(?<review>[0-9a-f]+) -->"; "createdAt")) as $fixes
| (.comments | markers("<!-- devkit-block sha=(?<sha>[0-9a-f]+) -->"; "createdAt") | sort_by(.at)) as $blocks
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
| ($last != null and $last.verdict == "CAMBIOS" and $last.sha == $head
   and ([$fixes[] | select(.review == $last.sha)] | length) == 0) as $pending_fix
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

# run_skill <nombre del log> <prompt> [clave de launched] [intento]. Salida JSON
# de claude -p: la última línea trae costo, tokens y turnos, que es la medida de
# cada ciclo. Al terminar se registra el estado del trabajo, para que un corte
# sea visible, y si el corte fue por cuota se programa el relanzamiento.
run_skill() {
  local name=$1 prompt=$2 key=${3:--} attempt=${4:-1} logf rc summary
  logf="$RUN_DIR/$name.log"
  # Un solo `claude -p` a la vez: desde DEVKIT-27 un relanzamiento por cuota
  # puede despertar mientras el bucle atiende otro PR, y dos agentes sobre el
  # mismo workspace se pisarían la rama.
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log "$name espera: otra skill ocupa el workspace"
    flock 9
  fi
  "$CLAUDE_BIN" -p "$prompt" --output-format json \
    --permission-mode acceptEdits \
    --allowedTools "Bash" "Read" "Edit" "Write" "Grep" "Glob" "Skill" "mcp__plugin_Notion_notion" \
    >"$logf" 2>&1
  rc=$?
  flock -u 9
  exec 9>&-
  summary=$(tail -1 "$logf" | jq -r '
    "costo=\(.total_cost_usd // "?") turnos=\(.num_turns // "?") tokens: entrada=\(.usage.input_tokens // "?") cache=\(.usage.cache_read_input_tokens // "?") salida=\(.usage.output_tokens // "?") :: \((.result // "") | gsub("\n"; " ") | .[0:160])"' 2>/dev/null)
  [ -n "$summary" ] || summary="$(tail -1 "$logf" | cut -c1-160)"
  if [ $rc -eq 0 ]; then
    log "$name terminado: $summary"
  else
    log "$name falló (rc=$rc): $summary; ver $logf"
  fi
  work_state
  if [ $rc -ne 0 ] && quota_hit "$logf"; then
    quota_pause "$name" "$prompt" "$key" "$attempt" "$logf"
  fi
  return $rc
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

# Hooks de prueba del relanzamiento por cuota, sin GitHub y sin gastar cuota:
#   --quota-hit             rc 0 si el texto por stdin es un aviso de límite
#   --quota-reset           imprime el epoch de reinicio que lee de ese texto
#   --run-skill <n> <p>     una ejecución de run_skill, esperando su relanzamiento
# Los tres se apoyan en DEVKIT_CLAUDE_BIN y DEVKIT_RUN_DIR. Ver watch-test.sh.
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
esac

log "vigilancia iniciada (cada ${INTERVAL}s, guardia de ${MAX_CYCLES} ciclos)"

while true; do
  # Se relee en cada vuelta: en un proyecto nuevo, devkit.toml arranca con
  # `project = "PROJ"` y project-init lo corrige después, sin reiniciar el
  # contenedor.
  CODE=""
  [ -f "$WS/devkit.toml" ] && CODE="$(sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/devkit.toml" | head -1)"
  if [ -d .git ] && [ -n "${GH_TOKEN:-}" ]; then
    BOT="$(gh api user --jq .login 2>/dev/null)"
    log "consultando GitHub"

    # --- PRs abiertos: revisar, corregir o bloquear ------------------------
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
            launched "revisar:$num:$head" && continue
            mark "revisar:$num:$head"
            log "PR #$num ($key) head $short sin informe: lanzando pr-review"
            run_skill "pr-review-$num-$short" "/pr-review $num" "revisar:$num:$head"
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
          bloquear)
            launched "bloquear:$num:$head" && continue
            mark "bloquear:$num:$head"
            log "PR #$num ($key) $ref ciclos sin OK: lanzando task-block"
            # Primero el marcador en el PR: es lo que detiene al bucle aunque
            # task-block falle. Luego la card.
            gh pr comment "$num" --body "<!-- devkit-block sha=$head -->
Tres ciclos de revisión y corrección sin veredicto OK. La card pasa a Bloqueada y el bucle no toca este PR hasta que decidas.
Para retomar: mueve la card a Revisión automática y comenta aquí qué hacer. El bucle lanza task-fix con tu comentario y el conteo de ciclos vuelve a cero." >/dev/null 2>&1 \
              || log "PR #$num: no se pudo publicar el marcador devkit-block"
            run_skill "task-block-$num" "/task-block $key Tres ciclos de revisión y corrección sin veredicto OK en el PR $url; el bucle no lo toca hasta que decidas" "bloquear:$num:$head"
            ;;
          bloqueado|nada) ;;
          *) log "PR #$num: decisión desconocida '$action'" ;;
        esac
      done

    # --- PRs mergeados en las últimas 48 h: cerrar --------------------------
    gh pr list --state merged --limit 30 --json number,title,url,mergedAt \
      --jq '[.[] | select(.mergedAt > (now - 172800 | todate))] | sort_by(.mergedAt)
             | .[] | "\(.number)\t\(.url)\t\(.title)"' 2>/dev/null \
    | while IFS=$'\t' read -r num url title; do
        key=$(key_of "$title" "$CODE") || continue
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
        # Se registra antes de lanzar: si falla, el humano o project-status lo
        # repiten; task-close es idempotente.
        mark "cerrar:$num"
        log "PR #$num mergeado ($key): lanzando task-close"
        run_skill "task-close-$num" "/task-close $key $url" "cerrar:$num"
      done
  fi
  sleep_or_poke "$INTERVAL"
done

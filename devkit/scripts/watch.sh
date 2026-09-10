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
# Uso de prueba: `bash watch.sh --decide < pr.json` imprime la decisión para
# el JSON de `gh pr view <N> --json headRefOid,reviews,comments`, y
# `bash watch.sh --decide-merged < pr.json` la del PR mergeado, para el JSON
# de `gh pr view <N> --json comments`.
set -u
WS=/workspace
RUN_DIR=/run/devkit
LAUNCHED="$RUN_DIR/launched"
INTERVAL="${DEVKIT_WATCH_INTERVAL:-300}"
MAX_CYCLES="${DEVKIT_WATCH_MAX_CYCLES:-3}"

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
log "vigilancia iniciada (cada ${INTERVAL}s, guardia de ${MAX_CYCLES} ciclos)"

launched() { grep -qxF "$1" "$LAUNCHED"; }
mark() { echo "$1" >> "$LAUNCHED"; }

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

# run_skill <nombre del log> <prompt>. Salida JSON de claude -p: la última
# línea trae costo, tokens y turnos, que es la medida de cada ciclo. Al
# terminar se registra el estado del trabajo, para que un corte sea visible.
run_skill() {
  local name=$1 prompt=$2 logf rc summary
  logf="$RUN_DIR/$name.log"
  claude -p "$prompt" --output-format json \
    --permission-mode acceptEdits \
    --allowedTools "Bash" "Read" "Edit" "Write" "Grep" "Glob" "Skill" "mcp__plugin_Notion_notion" \
    >"$logf" 2>&1
  rc=$?
  summary=$(tail -1 "$logf" | jq -r '
    "costo=\(.total_cost_usd // "?") turnos=\(.num_turns // "?") tokens: entrada=\(.usage.input_tokens // "?") cache=\(.usage.cache_read_input_tokens // "?") salida=\(.usage.output_tokens // "?") :: \((.result // "") | gsub("\n"; " ") | .[0:160])"' 2>/dev/null)
  [ -n "$summary" ] || summary="$(tail -1 "$logf" | cut -c1-160)"
  if [ $rc -eq 0 ]; then
    log "$name terminado: $summary"
  else
    log "$name falló (rc=$rc): $summary; ver $logf"
  fi
  work_state
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

while true; do
  # Se relee en cada vuelta: en un proyecto nuevo, devkit.toml arranca con
  # `project = "PROJ"` y project-init lo corrige después, sin reiniciar el
  # contenedor.
  CODE=""
  [ -f "$WS/devkit.toml" ] && CODE="$(sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/devkit.toml" | head -1)"
  if [ -d .git ] && [ -n "${GH_TOKEN:-}" ]; then
    BOT="$(gh api user --jq .login 2>/dev/null)"

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
            run_skill "pr-review-$num-$short" "/pr-review $num"
            ;;
          fix)
            launched "fix:$num:$ref" && continue
            mark "fix:$num:$ref"
            log "PR #$num ($key) CAMBIOS en $short: lanzando task-fix"
            run_skill "task-fix-$num-$short" "/task-fix $key"
            ;;
          fix-humano)
            launched "fix-humano:$num:$ref" && continue
            mark "fix-humano:$num:$ref"
            text=$(printf '%s' "$extra" | base64 -d 2>/dev/null)
            log "PR #$num ($key) comentario humano de $ref: lanzando task-fix"
            # La fecha del comentario en el nombre: un PR puede recibir varios
            # comentarios humanos y cada ejecución conserva su log.
            run_skill "task-fix-$num-humano-${ref//[^0-9A-Za-z]/}" "/task-fix $key $text"
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
            run_skill "task-block-$num" "/task-block $key Tres ciclos de revisión y corrección sin veredicto OK en el PR $url; el bucle no lo toca hasta que decidas"
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
        # Se registra antes de lanzar: si falla, el humano o session-start lo
        # repiten; task-close es idempotente.
        mark "cerrar:$num"
        log "PR #$num mergeado ($key): lanzando task-close"
        run_skill "task-close-$num" "/task-close $key $url"
      done
  fi
  sleep "$INTERVAL"
done

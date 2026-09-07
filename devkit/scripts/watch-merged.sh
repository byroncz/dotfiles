#!/usr/bin/env bash
# Cada 5 min busca PRs mergeados cuyo título empieza por una Clave (CODIGO-n)
# y lanza `task-close` en modo headless para cada uno, una sola vez.
# Registro de cierres ya lanzados: /run/devkit/closed (tmpfs, se reinicia con
# el contenedor; task-close es idempotente, así que repetir no daña).
set -u
WS=/workspace
RUN_DIR=/run/devkit
CLOSED="$RUN_DIR/closed"
INTERVAL="${DEVKIT_WATCH_INTERVAL:-300}"

cd "$WS" 2>/dev/null || exit 0
touch "$CLOSED"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
log "vigilancia iniciada (cada ${INTERVAL}s)"

while true; do
  # Se relee en cada vuelta: en un proyecto nuevo, devkit.toml arranca con
  # `project = "PROJ"` y project-init lo corrige después, sin reiniciar el
  # contenedor.
  CODE=""
  [ -f "$WS/devkit.toml" ] && CODE="$(sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/devkit.toml" | head -1)"
  if [ -d .git ] && [ -n "${GH_TOKEN:-}" ]; then
    # PRs mergeados en las últimas 48 h, del más antiguo al más nuevo.
    gh pr list --state merged --limit 30 --json number,title,url,mergedAt \
      --jq '[.[] | select(.mergedAt > (now - 172800 | todate))] | sort_by(.mergedAt)
             | .[] | "\(.number)\t\(.url)\t\(.title)"' 2>/dev/null \
    | while IFS=$'\t' read -r num url title; do
        key=$(printf '%s' "$title" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | head -1)
        [ -n "$key" ] || continue
        # Solo cards de este proyecto y con número real (la -0 es "sin card").
        [ -z "$CODE" ] || [ "${key%%-*}" = "$CODE" ] || continue
        [ "${key##*-}" != "0" ] || continue
        grep -qx "$num" "$CLOSED" && continue
        log "PR #$num mergeado ($key): lanzando task-close"
        if claude -p "/task-close $key $url" \
             --permission-mode acceptEdits \
             --allowedTools "Bash(gh:*)" "Bash(git:*)" "mcp__plugin_Notion_notion" "Read" "Grep" "Glob" \
             >"$RUN_DIR/task-close-$num.log" 2>&1; then
          log "task-close $key terminado: $(tail -1 "$RUN_DIR/task-close-$num.log" | cut -c1-120)"
        else
          log "task-close $key falló; ver $RUN_DIR/task-close-$num.log"
        fi
        # Se registra igual: si falló, el humano o session-start lo repiten.
        echo "$num" >> "$CLOSED"
      done
  fi
  sleep "$INTERVAL"
done

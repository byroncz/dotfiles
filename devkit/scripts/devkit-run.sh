#!/usr/bin/env bash
# Único punto de lanzamiento de una skill de Claude Code, en primer o segundo
# plano (DEVKIT-45, absorbe DEVKIT-18). Antes, un lanzamiento fuera del ciclo
# de `watch.sh` era un `nohup claude -p ...` escrito a mano desde /workspace;
# ahora es un solo comando, y aplica la misma tabla de modelo/esfuerzo por rol
# que usa el bucle.
#
# Uso normal, para un humano o para task-close al tomar la siguiente hija:
#   devkit-run <skill> <Clave> [texto extra...]
#     Arma el prompt "/<skill> <Clave> [texto extra]", lo lanza con `nohup`
#     desde /workspace y vuelve enseguida. Log en
#     /run/devkit/<skill>-<n>.log (n crece si ya hay uno); al terminar,
#     agrega el resumen de costo a watch.log, igual que una skill lanzada por
#     el bucle.
#
# Uso con anulación manual, para subir o bajar el rol de un lanzamiento
# concreto sin tocar roles.toml:
#   devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high>] <skill> <Clave> [texto extra...]
#     La línea de resumen en watch.log marca "(anulación manual)".
#
# Modos que usa `watch.sh` (no para uso manual):
#   devkit-run --rol "<prompt>"                     imprime "modelo esfuerzo presupuesto"
#   devkit-run --sync "<prompt>"                    corre en primer plano, JSON por stdout
#   devkit-run --resumen <log> <modelo> <esfuerzo> <presupuesto>
#                                                    imprime la línea de costo/tokens/turnos
#   devkit-run --test                               autoprueba
#
# La tabla rol -> modelo/esfuerzo/turnos vive en devkit/agents/roles.toml.
# Los permisos (qué puede correr una skill sin pedir permiso) siguen en
# `devkit/agents/settings.json`: este script no los toca ni los reemplaza.
# `docs/ARCHITECTURE.md` 8.2 documenta que la lista `allow` de ese archivo no
# restringe nada en modo `-p`/headless (se probó con `claude -p` real:
# comandos fuera de `allow` corren igual); lo que sí bloquea es la lista
# `deny` y el hook `pr-guard.sh`, que ya registra en
# `/run/devkit/denials.log` cada comando que rechaza, para ampliar sus
# reglas cuando bloquee algo legítimo. Ver la entrada de Documentación de
# DEVKIT-45 para la evidencia completa.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
CLAUDE_BIN="${DEVKIT_CLAUDE_BIN:-claude}"
ROLES_FILE="${DEVKIT_ROLES_FILE:-}"
if [ -z "$ROLES_FILE" ]; then
  if [ -f "$WS/.devkit/roles.toml" ]; then
    # Anulación por proyecto: $WS/.devkit/roles.toml sobrescribe la tabla del
    # template (DEVKIT-53, H5 de pr-review). Se prueba primero, así gana cuando
    # existe, incluso en modo dev donde también existe ../agents/roles.toml.
    ROLES_FILE="$WS/.devkit/roles.toml"
  elif [ -f "$HERE/../agents/roles.toml" ]; then
    ROLES_FILE="$HERE/../agents/roles.toml"
  else
    # $HERE es /opt/devkit/scripts cuando corre desde el alias de la imagen
    # (o SCRIPTS_DIR fuera de dev): el Dockerfile solo copia scripts/, así
    # que ../agents no existe ahí. TEMPLATE_DIR sí tiene agents/roles.toml
    # siempre: en dev es el symlink a $WS/devkit, y en un proyecto
    # instanciado es el clon del template que hace entrypoint.sh (DEVKIT-50,
    # hallazgo H1 de pr-review).
    ROLES_FILE="${DEVKIT_ROLES_FILE_FALLBACK:-/opt/devkit/template/agents/roles.toml}"
  fi
fi
WATCH_LOG="${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}"
# Mismo candado que `run_skill` en watch.sh: un solo `claude -p` a la vez
# sobre /workspace (DEVKIT-27), para que un `devkit-run` a mano no se pise
# con el bucle. `--sync` no lo toma: lo llama `run_skill`, que ya lo tiene.
LOCK="${DEVKIT_LOCK:-$RUN_DIR/skill.lock}"
# Mismas alarmas de DEVKIT-46 que `run_skill` en watch.sh, para que un
# lanzamiento por `--worker` (manual o desde task-close/epic-plan) avise
# igual que el bucle: skill lenta, con el mismo umbral y sondeo.
SKILL_TIMEOUT="${DEVKIT_WATCH_SKILL_TIMEOUT:-1200}"
SKILL_POLL="${DEVKIT_WATCH_SKILL_POLL:-5}"

# Última coincidencia de "<rol>.<campo> = valor" en roles.toml, sin comillas.
# roles.toml usa claves punteadas (TOML válido) a propósito: este grep no
# necesita entender tablas ni tipos, solo esa forma fija.
role_field() {  # role_field <rol> <campo>
  grep -E "^${1}\.${2}[[:space:]]*=" "$ROLES_FILE" 2>/dev/null | tail -1 \
    | sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# Rol de una skill a partir del primer token del prompt ("/pr-review 31" ->
# "pr-review"). Grupos del criterio de aceptación de DEVKIT-45: contabilidad
# (task-close, task-block: solo comentan o cierran, no escriben código),
# revision (pr-review, siempre el modelo fuerte) e implementacion (el resto).
# epic-plan entra en revision desde DEVKIT-50: un mal desglose de Épica cuesta
# más que cualquier card individual, así que se queda con el modelo fuerte y
# esfuerzo alto en vez del que le tocaría por Tipo (que además no tiene,
# porque una Épica no es feature/bug/chore).
role_of() {  # role_of <prompt>
  local skill
  skill=$(printf '%s' "$1" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  case "$skill" in
    task-close|task-block) printf 'contabilidad' ;;
    pr-review|epic-plan) printf 'revision' ;;
    *) printf 'implementacion' ;;
  esac
}

# Tipo de la card (feature/bug/chore) para el rol implementación. watch.sh no
# consulta Notion desde bash (ver la nota de `work_state` ahí), así que se
# deriva del prefijo de la rama actual: feat/, fix/ o chore/, el mismo que
# usa `task-start` para nombrarla (AGENTS.md). Sin rama de card todavía (por
# ejemplo, `task-start` antes de crear la suya, que corre en `main`), no hay
# forma de saberlo sin tocar Notion: usa "feature" como término medio
# razonado, más caro que chore pero lejos del modelo de revisión, en vez de
# bloquear el lanzamiento por un dato que no existe todavía.
tipo_of() {
  local branch
  branch=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null)
  case "$branch" in
    feat/*) printf 'feature' ;;
    fix/*) printf 'bug' ;;
    chore/*) printf 'chore' ;;
    *) printf 'feature' ;;
  esac
}

# "<modelo> <esfuerzo> <presupuesto de turnos>" para un prompt.
model_effort_of() {  # model_effort_of <prompt>
  local role
  role=$(role_of "$1")
  [ "$role" = "implementacion" ] && role="implementacion.$(tipo_of)"
  printf '%s %s %s' "$(role_field "$role" model)" "$(role_field "$role" effort)" "$(role_field "$role" max_turns)"
}

# Ejecuta la skill en primer plano; deja el JSON de `claude -p` en stdout.
run_claude() {  # run_claude <prompt> <modelo> <esfuerzo>
  "$CLAUDE_BIN" -p "$1" --model "$2" --effort "$3" --output-format json \
    --permission-mode acceptEdits \
    --allowedTools "Bash" "Read" "Edit" "Write" "Grep" "Glob" "Skill" "mcp__plugin_Notion_notion"
}

# Línea de costo/tokens/turnos/modelo/esfuerzo de un log ya terminado. La
# comparten `run_skill` (watch.sh) y el modo `--worker` de este script, para
# no repetir el `jq` en dos archivos.
resumen() {  # resumen <log> <modelo> <esfuerzo> <presupuesto>
  local logf=$1 modelo=$2 esfuerzo=$3 presupuesto=$4 linea turnos excedido=""
  linea=$(tail -1 "$logf" 2>/dev/null | jq -r '
    "costo=\(.total_cost_usd // "?") turnos=\(.num_turns // "?") tokens: entrada=\(.usage.input_tokens // "?") cache=\(.usage.cache_read_input_tokens // "?") salida=\(.usage.output_tokens // "?") :: \((.result // "") | gsub("\n"; " ") | .[0:160])"' 2>/dev/null)
  [ -n "$linea" ] || linea="$(tail -1 "$logf" 2>/dev/null | cut -c1-160)"
  turnos=$(tail -1 "$logf" 2>/dev/null | jq -r '.num_turns // empty' 2>/dev/null)
  if [ -n "$presupuesto" ] && [ "$presupuesto" != "-" ] && [ -n "$turnos" ] \
     && [ "$turnos" -gt "$presupuesto" ] 2>/dev/null; then
    excedido=" (excede el presupuesto de $presupuesto turnos de roles.toml)"
  fi
  printf 'modelo=%s esfuerzo=%s %s%s' "$modelo" "$esfuerzo" "$linea" "$excedido"
}

# Alarma de skill lenta (DEVKIT-46), igual que `watch_long_running` en
# watch.sh pero escribiendo directo a watch.log: `--worker` no comparte
# proceso con el bucle, así que no puede reusar su función.
watch_long_running() {  # watch_long_running <prompt> <pid>
  local prompt=$1 pid=$2 waited=0 alarmed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$SKILL_POLL"
    waited=$((waited + SKILL_POLL))
    if [ "$alarmed" -eq 0 ] && [ "$waited" -ge "$SKILL_TIMEOUT" ]; then
      printf '%s devkit-run "%s" ALARMA: lleva %s min corriendo (límite %ss)\n' \
        "$(date -u +%FT%TZ)" "$prompt" "$((waited / 60))" "$SKILL_TIMEOUT" >> "$WATCH_LOG"
      alarmed=1
    fi
  done
}

# Barrera mecánica de DEVKIT-50 sobre la regla de cierre de DEVKIT-44: un
# `result` que termina en pregunta es una card `En progreso` cortando en seco
# en vez de resolver en un estado observable (AGENTS.md), y DEVKIT-48 mostró
# que la regla escrita en las skills no basta. En vez de dejarla colgada, el
# lanzador mismo relanza una vez `task-block` con un motivo forzado. No se
# relanza si el propio `task-block` (o `task-close`, que no toma decisiones de
# alcance) fue el que preguntó: relanzarlo entraría en bucle sin arreglar
# nada, y ahí sí queda para el humano vía las alarmas de arriba.
forzar_task_block() {  # forzar_task_block <prompt> <logf>
  local prompt=$1 logf=$2 skill clave motivo
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  case "$skill" in task-block|task-close) return 0 ;; esac
  clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  [ -n "$clave" ] || return 0
  motivo="devkit-run: $skill terminó con una pregunta abierta en vez de un estado observable (barrera mecánica de DEVKIT-50 sobre DEVKIT-44); ver $logf"
  printf '%s devkit-run "%s" relanza task-block forzado: %s\n' "$(date -u +%FT%TZ)" "$prompt" "$clave" >> "$WATCH_LOG"
  "$HERE/devkit-run.sh" task-block "$clave" "$motivo" >/dev/null 2>&1
}

run_tests() {
  local fail=0 tmp
  check() {
    local name=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
      printf 'ok   %-58s %s\n' "$name" "$got"
    else
      printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
      fail=1
    fi
  }

  check "rol de pr-review" revision "$(role_of '/pr-review 31')"
  check "rol de epic-plan" revision "$(role_of '/epic-plan DEVKIT-1')"
  check "rol de task-close" contabilidad "$(role_of '/task-close DEVKIT-44 url')"
  check "rol de task-block" contabilidad "$(role_of '/task-block DEVKIT-44 razón')"
  check "rol de task-start" implementacion "$(role_of '/task-start')"
  check "rol de task-fix" implementacion "$(role_of '/task-fix DEVKIT-44')"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  ROLES_FILE="$tmp/roles.toml" cat >"$tmp/roles.toml" <<'FIN'
contabilidad.model = "modelo-barato"
contabilidad.effort = "low"
contabilidad.max_turns = 15
implementacion.feature.model = "modelo-fuerte"
implementacion.feature.effort = "medium"
implementacion.feature.max_turns = 40
implementacion.chore.model = "modelo-barato"
implementacion.chore.effort = "medium"
implementacion.chore.max_turns = 25
revision.model = "modelo-revision"
revision.effort = "high"
revision.max_turns = 50
FIN
  check "campo de contabilidad" "modelo-barato" \
    "$(ROLES_FILE="$tmp/roles.toml" role_field contabilidad model)"
  check "campo de revisión" "modelo-revision" "$(ROLES_FILE="$tmp/roles.toml" role_field revision model)"

  # Sin DEVKIT_ROLES_FILE y sin hermano ../agents (la forma en que corre
  # desde /opt/devkit/scripts en la imagen), el valor por defecto debe caer
  # al respaldo en vez de a un archivo que no existe (DEVKIT-50, H1).
  mkdir -p "$tmp/nested/scripts"
  cp "$HERE/devkit-run.sh" "$tmp/nested/scripts/devkit-run.sh"
  check "ROLES_FILE por defecto cae al respaldo sin ../agents" "modelo-revision high 50" \
    "$(DEVKIT_ROLES_FILE_FALLBACK="$tmp/roles.toml" WS="$tmp" bash "$tmp/nested/scripts/devkit-run.sh" --rol '/pr-review 9')"

  git -C "$tmp" init -q
  git -C "$tmp" commit -q --allow-empty -m init --no-gpg-sign
  git -C "$tmp" checkout -q -b feat/DEVKIT-1-algo
  check "tipo desde rama feat/" feature "$(WS="$tmp" tipo_of)"
  git -C "$tmp" checkout -q -b chore/DEVKIT-2-algo
  check "tipo desde rama chore/" chore "$(WS="$tmp" tipo_of)"

  check "modelo/esfuerzo de pr-review" "modelo-revision high 50" \
    "$(ROLES_FILE="$tmp/roles.toml" WS="$tmp" model_effort_of '/pr-review 9')"
  check "modelo/esfuerzo de task-close" "modelo-barato low 15" \
    "$(ROLES_FILE="$tmp/roles.toml" WS="$tmp" model_effort_of '/task-close DEVKIT-2 url')"
  check "modelo/esfuerzo de implementación en rama chore/" "modelo-barato medium 25" \
    "$(ROLES_FILE="$tmp/roles.toml" WS="$tmp" model_effort_of '/task-fix DEVKIT-2')"

  # --worker de punta a punta, con un doble de `claude` que no gasta cuota.
  local doble
  doble="$tmp/claude"
  cat >"$doble" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$doble"
  mkdir -p "$tmp/run"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    bash "$HERE/devkit-run.sh" --worker '/task-close DEVKIT-2 url' "$tmp/run/task-close-1.log" \
      modelo-barato low 15 >/dev/null 2>&1
  check "worker deja el log de claude" 'listo' \
    "$(jq -r .result "$tmp/run/task-close-1.log" 2>/dev/null)"
  check "worker agrega el resumen a watch.log" 'modelo=modelo-barato esfuerzo=low' \
    "$(grep -oE 'modelo=modelo-barato esfuerzo=low' "$tmp/run/watch.log" 2>/dev/null | head -1)"

  # Lanzamiento en segundo plano: vuelve enseguida y numera el log si ya
  # existe uno para la misma skill.
  : >"$tmp/run/pr-review-1.log"
  local antes despues rc espera=0
  antes=$(date +%s%N)
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    bash "$HERE/devkit-run.sh" pr-review DEVKIT-2 >/dev/null 2>&1
  rc=$?
  despues=$(date +%s%N)
  check "el lanzamiento en segundo plano no espera al claude de mentira" 0 "$rc"
  if [ $(( (despues - antes) / 1000000 )) -lt 2000 ]; then
    printf 'ok   %-58s %s\n' "vuelve enseguida (< 2s)" "sí"
  else
    printf 'FAIL %-58s tardó %sms\n' "vuelve enseguida (< 2s)" "$(( (despues - antes) / 1000000 ))"
    fail=1
  fi
  # El worker corre en segundo plano (nohup): se espera a que aparezca el
  # log, con tope, en vez de comprobar justo después de volver.
  while [ ! -e "$tmp/run/pr-review-2.log" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "numera el log siguiente en vez de pisar el existente" 1 \
    "$([ -e "$tmp/run/pr-review-2.log" ] && echo 1 || echo 0)"

  # El candado: con skill.lock tomado, --worker espera y avisa en vez de
  # correr en paralelo con lo que sea que lo tiene (DEVKIT-27: dos agentes
  # sobre el mismo workspace se pisarían la rama).
  (
    exec 9>"$tmp/run/skill.lock"
    flock 9
    sleep 0.6
  ) &
  local tenedor=$!
  sleep 0.1  # deja que el subshell de arriba tome el candado primero
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    bash "$HERE/devkit-run.sh" --worker '/task-close DEVKIT-2 url' "$tmp/run/candado.log" \
      modelo-barato low 15 >/dev/null 2>&1
  wait "$tenedor" 2>/dev/null
  check "espera el candado en vez de correr en paralelo" \
    "espera: otra skill ocupa el workspace" \
    "$(grep -oE 'espera: otra skill ocupa el workspace' "$tmp/run/watch.log" | head -1)"

  # El resumen avisa cuando se pasa del presupuesto de turnos.
  printf '{"result":"listo","total_cost_usd":0.5,"num_turns":99}\n' >"$tmp/exceso.log"
  check "avisa cuando se excede el presupuesto de turnos" 'excede el presupuesto de 15 turnos' \
    "$(resumen "$tmp/exceso.log" modelo-x low 15 | grep -oE 'excede el presupuesto de 15 turnos')"

  # Cadena task-close -> task-start (DEVKIT-50): el doble de claude, al ver
  # un prompt de task-close, lanza a su vez devkit-run task-start con el
  # mismo entorno de prueba, imitando lo que hace la skill al tomar la
  # siguiente hija. Debe quedar en watch.log un resumen por cada rol
  # (contabilidad para task-close, implementación para task-start).
  git -C "$tmp" checkout -q -b feat/DEVKIT-3-algo
  local cadena
  cadena="$tmp/claude-cadena"
  cat >"$cadena" <<FIN
#!/usr/bin/env bash
case "\$2" in
  */task-close*)
    DEVKIT_CLAUDE_BIN="$cadena" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \\
      DEVKIT_ROLES_FILE="$tmp/roles.toml" \\
      bash "$HERE/devkit-run.sh" task-start DEVKIT-3 >/dev/null 2>&1
    ;;
esac
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$cadena"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$cadena" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    bash "$HERE/devkit-run.sh" task-close DEVKIT-3 url >/dev/null 2>&1
  espera=0
  while [ "$(grep -cE 'devkit-run "/task-(close|start)' "$tmp/run/watch.log" 2>/dev/null)" -lt 2 ] \
        && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "cadena task-close -> task-start: dos resúmenes con roles distintos" 2 \
    "$(grep -oE 'modelo=(modelo-barato|modelo-fuerte)' "$tmp/run/watch.log" | sort -u | wc -l | tr -d ' ')"

  # Anulación manual: --modelo/--esfuerzo pisan el rol resuelto y la línea de
  # resumen lo marca, sin comparar contra el presupuesto de roles.toml.
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    bash "$HERE/devkit-run.sh" --modelo modelo-a-mano --esfuerzo high task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/run/task-fix-1.log" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "anulación manual usa el modelo y esfuerzo pedidos" 'modelo=modelo-a-mano esfuerzo=high' \
    "$(grep -oE 'modelo=modelo-a-mano esfuerzo=high' "$tmp/run/watch.log" | head -1)"
  check "anulación manual queda marcada en el resumen" 'anulación manual' \
    "$(grep -oE 'anulación manual' "$tmp/run/watch.log" | head -1)"

  # Barrera mecánica DEVKIT-50/DEVKIT-44: un result que termina en pregunta
  # relanza task-block una sola vez, salvo si quien preguntó ya era
  # task-block o task-close (evita el bucle).
  local pregunton
  pregunton="$tmp/claude-pregunton"
  cat >"$pregunton" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"¿qué credencial uso?","total_cost_usd":0.01,"num_turns":2}\n'
FIN
  chmod +x "$pregunton"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$pregunton" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ "$(grep -c 'relanza task-block forzado' "$tmp/run/watch.log" 2>/dev/null)" -lt 1 ] \
        && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "pregunta abierta alarma y relanza task-block forzado" 'relanza task-block forzado: DEVKIT-3' \
    "$(grep -oE 'relanza task-block forzado: DEVKIT-3' "$tmp/run/watch.log" | head -1)"

  # --modelo/--esfuerzo sin valor deben salir con el mensaje de uso, no
  # colgar el proceso (DEVKIT-50, H3).
  local rc
  timeout 5 bash "$HERE/devkit-run.sh" --modelo >/dev/null 2>&1; rc=$?
  check "--modelo sin valor no cuelga" 64 "$rc"
  timeout 5 bash "$HERE/devkit-run.sh" --esfuerzo >/dev/null 2>&1; rc=$?
  check "--esfuerzo sin valor no cuelga" 64 "$rc"

  # .devkit/roles.toml anula la tabla del template (DEVKIT-53, H3): se prioriza
  # sobre la de ../agents y la del template fallback.
  mkdir -p "$tmp/.devkit"
  cat >"$tmp/.devkit/roles.toml" <<'FIN'
contabilidad.model = "anulacion-proyecto"
contabilidad.effort = "high"
contabilidad.max_turns = 99
revision.model = "anulacion-proyecto"
revision.effort = "high"
revision.max_turns = 99
implementacion.chore.model = "anulacion-proyecto"
implementacion.chore.effort = "high"
implementacion.chore.max_turns = 99
FIN
  check "ROLES_FILE desde .devkit/roles.toml (pr-review)" "anulacion-proyecto high 99" \
    "$(DEVKIT_WS="$tmp" bash "$HERE/devkit-run.sh" --rol '/pr-review 9')"
  check "ROLES_FILE desde .devkit/roles.toml (task-close en chore)" "anulacion-proyecto high 99" \
    "$(DEVKIT_WS="$tmp" bash "$HERE/devkit-run.sh" --rol '/task-close DEVKIT-2')"

  return $fail
}

case "${1:-}" in
  --rol)
    model_effort_of "${2:-}"
    exit 0
    ;;
  --sync)
    read -r modelo esfuerzo _ < <(model_effort_of "${2:-}")
    run_claude "${2:-}" "$modelo" "$esfuerzo"
    exit $?
    ;;
  --resumen)
    resumen "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    exit 0
    ;;
  --worker)
    # --worker <prompt> <log> <modelo> <esfuerzo> <presupuesto> [manual]: ya
    # corre dentro de un proceso desacoplado (nohup); toma el mismo candado
    # que `run_skill` antes de tocar /workspace, ejecuta y al terminar deja
    # el resumen en watch.log, igual que el bucle. `manual` (cualquier valor
    # no vacío) marca que `--modelo`/`--esfuerzo` anularon el rol resuelto.
    # Las alarmas de skill lenta, error y pregunta abierta son las mismas de
    # `run_skill` en watch.sh (DEVKIT-46/DEVKIT-50): un lanzamiento manual o
    # desde task-close/epic-plan no corre por el bucle, así que las repite
    # aquí en vez de perderlas.
    cd "$WS" 2>/dev/null || exit 1
    mkdir -p "$RUN_DIR"
    prompt=${2:-} logf=${3:-} modelo=${4:-} esfuerzo=${5:-} presupuesto=${6:-} manual=${7:-}
    exec 9>"$LOCK"
    if ! flock -n 9; then
      printf '%s devkit-run "%s" espera: otra skill ocupa el workspace\n' "$(date -u +%FT%TZ)" "$prompt" >> "$WATCH_LOG"
      flock 9
    fi
    run_claude "$prompt" "$modelo" "$esfuerzo" >"$logf" 2>&1 &
    skill_pid=$!
    watch_long_running "$prompt" "$skill_pid" &
    watcher_pid=$!
    wait "$skill_pid"
    rc=$?
    kill "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
    flock -u 9
    exec 9>&-
    estado=terminado
    [ $rc -eq 0 ] || estado="falló (rc=$rc)"
    resumen_txt="$(resumen "$logf" "$modelo" "$esfuerzo" "$presupuesto")"
    [ -z "$manual" ] || resumen_txt="$resumen_txt (anulación manual)"
    printf '%s devkit-run "%s" %s: %s\n' "$(date -u +%FT%TZ)" "$prompt" "$estado" "$resumen_txt" >> "$WATCH_LOG"
    if [ $rc -eq 0 ]; then
      resultado=$(tail -1 "$logf" 2>/dev/null | jq -r '.result // ""' 2>/dev/null)
      if printf '%s' "$resultado" | grep -qE '\?[[:space:]]*$'; then
        printf '%s devkit-run "%s" ALARMA: terminó con una pregunta abierta en vez de un estado observable\n' \
          "$(date -u +%FT%TZ)" "$prompt" >> "$WATCH_LOG"
        forzar_task_block "$prompt" "$logf"
      fi
    else
      printf '%s devkit-run "%s" ALARMA: terminó con error (rc=%s): %s; ver %s\n' \
        "$(date -u +%FT%TZ)" "$prompt" "$rc" "$resumen_txt" "$logf" >> "$WATCH_LOG"
    fi
    exit $rc
    ;;
  --test)
    run_tests
    exit $?
    ;;
esac

# Anulación manual del rol para este lanzamiento (no toca roles.toml): un
# humano sube o baja modelo/esfuerzo puntualmente, por ejemplo para forzar el
# modelo fuerte en una card que se ve difícil. Van antes de <skill> <Clave>
# porque son opcionales y `shift 2` de más abajo asume esa posición fija.

# Sin esto, --modelo o --esfuerzo como último argumento cuelgan el proceso:
# `shift 2` falla por falta de argumentos, el error se traga y el bucle no
# avanza (DEVKIT-50, hallazgo H3 de pr-review).
falta_valor() {  # falta_valor <valor>
  case "${1-}" in
    ''|-*) return 0 ;;
    *) return 1 ;;
  esac
}

modelo_manual="" esfuerzo_manual=""
while true; do
  case "${1:-}" in
    --modelo)
      if falta_valor "${2:-}"; then
        echo "uso: devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high>] <skill> <Clave> [texto extra...]" >&2
        echo "     devkit-run --test   corre la autoprueba" >&2
        exit 64
      fi
      modelo_manual="$2"; shift 2 ;;
    --esfuerzo)
      if falta_valor "${2:-}"; then
        echo "uso: devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high>] <skill> <Clave> [texto extra...]" >&2
        echo "     devkit-run --test   corre la autoprueba" >&2
        exit 64
      fi
      esfuerzo_manual="$2"; shift 2 ;;
    *) break ;;
  esac
done

skill="${1:-}"
clave="${2:-}"
if [ -z "$skill" ] || [ -z "$clave" ]; then
  echo "uso: devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high>] <skill> <Clave> [texto extra...]" >&2
  echo "     devkit-run --test   corre la autoprueba" >&2
  exit 64
fi
shift 2 2>/dev/null
prompt="/$skill $clave"
[ $# -eq 0 ] || prompt="$prompt $*"

mkdir -p "$RUN_DIR"
n=1
while [ -e "$RUN_DIR/$skill-$n.log" ]; do n=$((n + 1)); done
logf="$RUN_DIR/$skill-$n.log"
read -r modelo esfuerzo presupuesto < <(model_effort_of "$prompt")
manual=""
if [ -n "$modelo_manual" ]; then modelo="$modelo_manual"; manual=1; fi
if [ -n "$esfuerzo_manual" ]; then esfuerzo="$esfuerzo_manual"; manual=1; fi
# Con anulación manual no hay presupuesto de roles.toml que comparar con el
# turno real: el rol resuelto ya no aplica.
[ -z "$manual" ] || presupuesto="-"

nohup "$HERE/devkit-run.sh" --worker "$prompt" "$logf" "$modelo" "$esfuerzo" "$presupuesto" "$manual" \
  >/dev/null 2>&1 &
disown
echo "lanzado: $prompt"
echo "modelo=$modelo esfuerzo=$esfuerzo log=$logf pid=$!"

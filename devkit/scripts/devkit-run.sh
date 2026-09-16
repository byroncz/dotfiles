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
#   devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high|xhigh|max>] <skill> <Clave> [texto extra...]
#     La línea de resumen en watch.log marca "(anulación manual)".
#
# Modos que usa `watch.sh` (no para uso manual):
#   devkit-run --rol "<prompt>"                     imprime "modelo esfuerzo presupuesto"
#   devkit-run --sync "<prompt>"                    corre en primer plano, JSON por stdout
#   devkit-run --resumen <log> <modelo> <esfuerzo> <presupuesto>
#                                                    imprime la línea de costo/tokens/turnos
#   devkit-run --otros-agentes                      lista los `claude -p` ajenos
#                                                    sobre este workspace; sale 0
#                                                    si está libre, 1 si no
#   devkit-run --test                               autoprueba
#
# La tabla rol -> modelo/esfuerzo/turnos vive en devkit/agents/roles.toml.
# Desde DEVKIT-54, el modelo no se elige por Tipo de la card sino por el papel
# de la skill en el flujo: `roles.toml` declara una lista `frontera` ordenada
# de alias de modelo y cada rol un `model_index` (posición 1-based desde la
# que empieza a buscar). El Tipo sigue eligiendo prefijo de rama y sección
# del CHANGELOG, pero ya no modelo.
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
# Cache de disponibilidad de modelo, una vez por arranque: /run/devkit es
# tmpfs y nace vacío en cada `devkit recreate`, igual que /run/devkit/launched
# (DEVKIT-24), así que el resultado no sobrevive a un rebuild y se vuelve a
# comprobar entonces.
FRONTERA_CACHE_DIR="${DEVKIT_FRONTERA_CACHE_DIR:-$RUN_DIR/frontera}"
MODEL_CHECK_TIMEOUT="${DEVKIT_MODEL_CHECK_TIMEOUT:-30}"
# Segundos que vale un `no` en la caché antes de volver a sondear. Un `si` vale
# todo el arranque; un `no` no, porque la sonda no distingue un modelo que no
# existe de una cuota agotada o un corte de red, y la cuota vuelve (DEVKIT-27).
# Cachear el `no` para siempre dejaba `fable` y `opus` fuera hasta el próximo
# `devkit recreate` (DEVKIT-54, H1 de pr-review).
MODEL_RETRY="${DEVKIT_MODEL_RETRY:-600}"
# Mismo candado que `run_skill` en watch.sh: un solo `claude -p` a la vez
# sobre /workspace (DEVKIT-27), para que un `devkit-run` a mano no se pise
# con el bucle. `--sync` no lo toma: lo llama `run_skill`, que ya lo tiene.
LOCK="${DEVKIT_LOCK:-$RUN_DIR/skill.lock}"
# Mismas alarmas de DEVKIT-46 que `run_skill` en watch.sh, para que un
# lanzamiento por `--worker` (manual o desde task-close/epic-plan) avise
# igual que el bucle: skill lenta, con el mismo umbral y sondeo.
SKILL_TIMEOUT="${DEVKIT_WATCH_SKILL_TIMEOUT:-1200}"
SKILL_POLL="${DEVKIT_WATCH_SKILL_POLL:-5}"
# Scripts bash que reemplazan a las skills task-close y task-block (DEVKIT-55).
# Se pueden sustituir por un doble en la autoprueba, para no tocar Notion.
TASK_BLOCK_BIN="${DEVKIT_TASK_BLOCK_BIN:-$HERE/task-block.sh}"
TASK_CLOSE_BIN="${DEVKIT_TASK_CLOSE_BIN:-$HERE/task-close.sh}"

# Última coincidencia de "<clave>.<campo> = valor" en roles.toml, sin
# comillas. La clave puede ser un rol (`revision`, `implementacion`) o el
# nombre de una skill puntual (`epic-plan`), para
# anular un campo del rol sin crear un rol nuevo. roles.toml usa claves
# punteadas (TOML válido) a propósito: este grep no necesita entender tablas
# ni tipos, solo esa forma fija.
role_field() {  # role_field <clave> <campo>
  grep -E "^${1}\.${2}[[:space:]]*=" "$ROLES_FILE" 2>/dev/null | tail -1 \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# Lista `frontera = ["a", "b", "c"]` de roles.toml, un alias de modelo por
# línea de salida, en el orden declarado. Es un array, no un escalar, así que
# no usa role_field.
frontera_list() {
  grep -E '^frontera[[:space:]]*=' "$ROLES_FILE" 2>/dev/null | tail -1 \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/^frontera[[:space:]]*=[[:space:]]*\[(.*)\][[:space:]]*$/\1/' \
    | tr ',' '\n' | sed -E 's/^[[:space:]"]+//; s/[[:space:]"]+$//'
}

# Rol de una skill a partir del primer token del prompt ("/pr-review 31" ->
# "pr-review"). Grupos del criterio de aceptación de DEVKIT-45/DEVKIT-54:
# revisión (pr-review, epic-plan: un mal desglose o una revisión floja cuestan
# más que cualquier card) e implementación (el resto: task-start, task-fix,
# task-submit, task-document). El rol `contabilidad` (task-close, task-block)
# se retiró en DEVKIT-55: esos dos pasos ya no son skills sino scripts bash
# (`task-close.sh`, `task-block.sh`) que no gastan modelo.
role_of() {  # role_of <prompt>
  local skill
  skill=$(printf '%s' "$1" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  case "$skill" in
    pr-review|epic-plan) printf 'revision' ;;
    *) printf 'implementacion' ;;
  esac
}

# Si el modelo <alias> responde, con el resultado cacheado en
# FRONTERA_CACHE_DIR para no repetir la llamada en cada lanzamiento (DEVKIT-54:
# "una llamada mínima por modelo", "una vez por arranque"). Devuelve
# verdadero/falso por código de salida.
#
# "Mínima" hay que forzarlo: una sonda lanzada tal cual desde /workspace hereda
# todo el contexto del proyecto (AGENTS.md, las skills, los servidores MCP) y
# deja de ser una sonda. Medido en DEVKIT-54 con `fable`: 41 s y USD 0.95 para
# responder "ok", con 243k tokens de caché leídos. Como el timeout por defecto
# son 30 s, el primer modelo de la lista se marcaba caído en cada arranque y
# todo el flujo caía al segundo sin que nada lo avisara. Aislada —desde un
# directorio vacío, sin MCP y sin herramientas— la misma sonda tarda 2 s y
# cuesta centavos, que es lo que se quería.
modelo_disponible() {  # modelo_disponible <alias>
  local modelo_id=$1 cache
  cache="$FRONTERA_CACHE_DIR/$modelo_id"
  mkdir -p "$FRONTERA_CACHE_DIR" 2>/dev/null
  if [ -f "$cache" ]; then
    [ "$(cat "$cache" 2>/dev/null)" = "si" ] && return 0
    local edad
    edad=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    [ "$edad" -ge "$MODEL_RETRY" ] || return 1
  fi
  local resultado=no vacio rc err
  vacio=$(mktemp -d)
  # El stderr de la sonda queda junto a la caché para diagnosticar un fallo
  # sin repetir la llamada. Si el directorio no se puede escribir, se descarta:
  # la sonda no debe fallar por no poder guardar su diagnóstico.
  err="$FRONTERA_CACHE_DIR/$modelo_id.err"
  [ -w "$FRONTERA_CACHE_DIR" ] || err=/dev/null
  # `</dev/null` no es decorativo: `claude -p` lee stdin, y esta función se
  # llama desde el bucle de `resolver_modelo`. Sin esto, la primera sonda se
  # comía el resto de la lista de modelos y la resolución terminaba en el
  # último recurso en vez de en el siguiente modelo (DEVKIT-54).
  (cd "$vacio" && timeout "$MODEL_CHECK_TIMEOUT" "$CLAUDE_BIN" -p "ok" \
      --model "$modelo_id" --output-format json \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --disallowedTools "Bash" "Read" "Edit" "Write" "Grep" "Glob" "Skill" \
      </dev/null >/dev/null 2>"$err")
  rc=$?
  [ "$rc" -eq 0 ] && resultado=si
  rm -rf "$vacio"
  printf '%s' "$resultado" > "$cache" 2>/dev/null
  # Solo se registra la sonda que de verdad corrió, no las lecturas de caché:
  # así queda una línea por modelo y por arranque, y la caída al siguiente es
  # visible en watch.log sin tener que reproducirla (DEVKIT-54).
  if [ "$resultado" = "si" ]; then
    printf '%s devkit-run sonda de modelo: %s responde\n' \
      "$(date -u +%FT%TZ)" "$modelo_id" >> "$WATCH_LOG" 2>/dev/null
  elif [ "$rc" -eq 124 ]; then
    # 124 es el código de `timeout`: el modelo no contestó a tiempo.
    printf '%s devkit-run sonda de modelo: %s no responde en %ss; cae al siguiente de la lista\n' \
      "$(date -u +%FT%TZ)" "$modelo_id" "$MODEL_CHECK_TIMEOUT" >> "$WATCH_LOG" 2>/dev/null
  else
    # Cualquier otro código es un error de la CLI (alias desconocido, cuota,
    # red), casi siempre inmediato: decir "no responde en 30s" lo confundía
    # con un timeout (DEVKIT-54, H2 de pr-review).
    local detalle
    detalle=$(grep -m1 -v '^[[:space:]]*$' "$err" 2>/dev/null | cut -c1-160)
    printf '%s devkit-run sonda de modelo: %s falló (rc=%s): %s; cae al siguiente de la lista\n' \
      "$(date -u +%FT%TZ)" "$modelo_id" "$rc" "${detalle:-sin detalle en stderr}" >> "$WATCH_LOG" 2>/dev/null
  fi
  [ "$resultado" = "si" ]
}

# Primer modelo disponible de `frontera`, buscando desde la posición
# <indice_inicial> (1-based) hacia el final de la lista. Si ninguno responde,
# devuelve el último de la lista completa como último recurso: lanzar con el
# modelo más débil vale más que no lanzar nada.
#
# La lista se carga entera en un array antes de sondear nada. Recorrerla con
# `while read` desde un heredoc parecía equivalente y no lo es: la sonda es un
# proceso que también lee stdin, así que se llevaba por delante los modelos que
# faltaban por probar.
resolver_modelo() {  # resolver_modelo <indice_inicial>
  local idx=${1:-1} modelo i=0
  local -a modelos=()
  while IFS= read -r modelo; do
    [ -n "$modelo" ] && modelos+=("$modelo")
  done < <(frontera_list)
  [ "${#modelos[@]}" -gt 0 ] || return 1
  [ -n "$idx" ] || idx=1
  for modelo in "${modelos[@]}"; do
    i=$((i + 1))
    [ "$i" -ge "$idx" ] || continue
    if modelo_disponible "$modelo"; then
      printf '%s' "$modelo"
      return 0
    fi
  done
  printf '%s' "${modelos[$(( ${#modelos[@]} - 1 ))]}"
}

# "<modelo> <esfuerzo> <presupuesto de turnos>" para un prompt. El esfuerzo
# admite una anulación por skill (por ejemplo `epic-plan.effort`) por encima
# del que trae su rol; el modelo sale siempre de `resolver_modelo` con el
# `model_index` del rol.
model_effort_of() {  # model_effort_of <prompt>
  local role skill idx modelo esfuerzo turnos
  skill=$(printf '%s' "$1" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  role=$(role_of "$1")
  idx=$(role_field "$role" model_index)
  modelo=$(resolver_modelo "$idx")
  esfuerzo=$(role_field "$skill" effort)
  [ -n "$esfuerzo" ] || esfuerzo=$(role_field "$role" effort)
  turnos=$(role_field "$role" max_turns)
  # Campos vacíos como "-": `read` parte por espacios y se salta los campos
  # vacíos, así que un modelo vacío se leía como si fuera el esfuerzo
  # (DEVKIT-55).
  printf '%s %s %s' "${modelo:--}" "${esfuerzo:--}" "${turnos:--}"
}

# Ejecuta la skill en primer plano; deja el JSON de `claude -p` en stdout.
#
# DEVKIT_SCRIPTS_DIR y DEVKIT_RUN_DIR se exportan al `claude -p` (DEVKIT-55).
# Las skills invocan scripts por ruta,
# `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/..."`, y la variable solo
# vivía en /run/devkit/env, que carga la shell del humano: ni watch.sh ni el
# agente la tenían. El respaldo /opt/devkit/scripts es la copia de la imagen,
# que en modo dev queda atrás del workspace; la del 2026-09-16 no entendía
# `frontera`, resolvió un modelo vacío y el `task-start DEVKIT-55` que lanzó
# `task-close` murió en el primer turno. El valor es $HERE y no lo que traiga
# el entorno: el script que resolvió este lanzamiento es el que deben usar
# los lanzamientos que salgan de él.
run_claude() {  # run_claude <prompt> <modelo> <esfuerzo>
  DEVKIT_SCRIPTS_DIR="$HERE" DEVKIT_RUN_DIR="$RUN_DIR" \
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
# lanzador mismo bloquea la card con un motivo forzado. Desde DEVKIT-55 el
# bloqueo es `task-block.sh`, bash contra la API de Notion: no gasta modelo
# y no puede, a su vez, terminar en pregunta, así que ya no hace falta
# excluir a nadie para evitar un bucle.
forzar_task_block() {  # forzar_task_block <prompt> <logf>
  local prompt=$1 logf=$2 skill clave motivo
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  [ -n "$clave" ] || return 0
  motivo="devkit-run: $skill terminó con una pregunta abierta en vez de un estado observable (barrera mecánica de DEVKIT-50 sobre DEVKIT-44); ver $logf"
  printf '%s devkit-run "%s" bloquea la card con task-block.sh: %s\n' "$(date -u +%FT%TZ)" "$prompt" "$clave" >> "$WATCH_LOG"
  "$TASK_BLOCK_BIN" "$clave" "$motivo" >>"$WATCH_LOG" 2>&1
}

# Modelo vacío: la CLI rechaza `--model ""` con un 400 en el primer turno y el
# lanzamiento muere sin hacer nada (DEVKIT-55, `task-start-4.log`). Mejor no
# lanzar y decirlo: motivo por stderr, ALARMA en watch.log y código falso.
modelo_valido() {  # modelo_valido <modelo> <prompt>
  case "$1" in ''|-) ;; *) return 0 ;; esac
  printf 'devkit-run: no se pudo resolver un modelo para "%s" (roles.toml: %s); no se lanza. Revisa `frontera` y el rol.\n' \
    "$2" "$ROLES_FILE" >&2
  printf '%s devkit-run "%s" ALARMA: modelo vacío al resolver el rol (roles.toml: %s); no se lanza\n' \
    "$(date -u +%FT%TZ)" "$2" "$ROLES_FILE" >> "$WATCH_LOG" 2>/dev/null
  return 1
}

# Procesos `claude -p` ajenos que ya están trabajando sobre este workspace.
#
# Existe por la Ampliación 2 de DEVKIT-54. Una skill que comprueba si hay otro
# agente corriendo con un `pgrep -f "<Clave>"` a secas se encuentra a sí misma
# cuatro veces: la Clave viaja en el argumento del lanzador, así que coinciden
# el `devkit-run.sh --worker`, el subshell que corre la skill, su vigilante y
# el propio `claude -p`. task-start leyó esos cuatro como "hay un segundo
# proceso sobre /workspace" y bloqueó la card sin motivo.
#
# La regla: descartar la ascendencia propia (que cubre el `claude -p` de uno
# mismo y su lanzador), descartar cualquier `devkit-run.sh` (lanzador y
# vigilante, que no son agentes) y quedarse solo con procesos `claude -p`.

# Cadena de PIDs desde el proceso actual hasta la raíz. La skill llama a este
# script desde su herramienta Bash, así que su propio `claude -p` es un
# ancestro, no el PID actual: filtrar solo por `$$` no alcanza.
ancestros_propios() {
  local pid=$$ padre
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    printf '%s ' "$pid"
    padre=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$padre" != "$pid" ] || break
    pid=$padre
  done
}

# Filtrado puro, separado de la consulta a `ps` para poder probarlo con una
# tabla fija en la autoprueba. Lee "<pid> <args>" por línea en stdin.
filtrar_agentes() {  # filtrar_agentes <lista de pids propios>
  local propios=" $1 " pid args
  while read -r pid args; do
    [ -n "$pid" ] || continue
    case "$propios" in *" $pid "*) continue ;; esac
    case "$args" in *devkit-run.sh*) continue ;; esac
    case "$args" in
      *claude*" -p "*|*claude*" -p") printf '%s %s\n' "$pid" "$args" ;;
    esac
  done
}

# Imprime un proceso ajeno por línea. Sale 0 si el workspace está libre y 1 si
# lo ocupa otro agente, para usarlo directo en un `if`.
otros_agentes() {
  local encontrados
  encontrados=$(ps -eo pid=,args= 2>/dev/null | filtrar_agentes "$(ancestros_propios)")
  [ -z "$encontrados" ] && return 0
  printf '%s\n' "$encontrados"
  return 1
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
  # DEVKIT-55: task-close y task-block son bash; el rol que los agrupaba ya no
  # existe en la tabla del template. Fuera de dev no hay ../agents: se busca
  # la tabla como ROLES_FILE, y un archivo ausente cuenta 0.
  local tabla_template="$HERE/../agents/roles.toml"
  [ -f "$tabla_template" ] || tabla_template="${DEVKIT_ROLES_FILE_FALLBACK:-/opt/devkit/template/agents/roles.toml}"
  check "roles.toml del template sin rol contabilidad" 0 \
    "$(cat "$tabla_template" 2>/dev/null | grep -c '^contabilidad\.')"
  check "rol de task-start" implementacion "$(role_of '/task-start')"
  check "rol de task-fix" implementacion "$(role_of '/task-fix DEVKIT-44')"
  check "rol de task-submit" implementacion "$(role_of '/task-submit DEVKIT-44')"
  check "rol de task-document" implementacion "$(role_of '/task-document DEVKIT-44')"

  # Comprobación de concurrencia (DEVKIT-54, Ampliación 2). La tabla imita lo
  # que devolvió `ps` el 2026-09-16: tres procesos propios del lanzador más el
  # `claude -p` propio, que es de donde salió el falso positivo. Solo el
  # `claude -p` ajeno debe aparecer.
  local tabla propios
  propios="37786 37792 37794"
  tabla='37786 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-54 /run/devkit/task-start-3.log opus high 40
37792 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-54 /run/devkit/task-start-3.log opus high 40
37793 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-54 /run/devkit/task-start-3.log opus high 40
37794 claude -p /task-start DEVKIT-54 --model opus --effort high --output-format json
40001 claude -p /pr-review 38 --model fable --effort high --output-format json'
  check "concurrencia: solo cuenta el claude -p ajeno" \
    "40001 claude -p /pr-review 38 --model fable --effort high --output-format json" \
    "$(printf '%s\n' "$tabla" | filtrar_agentes "$propios")"
  # El vigilante (37793) no está en la lista de propios y aun así se descarta,
  # porque sus argumentos son los de devkit-run.sh: sin esa regla, un
  # lanzamiento se vería a sí mismo como agente ajeno.
  check "concurrencia: sin ajenos, el workspace está libre" "" \
    "$(printf '%s\n' "$tabla" | grep -v '^40001 ' | filtrar_agentes "$propios")"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Un doble de `claude` que no gasta cuota: responde bien a cualquier
  # `--model`, así sirve tanto para las comprobaciones de disponibilidad como
  # para los lanzamientos de punta a punta de más abajo.
  local doble
  doble="$tmp/claude"
  cat >"$doble" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$doble"

  cat >"$tmp/roles.toml" <<'FIN'
frontera = ["modelo-barato", "modelo-medio", "modelo-fuerte"]
implementacion.model_index = 1
implementacion.effort = "low"
implementacion.max_turns = 15
revision.model_index = 3
revision.effort = "high"
revision.max_turns = 50
epic-plan.effort = "max"
FIN

  check "campo model_index de implementación" "1" \
    "$(ROLES_FILE="$tmp/roles.toml" role_field implementacion model_index)"
  check "campo model_index de revisión" "3" \
    "$(ROLES_FILE="$tmp/roles.toml" role_field revision model_index)"
  check "anulación de esfuerzo por skill (epic-plan)" "max" \
    "$(ROLES_FILE="$tmp/roles.toml" role_field epic-plan effort)"
  check "lista de frontera, una por línea" "modelo-barato
modelo-medio
modelo-fuerte" "$(ROLES_FILE="$tmp/roles.toml" frontera_list)"
  # Un comentario al final de la línea es TOML válido y `.devkit/roles.toml`
  # se edita a mano: no puede colarse en el valor (DEVKIT-54, H3).
  cat >"$tmp/roles-comentarios.toml" <<'FIN'
frontera = ["a", "b"]  # del más fuerte al más barato
revision.model_index = 1 # primero de la lista
revision.effort = "high"  # "max" solo en epic-plan
FIN
  check "frontera_list ignora un comentario en línea" "a
b" "$(ROLES_FILE="$tmp/roles-comentarios.toml" frontera_list)"
  check "role_field ignora un comentario en línea (número)" "1" \
    "$(ROLES_FILE="$tmp/roles-comentarios.toml" role_field revision model_index)"
  check "role_field ignora un comentario en línea (cadena)" "high" \
    "$(ROLES_FILE="$tmp/roles-comentarios.toml" role_field revision effort)"

  # Sin DEVKIT_ROLES_FILE y sin hermano ../agents (la forma en que corre
  # desde /opt/devkit/scripts en la imagen), el valor por defecto debe caer
  # al respaldo en vez de a un archivo que no existe (DEVKIT-50, H1).
  mkdir -p "$tmp/nested/scripts"
  cp "$HERE/devkit-run.sh" "$tmp/nested/scripts/devkit-run.sh"
  check "ROLES_FILE por defecto cae al respaldo sin ../agents" "modelo-fuerte high 50" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_ROLES_FILE_FALLBACK="$tmp/roles.toml" DEVKIT_WS="$tmp" \
       DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-fallback" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" \
       bash "$tmp/nested/scripts/devkit-run.sh" --rol '/pr-review 9')"

  # Resolución normal de la lista (DEVKIT-54): con todos los modelos
  # disponibles, resolver_modelo devuelve el que toca por model_index, sin
  # caer al siguiente.
  check "resolución normal: primer modelo de la lista" "modelo-barato" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-normal-1" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 1)"
  check "resolución normal: tercer modelo de la lista" "modelo-fuerte" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-normal-3" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 3)"

  # Caída al siguiente modelo (DEVKIT-54): un doble que rechaza un alias
  # puntual simula un modelo que no existe o no responde; resolver_modelo
  # debe caer al siguiente de la lista, y quedar cacheado que el primero no
  # sirve.
  local caido
  caido="$tmp/claude-caido"
  cat >"$caido" <<'FIN'
#!/usr/bin/env bash
modelo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) modelo=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$modelo" = "modelo-inexistente" ]; then
  echo "error: modelo desconocido" >&2
  exit 1
fi
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":1}\n'
FIN
  chmod +x "$caido"
  # Tres modelos a propósito, no dos: con dos, "el siguiente de la lista" y
  # "el último recurso" son el mismo valor y la prueba pasa aunque la
  # resolución esté rota. Así se escapó que la sonda se comía el stdin del
  # bucle y cortaba la lista tras el primer modelo (DEVKIT-54).
  cat >"$tmp/roles-caida.toml" <<'FIN'
frontera = ["modelo-inexistente", "modelo-bueno", "modelo-ultimo"]
implementacion.model_index = 1
implementacion.effort = "high"
implementacion.max_turns = 10
FIN
  check "caída al siguiente modelo cuando el primero no responde" "modelo-bueno" \
    "$(CLAUDE_BIN="$caido" ROLES_FILE="$tmp/roles-caida.toml" FRONTERA_CACHE_DIR="$tmp/frontera-caida" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 1)"
  check "el modelo caído queda cacheado como no disponible" "no" \
    "$(cat "$tmp/frontera-caida/modelo-inexistente" 2>/dev/null)"
  check "el modelo elegido tras la caída queda cacheado como disponible" "si" \
    "$(cat "$tmp/frontera-caida/modelo-bueno" 2>/dev/null)"
  # Una sonda que lee stdin no debe truncar la lista: con un doble que se
  # come la entrada, la resolución tiene que seguir llegando al segundo
  # modelo y no saltar al último.
  local traga
  traga="$tmp/claude-traga"
  cat >"$traga" <<'FIN'
#!/usr/bin/env bash
modelo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) modelo=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null            # se come todo el stdin, como hace claude -p
[ "$modelo" != "modelo-inexistente" ] || exit 1
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":1}\n'
FIN
  chmod +x "$traga"
  check "una sonda que lee stdin no trunca la lista de frontera" "modelo-bueno" \
    "$(CLAUDE_BIN="$traga" ROLES_FILE="$tmp/roles-caida.toml" FRONTERA_CACHE_DIR="$tmp/frontera-traga" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 1)"
  # La caída tiene que quedar en watch.log: es la forma de verla sin
  # reproducirla a mano (criterio de aceptación de DEVKIT-54).
  : >"$tmp/sonda-watch.log"
  CLAUDE_BIN="$caido" ROLES_FILE="$tmp/roles-caida.toml" \
    FRONTERA_CACHE_DIR="$tmp/frontera-log" WATCH_LOG="$tmp/sonda-watch.log" \
    resolver_modelo 1 >/dev/null
  # Un error inmediato de la CLI se registra como fallo con su stderr, no como
  # timeout, y el stderr queda junto a la caché.
  check "la caída al siguiente modelo queda registrada en watch.log" \
    'sonda de modelo: modelo-inexistente falló (rc=1): error: modelo desconocido' \
    "$(grep -oE 'sonda de modelo: modelo-inexistente falló \(rc=1\): error: modelo desconocido' "$tmp/sonda-watch.log" | head -1)"
  check "el stderr de la sonda queda en <alias>.err" "error: modelo desconocido" \
    "$(cat "$tmp/frontera-log/modelo-inexistente.err" 2>/dev/null)"
  # Solo el rc 124 de `timeout` se registra como "no responde en Ns".
  local lento
  lento="$tmp/claude-lento"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$lento"
  chmod +x "$lento"
  CLAUDE_BIN="$lento" FRONTERA_CACHE_DIR="$tmp/frontera-lento" WATCH_LOG="$tmp/sonda-watch.log" \
    MODEL_CHECK_TIMEOUT=1 modelo_disponible modelo-lento
  check "un timeout de la sonda se registra como no responde" \
    'sonda de modelo: modelo-lento no responde en 1s' \
    "$(grep -oE 'sonda de modelo: modelo-lento no responde en 1s' "$tmp/sonda-watch.log" | head -1)"
  check "el modelo que sí responde también deja su línea" \
    'sonda de modelo: modelo-bueno responde' \
    "$(grep -oE 'sonda de modelo: modelo-bueno responde' "$tmp/sonda-watch.log" | head -1)"
  # Una segunda resolución con la caché ya escrita no vuelve a sondear ni a
  # registrar: "una vez por arranque".
  : >"$tmp/sonda-watch.log"
  CLAUDE_BIN="$caido" ROLES_FILE="$tmp/roles-caida.toml" \
    FRONTERA_CACHE_DIR="$tmp/frontera-log" WATCH_LOG="$tmp/sonda-watch.log" \
    resolver_modelo 1 >/dev/null
  check "con la caché escrita no vuelve a sondear" "0" \
    "$(grep -c 'sonda de modelo' "$tmp/sonda-watch.log" | tr -d ' ')"
  # Un `no` caduca: un fallo transitorio (cuota, red) no puede dejar el modelo
  # fuera todo el arranque. Dentro del plazo se respeta sin sondear; con
  # MODEL_RETRY=0 ya venció, la sonda vuelve a correr y el modelo queda en `si`.
  mkdir -p "$tmp/frontera-transitorio"
  printf 'no' >"$tmp/frontera-transitorio/modelo-bueno"
  check "un no dentro del plazo no vuelve a sondear" "no" \
    "$(CLAUDE_BIN="$doble" FRONTERA_CACHE_DIR="$tmp/frontera-transitorio" WATCH_LOG="$tmp/sonda-watch.log" MODEL_RETRY=600 modelo_disponible modelo-bueno; cat "$tmp/frontera-transitorio/modelo-bueno")"
  check "un fallo transitorio no persiste tras el plazo" "si" \
    "$(CLAUDE_BIN="$doble" FRONTERA_CACHE_DIR="$tmp/frontera-transitorio" WATCH_LOG="$tmp/sonda-watch.log" MODEL_RETRY=0 modelo_disponible modelo-bueno; cat "$tmp/frontera-transitorio/modelo-bueno")"

  check "modelo/esfuerzo de pr-review" "modelo-fuerte high 50" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-pr" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/pr-review 9')"
  check "modelo/esfuerzo de epic-plan (esfuerzo máximo por skill)" "modelo-fuerte max 50" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-epic" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/epic-plan DEVKIT-1')"
  check "modelo/esfuerzo de task-fix (rol implementación)" "modelo-barato low 15" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-fix" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/task-fix DEVKIT-2')"

  # --worker de punta a punta, con el mismo doble de arriba.
  mkdir -p "$tmp/run"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" --worker '/task-document DEVKIT-2' "$tmp/run/task-document-1.log" \
      modelo-barato low 15 >/dev/null 2>&1
  check "worker deja el log de claude" 'listo' \
    "$(jq -r .result "$tmp/run/task-document-1.log" 2>/dev/null)"
  check "worker agrega el resumen a watch.log" 'modelo=modelo-barato esfuerzo=low' \
    "$(grep -oE 'modelo=modelo-barato esfuerzo=low' "$tmp/run/watch.log" 2>/dev/null | head -1)"

  # Lanzamiento en segundo plano: vuelve enseguida y numera el log si ya
  # existe uno para la misma skill.
  : >"$tmp/run/pr-review-1.log"
  local antes despues rc espera=0
  antes=$(date +%s%N)
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
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
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" --worker '/task-document DEVKIT-2' "$tmp/run/candado.log" \
      modelo-barato low 15 >/dev/null 2>&1
  wait "$tenedor" 2>/dev/null
  check "espera el candado en vez de correr en paralelo" \
    "espera: otra skill ocupa el workspace" \
    "$(grep -oE 'espera: otra skill ocupa el workspace' "$tmp/run/watch.log" | head -1)"

  # El resumen avisa cuando se pasa del presupuesto de turnos.
  printf '{"result":"listo","total_cost_usd":0.5,"num_turns":99}\n' >"$tmp/exceso.log"
  check "avisa cuando se excede el presupuesto de turnos" 'excede el presupuesto de 15 turnos' \
    "$(resumen "$tmp/exceso.log" modelo-x low 15 | grep -oE 'excede el presupuesto de 15 turnos')"

  # Cadena epic-plan -> task-start (DEVKIT-50): el doble de claude, al ver un
  # prompt de epic-plan, lanza a su vez devkit-run task-start con el mismo
  # entorno de prueba, imitando lo que hace la skill al arrancar la primera
  # hija. Debe quedar en watch.log un resumen por cada rol (revisión para
  # epic-plan, implementación para task-start). Hasta DEVKIT-55 la cadena
  # salía de task-close, que ahora es bash y se prueba en watch-test.sh.
  git -C "$tmp" init -q
  git -C "$tmp" commit -q --allow-empty -m init --no-gpg-sign
  git -C "$tmp" checkout -q -b feat/DEVKIT-3-algo
  local cadena
  cadena="$tmp/claude-cadena"
  cat >"$cadena" <<FIN
#!/usr/bin/env bash
case "\$2" in
  */epic-plan*)
    DEVKIT_CLAUDE_BIN="$cadena" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \\
      DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \\
      bash "$HERE/devkit-run.sh" task-start DEVKIT-3 >/dev/null 2>&1
    ;;
esac
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$cadena"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$cadena" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" epic-plan DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ "$(grep -cE 'devkit-run "/(epic-plan|task-start)' "$tmp/run/watch.log" 2>/dev/null)" -lt 2 ] \
        && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "cadena epic-plan -> task-start: dos resúmenes con roles distintos" 2 \
    "$(grep -oE 'modelo=(modelo-barato|modelo-fuerte)' "$tmp/run/watch.log" | sort -u | wc -l | tr -d ' ')"

  # Anulación manual: --modelo/--esfuerzo pisan el rol resuelto y la línea de
  # resumen lo marca, sin comparar contra el presupuesto de roles.toml.
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
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
  # bloquea la card con task-block.sh (DEVKIT-55). Un doble del script anota
  # los argumentos que recibe, así la prueba no toca Notion.
  local pregunton bloqueo
  pregunton="$tmp/claude-pregunton"
  cat >"$pregunton" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"¿qué credencial uso?","total_cost_usd":0.01,"num_turns":2}\n'
FIN
  chmod +x "$pregunton"
  bloqueo="$tmp/task-block-doble"
  printf '#!/usr/bin/env bash\nprintf "%%s|" "$@" >"%s/bloqueo.args"\n' "$tmp" >"$bloqueo"
  chmod +x "$bloqueo"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$pregunton" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/bloqueo.args" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "pregunta abierta bloquea la card con task-block.sh" 'bloquea la card con task-block.sh: DEVKIT-3' \
    "$(grep -oE 'bloquea la card con task-block.sh: DEVKIT-3' "$tmp/run/watch.log" | head -1)"
  check "task-block.sh recibe la Clave como primer argumento" 'DEVKIT-3' \
    "$(cut -d'|' -f1 "$tmp/bloqueo.args" 2>/dev/null)"

  # `devkit-run task-block` y `devkit-run task-close` delegan en el script
  # bash, en primer plano y con los argumentos tal cual (DEVKIT-55).
  rm -f "$tmp/bloqueo.args"
  DEVKIT_TASK_BLOCK_BIN="$bloqueo" bash "$HERE/devkit-run.sh" task-block DEVKIT-3 falta el token >/dev/null 2>&1
  check "devkit-run task-block delega en el script bash" 'DEVKIT-3|falta|el|token|' \
    "$(cat "$tmp/bloqueo.args" 2>/dev/null)"
  # Un watch.sh viejo pide las skills retiradas por --sync: van a los scripts
  # y no llegan a `claude`.
  rm -f "$tmp/bloqueo.args"
  DEVKIT_CLAUDE_BIN=/bin/false DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" --sync '/task-block DEVKIT-3 tres ciclos sin OK' >/dev/null 2>&1
  check "--sync /task-block (watch.sh viejo) va al script" 'DEVKIT-3|tres ciclos sin OK|' \
    "$(cat "$tmp/bloqueo.args" 2>/dev/null)"
  rm -f "$tmp/bloqueo.args"
  DEVKIT_CLAUDE_BIN=/bin/false DEVKIT_TASK_CLOSE_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" --sync '/task-close DEVKIT-3 https://github.com/o/r/pull/9' >/dev/null 2>&1
  check "--sync /task-close (watch.sh viejo) va al script" 'DEVKIT-3|https://github.com/o/r/pull/9|' \
    "$(cat "$tmp/bloqueo.args" 2>/dev/null)"

  # Modelo vacío (DEVKIT-55): con una lista `frontera` vacía no hay modelo que
  # resolver. Antes se lanzaba `claude --model ""` y moría con un 400; ahora no
  # se lanza, sale con 65 y deja la alarma.
  printf 'frontera = []\nimplementacion.model_index = 1\nimplementacion.effort = "high"\n' >"$tmp/roles-vacio.toml"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles-vacio.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-vacio" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-3 >/dev/null 2>&1; rc=$?
  check "modelo vacío: no lanza y sale con 65" 65 "$rc"
  check "modelo vacío: deja la alarma en watch.log" 'ALARMA: modelo vacío' \
    "$(grep -oE 'ALARMA: modelo vacío' "$tmp/run/watch.log" | head -1)"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/vacio.log" "" high 40 >/dev/null 2>&1; rc=$?
  check "modelo vacío en --worker: tampoco lanza" "65 no" \
    "$rc $([ -s "$tmp/run/vacio.log" ] && echo si || echo no)"

  # El `claude -p` recibe DEVKIT_SCRIPTS_DIR y DEVKIT_RUN_DIR del lanzador
  # (Ampliación de DEVKIT-55): sin la variable en el entorno, o con la copia
  # vieja de la imagen, una skill que invoca otro script por ruta debe llegar
  # al de este mismo directorio (el del workspace, en modo dev).
  local espejo
  espejo="$tmp/claude-espejo"
  cat >"$espejo" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"%s %s","total_cost_usd":0,"num_turns":1}\n' "$DEVKIT_SCRIPTS_DIR" "$DEVKIT_RUN_DIR"
FIN
  chmod +x "$espejo"
  env -u DEVKIT_SCRIPTS_DIR DEVKIT_CLAUDE_BIN="$espejo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-1.log" modelo-x high 40 >/dev/null 2>&1
  check "worker sin la variable exporta DEVKIT_SCRIPTS_DIR y DEVKIT_RUN_DIR" "$HERE $tmp/run" \
    "$(jq -r .result "$tmp/run/espejo-1.log" 2>/dev/null)"
  DEVKIT_SCRIPTS_DIR=/opt/devkit/scripts DEVKIT_CLAUDE_BIN="$espejo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-2.log" modelo-x high 40 >/dev/null 2>&1
  check "worker con la copia de la imagen en el entorno usa la suya" "$HERE $tmp/run" \
    "$(jq -r .result "$tmp/run/espejo-2.log" 2>/dev/null)"
  # --worker corre el `claude -p` con el candado tomado: debe avisarlo con
  # DEVKIT_LOCK_HELD=1, o task-block.sh no guarda el wip (DEVKIT-55, H2).
  local espejo_candado
  espejo_candado="$tmp/claude-espejo-candado"
  cat >"$espejo_candado" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"candado=%s","total_cost_usd":0,"num_turns":1}\n' "${DEVKIT_LOCK_HELD:-no}"
FIN
  chmod +x "$espejo_candado"
  env -u DEVKIT_LOCK_HELD DEVKIT_CLAUDE_BIN="$espejo_candado" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-candado.log" modelo-x high 40 >/dev/null 2>&1
  check "worker exporta DEVKIT_LOCK_HELD=1 al claude -p" "candado=1" \
    "$(jq -r .result "$tmp/run/espejo-candado.log" 2>/dev/null)"

  # El alias `devkit-run` de zshrc no existe en el Bash no interactivo con el
  # que corre `claude -p` (DEVKIT-54: epic-plan y task-close quedaron sin
  # lanzar la siguiente hija porque sus SKILL.md invocaban el alias). La
  # ruta explícita por `DEVKIT_SCRIPTS_DIR`, que es como las llaman ahora,
  # debe resolver igual en ese Bash no interactivo y sin el alias cargado.
  check "el alias devkit-run no existe en un bash -c no interactivo" '' \
    "$(bash -c 'type devkit-run' 2>/dev/null)"
  check "la ruta explícita por DEVKIT_SCRIPTS_DIR encuentra el script sin el alias" 'lanzado: /task-start DEVKIT-9' \
    "$(DEVKIT_SCRIPTS_DIR="$HERE" DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
       bash -c '"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/devkit-run.sh" task-start DEVKIT-9' | head -1)"

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
frontera = ["anulacion-proyecto"]
revision.model_index = 1
revision.effort = "high"
revision.max_turns = 99
implementacion.model_index = 1
implementacion.effort = "high"
implementacion.max_turns = 99
FIN
  check "ROLES_FILE desde .devkit/roles.toml (pr-review)" "anulacion-proyecto high 99" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_WS="$tmp" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion-1" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" bash "$HERE/devkit-run.sh" --rol '/pr-review 9')"
  check "ROLES_FILE desde .devkit/roles.toml (task-fix)" "anulacion-proyecto high 99" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_WS="$tmp" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion-2" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" bash "$HERE/devkit-run.sh" --rol '/task-fix DEVKIT-2')"

  return $fail
}

case "${1:-}" in
  --rol)
    model_effort_of "${2:-}"
    exit 0
    ;;
  --sync)
    # Un `watch.sh` anterior a DEVKIT-55, todavía vivo tras el merge hasta el
    # próximo `devkit recreate`, sigue pidiendo "/task-close <Clave> <URL>" y
    # "/task-block <Clave> <motivo>" como skills. Esas skills ya no existen:
    # se atienden con los scripts bash, para que el cambio de versión no deje
    # cards sin cerrar ni un `claude -p` improvisando un paso que no conoce.
    case "${2:-}" in
      /task-close\ *|/task-block\ *)
        read -r sync_skill sync_clave sync_resto <<<"${2#/}"
        if [ "$sync_skill" = task-block ]; then
          "$TASK_BLOCK_BIN" "$sync_clave" "$sync_resto"
        else
          # shellcheck disable=SC2086  # la URL del PR es una sola palabra
          "$TASK_CLOSE_BIN" "$sync_clave" $sync_resto
        fi
        exit $?
        ;;
    esac
    read -r modelo esfuerzo _ < <(model_effort_of "${2:-}")
    modelo_valido "${modelo:-}" "${2:-}" || exit 65
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
    modelo_valido "$modelo" "$prompt" || exit 65
    exec 9>"$LOCK"
    if ! flock -n 9; then
      printf '%s devkit-run "%s" espera: otra skill ocupa el workspace\n' "$(date -u +%FT%TZ)" "$prompt" >> "$WATCH_LOG"
      flock 9
    fi
    # El candado queda tomado durante todo el `claude -p`: task-block.sh lo
    # sabe por DEVKIT_LOCK_HELD y guarda el wip sin volver a pedirlo.
    DEVKIT_LOCK_HELD=1 run_claude "$prompt" "$modelo" "$esfuerzo" >"$logf" 2>&1 &
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
  --otros-agentes)
    otros_agentes
    exit $?
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
        echo "uso: devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high|xhigh|max>] <skill> <Clave> [texto extra...]" >&2
        echo "     devkit-run --test   corre la autoprueba" >&2
        exit 64
      fi
      modelo_manual="$2"; shift 2 ;;
    --esfuerzo)
      if falta_valor "${2:-}"; then
        echo "uso: devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high|xhigh|max>] <skill> <Clave> [texto extra...]" >&2
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
  echo "uso: devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high|xhigh|max>] <skill> <Clave> [texto extra...]" >&2
  echo "     devkit-run --test   corre la autoprueba" >&2
  exit 64
fi
shift 2 2>/dev/null

# task-close y task-block dejaron de ser skills en DEVKIT-55: son bash contra
# la API de Notion, corren en primer plano en segundos y no resuelven modelo.
# `devkit-run task-close <Clave> [URL]` y `devkit-run task-block <Clave>
# <motivo>` siguen valiendo, para no cambiar la costumbre del humano.
case "$skill" in
  task-close|task-block)
    if [ "$skill" = task-block ]; then exec "$TASK_BLOCK_BIN" "$clave" "$@"; fi
    exec "$TASK_CLOSE_BIN" "$clave" "$@"
    ;;
esac

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
modelo_valido "${modelo:-}" "$prompt" || exit 65
# Con anulación manual no hay presupuesto de roles.toml que comparar con el
# turno real: el rol resuelto ya no aplica.
[ -z "$manual" ] || presupuesto="-"

nohup "$HERE/devkit-run.sh" --worker "$prompt" "$logf" "$modelo" "$esfuerzo" "$presupuesto" "$manual" \
  >/dev/null 2>&1 &
disown
echo "lanzado: $prompt"
echo "modelo=$modelo esfuerzo=$esfuerzo log=$logf pid=$!"

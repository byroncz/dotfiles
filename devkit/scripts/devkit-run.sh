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
#     desde /workspace y vuelve en cuanto confirma que arrancó. Log en
#     /run/devkit/<skill>-<n>.log (n crece si ya hay uno); al terminar,
#     agrega el resumen de costo a watch.log, igual que una skill lanzada por
#     el bucle.
#     Antes de lanzar espera el marcador /run/devkit/ready del arranque del
#     contenedor. Después espera hasta 5 s: si el worker muere en ese rato
#     sin resumen "terminado", imprime las últimas líneas del log y sale con
#     70 (DEVKIT-57). Un `task-start` lanzado con el editor recién abierto
#     imprimió su PID y nunca corrió, y nadie lo supo hasta ir a mirar.
#
# Qué hace cada agente, sin lanzar otro agente (DEVKIT-57):
#   devkit-run --estado [--seguir]
#     Tabla de los últimos lanzamientos: skill, card, quién lanzó, hace
#     cuánto y estado (en curso, terminó, error, bloqueada, no arrancó).
#     Debajo, un bloque `Consumo` con el porcentaje de cuota del plan en vivo
#     (sesión y semana), leído con `claude -p "/usage"` (DEVKIT-62): es la
#     misma cifra oficial de una sesión interactiva, no una estimación desde
#     watch.log. `--seguir` refresca todo cada 3 s hasta Ctrl-C.
#
# Uso con anulación manual, para subir o bajar el rol de un lanzamiento
# concreto sin tocar roles.toml:
#   devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high|xhigh|max>] <skill> <Clave> [texto extra...]
#     La línea de resumen en watch.log marca "(anulación manual)".
#
# Modos que usa `watch.sh` (no para uso manual):
#   devkit-run --rol "<prompt>"                     imprime "modelo esfuerzo presupuesto ronda"
#   devkit-run --sync "<prompt>"                    corre en primer plano, JSON por stdout
#   devkit-run --resumen <log> <modelo> <esfuerzo> <presupuesto> [ronda]
#                                                    imprime la línea de costo/tokens/turnos
#   devkit-run --otros-agentes                      lista los `claude -p` ajenos
#                                                    sobre este workspace; sale 0
#                                                    si está libre, 1 si no
#   devkit-run --siguiente-modelo <alias>           imprime el modelo disponible
#                                                    que sigue a <alias> en
#                                                    `frontera` (vuelve al primero
#                                                    tras el último)
#   devkit-run --test                               autoprueba
#
# `--sync` usa DEVKIT_MODELO_FORZADO en vez del modelo del rol cuando viene no
# vacía: así relanza watch.sh un task-fix con otro modelo (DEVKIT-57). Usa
# DEVKIT_RONDA, si viene, en vez de volver a leer el PR (DEVKIT-61).
#
# La tabla rol -> modelo/esfuerzo/turnos vive en devkit/agents/roles.toml.
# Desde DEVKIT-54, el modelo no se elige por Tipo de la card sino por el papel
# de la skill en el flujo: `roles.toml` declara una lista `frontera` ordenada
# de alias de modelo y cada rol un `model_index` (posición 1-based desde la
# que empieza a buscar). El Tipo sigue eligiendo prefijo de rama y sección
# del CHANGELOG, pero ya no modelo. Desde DEVKIT-61, `implementacion.rondas`
# cambia modelo y esfuerzo según cuántas veces se corrigió el PR (ver
# `model_effort_of`).
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
# Para leer la ronda de un lanzamiento (DEVKIT-61): la card en Notion trae la
# URL del PR, y gh cuenta sus comentarios devkit-fix. Sustituibles por dobles.
NOTION_BIN="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH_BIN="${DEVKIT_GH_BIN:-gh}"
# Arranque y estado de los lanzamientos (DEVKIT-57). READY lo escribe
# entrypoint.sh como último paso del arranque; `devkit shell` y `devkit code`
# ya lo esperan desde el host, y ahora también `devkit-run`.
READY_FILE="${DEVKIT_READY_FILE:-$RUN_DIR/ready}"
READY_TIMEOUT="${DEVKIT_READY_TIMEOUT:-120}"
# Segundos que espera tras lanzar para confirmar que el worker sigue vivo.
ARRANQUE_ESPERA="${DEVKIT_ARRANQUE_ESPERA:-5}"
# Un lanzamiento sin proceso visible ni resumen cuenta como `en curso` durante
# este margen, contado desde su línea "lanzando": entre esa línea y el
# `claude -p` pasan la sonda de modelos (hasta 30 s por modelo) y el `nohup`.
# El 2026-09-16, `watch.sh --agentes-vivos` dijo "sin agentes vivos" dos
# segundos después de "lanzando pr-review" por mirar solo los procesos.
ESTADO_GRACIA="${DEVKIT_ESTADO_GRACIA:-120}"
ESTADO_FILAS="${DEVKIT_ESTADO_FILAS:-20}"
ESTADO_INTERVALO="${DEVKIT_ESTADO_INTERVALO:-3}"
PS_BIN="${DEVKIT_PS_BIN:-ps}"
# Marcador de alarmas vistas (DEVKIT-63): `--estado` guarda ahí cuántas líneas
# de watch.log tenía al mostrarlas, y el segmento `!<k>` del prompt cuenta las
# `ALARMA:` posteriores a esa marca en vez de recorrer todo el log cada vez.
ALARMAS_VISTAS="${DEVKIT_ALARMAS_VISTAS:-$RUN_DIR/alarmas-vistas}"
# Timeout de `leer_cuota` (DEVKIT-62): `claude -p "/usage"` es un comando
# local que no llama al modelo (mide bajo 1.5 s aislado), pero un margen
# generoso evita que --estado se cuelgue si la CLI no responde.
CUOTA_TIMEOUT="${DEVKIT_CUOTA_TIMEOUT:-20}"
# La lectura en sí tarda ~1.3 s: --estado nunca la espera en línea (H1 de
# pr-review en DEVKIT-62). CUOTA_TTL es cuánto se muestra una lectura antes de
# refrescarla en segundo plano; CUOTA_CACHE guarda la última lectura con su
# hora, y CUOTA_LOCK evita que dos refrescos corran a la vez.
CUOTA_TTL="${DEVKIT_CUOTA_TTL:-60}"
CUOTA_CACHE="${DEVKIT_CUOTA_CACHE:-$RUN_DIR/cuota.cache}"
CUOTA_LOCK="${DEVKIT_CUOTA_LOCK:-$RUN_DIR/cuota.lock}"
# Columna "bloquea a" de `--estado` (ampliación de DEVKIT-63): mismo patrón de
# caché que Consumo, una sola llamada a Notion por refresco. BLOQUEOS_TTL es
# más corto que CUOTA_TTL porque el Estado de una card cambia más seguido que
# la cuota del plan.
BLOQUEOS_TTL="${DEVKIT_BLOQUEOS_TTL:-30}"
BLOQUEOS_CACHE="${DEVKIT_BLOQUEOS_CACHE:-$RUN_DIR/bloqueos.cache}"
BLOQUEOS_LOCK="${DEVKIT_BLOQUEOS_LOCK:-$RUN_DIR/bloqueos.lock}"
# Antes de lanzar, `run_claude` comprueba con `claude mcp list` que Notion está
# conectado (DEVKIT-65): todas las skills la necesitan (AGENTS.md), y sin ella
# piden autorizar el conector y no avanzan. En 0 en la autoprueba, que corre
# contra dobles de `claude` sin `mcp list`; las pruebas de esta comprobación
# la reactivan a mano.
NOTION_CHECK="${DEVKIT_NOTION_CHECK:-1}"
# H4 de pr-review (DEVKIT-65): un `task-start` lanzado por `epic-plan` -que a
# su vez corre dentro de otro `claude -p`- terminó tres veces montando el
# conector de Notion con otro nombre de servidor y sin cobertura de
# `--allowedTools` (incidentes reales del 2026-09-16). La hipótesis de que la
# causa son las marcas de sesión anidada que el hijo hereda del padre
# (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, ...) no quedó confirmada: en este
# contenedor, `claude mcp list` con esas marcas puestas a mano y con la lista
# blanca de abajo dio el mismo resultado (comentario de la card, 2026-09-17
# 04:11; repetido en la revisión de pr-review sobre el commit ef9a3fe). Como
# medida defensiva de todas formas, `run_claude` copia al hijo solo las
# variables que de verdad hace falta -identidad de Notion/GitHub, red de
# salida (compose.yaml la fija a nivel de contenedor, ver AGENTS.md) y hora
# local- y descarta todo lo demás con esta lista blanca en vez de con una
# lista negra de marcas de sesión anidada: una CLI nueva puede sumar una
# marca que hoy no conocemos, y una lista negra la dejaría pasar igual.
# H2 de pr-review (DEVKIT-65): revisado el bloque `ENV` del Dockerfile y el
# `environment:` de `compose.yaml` completos. Suman `DISABLE_AUTOUPDATER=1`
# (Dockerfile: sin ella la CLI intenta actualizarse sola, sin salida a
# internet desde `dev`) y `MCP_OAUTH_CALLBACK_PORT=54545` (compose.yaml: el
# plugin de Notion vuelve a este puerto fijo tras el OAuth; sin la variable
# usa uno al azar que el proxy no espera). `TERM` y `UV_PYTHON_INSTALL_DIR`/
# `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` quedan fuera a propósito: `claude -p` no
# es interactivo y no consulta `TERM`, y los tres `UV_*` del Dockerfile ya
# apuntan a rutas bajo `$HOME`, que sí viaja en la lista; sin la variable,
# `uv` cae al mismo valor por defecto. `DEVKIT_PROJECT` y `DEVKIT_VERSION`
# (compose.yaml) también quedan fuera: ninguna skill ni este script las lee.
ENV_HEREDABLE="HOME PATH LANG LC_ALL TZ CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy DISABLE_AUTOUPDATER MCP_OAUTH_CALLBACK_PORT"
# En 0, `run_claude` vuelve al `claude -p` con el entorno completo heredado
# (el comportamiento previo a DEVKIT-65): lo usa la autoprueba de otro
# archivo (`watch-test.sh`) cuyos dobles de `claude` ya simulan estado propio
# con variables sueltas (contador de llamadas, `FIX_DIR`, ...) fuera de
# ENV_HEREDABLE, y no le corresponde conocer esta lista. La comprobación de
# la limpieza vive en la autoprueba de este archivo.
ENV_LIMPIO="${DEVKIT_ENV_LIMPIO:-1}"

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
  toml_lista frontera
}

# Cualquier lista `<clave> = ["a", "b"]` de roles.toml, un elemento por línea.
# La usan `frontera` y `<rol>.rondas` (DEVKIT-61).
toml_lista() {  # toml_lista <clave>
  local clave=${1//./\\.}
  grep -E "^${clave}[[:space:]]*=" "$ROLES_FILE" 2>/dev/null | tail -1 \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E "s/^${clave}[[:space:]]*=[[:space:]]*\[(.*)\][[:space:]]*\$/\1/" \
    | tr ',' '\n' | sed -E 's/^[[:space:]"]+//; s/[[:space:]"]+$//' | grep -v '^$'
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
      "$(date +%FT%T%:z)" "$modelo_id" >> "$WATCH_LOG" 2>/dev/null
  elif [ "$rc" -eq 124 ]; then
    # 124 es el código de `timeout`: el modelo no contestó a tiempo.
    printf '%s devkit-run sonda de modelo: %s no responde en %ss; cae al siguiente de la lista\n' \
      "$(date +%FT%T%:z)" "$modelo_id" "$MODEL_CHECK_TIMEOUT" >> "$WATCH_LOG" 2>/dev/null
  else
    # Cualquier otro código es un error de la CLI (alias desconocido, cuota,
    # red), casi siempre inmediato: decir "no responde en 30s" lo confundía
    # con un timeout (DEVKIT-54, H2 de pr-review).
    local detalle
    detalle=$(grep -m1 -v '^[[:space:]]*$' "$err" 2>/dev/null | cut -c1-160)
    printf '%s devkit-run sonda de modelo: %s falló (rc=%s): %s; cae al siguiente de la lista\n' \
      "$(date +%FT%T%:z)" "$modelo_id" "$rc" "${detalle:-sin detalle en stderr}" >> "$WATCH_LOG" 2>/dev/null
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

# Modelo disponible que sigue a <alias> en `frontera` (DEVKIT-57). Lo usa
# watch.sh para relanzar un task-fix que respondió "nada que corregir" con un
# CAMBIOS vigente: otro modelo lee el mismo informe con otros ojos. Si <alias>
# es el último o no está en la lista, empieza por el primero; repetir el
# mismo modelo que ya falló no aporta otra lectura.
siguiente_modelo() {  # siguiente_modelo <alias>
  local actual=$1 modelo i=0 pos=0
  local -a modelos=()
  while IFS= read -r modelo; do
    [ -n "$modelo" ] && modelos+=("$modelo")
  done < <(frontera_list)
  [ "${#modelos[@]}" -gt 0 ] || return 1
  for modelo in "${modelos[@]}"; do
    i=$((i + 1))
    [ "$modelo" = "$actual" ] && pos=$i
  done
  [ "$pos" -lt "${#modelos[@]}" ] || pos=0
  resolver_modelo "$((pos + 1))"
}

# --- Escalera de modelos por ronda (DEVKIT-61) ------------------------------
# La ronda de un lanzamiento de implementación es cuántas veces se corrigió ya
# su PR, más uno: task-start y task-submit son siempre la 1 (todavía no hay
# PR); task-fix y task-document cuentan los comentarios `<!-- devkit-fix` del
# PR de la card. `implementacion.rondas` en roles.toml dice qué modelo y
# esfuerzo toca en cada ronda. Revisión no tiene ronda: imprime "-".

ronda_aviso() {  # ronda_aviso <prompt> <texto>
  printf '%s devkit-run ronda de "%s": %s\n' "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" "$2" \
    >> "$WATCH_LOG" 2>/dev/null
}

# PR de una card: la URL que guarda Notion; si falta, el PR de su rama. La
# rama sale de la card o, sin Notion, de las ramas locales y remotas cuyo
# nombre trae la Clave seguida de un guion (así DEVKIT-6 no toma DEVKIT-61).
pr_de_clave() {  # pr_de_clave <Clave>
  local clave=$1 card pr rama
  card=$("$NOTION_BIN" card "$clave" 2>/dev/null)
  pr=$(jq -r '.pr // empty' <<<"$card" 2>/dev/null)
  if [ -n "$pr" ]; then printf '%s' "$pr"; return 0; fi
  rama=$(jq -r '.rama // empty' <<<"$card" 2>/dev/null | sed -E 's#^.*/tree/##')
  [ -n "$rama" ] || rama=$(git -C "$WS" for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
    | sed -E 's#^origin/##' | grep -E "^[a-z]+/$clave-" | head -1)
  [ -n "$rama" ] || return 1
  pr=$("$GH_BIN" pr list --head "$rama" --state all --limit 1 --json number 2>/dev/null \
    | jq -r '.[0].number // empty' 2>/dev/null)
  [ -n "$pr" ] || return 1
  printf '%s' "$pr"
}

# ¿Terminó un `task-start` sin entregar ni bloquear? (DEVKIT-77). Un buen
# final deja la card en `Revisión automática` (task-submit corrió) o
# `Bloqueada` (task-block.sh corrió, por esta u otra barrera); cualquier otra
# cosa con `task-start` de por medio y la card todavía `En progreso` es el
# corte silencioso que dejó DEVKIT-63. Solo mira `task-start`: es la única
# skill de este grupo que puede terminar "bien" sin haber tocado el Estado.
task_start_sin_entregar() {  # task_start_sin_entregar <prompt> <clave>
  local prompt=$1 clave=$2 skill estado
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  [ "$skill" = task-start ] || return 1
  [ -n "$clave" ] || return 1
  estado=$(jq -r '.estado // empty' <<<"$("$NOTION_BIN" card "$clave" 2>/dev/null)" 2>/dev/null)
  [ "$estado" = "En progreso" ]
}

ronda_de() {  # ronda_de <prompt>
  local prompt=$1 skill clave pr n
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  case "$skill" in
    pr-review|epic-plan) printf -- '-'; return 0 ;;
    task-fix|task-document) ;;
    *) printf '1'; return 0 ;;
  esac
  clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  if [ -z "$clave" ]; then
    ronda_aviso "$prompt" "sin Clave en el prompt; uso la ronda 1"
    printf '1'; return 0
  fi
  if ! pr=$(pr_de_clave "$clave"); then
    ronda_aviso "$prompt" "no encuentro el PR de $clave (ni en Notion ni por su rama); uso la ronda 1"
    printf '1'; return 0
  fi
  n=$("$GH_BIN" pr view "$pr" --json comments 2>/dev/null \
    | jq '[.comments[]? | select((.body // "") | contains("<!-- devkit-fix"))] | length' 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*)
      ronda_aviso "$prompt" "no pude leer los comentarios del PR $pr de $clave; uso la ronda 1"
      printf '1' ;;
    *) printf '%s' "$((n + 1))" ;;
  esac
}

# "<modelo> <esfuerzo> <presupuesto de turnos> <ronda>" para un prompt.
#
# Modelo y esfuerzo: si el rol declara `rondas`, el elemento de la ronda
# (`<alias>:<esfuerzo>`, el último si la ronda pasa del largo de la lista),
# con su alias por la misma sonda de `frontera`; si el alias no responde, el
# modelo de `model_index` y una línea en watch.log. Sin `rondas`,
# `model_index` y `effort` del rol, como antes de DEVKIT-61. `revision` no
# escala: su `rondas` se ignora con aviso. Tanto el modelo como el esfuerzo
# admiten además una anulación por skill (por ejemplo `epic-plan.model_index`
# o `epic-plan.effort`, DEVKIT-72), que manda sobre el valor del rol.
#
# [ronda] viene cuando quien llama ya la resolvió (watch.sh la pasa de `--rol`
# a `--sync` en DEVKIT_RONDA): no se vuelve a consultar el PR ni se repiten
# los avisos en watch.log.
model_effort_of() {  # model_effort_of <prompt> [ronda]
  local role skill idx modelo esfuerzo turnos ronda avisar=1 elem alias esf i
  local -a rondas=()
  skill=$(printf '%s' "$1" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  role=$(role_of "$1")
  if [ -n "${2:-}" ]; then ronda=$2; avisar=""; else ronda=$(ronda_de "$1"); fi
  idx=$(role_field "$role" model_index)
  i=$(role_field "$skill" model_index)
  [ -z "$i" ] || idx=$i
  esfuerzo=$(role_field "$role" effort)
  while IFS= read -r elem; do rondas+=("$elem"); done < <(toml_lista "$role.rondas")
  if [ "$role" = revision ]; then
    if [ "${#rondas[@]}" -gt 0 ] && [ -n "$avisar" ]; then
      printf '%s devkit-run "%s": revision.rondas se ignora; el revisor no escala (DEVKIT-61)\n' \
        "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" >> "$WATCH_LOG" 2>/dev/null
    fi
    ronda="-"
    modelo=$(resolver_modelo "$idx")
  elif [ "${#rondas[@]}" -gt 0 ] && [[ "$ronda" =~ ^[0-9]+$ ]] && [ "$ronda" -ge 1 ]; then
    i=$ronda
    [ "$i" -le "${#rondas[@]}" ] || i=${#rondas[@]}
    elem=${rondas[$((i - 1))]}
    alias=${elem%%:*}
    esf=""
    case "$elem" in *:*) esf=${elem#*:} ;; esac
    [ -z "$esf" ] || esfuerzo=$esf
    if [ -n "$alias" ] && modelo_disponible "$alias"; then
      modelo=$alias
    else
      modelo=$(resolver_modelo "$idx")
      [ -z "$avisar" ] || ronda_aviso "$1" "ronda $ronda pide ${alias:-un alias vacío}, que no responde; uso $modelo (model_index del rol)"
    fi
  else
    modelo=$(resolver_modelo "$idx")
  fi
  esf=$(role_field "$skill" effort)
  [ -z "$esf" ] || esfuerzo=$esf
  turnos=$(role_field "$role" max_turns)
  # Campos vacíos como "-": `read` parte por espacios y se salta los campos
  # vacíos, así que un modelo vacío se leía como si fuera el esfuerzo
  # (DEVKIT-55).
  printf '%s %s %s %s' "${modelo:--}" "${esfuerzo:--}" "${turnos:--}" "${ronda:--}"
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
#
# DEVKIT_ORIGEN y DEVKIT_MODELO_FORZADO van vacías: describen este lanzamiento,
# no los que la skill haga después (DEVKIT-57). Un epic-plan que lanza
# task-start debe verse como origen `epic-plan`, no heredar el de su lanzador.
#
# DEVKIT_MODEL y DEVKIT_EFFORT son el modelo y el esfuerzo que recibe este
# `claude -p`, ya resueltos: rol, caída en `frontera`, `--modelo`/`--esfuerzo`
# o DEVKIT_MODELO_FORZADO (DEVKIT-58). Las skills los copian en la línea
# "<Verbo> con <modelo>, esfuerzo <x>" del PR, del informe de revisión y de
# la entrada de Documentación, para decidir con evidencia qué modelo alcanza
# para cada papel. Se leen de aquí y no de roles.toml porque solo este punto
# sabe qué se lanzó de verdad.
#
# Líneas "NOMBRE=valor" de ENV_HEREDABLE presentes en el entorno de quien
# llama, para copiarlas al `claude -p` hijo con `env -i` (DEVKIT-65). Función
# aparte para poder probarla sin lanzar nada de verdad.
entorno_hijo() {
  local nombre
  for nombre in $ENV_HEREDABLE; do
    [ -z "${!nombre:-}" ] || printf '%s=%s\n' "$nombre" "${!nombre}"
  done
}

# Aviso de DEVKIT-65: sin Notion conectado en el entorno del `claude -p`
# hijo, todas las skills piden autorizar el conector y no avanzan. Mejor
# avisarlo antes que dejarlo fallar a medias.
alarma_sin_notion() {  # alarma_sin_notion <prompt>
  printf 'devkit-run: el servidor de Notion no está conectado en el entorno del lanzamiento ("%s mcp list"); no se lanza "%s".\n' \
    "$CLAUDE_BIN" "$1" >&2
  printf '%s devkit-run "%s" ALARMA: sin Notion conectado (claude mcp list); no se lanza\n' \
    "$(date +%FT%T%:z)" "$1" >> "$WATCH_LOG" 2>/dev/null
}

run_claude() {  # run_claude <prompt> <modelo> <esfuerzo>
  local -a extra=(
    "DEVKIT_ORIGEN=" "DEVKIT_MODELO_FORZADO=" "DEVKIT_RONDA="
    "DEVKIT_MODEL=$2" "DEVKIT_EFFORT=$3"
    "DEVKIT_SCRIPTS_DIR=$HERE" "DEVKIT_RUN_DIR=$RUN_DIR"
  )
  [ -z "${DEVKIT_LOCK_HELD:-}" ] || extra+=("DEVKIT_LOCK_HELD=$DEVKIT_LOCK_HELD")
  [ -z "${DEVKIT_LANZADOR:-}" ] || extra+=("DEVKIT_LANZADOR=$DEVKIT_LANZADOR")

  local -a lanzador
  if [ "$ENV_LIMPIO" = 0 ]; then
    lanzador=(env "${extra[@]}")
  else
    local -a entorno
    mapfile -t entorno < <(entorno_hijo)
    entorno+=("${extra[@]}")
    lanzador=(env -i "${entorno[@]}")
  fi

  # La sonda usa el mismo entorno que el lanzamiento real: comprobar con el
  # entorno de quien llama (con marcas de sesión anidada de sobra) daría un
  # falso "no conectado" justo en el caso que la lista blanca de arriba
  # arregla.
  if [ "$NOTION_CHECK" != 0 ] \
     && ! "${lanzador[@]}" "$CLAUDE_BIN" mcp list 2>/dev/null | grep -qiE 'notion.*(connected|✔)'; then
    alarma_sin_notion "$1"
    return 67
  fi
  "${lanzador[@]}" "$CLAUDE_BIN" -p "$1" --model "$2" --effort "$3" --output-format json \
    --permission-mode acceptEdits \
    --allowedTools "Bash" "Read" "Edit" "Write" "Grep" "Glob" "Skill" \
      "mcp__plugin_Notion_notion" "mcp__claude_ai_Notion"
}

# Línea de costo/tokens/turnos/modelo/esfuerzo de un log ya terminado. La
# comparten `run_skill` (watch.sh) y el modo `--worker` de este script, para
# no repetir el `jq` en dos archivos. `ronda=` va justo después de `esfuerzo=`
# (DEVKIT-61): `cycle_cost` suma `costo=` y `--estado` lee el encabezado de la
# línea, así que ninguno de los dos depende de lo que hay entre medio.
resumen() {  # resumen <log> <modelo> <esfuerzo> <presupuesto> [ronda]
  local logf=$1 modelo=$2 esfuerzo=$3 presupuesto=$4 ronda=${5:--} linea turnos excedido=""
  linea=$(tail -1 "$logf" 2>/dev/null | jq -r '
    "costo=\(.total_cost_usd // "?") turnos=\(.num_turns // "?") tokens: entrada=\(.usage.input_tokens // "?") cache=\(.usage.cache_read_input_tokens // "?") salida=\(.usage.output_tokens // "?") :: \((.result // "") | gsub("\n"; " ") | .[0:160])"' 2>/dev/null)
  [ -n "$linea" ] || linea="$(tail -1 "$logf" 2>/dev/null | cut -c1-160)"
  turnos=$(tail -1 "$logf" 2>/dev/null | jq -r '.num_turns // empty' 2>/dev/null)
  if [ -n "$presupuesto" ] && [ "$presupuesto" != "-" ] && [ -n "$turnos" ] \
     && [ "$turnos" -gt "$presupuesto" ] 2>/dev/null; then
    excedido=" (excede el presupuesto de $presupuesto turnos de roles.toml)"
  fi
  printf 'modelo=%s esfuerzo=%s ronda=%s %s%s' "$modelo" "$esfuerzo" "$ronda" "$linea" "$excedido"
}

# Cuota del plan, leída en vivo con `claude -p "/usage"` (DEVKIT-62). La
# compuerta de la card probó que sí existe una fuente oficial legible por
# script: la CLI responde con el mismo texto que `/usage` en una sesión
# interactiva, como comando local que no gasta turnos ni cuota
# (`duration_api_ms=0`, `total_cost_usd=0`). No hay campo numérico
# estructurado para el porcentaje, así que se extrae del texto con una
# expresión regular sobre sus dos líneas fijas. Aislada igual que
# `modelo_disponible` (directorio vacío, sin MCP): --estado no necesita
# heredar el contexto de /workspace para esta lectura.
leer_cuota() {  # leer_cuota -> "sesion_pct<TAB>sesion_reset<TAB>semana_pct<TAB>semana_reset"
  local vacio salida texto linea_sesion linea_semana sesion_pct sesion_reset semana_pct semana_reset
  vacio=$(mktemp -d)
  # --no-session-persistence (H2 de pr-review en DEVKIT-62): sin ella, cada
  # lectura deja una sesión de Claude Code en ~/.claude/projects/, que con
  # --estado --seguir son miles por hora y además inflan las cifras de
  # sesiones/requests que el propio /usage reporta.
  salida=$(cd "$vacio" && timeout "$CUOTA_TIMEOUT" "$CLAUDE_BIN" -p "/usage" --output-format json \
      --no-session-persistence \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' </dev/null 2>/dev/null)
  rm -rf "$vacio"
  texto=$(printf '%s' "$salida" | jq -r '.result // empty' 2>/dev/null)
  [ -n "$texto" ] || return 1
  linea_sesion=$(printf '%s\n' "$texto" | grep -E '^Current session: [0-9]+% used')
  linea_semana=$(printf '%s\n' "$texto" | grep -E '^Current week \(all models\): [0-9]+% used')
  [ -n "$linea_sesion" ] && [ -n "$linea_semana" ] || return 1
  sesion_pct=$(printf '%s' "$linea_sesion" | grep -oE '[0-9]+' | head -1)
  sesion_reset=$(printf '%s' "$linea_sesion" | sed -E 's/^Current session: [0-9]+% used · resets //')
  semana_pct=$(printf '%s' "$linea_semana" | grep -oE '[0-9]+' | head -1)
  semana_reset=$(printf '%s' "$linea_semana" | sed -E 's/^Current week \(all models\): [0-9]+% used · resets //')
  printf '%s\t%s\t%s\t%s' "$sesion_pct" "$sesion_reset" "$semana_pct" "$semana_reset"
}

# Refresca CUOTA_CACHE en segundo plano, sin bloquear a quien la llamó (H1 de
# pr-review en DEVKIT-62). El candado evita dos refrescos a la vez: si uno ya
# está en curso, este no espera ni relanza, simplemente no hace nada.
# La subshell cierra sus descriptores de entrada/salida (H3 de pr-review): si
# no, hereda los del llamador y quien lea `--estado` por pipe o `$(...)`
# queda atado a que termine el refresco, justo lo que H1 evitaba.
refrescar_cuota_bg() {
  (
    mkdir -p "$(dirname "$CUOTA_CACHE")" 2>/dev/null
    exec 8>"$CUOTA_LOCK"
    flock -n 8 || exit 0
    local cuota
    if cuota=$(leer_cuota); then
      printf '%s\tok\t%s\n' "$(date +%s)" "$cuota" >"$CUOTA_CACHE.tmp" && mv -f "$CUOTA_CACHE.tmp" "$CUOTA_CACHE"
    else
      printf '%s\tfail\n' "$(date +%s)" >"$CUOTA_CACHE.tmp" && mv -f "$CUOTA_CACHE.tmp" "$CUOTA_CACHE"
    fi
  ) </dev/null >/dev/null 2>&1 &
}

# Bloque `Consumo` de `--estado`: porcentaje de cuota en vivo, con la hora de
# la lectura (DEVKIT-62). `claude -p "/usage"` tarda ~1.3 s; en vez de
# esperarlo en línea, se muestra la última lectura de CUOTA_CACHE (si hay) y
# se refresca en segundo plano cuando vence CUOTA_TTL o cuando no hay ninguna
# todavía. Así `--estado` nunca queda atado a esa lectura (H1 de pr-review).
mostrar_consumo() {
  local ts estado sesion_pct sesion_reset semana_pct semana_reset edad
  if [ -s "$CUOTA_CACHE" ]; then
    IFS=$'\t' read -r ts estado sesion_pct sesion_reset semana_pct semana_reset <"$CUOTA_CACHE"
    edad=$(( $(date +%s) - ts ))
    if [ "$estado" = ok ]; then
      printf '\nConsumo (cuota oficial, leída %s)\n' "$(date -d "@$ts" +%T 2>/dev/null || date -r "$ts" +%T)"
      printf '  sesión: %s%% usada, reinicia %s\n' "$sesion_pct" "$sesion_reset"
      printf '  semana: %s%% usada, reinicia %s\n' "$semana_pct" "$semana_reset"
    else
      printf '\nConsumo: no se pudo leer la cuota oficial con `claude -p "/usage"` ahora\n'
    fi
    [ "$edad" -lt "$CUOTA_TTL" ] || refrescar_cuota_bg
  else
    printf '\nConsumo: todavía no hay una lectura de la cuota oficial, refrescando en segundo plano\n'
    refrescar_cuota_bg
  fi
}

# Código del proyecto activo, para `notion.sh bloqueos <código>`. Se relee
# cada vez: un proyecto nuevo arranca con `project = "PROJ"` en
# `.devkit/devkit.toml` y `project-init` lo corrige después, sin que haya que
# reiniciar el contenedor (mismo criterio que `project_code` en watch.sh).
project_code() {
  [ -f "$WS/.devkit/devkit.toml" ] || return 0
  sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/.devkit/devkit.toml" | head -1
}

# Refresca BLOQUEOS_CACHE en segundo plano, mismo patrón que
# `refrescar_cuota_bg`: `notion.sh bloqueos` es una llamada a la red, y
# `--estado` no la espera en línea.
refrescar_bloqueos_bg() {
  (
    mkdir -p "$(dirname "$BLOQUEOS_CACHE")" 2>/dev/null
    exec 8>"$BLOQUEOS_LOCK"
    flock -n 8 || exit 0
    local codigo bloqueos
    codigo=$(project_code)
    if [ -n "$codigo" ] && bloqueos=$("$NOTION_BIN" bloqueos "$codigo" 2>/dev/null); then
      printf '%s\t%s\n' "$(date +%s)" "$bloqueos" >"$BLOQUEOS_CACHE.tmp" && mv -f "$BLOQUEOS_CACHE.tmp" "$BLOQUEOS_CACHE"
    fi
  ) </dev/null >/dev/null 2>&1 &
}

# "bloquea a: <Claves>" para una fila de `--estado` cuya Clave frena a otras
# (ampliación de DEVKIT-63): vacío si no hay caché todavía, si no frena a
# nadie, o si la Clave de la fila ni siquiera aparece (no está Lista para
# merge). El refresco en segundo plano corre una sola vez por TTL, no por
# fila: `mostrar_estado` llama esta función varias veces por vuelta y todas
# comparten la misma caché.
bloquea_a() {  # bloquea_a <Clave>
  local ts bloqueos edad lista
  [ -s "$BLOQUEOS_CACHE" ] || { refrescar_bloqueos_bg; return 0; }
  IFS=$'\t' read -r ts bloqueos <"$BLOQUEOS_CACHE"
  edad=$(( $(date +%s) - ts ))
  [ "$edad" -lt "$BLOQUEOS_TTL" ] || refrescar_bloqueos_bg
  lista=$(jq -r --arg c "$1" '.[] | select(.clave == $c) | .bloquea_a | join(", ")' <<<"$bloqueos" 2>/dev/null)
  [ -n "$lista" ] && printf 'bloquea a: %s' "$lista"
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
        "$(date +%FT%T%:z)" "$prompt" "$((waited / 60))" "$SKILL_TIMEOUT" >> "$WATCH_LOG"
      alarmed=1
    fi
  done
}

# ¿El `result` de una skill es una pregunta abierta al humano, que nadie va a
# contestar en modo headless? La forma original (DEVKIT-50) solo miraba si el
# texto terminaba en "?". DEVKIT-77 mostró un cierre real que no la cumplía:
# "¿Cómo quieres que siga? Opciones: 1. [...] 2. [...] 3. [...] antes de
# decidir.", una pregunta con opciones que el agente cierra con una frase que
# no termina en "?". Puro, para poder probarlo con el texto real del
# incidente sin lanzar nada.
pregunta_abierta() {  # pregunta_abierta <resultado>
  local resultado=$1 parrafo
  # Regla original: el texto entero termina en pregunta.
  printf '%s' "$resultado" | grep -qE '\?[[:space:]]*$' && return 0
  # Último párrafo (el texto tras la última línea en blanco, o todo el
  # resultado si no hay ninguna): ahí es donde el agente suele dejar la
  # pregunta, aunque después la explique o la cierre sin "?".
  parrafo=$(printf '%s' "$resultado" | awk 'BEGIN{RS=""} {p=$0} END{print p}')
  [ -n "$parrafo" ] || parrafo=$resultado
  # Una línea que empieza por "¿" en ese párrafo.
  printf '%s\n' "$parrafo" | grep -qE '^¿' && return 0
  # Frases fijas del incidente, en cualquier parte del párrafo.
  printf '%s' "$parrafo" | grep -qiE '¿Cómo quieres que siga|¿Qué prefieres' && return 0
  # "Opciones:" seguida de líneas numeradas.
  printf '%s\n' "$parrafo" | grep -qE '^Opciones:' \
    && printf '%s\n' "$parrafo" | grep -qE '^[0-9]+\.' && return 0
  return 1
}

# Barrera mecánica de DEVKIT-50 sobre la regla de cierre de DEVKIT-44: un
# `result` que termina en pregunta es una card `En progreso` cortando en seco
# en vez de resolver en un estado observable (AGENTS.md), y DEVKIT-48 mostró
# que la regla escrita en las skills no basta. En vez de dejarla colgada, el
# lanzador mismo bloquea la card con un motivo forzado. Desde DEVKIT-55 el
# bloqueo es `task-block.sh`, bash contra la API de Notion: no gasta modelo
# y no puede, a su vez, terminar en pregunta, así que ya no hace falta
# excluir a nadie para evitar un bucle.
forzar_task_block() {  # forzar_task_block <prompt> <logf> <motivo>
  local prompt=$1 logf=$2 motivo skill clave
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  [ -n "$clave" ] || return 0
  motivo="devkit-run: $skill $3; ver $logf"
  printf '%s devkit-run "%s" bloquea la card con task-block.sh: %s\n' "$(date +%FT%T%:z)" "$prompt" "$clave" >> "$WATCH_LOG"
  "$TASK_BLOCK_BIN" "$clave" "$motivo" >>"$WATCH_LOG" 2>&1
}

# ¿El `claude -p` terminó sin acceso a Notion? (DEVKIT-65). Solo bloquea la
# card el campo estructurado `permission_denials` del evento `result`, cuando
# lista una herramienta de Notion que la CLI negó: es un hecho, no una frase.
notion_denegado() {  # notion_denegado <logf>
  tail -1 "$1" 2>/dev/null \
    | jq -e '[.permission_denials[]?.tool_name // ""] | map(test("mcp__.*notion"; "i")) | any' \
      >/dev/null 2>&1
}

# Respaldo por si la CLI no anota la negación: la frase del agente. Solo deja
# una ALARMA, no bloquea (H13 de pr-review): un `result` que resume este mismo
# mecanismo, como `task-fix-46-ce49aa6.log`, que terminó bien, dice las mismas
# frases, y esa clase de falso positivo no se agota sumando negativos.
# H14: sobre el `result` crudo, sin quitar comillas ni backticks, porque el
# agente suele escribir entre backticks el nombre del plugin o la herramienta.
result_sin_notion() {  # result_sin_notion <logf>
  tail -1 "$1" 2>/dev/null | jq -r '.result // ""' 2>/dev/null | tr '\n' ' ' | grep -qiE \
    'notion[^.]{0,80}(no tiene permiso|no tengo acceso|sin acceso|no (tengo|estoy|están?) autorizad[oa]s?)|(no tiene permiso|no tengo acceso|sin acceso)[^.]{0,40}notion|(autoriza[rd][a-z]*|autorizad[oa]s?)[^.]{0,20}mcp__[a-z_]*notion'
}

# Modelo vacío: la CLI rechaza `--model ""` con un 400 en el primer turno y el
# lanzamiento muere sin hacer nada (DEVKIT-55, `task-start-4.log`). Mejor no
# lanzar y decirlo: motivo por stderr, ALARMA en watch.log y código falso.
modelo_valido() {  # modelo_valido <modelo> <prompt>
  case "$1" in ''|-) ;; *) return 0 ;; esac
  printf 'devkit-run: no se pudo resolver un modelo para "%s" (roles.toml: %s); no se lanza. Revisa `frontera` y el rol.\n' \
    "$2" "$ROLES_FILE" >&2
  printf '%s devkit-run "%s" ALARMA: modelo vacío al resolver el rol (roles.toml: %s); no se lanza\n' \
    "$(date +%FT%T%:z)" "$2" "$ROLES_FILE" >> "$WATCH_LOG" 2>/dev/null
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

# El propio `claude -p` de quien llama, entre sus ancestros (DEVKIT-77):
# descarta `devkit-run.sh` y se queda con `claude ... -p <prompt> ...`, igual
# que la variante con banderas después del prompt de `filtrar_agentes` (no la
# variante sin espacio final, `*claude*" -p"`, porque `run_claude` siempre
# pasa el prompt después de `-p`), pero sobre la ascendencia propia en vez del
# `ps` completo, y devuelve el primero que encuentra en vez de filtrarlos
# todos. Puro, para probarlo con una tabla fija: recibe "<pid> <args>" por
# línea.
propio_de() {
  local pid args prompt
  while read -r pid args; do
    [ -n "$pid" ] || continue
    case "$args" in *devkit-run.sh*) continue ;; esac
    case "$args" in
      *claude*" -p "*)
        # Solo el argumento de `-p` (el prompt), sin las banderas que siguen
        # (`--model`, `--effort`, ...): así se lee de un vistazo.
        prompt=$(printf '%s' "$args" | sed -E 's/^.*-p ([^-].*)$/\1/; s/ --.*$//')
        printf '%s claude -p "%s"' "$pid" "$prompt"
        return 0 ;;
    esac
  done
  return 1
}

# Imprime un proceso ajeno por línea. Sale 0 si el workspace está libre y 1 si
# lo ocupa otro agente, para usarlo directo en un `if`. Antes de esa lista,
# si corre dentro de un agente, imprime `propio: <pid> claude -p "<prompt>"`
# (DEVKIT-77): así el agente ve su propio proceso ya identificado -el mismo
# que le hace desconfiar y correr su propio `ps`, como en DEVKIT-63- en vez
# de tener que buscarlo aparte.
otros_agentes() {
  local encontrados propio
  encontrados=$(ps -eo pid=,args= 2>/dev/null | filtrar_agentes "$(ancestros_propios)")
  if propio=$(
    for pid in $(ancestros_propios); do
      printf '%s %s\n' "$pid" "$(ps -o args= -p "$pid" 2>/dev/null)"
    done | propio_de
  ); then
    printf 'propio: %s\n' "$propio"
  fi
  [ -z "$encontrados" ] && return 0
  printf '%s\n' "$encontrados"
  return 1
}

# --- Quién lanzó, arranque y estado de los lanzamientos (DEVKIT-57) ---------
#
# Cada lanzamiento deja en watch.log una línea con forma fija:
#   <fecha> <id> lanzando (origen=<origen>): "<prompt>" log=<log>
# donde <id> es el nombre del log sin `.log` (`task-start-3`,
# `pr-review-41-4391e46`). La escriben este script, antes del `nohup`, y
# `run_skill` en watch.sh, antes de tomar el candado. `--estado` parte de esas
# líneas y no de los procesos: un lanzamiento existe desde que se pidió, no
# desde que su `claude -p` aparece en `ps`.

# Origen de un lanzamiento: `humano`, `bucle`, `task-close` o la skill que lo
# pidió (`epic-plan`). Quien llama puede declararlo con DEVKIT_ORIGEN:
# watch.sh pone `bucle` y task-close.sh pone `task-close`. Si no viene, se
# busca entre los ancestros el primer `claude -p /<skill>`: epic-plan llama a
# devkit-run desde su herramienta Bash, así que su `claude -p` es ancestro.
# Sin ninguno de los dos, lo lanzó un humano desde la terminal.
#
# Filtrado puro, como filtrar_agentes: lee "<pid> <args>" de los ancestros,
# del más cercano al más lejano.
origen_de() {
  local pid args skill
  while read -r pid args; do
    case "$args" in *devkit-run.sh*) continue ;; *claude*) ;; *) continue ;; esac
    skill=$(printf '%s' "$args" | grep -oE '(^| )-p /[a-zA-Z-]+' | head -1 | sed -E 's#.*-p /##')
    if [ -n "$skill" ]; then
      printf '%s' "$skill"
      return 0
    fi
  done
  printf 'humano'
}

origen_lanzamiento() {
  if [ -n "${DEVKIT_ORIGEN:-}" ]; then
    printf '%s' "$DEVKIT_ORIGEN"
    return 0
  fi
  local pid
  for pid in $(ancestros_propios); do
    printf '%s %s\n' "$pid" "$(ps -o args= -p "$pid" 2>/dev/null)"
  done | origen_de
}

# El prompt en una sola línea, sin comillas y corto: un task-fix con el
# comentario del humano trae saltos de línea que romperían la forma fija.
prompt_en_linea() {  # prompt_en_linea <prompt>
  local p
  p=$(printf '%s' "$1" | tr '\n"' '  ')
  printf '%s' "${p:0:120}"
}

linea_lanzando() {  # linea_lanzando <id> <origen> <prompt> <log>
  printf '%s %s lanzando (origen=%s): "%s" log=%s\n' \
    "$(date +%FT%T%:z)" "$1" "$2" "$(prompt_en_linea "$3")" "$4"
}

# Espera el marcador de fin de arranque. Sin él, el contenedor todavía está
# leyendo secretos o clonando, y un `claude -p` lanzado en ese rato puede
# morir sin token ni rastro: el caso de origen de DEVKIT-57.
esperar_arranque() {  # esperar_arranque <prompt>
  [ -e "$READY_FILE" ] && return 0
  local t=0
  printf 'devkit-run: esperando a que termine el arranque del contenedor' >&2
  while [ ! -e "$READY_FILE" ] && [ "$t" -lt "$READY_TIMEOUT" ]; do
    sleep 1
    t=$((t + 1))
    printf '.' >&2
  done
  printf '\n' >&2
  [ -e "$READY_FILE" ] && return 0
  printf 'devkit-run: el arranque del contenedor no terminó en %ss (falta %s); no se lanza "%s".\n' \
    "$READY_TIMEOUT" "$READY_FILE" "$1" >&2
  printf 'Mira qué pasó con `devkit logs <proyecto>` desde el host y vuelve a lanzar cuando termine.\n' >&2
  printf '%s devkit-run "%s" ALARMA: arranque del contenedor sin terminar tras %ss; no se lanza\n' \
    "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" "$READY_TIMEOUT" >> "$WATCH_LOG" 2>/dev/null
  return 1
}

# Ampliación de DEVKIT-63: en modo dev, `devkit-run` lee `roles.toml` y este
# mismo archivo del workspace en el instante del lanzamiento, no de la imagen.
# Tras el merge de DEVKIT-61 (22:19 del 2026-09-16) el workspace seguía en el
# `main` que había clonado el `recreate` anterior -la Limpieza local de
# `task-close.sh` no lo actualizó, ver el comentario junto a `no_limpia` en
# task-close.sh-, y un lanzamiento manual a las 22:50 salió sin la escalera de
# modelos aunque `origin/main` ya la tenía. Este aviso no arregla eso: solo lo
# hace observable antes de resolver el modelo, cuando todavía se puede parar.
avisar_atras_de_origin() {  # avisar_atras_de_origin <prompt>
  local atras
  if ! timeout 5 git -C "$WS" fetch -q origin main 2>/dev/null; then
    printf 'devkit-run: no se pudo comprobar si el workspace está detrás de origin/main (git fetch falló).\n' >&2
    return 0
  fi
  atras=$(git -C "$WS" rev-list --count main..origin/main 2>/dev/null) || return 0
  case "$atras" in ''|0) return 0 ;; esac
  printf 'devkit-run: el workspace está %s commit(s) detrás de origin/main; puede estar lanzando con código viejo (git switch main && git pull --ff-only).\n' \
    "$atras" >&2
  printf '%s devkit-run "%s" ALARMA: workspace %s commit(s) detrás de origin/main; puede lanzar con código viejo\n' \
    "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" "$atras" >> "$WATCH_LOG" 2>/dev/null
}

# Confirma que el lanzamiento en segundo plano arrancó. Espera hasta
# ARRANQUE_ESPERA segundos mirando al worker; si sigue vivo, arrancó (corre
# su `claude -p` o espera el candado). Si murió, solo vale como arranque si
# dejó su resumen "terminado" en watch.log: una skill muy corta. En otro
# caso imprime el final del log y las alarmas, y devuelve falso.
confirmar_arranque() {  # confirmar_arranque <pid del worker> <prompt> <log>
  local pid=$1 prompt=$2 logf=$3 id t=0 pasos claude_pid alarmas
  id=$(basename "$logf" .log)
  pasos=$((ARRANQUE_ESPERA * 5))
  while [ "$t" -lt "$pasos" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    t=$((t + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    claude_pid=$(ps -eo pid=,args= 2>/dev/null | grep -F -- "-p $prompt" \
      | grep -v -e 'devkit-run.sh' -e 'grep' | awk 'NR == 1 {print $1}')
    if [ -n "$claude_pid" ]; then
      echo "arrancó: claude -p vivo (pid $claude_pid)"
    else
      echo "arrancó: el worker (pid $pid) espera el candado; síguelo con devkit-run --estado"
    fi
    return 0
  fi
  if grep -qF "terminado [$id]:" "$WATCH_LOG" 2>/dev/null; then
    echo "arrancó y ya terminó; resumen en $WATCH_LOG"
    return 0
  fi
  {
    printf 'devkit-run: "%s" no arrancó: el worker murió en sus primeros %ss sin terminar.\n' "$prompt" "$ARRANQUE_ESPERA"
    printf 'Últimas líneas de %s:\n' "$logf"
    if [ -s "$logf" ]; then
      tail -n 20 "$logf" | sed 's/^/  /'
    else
      echo "  (log vacío: claude -p no llegó a escribir)"
    fi
    alarmas=$(grep -F "\"$(prompt_en_linea "$prompt")\"" "$WATCH_LOG" 2>/dev/null | grep 'ALARMA' | tail -3)
    if [ -n "$alarmas" ]; then
      echo "Alarmas en $WATCH_LOG:"
      printf '%s\n' "$alarmas" | sed 's/^/  /'
    fi
  } >&2
  # H5 de pr-review (DEVKIT-65): sin Notion conectada, `alarma_sin_notion` (en
  # `run_claude`) ya dejó la alarma específica del caso; sin este `if`, esto
  # sumaba una segunda "ALARMA: no arrancó" genérica y menos precisa por el
  # mismo evento (rc=67, candado ya liberado).
  if ! grep -qE "falló \(rc=67\) \[$id\]:" "$WATCH_LOG" 2>/dev/null; then
    printf '%s devkit-run "%s" ALARMA: no arrancó; el worker murió en %ss sin resumen [%s]\n' \
      "$(date +%FT%T%:z)" "$(prompt_en_linea "$prompt")" "$ARRANQUE_ESPERA" "$id" >> "$WATCH_LOG" 2>/dev/null
  fi
  return 1
}

# Lanzamientos registrados en watch.log, uno por línea "lanzando", en TSV:
# <n.º de línea> <fecha> <id> <origen> <prompt> <log>.
lanzamientos() {  # lanzamientos <watch.log>
  grep -nE '^[^ ]+ [^ ]+ lanzando \(origen=[^)]*\): ".*" log=[^ ]+$' "$1" 2>/dev/null \
    | sed -E 's/^([0-9]+):([^ ]+) ([^ ]+) lanzando \(origen=([^)]*)\): "(.*)" log=([^ ]+)$/\1\t\2\t\3\t\4\t\5\t\6/'
}

hace() {  # hace <segundos>
  local s=$1
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%sh%02dm' "$((s / 3600))" "$((s % 3600 / 60))"
  else printf '%sd' "$((s / 86400))"
  fi
}

# Una fila TSV por lanzamiento: skill, card, origen, hace cuánto, estado y
# detalle. Estados:
#   en curso    sin resumen, y su proceso vive, o se lanzó hace menos de
#               ESTADO_GRACIA segundos, o espera el candado
#   terminó     resumen "terminado"
#   error       resumen con rc distinto de cero, o log escrito sin resumen
#               y sin proceso (murió a medias)
#   bloqueada   terminó o falló, y task-block.sh bloqueó su card después de
#               lanzarlo; el detalle es el motivo
#   no arrancó  sin resumen, sin proceso y sin log pasado el margen, o
#               marcado así por confirmar_arranque
# Lee `ps` de PS_BIN y la hora de <ahora>, para probarlo con datos fijos.
estado_filas() {  # estado_filas <watch.log> <ahora epoch>
  local wlog=$1 ahora=$2 procesos candado=libre
  procesos=$("$PS_BIN" -eo pid=,args= 2>/dev/null)
  # Lectura, no escritura: abrir el candado con `>` le cambiaría el mtime,
  # que watch.sh usa como señal de actividad para la alarma de rama huérfana.
  if [ -e "$LOCK" ] && exec 7<"$LOCK"; then
    flock -n 7 || candado=ocupado
    exec 7<&-
  fi
  local ln ts id origen prompt logf skill arg clave t0 edad resto fin estado detalle bloqueo
  while IFS=$'\t' read -r ln ts id origen prompt logf <&3; do
    skill=${prompt%% *}
    skill=${skill#/}
    arg=$(printf '%s' "$prompt" | awk '{print $2}')
    clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
    # pr-review recibe el número de PR, no la Clave: se toma de la línea
    # "PR #<n> (<Clave>)" que el bucle escribe antes de lanzarlo.
    if [ -z "$clave" ] && [ -n "$arg" ]; then
      clave=$(head -n "$ln" "$wlog" | grep -oE "PR #$arg \([A-Z][A-Z0-9]+-[0-9]+\)" | tail -1 \
        | grep -oE '[A-Z][A-Z0-9]+-[0-9]+')
    fi
    t0=$(date -d "$ts" +%s 2>/dev/null || echo "$ahora")
    edad=$((ahora - t0))
    resto=$(tail -n +"$((ln + 1))" "$wlog")
    fin=$(printf '%s\n' "$resto" | grep -m1 -E \
      "^[^ ]+ ($id terminado: |ALARMA: $id terminó con error \(rc=[0-9]+\)|devkit-run \".*\" (terminado|falló \(rc=[0-9]+\)) \[$id\]:|devkit-run \".*\" ALARMA: no arrancó.*\[$id\]$)")
    estado="" detalle=""
    if [ -n "$fin" ]; then
      case "$fin" in
        *"ALARMA: no arrancó"*) estado="no arrancó"; detalle="el worker murió al arrancar; ver $logf" ;;
        *"terminó con error"*|*"falló (rc="*)
          estado=error
          detalle="$(printf '%s' "$fin" | grep -oE 'rc=[0-9]+' | head -1); ver $logf" ;;
        *) estado=terminó ;;
      esac
    elif grep -qF -- "$logf" <<<"$procesos" \
         || { [ "$origen" = bucle ] && grep -qF -- "--sync /$skill $arg" <<<"$procesos"; }; then
      estado="en curso"
    elif [ "$edad" -lt "$ESTADO_GRACIA" ]; then
      estado="en curso"; detalle="arrancando"
    elif [ "$candado" = ocupado ] && printf '%s\n' "$resto" | grep -qE "^[^ ]+ $id espera: "; then
      estado="en curso"; detalle="espera el candado"
    elif [ -s "$logf" ]; then
      estado=error; detalle="murió sin resumen; ver $logf"
    else
      estado="no arrancó"; detalle="sin proceso, log ni resumen tras $(hace "$edad")"
    fi
    # Bloqueo de la card después del lanzamiento y antes de que otro
    # lanzamiento de la misma card tome el relevo. La Clave va seguida de un
    # espacio o de la comilla final del prompt: así DEVKIT-57 no pasa por
    # DEVKIT-5.
    if [ -n "$clave" ] && [ "$estado" != "en curso" ]; then
      bloqueo=$(printf '%s\n' "$resto" | awk -v c="$clave" '
        / lanzando \(origen=/ && index($0, "\"/") && (index($0, " " c " ") || index($0, " " c "\"")) { exit }
        index($0, " task-block.sh " c " Bloqueada") { print; exit }')
      if [ -n "$bloqueo" ]; then
        estado=bloqueada
        detalle=$(printf '%s' "$bloqueo" | sed -E 's/^.* task-block\.sh [^ ]+ Bloqueada desde [^:]*: //')
        detalle=${detalle:0:100}
      fi
    fi
    # Respaldo de DEVKIT-77: un `task-start` que "terminó" bien según la
    # línea de resumen, pero dejó su card `En progreso` sin PR y sin
    # bloquear, no es un avance real (DEVKIT-63). Mismo corte por el
    # siguiente lanzamiento de la misma Clave que usa `bloqueo`, para no
    # confundir esta alarma con la de un lanzamiento posterior.
    if [ "$skill" = task-start ] && [ "$estado" = terminó ] && [ -n "$clave" ] \
       && printf '%s\n' "$resto" | awk -v c="$clave" '
            / lanzando \(origen=/ && index($0, "\"/") && (index($0, " " c " ") || index($0, " " c "\"")) { found=0; exit }
            index($0, "ALARMA: terminó sin entregar ni bloquear (" c "):") { found=1; exit }
            END { exit (found ? 0 : 1) }'; then
      estado=error
      detalle="terminó sin entregar ni bloquear; card $clave sigue En progreso"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$skill" "${clave:--}" "$origen" "$(hace "$edad")" "$estado" "${detalle:--}"
  done 3< <(lanzamientos "$wlog" | tail -n "$ESTADO_FILAS")
}

# Conteo rápido de "en curso" para el segmento `agentes:<a>` del prompt
# (DEVKIT-63): mismo criterio que `estado_filas`, en una sola pasada del log
# y con bash builtins en vez de un `grep`/`date`/`tail` por fila -con unos 15
# lanzamientos, `estado_filas` completo mide sobre 90 ms (`starship timings`),
# muy por encima del presupuesto de 50 ms por módulo del prompt. La única
# diferencia a propósito: un `--sync` anidado del bucle (un `claude -p`
# lanzado dentro de otro, caso raro) cuenta como "en curso" recién cuando
# aparece en `ps` con la ruta de su log, no antes; `estado_filas` también lo
# detecta por su patrón `--sync /<skill> <arg>` en la lista de procesos. Ver
# docs/ARCHITECTURE.md 4.4.
agentes_en_curso_rapido() {  # agentes_en_curso_rapido <watch.log> <ahora epoch>
  local wlog=$1 ahora=$2 procesos lanz ids candado=libre en_curso=0
  local -A done_ids
  procesos=$("$PS_BIN" -eo args= 2>/dev/null)
  lanz=$(lanzamientos "$wlog" | tail -n "$ESTADO_FILAS")
  [ -n "$lanz" ] || { echo 0; return 0; }
  ids=$(printf '%s\n' "$lanz" | cut -f3 | paste -sd'|' -)
  if [ -n "$ids" ]; then
    while IFS= read -r d; do [ -n "$d" ] && done_ids[$d]=1; done < <(
      grep -oE "($ids) terminado: |ALARMA: ($ids) terminó con error \(rc=[0-9]+\)|devkit-run \".*\" (terminado|falló \(rc=[0-9]+\)) \[($ids)\]:|devkit-run \".*\" ALARMA: no arrancó.*\[($ids)\]\$" \
        "$wlog" 2>/dev/null | grep -oE -- "$ids")
  fi
  if [ -e "$LOCK" ] && exec 7<"$LOCK"; then
    flock -n 7 || candado=ocupado
    exec 7<&-
  fi
  local ln ts id origen prompt logf t0 edad
  while IFS=$'\t' read -r ln ts id origen prompt logf; do
    [ -n "${done_ids[$id]:-}" ] && continue
    if [[ $procesos == *"$logf"* ]]; then
      en_curso=$((en_curso + 1)); continue
    fi
    t0=$(date -d "$ts" +%s 2>/dev/null || echo "$ahora")
    edad=$((ahora - t0))
    if [ "$edad" -lt "$ESTADO_GRACIA" ]; then
      en_curso=$((en_curso + 1)); continue
    fi
    if [ "$candado" = ocupado ] && grep -qE "^[^ ]+ $id espera: " "$wlog" 2>/dev/null; then
      en_curso=$((en_curso + 1))
    fi
  done <<<"$lanz"
  echo "$en_curso"
}

# Rellena a <n> caracteres. `printf %-Ns` cuenta bytes, y "terminó" o
# "no arrancó" desalinearían la tabla.
rellenar() {  # rellenar <texto> <ancho>
  local s=$1 n=$2
  printf '%s%*s' "$s" "$(( n > ${#s} ? n - ${#s} : 0 ))" ''
}

mostrar_estado() {
  local filas skill clave origen edad estado detalle
  filas=$(estado_filas "$WATCH_LOG" "${DEVKIT_AHORA:-$(date +%s)}")
  if [ -z "$filas" ]; then
    echo "sin lanzamientos registrados en $WATCH_LOG"
  else
    printf '%s%s%s%s%s%s\n' "$(rellenar SKILL 15)" "$(rellenar CARD 12)" "$(rellenar LANZÓ 12)" \
      "$(rellenar HACE 8)" "$(rellenar ESTADO 12)" DETALLE
    local frena
    while IFS=$'\t' read -r skill clave origen edad estado detalle; do
      frena=""
      [ "$clave" = - ] || frena=$(bloquea_a "$clave")
      if [ -n "$frena" ]; then
        [ "$detalle" = - ] && detalle=$frena || detalle="$detalle; $frena"
      fi
      printf '%s%s%s%s%s%s\n' "$(rellenar "$skill" 15)" "$(rellenar "$clave" 12)" "$(rellenar "$origen" 12)" \
        "$(rellenar "$edad" 8)" "$(rellenar "$estado" 12)" "$detalle"
    done <<<"$filas"
  fi
  mostrar_consumo
  mkdir -p "$(dirname "$ALARMAS_VISTAS")" 2>/dev/null
  wc -l <"$WATCH_LOG" 2>/dev/null >"$ALARMAS_VISTAS.tmp" && mv -f "$ALARMAS_VISTAS.tmp" "$ALARMAS_VISTAS" \
    || echo 0 >"$ALARMAS_VISTAS"
}

seguir_estado() {
  while true; do
    [ -t 1 ] && printf '\033[H\033[2J'
    printf 'devkit-run --estado  %s  (cada %ss; Ctrl-C para salir)\n\n' "$(date +%T)" "$ESTADO_INTERVALO"
    mostrar_estado
    [ -t 1 ] || echo
    sleep "$ESTADO_INTERVALO"
  done
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

  # Los dobles de `claude` de esta autoprueba no entienden `mcp list`
  # (DEVKIT-65): sin apagar la comprobación aquí, cada lanzamiento de abajo
  # la vería como "sin Notion" y no llegaría a correr. Los casos que sí
  # prueban la comprobación la reactivan a mano con DEVKIT_NOTION_CHECK=1.
  export DEVKIT_NOTION_CHECK=0

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
  # DEVKIT-77: `--otros-agentes` identifica su propio `claude -p` entre los
  # ancestros (37794), no el vigilante (37793, argumentos de devkit-run.sh) ni
  # el `claude -p` ajeno (40001, ni siquiera está en la lista de ancestros).
  check "concurrencia: identifica el propio claude -p entre los ancestros" \
    '37794 claude -p "/task-start DEVKIT-54"' \
    "$(printf '%s\n' "$tabla" | grep -E '^(37786|37792|37793|37794) ' | propio_de)"
  local propio_rc=0 propio_sin
  propio_sin=$(printf '%s\n' "$tabla" | grep -E '^(37786|37792|37793) ' | propio_de) || propio_rc=$?
  check "concurrencia: sin un claude -p propio entre los ancestros, no hay salida" "" "$propio_sin"
  check "concurrencia: sin un claude -p propio entre los ancestros, sale con error" 1 "$propio_rc"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Dobles de notion.sh y gh para la ronda (DEVKIT-61). Responden desde
  # $RONDA_DIR: `card-<Clave>.json`, `pr-view.json` (comentarios del PR) y
  # `pr-list.json`; sin archivo, fallan como un servicio caído. Se exportan
  # para que ningún lanzamiento de esta prueba (task-fix, task-document)
  # consulte la card real en Notion ni el PR real en GitHub.
  export RONDA_DIR="$tmp/ronda"
  mkdir -p "$RONDA_DIR"
  cat >"$tmp/notion-doble" <<'FIN'
#!/usr/bin/env bash
[ "$1" = card ] && cat "$RONDA_DIR/card-$2.json" 2>/dev/null
FIN
  cat >"$tmp/gh-doble" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RONDA_DIR/gh-llamadas"
case "$1 $2" in
  "pr view") cat "$RONDA_DIR/pr-view.json" 2>/dev/null ;;
  "pr list") cat "$RONDA_DIR/pr-list.json" 2>/dev/null ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$tmp/notion-doble" "$tmp/gh-doble"
  export DEVKIT_NOTION_BIN="$tmp/notion-doble" DEVKIT_GH_BIN="$tmp/gh-doble"
  NOTION_BIN="$tmp/notion-doble" GH_BIN="$tmp/gh-doble"

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
  check "ROLES_FILE por defecto cae al respaldo sin ../agents" "modelo-fuerte high 50 -" \
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

  check "modelo/esfuerzo de pr-review" "modelo-fuerte high 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-pr" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/pr-review 9')"
  check "modelo/esfuerzo de epic-plan (esfuerzo máximo por skill)" "modelo-fuerte max 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-epic" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/epic-plan DEVKIT-1')"
  check "modelo/esfuerzo de task-fix (rol implementación)" "modelo-barato low 15 1" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-fix" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/task-fix DEVKIT-2')"

  # --- Anulación de `model_index` por skill (DEVKIT-72) ---------------------
  # `epic-plan.model_index` anula `revision.model_index`, igual que ya hacía
  # `epic-plan.effort`: con la tabla real del template, pr-review sube al
  # segundo modelo de frontera (opus) y epic-plan se queda en el primero
  # (fable).
  cat >"$tmp/roles-anulacion-modelo.toml" <<'FIN'
frontera = ["fable", "opus", "sonnet"]
revision.model_index = 2
revision.effort = "high"
revision.max_turns = 50
epic-plan.model_index = 1
epic-plan.effort = "max"
FIN
  check "pr-review sube al segundo modelo de frontera (revision.model_index)" "opus high 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-anulacion-modelo.toml" FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/pr-review 9')"
  check "epic-plan anula model_index a 1: primer modelo de frontera" "fable max 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-anulacion-modelo.toml" FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/epic-plan DEVKIT-1')"
  # De punta a punta, no solo en `model_effort_of` aislado: el doble de
  # `claude` recibe de verdad `--model opus` para pr-review y `--model fable`
  # para epic-plan. La ruta del log queda fija en el script del doble, no en
  # una variable de entorno: `run_claude` lanza con `env -i` y una lista
  # blanca que no incluye variables de esta prueba.
  local registra
  registra="$tmp/claude-registra"
  cat >"$registra" <<FIN
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/claude-llamadas"
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$registra"
  : >"$tmp/claude-llamadas"
  DEVKIT_CLAUDE_BIN="$registra" DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" \
    DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --sync '/pr-review 9' >/dev/null 2>&1
  check "el claude -p de pr-review recibe --model opus" 1 \
    "$(grep -c -- '--model opus' "$tmp/claude-llamadas")"
  : >"$tmp/claude-llamadas"
  DEVKIT_CLAUDE_BIN="$registra" DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" \
    DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --sync '/epic-plan DEVKIT-1' >/dev/null 2>&1
  check "el claude -p de epic-plan recibe --model fable" 1 \
    "$(grep -c -- '--model fable' "$tmp/claude-llamadas")"

  # --- Escalera de modelos por ronda (DEVKIT-61) ----------------------------
  # Tres rondas con modelo y esfuerzo distintos, para que cada ronda se vea en
  # la salida. La ronda de task-fix es 1 más los comentarios devkit-fix del PR.
  cat >"$tmp/roles-rondas.toml" <<'FIN'
frontera = ["modelo-fuerte", "modelo-medio", "modelo-barato"]
implementacion.model_index = 2
implementacion.effort = "low"
implementacion.max_turns = 40
implementacion.rondas = ["modelo-barato:low", "modelo-medio:medium", "modelo-fuerte:high"]  # experimento
revision.model_index = 1
revision.effort = "high"
revision.max_turns = 50
revision.rondas = ["modelo-barato:low"]
FIN
  # prs_con <n>: el PR de la card trae n comentarios devkit-fix y uno ajeno.
  prs_con() {
    local i c='{"body":"<!-- devkit-review sha=a1 verdict=CAMBIOS -->"}'
    for ((i = 0; i < $1; i++)); do c="$c,{\"body\":\"<!-- devkit-fix sha=b$i review=a$i -->\\nH1 | atendido\"}"; done
    printf '{"comments":[%s]}' "$c" >"$RONDA_DIR/pr-view.json"
  }
  ronda_env() {  # ronda_env <función> <args...>, con la tabla de rondas
    CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-rondas.toml" FRONTERA_CACHE_DIR="$tmp/frontera-rondas" \
      WATCH_LOG="$tmp/rondas-watch.log" "$@"
  }
  printf '{"pr":"https://github.com/o/r/pull/7","rama":"https://github.com/o/r/tree/feat/DEVKIT-7-algo"}' \
    >"$RONDA_DIR/card-DEVKIT-7.json"
  : >"$tmp/rondas-watch.log"
  prs_con 0
  check "ronda 1: task-fix sin devkit-fix previos" "modelo-barato low 40 1" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  prs_con 1
  check "ronda 2: un devkit-fix previo" "modelo-medio medium 40 2" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  prs_con 2
  check "ronda 3: dos devkit-fix previos" "modelo-fuerte high 40 3" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  prs_con 3
  check "ronda 4 repite el último elemento de la lista" "modelo-fuerte high 40 4" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  check "task-document también cuenta la ronda" "modelo-fuerte high 40 4" \
    "$(ronda_env model_effort_of '/task-document DEVKIT-7 7')"
  : >"$RONDA_DIR/gh-llamadas"
  check "task-start es ronda 1 sin consultar el PR" "modelo-barato low 40 1 0" \
    "$(ronda_env model_effort_of '/task-start DEVKIT-7') $(wc -l <"$RONDA_DIR/gh-llamadas" | tr -d ' ')"
  check "task-submit es ronda 1" "modelo-barato low 40 1" \
    "$(ronda_env model_effort_of '/task-submit DEVKIT-7')"
  check "ronda ya resuelta: no consulta el PR" "modelo-medio medium 40 2 0" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7' 2) $(wc -l <"$RONDA_DIR/gh-llamadas" | tr -d ' ')"
  # Sin URL del PR en Notion: gh pr list --head <rama de la card>.
  printf '{"pr":null,"rama":"https://github.com/o/r/tree/feat/DEVKIT-8-otra"}' >"$RONDA_DIR/card-DEVKIT-8.json"
  printf '[{"number":8}]' >"$RONDA_DIR/pr-list.json"
  prs_con 1
  check "sin PR en Notion lo busca por la rama" "modelo-medio medium 40 2" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-8')"
  check "gh pr list recibe la rama de la card" "pr list --head feat/DEVKIT-8-otra --state all --limit 1 --json number" \
    "$(grep '^pr list' "$RONDA_DIR/gh-llamadas" | tail -1)"
  # PR ilegible: ronda 1 y la línea en watch.log.
  rm -f "$RONDA_DIR/pr-view.json"
  check "PR ilegible: ronda 1" "modelo-barato low 40 1" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  check "PR ilegible: lo dice en watch.log" "no pude leer los comentarios del PR https://github.com/o/r/pull/7 de DEVKIT-7; uso la ronda 1" \
    "$(grep -oE 'no pude leer los comentarios del PR .*' "$tmp/rondas-watch.log" | tail -1)"
  check "card sin PR ni rama: ronda 1 con aviso" "modelo-barato low 40 1 1" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-99') $(grep -c 'no encuentro el PR de DEVKIT-99' "$tmp/rondas-watch.log")"
  # El alias de la ronda pasa por la sonda: si no responde, model_index.
  mkdir -p "$tmp/frontera-rondas-caida"
  printf 'si' >"$tmp/frontera-rondas-caida/modelo-medio"
  printf 'no' >"$tmp/frontera-rondas-caida/modelo-fuerte"
  prs_con 2
  check "alias de la ronda caído: usa el de model_index" "modelo-medio high 40 3" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-rondas.toml" FRONTERA_CACHE_DIR="$tmp/frontera-rondas-caida" \
       WATCH_LOG="$tmp/rondas-watch.log" MODEL_RETRY=600 model_effort_of '/task-fix DEVKIT-7')"
  check "alias de la ronda caído: lo dice en watch.log" "ronda 3 pide modelo-fuerte, que no responde; uso modelo-medio (model_index del rol)" \
    "$(grep -oE 'ronda 3 pide modelo-fuerte.*' "$tmp/rondas-watch.log" | tail -1)"
  # El revisor no escala: revision.rondas se ignora con una línea.
  : >"$tmp/rondas-watch.log"
  check "revisión ignora sus rondas" "modelo-fuerte high 50 -" \
    "$(ronda_env model_effort_of '/pr-review 7')"
  printf 'epic-plan.effort = "max"\n' >>"$tmp/roles-rondas.toml"
  check "epic-plan ignora las rondas y sube a max" "modelo-fuerte max 50 -" \
    "$(ronda_env model_effort_of '/epic-plan DEVKIT-1')"
  check "revision.rondas ignorada queda en watch.log" 2 \
    "$(grep -c 'revision.rondas se ignora; el revisor no escala' "$tmp/rondas-watch.log")"
  # Sin rondas, model_index y effort del rol, como antes (tabla de arriba),
  # aunque el PR vaya por la ronda 3: la ronda solo queda anotada.
  check "sin rondas manda model_index" "modelo-barato low 15 3" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-fix" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/task-fix DEVKIT-7')"
  printf '{"result":"x","total_cost_usd":0.5,"num_turns":1}\n' >"$tmp/resumen-ronda.log"
  check "la línea de resumen lleva ronda= junto a modelo= y esfuerzo=" "modelo=modelo-fuerte esfuerzo=high ronda=3 costo=0.5" \
    "$(resumen "$tmp/resumen-ronda.log" modelo-fuerte high 99 3 | grep -oE '^modelo=[^ ]+ esfuerzo=[^ ]+ ronda=[^ ]+ costo=[0-9.]+')"
  check "--resumen por línea de comandos pasa la ronda (lo usa watch.sh)" "modelo=m esfuerzo=e ronda=2" \
    "$(bash "$HERE/devkit-run.sh" --resumen "$tmp/resumen-ronda.log" m e 99 2 | grep -oE '^modelo=[^ ]+ esfuerzo=[^ ]+ ronda=[^ ]+')"
  check "resumen sin ronda (watch.sh viejo) escribe ronda=-" "modelo=m esfuerzo=e ronda=-" \
    "$(resumen "$tmp/resumen-ronda.log" m e 99 | grep -oE '^modelo=[^ ]+ esfuerzo=[^ ]+ ronda=[^ ]+')"
  # --modelo y --esfuerzo mandan sobre la ronda, de punta a punta.
  mkdir -p "$tmp/run-rondas"
  : >"$tmp/run-rondas/ready"
  DEVKIT_ARRANQUE_ESPERA=1 DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run-rondas" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles-rondas.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-rondas" \
    bash "$HERE/devkit-run.sh" --modelo modelo-a-mano --esfuerzo max task-fix DEVKIT-7 >/dev/null 2>&1
  espera_linea() {  # espera_linea <archivo> <patrón>
    local e=0
    while ! grep -qE "$2" "$1" 2>/dev/null && [ "$e" -lt 50 ]; do sleep 0.1; e=$((e + 1)); done
  }
  espera_linea "$tmp/run-rondas/watch.log" 'terminado \['
  check "--modelo/--esfuerzo mandan sobre la ronda" "modelo=modelo-a-mano esfuerzo=max ronda=3" \
    "$(grep -oE 'modelo=modelo-a-mano esfuerzo=max ronda=[0-9-]+' "$tmp/run-rondas/watch.log" | head -1)"
  # DEVKIT_MODELO_FORZADO pisa el modelo de la ronda; el esfuerzo de la ronda
  # se mantiene.
  cat >"$tmp/claude-espejo-ronda" <<'FIN'
#!/usr/bin/env bash
case "$*" in *"-p ok"*) printf '{"result":"ok"}\n'; exit 0 ;; esac
printf '{"result":"%s %s","total_cost_usd":0,"num_turns":1}\n' "$DEVKIT_MODEL" "$DEVKIT_EFFORT"
FIN
  chmod +x "$tmp/claude-espejo-ronda"
  check "DEVKIT_MODELO_FORZADO manda sobre la ronda" '{"result":"modelo-forzado high","total_cost_usd":0,"num_turns":1}' \
    "$(DEVKIT_MODELO_FORZADO=modelo-forzado DEVKIT_CLAUDE_BIN="$tmp/claude-espejo-ronda" DEVKIT_RUN_DIR="$tmp/run-rondas" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles-rondas.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-rondas" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-7' 2>/dev/null | tail -1)"

  # --worker de punta a punta, con el mismo doble de arriba.
  mkdir -p "$tmp/run"
  # Arranque terminado y confirmación corta (DEVKIT-57): sin el marcador, cada
  # lanzamiento de abajo esperaría 120 s; con 5 s de confirmación, la cadena
  # epic-plan -> task-start no cabe en su tope de espera.
  : >"$tmp/run/ready"
  export DEVKIT_ARRANQUE_ESPERA=1
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

  # DEVKIT-77: `pregunta_abierta` reconoce más formas que "termina en ?". El
  # incidente real de DEVKIT-63 cerraba con "antes de decidir.", sin "?" al
  # final, y la regla original de DEVKIT-50 no lo veía.
  check "pregunta_abierta: regla original, termina en ?" si \
    "$(pregunta_abierta '¿qué credencial uso?' && echo si || echo no)"
  check "pregunta_abierta: un cierre normal no dispara la barrera" no \
    "$(pregunta_abierta 'Completé DEVKIT-40: cambios en el Dockerfile y el CHANGELOG. PR #25 abierto y en Revisión automática.' && echo si || echo no)"
  local resultado_linea resultado_frase resultado_opciones
  resultado_linea=$'Reuní el contexto necesario.\n\n¿Prefieres que continúe con el plan A o el plan B?\nDime cuál y sigo enseguida.'
  check "pregunta_abierta: línea que empieza por ¿ en el último párrafo, sin terminar en ?" si \
    "$(pregunta_abierta "$resultado_linea" && echo si || echo no)"
  resultado_frase="Terminé de revisar el conflicto. ¿Cómo quieres que siga? Antes de tocar nada, prefiero confirmarlo contigo."
  check "pregunta_abierta: frase fija ¿Cómo quieres que siga, sin terminar en ?" si \
    "$(pregunta_abierta "$resultado_frase" && echo si || echo no)"
  resultado_opciones=$'Quedan tres caminos posibles antes de seguir.\nOpciones:\n1. Seguir de todas formas\n2. Esperar al humano\n3. Bloquear la card\nAvísame antes de decidir.'
  check "pregunta_abierta: Opciones: con líneas numeradas, sin terminar en ?" si \
    "$(pregunta_abierta "$resultado_opciones" && echo si || echo no)"

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
  check "el motivo de la pregunta abierta la nombra" 'pregunta abierta' \
    "$(cut -d'|' -f2 "$tmp/bloqueo.args" 2>/dev/null | grep -oE 'pregunta abierta|sin acceso a Notion' | head -1)"

  # DEVKIT-77, extremo a extremo: el texto real del incidente de DEVKIT-63
  # ("¿Cómo quieres que siga? Opciones: 1. [...] 2. [...] 3. [...] antes de
  # decidir.") no termina en "?", y antes de esta card no bloqueaba la card.
  local pregunton_opciones
  pregunton_opciones="$tmp/claude-pregunton-opciones"
  cat >"$pregunton_opciones" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"Encontré un conflicto real de concurrencia con DEVKIT-63; el chequeo dio libre dos veces.\\n¿Cómo quieres que siga?\\nOpciones:\\n1. Seguir de todas formas\\n2. Esperar al humano\\n3. Bloquear la card\\nAvísame antes de decidir.","total_cost_usd":0.01,"num_turns":2}\n'
FIN
  chmod +x "$pregunton_opciones"
  rm -f "$tmp/bloqueo.args"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$pregunton_opciones" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/bloqueo.args" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "pregunta abierta sin '?' final (texto real de DEVKIT-63) también bloquea" \
    'bloquea la card con task-block.sh: DEVKIT-3' \
    "$(grep -oE 'bloquea la card con task-block.sh: DEVKIT-3' "$tmp/run/watch.log" | head -1)"

  # DEVKIT-77: `task_start_sin_entregar` usa el mismo doble de notion.sh
  # (`card <Clave>`) para decidir si un task-start dejó la card sin resolver.
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  check "task_start_sin_entregar: card sigue En progreso" si \
    "$(task_start_sin_entregar '/task-start DEVKIT-63' DEVKIT-63 && echo si || echo no)"
  printf '{"estado":"Revisión automática"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  check "task_start_sin_entregar: card ya en Revisión automática, no hay corte" no \
    "$(task_start_sin_entregar '/task-start DEVKIT-63' DEVKIT-63 && echo si || echo no)"
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  check "task_start_sin_entregar: solo aplica a task-start, no a task-fix" no \
    "$(task_start_sin_entregar '/task-fix DEVKIT-63' DEVKIT-63 && echo si || echo no)"

  # Extremo a extremo: un task-start "limpio" (sin pregunta abierta, con el
  # doble genérico "listo") que deja la card En progreso sin PR ni bloqueo
  # también deja su propia ALARMA en watch.log (DEVKIT-77).
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-63 >/dev/null 2>&1
  espera=0
  while ! grep -q 'ALARMA: terminó sin entregar ni bloquear (DEVKIT-63):' "$tmp/run/watch.log" 2>/dev/null \
        && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "task-start limpio pero sin entregar deja su propia ALARMA" \
    'ALARMA: terminó sin entregar ni bloquear (DEVKIT-63): card sigue En progreso, sin PR ni bloqueo' \
    "$(grep -oE 'ALARMA: terminó sin entregar ni bloquear \(DEVKIT-63\): card sigue En progreso, sin PR ni bloqueo' "$tmp/run/watch.log" | head -1)"

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

  # DEVKIT_MODEL y DEVKIT_EFFORT llegan al `claude -p` con lo que se lanzó de
  # verdad (DEVKIT-58), no con lo que traiga el entorno del lanzador: un
  # task-document lanzado desde un task-start en opus no hereda su modelo.
  local espejo_modelo
  espejo_modelo="$tmp/claude-espejo-modelo"
  cat >"$espejo_modelo" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"%s %s","total_cost_usd":0,"num_turns":1}\n' "${DEVKIT_MODEL:-vacío}" "${DEVKIT_EFFORT:-vacío}"
FIN
  chmod +x "$espejo_modelo"
  DEVKIT_MODEL=heredado DEVKIT_EFFORT=heredado DEVKIT_CLAUDE_BIN="$espejo_modelo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-modelo.log" modelo-x max 40 >/dev/null 2>&1
  check "worker exporta DEVKIT_MODEL y DEVKIT_EFFORT resueltos" "modelo-x max" \
    "$(jq -r .result "$tmp/run/espejo-modelo.log" 2>/dev/null)"
  check "--sync exporta DEVKIT_MODEL y DEVKIT_EFFORT del rol" '{"result":"modelo-barato low","total_cost_usd":0,"num_turns":1}' \
    "$(env -u DEVKIT_MODELO_FORZADO DEVKIT_MODEL=heredado DEVKIT_CLAUDE_BIN="$espejo_modelo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-modelo" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-3' 2>/dev/null | tail -1)"
  check "--sync con modelo forzado exporta el forzado" '{"result":"modelo-forzado low","total_cost_usd":0,"num_turns":1}' \
    "$(DEVKIT_MODELO_FORZADO=modelo-forzado DEVKIT_CLAUDE_BIN="$espejo_modelo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-modelo" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-3' 2>/dev/null | tail -1)"

  # H1 de pr-review (DEVKIT-65): DEVKIT_LANZADOR=watch, que watch.sh fija al
  # llamar a --sync para que task-fix sepa que lo lanzó el bucle y no firme
  # manual=1, debe llegar al `claude -p` hijo pese a ENV_LIMPIO=1 y su lista
  # blanca de `env -i` (no está en ENV_HEREDABLE: la copia run_claude aparte).
  local espejo_lanzador
  espejo_lanzador="$tmp/claude-espejo-lanzador"
  cat >"$espejo_lanzador" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"%s","total_cost_usd":0,"num_turns":1}\n' "${DEVKIT_LANZADOR:-vacío}"
FIN
  chmod +x "$espejo_lanzador"
  check "--sync con DEVKIT_LANZADOR=watch lo pasa al claude -p pese a env -i" '{"result":"watch","total_cost_usd":0,"num_turns":1}' \
    "$(DEVKIT_LANZADOR=watch DEVKIT_ENV_LIMPIO=1 DEVKIT_CLAUDE_BIN="$espejo_lanzador" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-lanzador" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-3' 2>/dev/null | tail -1)"

  # DEVKIT-65: hipótesis no confirmada (ver el comentario de ENV_HEREDABLE
  # más arriba, H4 de pr-review) de que un `claude -p` lanzado por otro
  # (`epic-plan` corriendo dentro de un `claude -p`) hereda del padre las
  # marcas de sesión anidada (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, ...), que le
  # cambiarían a la CLI hija el nombre con el que monta el conector de Notion
  # y romperían `--allowedTools`. Confirmada o no, `run_claude` arranca con
  # `env -i` y la lista blanca de ENV_HEREDABLE como medida defensiva: aunque
  # el padre las meta, no llegan.
  local espejo_anidado
  espejo_anidado="$tmp/claude-espejo-anidado"
  cat >"$espejo_anidado" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"CLAUDECODE=%s ENTRYPOINT=%s","total_cost_usd":0,"num_turns":1}\n' \
  "${CLAUDECODE:-ausente}" "${CLAUDE_CODE_ENTRYPOINT:-ausente}"
FIN
  chmod +x "$espejo_anidado"
  CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_CHILD_SESSION=1 \
    DEVKIT_CLAUDE_BIN="$espejo_anidado" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-anidado.log" modelo-x high 40 >/dev/null 2>&1
  check "el claude -p hijo no hereda las marcas de sesión anidada del padre" 'CLAUDECODE=ausente ENTRYPOINT=ausente' \
    "$(jq -r .result "$tmp/run/espejo-anidado.log" 2>/dev/null)"

  # Ampliación de DEVKIT-65: `--allowedTools` trae los dos nombres con los
  # que la CLI puede montar el conector de Notion (el de la shell/bash y el
  # visto dentro de un agente anidado), por si vuelve a cambiar con una
  # versión de la CLI.
  local espejo_argv
  espejo_argv="$tmp/claude-espejo-argv"
  cat >"$espejo_argv" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*"
FIN
  chmod +x "$espejo_argv"
  DEVKIT_CLAUDE_BIN="$espejo_argv" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-argv.log" modelo-x high 40 >/dev/null 2>&1
  check "--allowedTools trae los dos nombres del conector de Notion" 2 \
    "$(grep -oE 'mcp__plugin_Notion_notion|mcp__claude_ai_Notion' "$tmp/run/espejo-argv.log" | sort -u | wc -l | tr -d ' ')"

  # DEVKIT-65: antes de lanzar de verdad, `run_claude` prueba con
  # `claude mcp list` que Notion está conectada en el entorno del hijo (el
  # mismo que va a usar, no el de quien llama). Conectada, todo sigue igual.
  local notion_ok
  notion_ok="$tmp/claude-notion-ok"
  cat >"$notion_ok" <<'FIN'
#!/usr/bin/env bash
if [ "$1 $2" = "mcp list" ]; then
  printf 'plugin:Notion:notion: https://mcp.notion.com/mcp (HTTP) - Connected\n'
  exit 0
fi
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":1}\n'
FIN
  chmod +x "$notion_ok"
  DEVKIT_NOTION_CHECK=1 DEVKIT_CLAUDE_BIN="$notion_ok" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/notion-ok.log" modelo-x high 40 >/dev/null 2>&1
  check "Notion conectada: el lanzamiento sigue normal" 'listo' \
    "$(jq -r .result "$tmp/run/notion-ok.log" 2>/dev/null)"

  # Sin Notion conectada (un doble que no entiende `mcp list` se ve igual que
  # un servidor caído), no corre el `claude -p` real y queda la alarma en vez
  # de gastar turnos pidiendo autorizar el conector.
  : >"$tmp/run/watch.log"
  DEVKIT_NOTION_CHECK=1 DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-9' "$tmp/run/sin-notion.log" modelo-x high 40 >/dev/null 2>&1
  check "sin Notion conectada no corre el claude -p real" "" \
    "$(jq -r .result "$tmp/run/sin-notion.log" 2>/dev/null)"
  check "sin Notion conectada deja la alarma en watch.log" 'ALARMA: sin Notion conectado' \
    "$(grep -oE 'ALARMA: sin Notion conectado' "$tmp/run/watch.log" | head -1)"
  # H5 de pr-review (DEVKIT-65): una sola ALARMA por el evento, no la
  # genérica "terminó con error (rc=67)" de encima.
  check "sin Notion conectada no repite la alarma genérica de error" 0 \
    "$(grep -c 'ALARMA: terminó con error' "$tmp/run/watch.log")"

  # Notion conectada al probar, pero el final del `claude -p` dice lo
  # contrario (DEVKIT-65). H13 de pr-review: solo `permission_denials` con una
  # herramienta de Notion bloquea la card; la frase del agente deja una ALARMA
  # y nada más. `--worker` corre sincrónico, así la prueba no depende de
  # esperas. Imprime "<bloquea si|no> <cuántas ALARMA de texto>".
  caso_notion() {  # caso_notion <nombre de $tmp/result-<nombre>.json>
    local doble_real="$tmp/claude-result-$1"
    cat >"$doble_real" <<'FIN'
#!/usr/bin/env bash
if [ "$1 $2" = "mcp list" ]; then
  printf 'plugin:Notion:notion: https://mcp.notion.com/mcp (HTTP) - Connected\n'
  exit 0
fi
cat "${0/claude-result-/result-}.json"
FIN
    chmod +x "$doble_real"
    rm -f "$tmp/bloqueo.args"
    : >"$tmp/run/watch.log"
    DEVKIT_NOTION_CHECK=1 DEVKIT_CLAUDE_BIN="$doble_real" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
      DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
      bash "$HERE/devkit-run.sh" --worker '/task-fix DEVKIT-9' "$tmp/run/notion-$1.log" modelo-x high 40 >/dev/null 2>&1
    printf '%s %s' "$([ -e "$tmp/bloqueo.args" ] && echo si || echo no)" \
      "$(grep -c 'ALARMA: el resultado describe falta de acceso a Notion' "$tmp/run/watch.log")"
  }

  # Un `result` con una herramienta de Notion en `permission_denials` bloquea,
  # con su propio motivo (H11), aunque el texto no diga nada.
  cat >"$tmp/result-permission-denials.json" <<'FIN'
{"result":"card sin cambios","permission_denials":[{"tool_name":"mcp__claude_ai_Notion__notion-fetch","tool_use_id":"x","tool_input":{}}],"total_cost_usd":0.01,"num_turns":2}
FIN
  check "permission_denials con mcp__claude_ai_Notion__notion-fetch bloquea la card sin ALARMA de texto" "si 0" \
    "$(caso_notion permission-denials)"
  check "el bloqueo por permission_denials deja su ALARMA en watch.log" 'ALARMA: terminó sin acceso a Notion' \
    "$(grep -oE 'ALARMA: terminó sin acceso a Notion' "$tmp/run/watch.log" | head -1)"
  check "el bloqueo por permission_denials es de DEVKIT-9" 'DEVKIT-9' \
    "$(cut -d'|' -f1 "$tmp/bloqueo.args" 2>/dev/null)"
  check "el motivo del bloqueo dice sin acceso a Notion, no pregunta abierta" 'sin acceso a Notion|' \
    "$(cut -d'|' -f2 "$tmp/bloqueo.args" 2>/dev/null | grep -oE 'sin acceso a Notion|pregunta abierta' | tr '\n' '|')"

  # Las frases con las que la card describe los incidentes: ALARMA, sin
  # bloquear (H9 y H13).
  printf '%s\n' '{"result":"no tengo acceso a Notion en esta sesión"}' >"$tmp/result-no-tengo-acceso.json"
  printf '%s\n' '{"result":"el plugin de Notion no tiene permiso en esta sesión headless"}' >"$tmp/result-sin-permiso.json"
  printf '%s\n' '{"result":"pidió autorizar mcp__claude_ai_Notion__* en permissions.allow"}' >"$tmp/result-otro-nombre.json"
  # H14: las mismas frases como las escribe el agente, con backticks,
  # comillas y otras conjugaciones de "autorizar".
  printf '%s\n' '{"result":"Pedí autorizar `mcp__claude_ai_Notion__*` en `permissions.allow`"}' >"$tmp/result-autorizar-backticks.json"
  printf '%s\n' '{"result":"El plugin `Notion` no tiene permiso en esta sesión headless"}' >"$tmp/result-plugin-backticks.json"
  printf '%s\n' '{"result":"No pude leer la card: \"El plugin de Notion no tiene permiso en esta sesión headless\""}' >"$tmp/result-entre-comillas.json"
  printf '%s\n' '{"result":"Las herramientas mcp__claude_ai_Notion__* no están autorizadas"}' >"$tmp/result-no-estan-autorizadas.json"
  local caso_texto
  for caso_texto in no-tengo-acceso sin-permiso otro-nombre autorizar-backticks plugin-backticks \
    entre-comillas no-estan-autorizadas; do
    check "el result $caso_texto deja ALARMA y no bloquea la card" "no 1" "$(caso_notion "$caso_texto")"
  done

  # H6: un `result` que solo cita un comando bloqueado por pr-guard, sin
  # mencionar Notion, ni bloquea ni alarma.
  printf '%s\n' '{"result":"el comando gh pr merge no autorizado por pr-guard; card en Revisión automática"}' \
    >"$tmp/result-pr-guard.json"
  check "un comando no autorizado por pr-guard no se confunde con sin acceso a Notion" "no 0" \
    "$(caso_notion pr-guard)"

  # H10 y H13: `result` reales de ejecuciones que terminaron bien y describen
  # este mismo mecanismo. Pueden alarmar; nunca bloquean la card.
  cat >"$tmp/result-pr-review-46-7fdb66e.json" <<'FIN'
{"result": "PR 46, veredicto **CAMBIOS**, 3 hallazgos (1 media, 2 baja). Informe publicado sobre el head 7fdb66e; la card DEVKIT-65 sigue en `Revisión automática`.\n\nQué encontré en este segundo ciclo:\n\n- **Los seis hallazgos anteriores quedaron corregidos.** H1 y H2 se confirman en vivo: esta misma sesión la lanzó el `run_claude` de la rama y su entorno ya trae `DEVKIT_LANZADOR=watch`, `DISABLE_AUTOUPDATER` y `MCP_OAUTH_CALLBACK_PORT`. H5 lo reproduje por el camino del lanzador y queda una sola alarma en lugar de tres. Las autopruebas pasan sin fallas: 118 casos en `devkit-run.sh --test` y 114 en `watch-test.sh`.\n- **H9 (media), el motivo del veredicto.** La sonda `claude mcp list` no reproduce el fallo, así que la única red que queda es la expresión sobre el `result`. Tras H6 solo reconoce \"no tengo acceso a Notion\" y \"no tengo/estoy autorizado\". Las frases con las que la card documenta los cuatro incidentes reales (\"el plugin de Notion no tiene permiso en esta sesión headless\", \"autorizar mcp__claude_ai_Notion__* en permissions.allow\") no coinciden. Si el fallo se repite, volvería a ser silencioso. Los logs de los incidentes ya no existen, así que lo contrasté con el texto citado en la card.\n- **H7 y H8 (baja).** Una frase del README sigue describiendo el disparador viejo de H6, y un comentario del caso de prueba afirma como hecho la causa que H4 retiró del resto.\n\nDos criterios quedan `No verificado` y son del humano: la demostración de la causa, que nadie ha logrado reproducir y el PR ya documenta con honestidad como hipótesis, y la prueba real con una Épica lanzada por `epic-plan`. Copia de trabajo y temporales eliminados.", "total_cost_usd": 0.01, "num_turns": 2}
FIN
  cat >"$tmp/result-task-start-1.json" <<'FIN'
{"result": "DEVKIT-65 entregada: PR #46 abierto con auto-merge, card en Revisión automática.\n\n**Resumen del cambio:** `run_claude` en `devkit-run.sh` ahora arma el `claude -p` hijo con `env -i` y una lista blanca de entorno (en vez de heredarlo tal cual), así un `task-start` lanzado por `epic-plan` anidado no arrastra las marcas de sesión anidada del padre (`CLAUDECODE`, etc.). Antes de lanzar, prueba con `claude mcp list` que Notion está conectada; si no, avisa con `ALARMA:` y no lanza. Si el propio resultado dice \"sin acceso a Notion\" pese a que la sonda pasó, bloquea la card. `--allowedTools` y `settings.json` cubren los dos nombres conocidos del conector. Documentado en README y en la entrada de Notion; 115+114 casos de autoprueba en verde, sin regresiones.\n\n**Limitación que dejé anotada en la card y el PR:** no pude correr la prueba real de punta a punta (una Épica completa lanzada por `epic-plan` en el contenedor de producción) porque esta sesión corre en una sandbox de agente en la nube, no en el devkit Docker real con Notion/GitHub conectados. Queda para confirmar quien revise o el humano.", "total_cost_usd": 0.01, "num_turns": 2}
FIN
  cat >"$tmp/result-task-fix-46-ce49aa6.json" <<'FIN'
{"result":"PR #46: corregí los 3 hallazgos (H10, H11, H12), no descarté ninguno. Head nuevo: `61eadf8`.\n\n- **H10:** `devkit-run.sh` ahora decide que el agente se quedó sin acceso a Notion sobre todo por el campo `permission_denials` del `result`. El texto queda de respaldo: \"notion\" y la frase de falta de acceso deben ir en la misma oración. Además, hice algo que el revisor no pidió: antes de buscar, se descarta lo que va entre comillas o backticks. Sin ese paso, los dos `result` reales (`pr-review-46-7fdb66e.log` y `task-start-1.log`) seguirían bloqueando la card, porque citan entre comillas la frase \"sin acceso a Notion\". Probé la detección con los 7 logs reales de `/run/devkit` y ninguno bloquea. Sumé a la autoprueba esos dos `result` reales, que no bloquean, y un caso que sí bloquea por `permission_denials`. También actualicé el README.\n- **H11:** `forzar_task_block` recibe el motivo como tercer argumento. Cuando falta Notion, la card ya no queda bloqueada con el motivo de \"pregunta abierta\". La autoprueba comprueba el motivo en los dos casos.\n- **H12:** agregué al CHANGELOG, en \"Sin publicar\", una viñeta sobre este bloqueo automático.\n\nLa autoprueba `devkit-run.sh --test` pasa con 125 casos correctos, y `bash -n` pasa sin errores. Publiqué la respuesta en el PR con el marcador que lee `pr-review`, sin `manual=1` porque me lanzó el bucle. Después avisé al bucle para que revise.\n\nPor error publiqué antes en el PR un comentario de prueba incompleto. Lo borré enseguida y no afecta al ciclo.","total_cost_usd":0.01,"num_turns":2}
FIN
  local caso_real
  for caso_real in pr-review-46-7fdb66e task-start-1 task-fix-46-ce49aa6; do
    check "el result real de $caso_real.log no bloquea la card" no \
      "$(caso_notion "$caso_real" | cut -d' ' -f1)"
  done

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
  check "ROLES_FILE desde .devkit/roles.toml (pr-review)" "anulacion-proyecto high 99 -" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_WS="$tmp" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion-1" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" bash "$HERE/devkit-run.sh" --rol '/pr-review 9')"
  check "ROLES_FILE desde .devkit/roles.toml (task-fix)" "anulacion-proyecto high 99 1" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_WS="$tmp" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion-2" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" bash "$HERE/devkit-run.sh" --rol '/task-fix DEVKIT-2')"

  # --- DEVKIT-57: quién lanzó, arranque y --estado ---------------------------
  # Origen por ancestros: el `claude -p /epic-plan` más cercano gana; los
  # lanzadores devkit-run.sh no cuentan; sin claude -p, humano.
  check "origen: claude -p /epic-plan entre los ancestros" epic-plan \
    "$(printf '%s\n' '500 bash -c devkit-run.sh task-start DEVKIT-3' \
         '400 /bin/zsh -c source snapshot; devkit-run task-start DEVKIT-3' \
         '300 claude -p /epic-plan DEVKIT-1 --model fable --effort max' \
         '200 bash /workspace/devkit/scripts/devkit-run.sh --worker /epic-plan DEVKIT-1 x.log fable max 50' \
         | origen_de)"
  check "origen: sin claude -p entre los ancestros es humano" humano \
    "$(printf '%s\n' '500 bash devkit-run.sh task-start DEVKIT-3' '400 -zsh' '1 /sbin/init' | origen_de)"
  check "origen: DEVKIT_ORIGEN declarado manda" task-close \
    "$(DEVKIT_ORIGEN=task-close origen_lanzamiento)"

  # Siguiente modelo de frontera: el que sigue, y tras el último, el primero.
  check "siguiente modelo tras modelo-barato" modelo-medio \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-sig" WATCH_LOG="$tmp/sonda-watch.log" siguiente_modelo modelo-barato)"
  check "siguiente modelo tras el último vuelve al primero" modelo-barato \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-sig" WATCH_LOG="$tmp/sonda-watch.log" siguiente_modelo modelo-fuerte)"

  # Arranque fallido 1: sin el marcador ready, no lanza y lo dice.
  local sin_ready salida
  sin_ready="$tmp/run-sin-ready"
  mkdir -p "$sin_ready"
  salida=$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$sin_ready" DEVKIT_WS="$tmp" DEVKIT_READY_TIMEOUT=1 \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-5 2>&1); rc=$?
  check "arranque sin terminar: sale con 69 y no lanza" "69 no" \
    "$rc $([ -e "$sin_ready/task-start-1.log" ] && echo si || echo no)"
  check "arranque sin terminar: mensaje claro" 'el arranque del contenedor no terminó en 1s' \
    "$(printf '%s' "$salida" | grep -oE 'el arranque del contenedor no terminó en 1s')"

  # Arranque fallido 2: claude -p muere enseguida con error. devkit-run no
  # vuelve con "lanzado" a secas: imprime el final del log y sale con 70.
  local muere
  muere="$tmp/claude-muere"
  printf '#!/usr/bin/env bash\necho "error: token OAuth ausente" >&2\nexit 1\n' >"$muere"
  chmod +x "$muere"
  salida=$(DEVKIT_CLAUDE_BIN="$muere" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" --modelo modelo-x task-start DEVKIT-6 2>&1); rc=$?
  check "arranque fallido: sale con 70" 70 "$rc"
  check "arranque fallido: imprime las últimas líneas del log" 'error: token OAuth ausente' \
    "$(printf '%s' "$salida" | grep -oE 'error: token OAuth ausente' | head -1)"

  # `avisar_atras_de_origin` (DEVKIT-63): repo real, porque lo que mide es
  # `git rev-list --count main..origin/main`, no algo que un doble simule.
  local atras
  atras="$tmp/atras"
  mkdir -p "$atras"
  git init -q --bare "$atras/origin.git"
  git init -q "$atras/ws"
  git -C "$atras/ws" config user.email t@t.com
  git -C "$atras/ws" config user.name t
  git -C "$atras/ws" commit -q --allow-empty -m base
  git -C "$atras/ws" branch -M main
  git -C "$atras/ws" remote add origin "$atras/origin.git"
  git -C "$atras/ws" push -q origin main
  check "avisar_atras_de_origin: al día no avisa" "" \
    "$(WS="$atras/ws" WATCH_LOG="$atras/watch.log" avisar_atras_de_origin "/task-start DEVKIT-1" 2>&1)"
  check "avisar_atras_de_origin: al día no deja ALARMA" 0 \
    "$([ -f "$atras/watch.log" ] && grep -c 'ALARMA' "$atras/watch.log" || echo 0)"
  # origin/main avanza con un commit que el clon todavía no conoce.
  git -C "$atras/ws" commit -q --allow-empty -m adelante
  git -C "$atras/ws" push -q origin main
  git -C "$atras/ws" reset -q --hard HEAD^
  git -C "$atras/ws" fetch -q origin
  check "avisar_atras_de_origin: atrás lo dice por stderr" \
    'el workspace está 1 commit(s) detrás de origin/main' \
    "$(WS="$atras/ws" WATCH_LOG="$atras/watch.log" avisar_atras_de_origin "/task-start DEVKIT-1" 2>&1 >/dev/null \
        | grep -oE 'el workspace está 1 commit\(s\) detrás de origin/main')"
  check "avisar_atras_de_origin: atrás deja ALARMA en watch.log" \
    'ALARMA: workspace 1 commit(s) detrás de origin/main' \
    "$(grep -oE 'ALARMA: workspace 1 commit\(s\) detrás de origin/main' "$atras/watch.log" | head -1)"
  # H1 del PR #53: el remoto avanza otra vez desde un segundo clon y `ws`
  # nunca vuelve a hacer `git fetch` por su cuenta. Antes, la función
  # comparaba contra la referencia `origin/main` que ya tenía guardada -la
  # de la línea 2062, un commit atrás- y se quedaba corta.
  local otro_clon
  otro_clon="$tmp/atras-otro-clon"
  git clone -q "$atras/origin.git" "$otro_clon"
  git -C "$otro_clon" config user.email t@t.com
  git -C "$otro_clon" config user.name t
  git -C "$otro_clon" commit -q --allow-empty -m "avanza sin que ws se entere"
  git -C "$otro_clon" push -q origin main
  check "avisar_atras_de_origin: detecta sin fetch previo del clon" \
    'el workspace está 2 commit(s) detrás de origin/main' \
    "$(WS="$atras/ws" WATCH_LOG="$atras/watch.log" avisar_atras_de_origin "/task-start DEVKIT-1" 2>&1 >/dev/null \
        | grep -oE 'el workspace está 2 commit\(s\) detrás de origin/main')"

  # --estado con un watch.log fijo, un `ps` de mentira y una hora fija: un
  # caso por estado. Las fechas se cuentan hacia atrás desde AHORA.
  local est ahora pslist
  est="$tmp/estado"
  mkdir -p "$est"
  ahora=$(date -d '2026-09-16T12:00:00Z' +%s)
  printf '{"result":"a medias"}\n' >"$est/task-fix-2.log"
  : >"$est/task-start-2.log"
  cat >"$est/watch.log" <<FIN
2026-09-16T11:00:00Z PR #41 (DEVKIT-56) head abc1234 sin informe: lanzando pr-review
2026-09-16T11:00:00Z pr-review-41-abc1234 lanzando (origen=bucle): "/pr-review 41" log=$est/pr-review-41-abc1234.log
2026-09-16T11:05:00Z pr-review-41-abc1234 terminado: modelo=fable esfuerzo=high costo=1.0 turnos=9 :: OK
2026-09-16T11:08:00Z task-start-5 lanzando (origen=humano): "/task-start DEVKIT-5" log=$est/task-start-5.log
2026-09-16T11:10:00Z task-start-1 lanzando (origen=task-close): "/task-start DEVKIT-57" log=$est/task-start-1.log
2026-09-16T11:12:00Z task-block.sh DEVKIT-5 Bloqueada desde En progreso: motivo de la cinco.
2026-09-16T11:12:05Z devkit-run "/task-start DEVKIT-5" terminado [task-start-5]: modelo=opus esfuerzo=high ronda=1 :: bloqueada
2026-09-16T11:20:00Z task-fix-1 lanzando (origen=humano): "/task-fix DEVKIT-58" log=$est/task-fix-1.log
2026-09-16T11:21:00Z devkit-run "/task-fix DEVKIT-58" falló (rc=1) [task-fix-1]: modelo=opus esfuerzo=high ronda=2 :: error
2026-09-16T11:30:00Z task-start-3 lanzando (origen=epic-plan): "/task-start DEVKIT-59" log=$est/task-start-3.log
2026-09-16T11:31:00Z task-block.sh DEVKIT-59 Bloqueada desde En progreso: Qué intenté: X. Qué necesito: el token de Y.
2026-09-16T11:31:05Z devkit-run "/task-start DEVKIT-59" terminado [task-start-3]: modelo=opus esfuerzo=high :: bloqueada
2026-09-16T11:40:00Z task-start-2 lanzando (origen=humano): "/task-start DEVKIT-60" log=$est/task-start-2.log
2026-09-16T11:45:00Z task-start-4 lanzando (origen=task-close): "/task-start DEVKIT-63" log=$est/task-start-4.log
2026-09-16T11:46:00Z devkit-run "/task-start DEVKIT-63" terminado [task-start-4]: modelo=sonnet esfuerzo=high ronda=1 :: dejo la decisión a tu criterio
2026-09-16T11:46:00Z devkit-run "/task-start DEVKIT-63" ALARMA: terminó sin entregar ni bloquear (DEVKIT-63): card sigue En progreso, sin PR ni bloqueo
2026-09-16T11:59:58Z task-fix-2 lanzando (origen=humano): "/task-fix DEVKIT-61" log=$est/task-fix-2.log
FIN
  pslist="$tmp/ps-estado"
  printf '#!/usr/bin/env bash\necho "4242 bash devkit-run.sh --worker /task-start DEVKIT-57 %s/task-start-1.log opus high 40"\n' "$est" >"$pslist"
  chmod +x "$pslist"
  local filas
  filas=$(PS_BIN="$pslist" LOCK="$est/skill.lock" estado_filas "$est/watch.log" "$ahora")
  fila() { printf '%s\n' "$filas" | awk -F'\t' -v c="$1" '$2 == c {print $5 "|" $3; exit}'; }
  check "estado terminó (pr-review, Clave desde la línea del PR)" "terminó|bucle" "$(fila DEVKIT-56)"
  check "estado en curso (proceso vivo)" "en curso|task-close" "$(fila DEVKIT-57)"
  check "estado error (rc distinto de cero)" "error|humano" "$(fila DEVKIT-58)"
  check "estado bloqueada, con el motivo" "bloqueada|epic-plan" "$(fila DEVKIT-59)"
  check "motivo del bloqueo en el detalle" "Qué intenté: X. Qué necesito: el token de Y." \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-59" {print $6}')"
  # Un lanzamiento de DEVKIT-57 entre medio no corta el bloqueo de DEVKIT-5:
  # la Clave se compara completa, no como prefijo.
  check "estado bloqueada con otra Clave que la extiende en medio" "bloqueada|humano" "$(fila DEVKIT-5)"
  check "estado no arrancó (sin proceso, log vacío, pasado el margen)" "no arrancó|humano" "$(fila DEVKIT-60)"
  # DEVKIT-77: un task-start que "terminó" pero dejó su card En progreso sin
  # PR ni bloqueo (DEVKIT-63) cuenta como error, no como avance.
  check "estado error: task-start terminó sin entregar ni bloquear" "error|task-close" "$(fila DEVKIT-63)"
  check "detalle: task-start terminó sin entregar ni bloquear" \
    "terminó sin entregar ni bloquear; card DEVKIT-63 sigue En progreso" \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-63" {print $6}')"
  # Evidencia del 2026-09-16: dos segundos después de "lanzando", sin ningún
  # proceso todavía, el lanzamiento ya cuenta como en curso.
  check "estado en curso desde la línea lanzando, sin proceso" "en curso|humano" "$(fila DEVKIT-61)"
  check "la tabla trae skill y hace cuánto" "task-fix 2s" \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-61" {print $1, $4}')"
  # `agentes_en_curso_rapido` (DEVKIT-63) cuenta lo mismo que `estado_filas`
  # sobre este mismo watch.log: DEVKIT-57 (proceso vivo) y DEVKIT-61 (gracia).
  check "agentes_en_curso_rapido coincide con las filas en curso de estado_filas" 2 \
    "$(PS_BIN="$pslist" LOCK="$est/skill.lock" agentes_en_curso_rapido "$est/watch.log" "$ahora")"
  # El doble genérico no trae "Current session"/"Current week": mostrar_estado
  # no se cae por eso, solo agrega el bloque Consumo con el aviso de que
  # todavía no hay lectura en caché. `head -1` porque, desde DEVKIT-62,
  # mostrar_estado siempre agrega ese bloque al final, con o sin lanzamientos.
  check "--estado sin lanzamientos lo dice" "sin lanzamientos registrados en $est/vacio.log" \
    "$(CLAUDE_BIN="$doble" CUOTA_CACHE="$tmp/cuota-vacio/cuota.cache" CUOTA_LOCK="$tmp/cuota-vacio/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | head -1)"

  # Columna "bloquea a" (ampliación de la card): caché ya tibia, sin llamar a
  # notion.sh en el propio check -el refresco es en segundo plano y no debe
  # bloquear la lectura (H1 de pr-review, mismo criterio que Consumo).
  local bloq
  bloq="$tmp/bloqueos"
  mkdir -p "$bloq"
  printf '%s\t%s\n' "$(date +%s)" '[{"clave":"DEVKIT-57","bloquea_a":["DEVKIT-61","DEVKIT-99"]}]' \
    >"$bloq/bloqueos.cache"
  check "bloquea_a: card en Lista para merge lista a quién frena" "bloquea a: DEVKIT-61, DEVKIT-99" \
    "$(BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" bloquea_a DEVKIT-57)"
  check "bloquea_a: card que no frena a nadie, vacío" "" \
    "$(BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" bloquea_a DEVKIT-999)"
  check "--estado suma la columna a la fila que corresponde" "bloquea a: DEVKIT-61, DEVKIT-99" \
    "$(BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" \
        CLAUDE_BIN="$doble" CUOTA_CACHE="$tmp/cuota-vacio2/cuota.cache" CUOTA_LOCK="$tmp/cuota-vacio2/cuota.lock" \
        PS_BIN="$pslist" LOCK="$est/skill.lock" DEVKIT_AHORA="$ahora" \
        WATCH_LOG="$est/watch.log" mostrar_estado | grep 'DEVKIT-57' | grep -oE 'bloquea a: DEVKIT-61, DEVKIT-99')"

  # --- DEVKIT-62: cuota en vivo con `claude -p "/usage"` -----------------
  # La compuerta de la card probó que el campo `result` de
  # `claude -p "/usage" --output-format json` trae el mismo texto que la
  # sesión interactiva. Un doble que lo imita, para probar la extracción sin
  # gastar cuota ni depender de una sesión real.
  local doble_cuota resultado_cuota
  doble_cuota="$tmp/claude-usage"
  cat >"$doble_cuota" <<'FIN'
#!/usr/bin/env bash
cat <<'JSON'
{"result":"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 42% used · resets Sep 17, 5:10pm (UTC)\nCurrent week (all models): 7% used · resets Sep 22, 11pm (UTC)\n","total_cost_usd":0}
JSON
FIN
  chmod +x "$doble_cuota"
  resultado_cuota=$(CLAUDE_BIN="$doble_cuota" leer_cuota)
  check "leer_cuota extrae el porcentaje de sesión" "42" "$(printf '%s' "$resultado_cuota" | cut -f1)"
  check "leer_cuota extrae cuándo reinicia la sesión" "Sep 17, 5:10pm (UTC)" \
    "$(printf '%s' "$resultado_cuota" | cut -f2)"
  check "leer_cuota extrae el porcentaje de semana" "7" "$(printf '%s' "$resultado_cuota" | cut -f3)"
  check "leer_cuota extrae cuándo reinicia la semana" "Sep 22, 11pm (UTC)" \
    "$(printf '%s' "$resultado_cuota" | cut -f4)"

  # H2 de pr-review: leer_cuota no debe dejar una sesión propia de Claude
  # Code en ~/.claude/projects/ (con --seguir serían miles por hora).
  local doble_cuota_args args_cuota
  doble_cuota_args="$tmp/claude-usage-args"
  cat >"$doble_cuota_args" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$DEVKIT_TEST_ARGS_FILE"
cat <<'JSON'
{"result":"Current session: 1% used · resets nunca\nCurrent week (all models): 1% used · resets nunca\n","total_cost_usd":0}
JSON
FIN
  chmod +x "$doble_cuota_args"
  args_cuota="$tmp/args-cuota.txt"
  DEVKIT_TEST_ARGS_FILE="$args_cuota" CLAUDE_BIN="$doble_cuota_args" leer_cuota >/dev/null
  check "leer_cuota pide --no-session-persistence a claude -p /usage" 1 \
    "$(grep -c -- '--no-session-persistence' "$args_cuota")"

  # H1 de pr-review: --estado no espera nunca la lectura de la cuota. Con
  # caché fresca, muestra la lectura sin volver a invocar `claude` (CLAUDE_BIN
  # apunta a un binario roto: si mostrar_consumo lo llamara, este caso caería).
  local cuota_fresca
  cuota_fresca="$tmp/cuota-fresca"
  mkdir -p "$cuota_fresca"
  printf '%s\tok\t42\tSep 17, 5:10pm (UTC)\t7\tSep 22, 11pm (UTC)\n' "$(date +%s)" >"$cuota_fresca/cuota.cache"
  check "con caché fresca, el bloque Consumo trae el encabezado con la cuota oficial" \
    "Consumo (cuota oficial, leída" \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=9999 CUOTA_CACHE="$cuota_fresca/cuota.cache" CUOTA_LOCK="$cuota_fresca/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | grep -oE '^Consumo \(cuota oficial, leída')"
  check "con caché fresca, el bloque Consumo trae sesión y semana sin invocar claude" \
    "sesión: 42% usada, reinicia Sep 17, 5:10pm (UTC)|semana: 7% usada, reinicia Sep 22, 11pm (UTC)" \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=9999 CUOTA_CACHE="$cuota_fresca/cuota.cache" CUOTA_LOCK="$cuota_fresca/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | sed -n 's/^  //p' | paste -sd'|')"

  # Con la caché en fail (una lectura anterior sin fuente), --estado lo dice
  # sin romper el resto, tampoco esperando un nuevo intento.
  local cuota_fail
  cuota_fail="$tmp/cuota-fail"
  mkdir -p "$cuota_fail"
  printf '%s\tfail\n' "$(date +%s)" >"$cuota_fail/cuota.cache"
  check "con la caché en fail, --estado avisa sin colgarse" \
    'Consumo: no se pudo leer la cuota oficial con `claude -p "/usage"` ahora' \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=9999 CUOTA_CACHE="$cuota_fail/cuota.cache" CUOTA_LOCK="$cuota_fail/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | tail -1)"

  # Caché vencida: se sigue mostrando la última lectura al instante, y se
  # dispara un refresco en segundo plano que la reemplaza sin que --estado lo
  # espere.
  local doble_cuota_lento cuota_vieja intento
  doble_cuota_lento="$tmp/claude-usage-lento"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$doble_cuota_lento"
  chmod +x "$doble_cuota_lento"
  cuota_vieja="$tmp/cuota-vieja"
  mkdir -p "$cuota_vieja"
  printf '%s\tok\t10\tya\t10\tya\n' "$(( $(date +%s) - 120 ))" >"$cuota_vieja/cuota.cache"
  check "caché vencida: se muestra igual, sin esperar el refresco" \
    "sesión: 10% usada, reinicia ya|semana: 10% usada, reinicia ya" \
    "$(CLAUDE_BIN="$doble_cuota" CUOTA_TTL=60 CUOTA_CACHE="$cuota_vieja/cuota.cache" CUOTA_LOCK="$cuota_vieja/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | sed -n 's/^  //p' | paste -sd'|')"
  local refrescada=0
  for intento in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(cut -f2,3 "$cuota_vieja/cuota.cache" 2>/dev/null)" = "$(printf 'ok\t42')" ] && { refrescada=1; break; }
    sleep 0.3
  done
  check "el refresco en segundo plano reemplaza la caché vencida" 1 "$refrescada"

  # H3 de pr-review: la subshell de refrescar_cuota_bg no debe heredar los
  # descriptores del llamador. Antes de cerrarlos, leer --estado por pipe (o
  # `$(...)`, como aquí con `tail -1`) esperaba a que el refresco de fondo
  # terminara, hasta CUOTA_TIMEOUT.
  local cuota_pipe salida_pipe t0_pipe t1_pipe ms_pipe
  cuota_pipe="$tmp/cuota-pipe"
  mkdir -p "$cuota_pipe"
  printf '%s\tok\t10\tya\t10\tya\n' "$(( $(date +%s) - 120 ))" >"$cuota_pipe/cuota.cache"
  t0_pipe=$(date +%s%N)
  salida_pipe=$(CLAUDE_BIN="$doble_cuota_lento" CUOTA_TIMEOUT=3 CUOTA_TTL=60 \
    CUOTA_CACHE="$cuota_pipe/cuota.cache" CUOTA_LOCK="$cuota_pipe/cuota.lock" \
    WATCH_LOG="$est/vacio.log" mostrar_estado | tail -1)
  t1_pipe=$(date +%s%N)
  ms_pipe=$(( (t1_pipe - t0_pipe) / 1000000 ))
  check "leído por pipe, --estado no espera el refresco de fondo" si \
    "$([ "$ms_pipe" -lt 1000 ] && echo si || echo "no (${ms_pipe}ms)")"
  check "leído por pipe, el bloque Consumo igual llega completo" \
    "semana: 10% usada, reinicia ya" \
    "$(printf '%s\n' "$salida_pipe" | grep -oE 'semana: 10% usada, reinicia ya')"

  # El criterio de la card: sin caché y con un `claude -p "/usage"` que no
  # responde, --estado sigue respondiendo bajo un segundo, incluso con un
  # watch.log de mil líneas.
  local watch_mil cuota_lenta t0 t1 ms salida_mil
  watch_mil="$tmp/watch-mil.log"
  : >"$watch_mil"
  for i in $(seq 1000); do printf '2026-09-16T11:00:00Z ruido de relleno %s\n' "$i"; done >>"$watch_mil"
  cuota_lenta="$tmp/cuota-lenta"
  salida_mil="$tmp/salida-mil.txt"
  t0=$(date +%s%N)
  CLAUDE_BIN="$doble_cuota_lento" CUOTA_TIMEOUT=1 \
    CUOTA_CACHE="$cuota_lenta/cuota.cache" CUOTA_LOCK="$cuota_lenta/cuota.lock" \
    WATCH_LOG="$watch_mil" mostrar_estado >"$salida_mil"
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  check "--estado responde bajo 1s con un /usage lento y un watch.log de mil líneas" si \
    "$([ "$ms" -lt 1000 ] && echo si || echo "no (${ms}ms)")"
  check "sin caché, --estado avisa que va a refrescar en segundo plano" \
    "Consumo: todavía no hay una lectura de la cuota oficial, refrescando en segundo plano" \
    "$(tail -1 "$salida_mil")"
  for intento in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$cuota_lenta/cuota.cache" ] && break
    sleep 0.3
  done
  check "el refresco en segundo plano respeta CUOTA_TIMEOUT y deja fail en la caché" fail \
    "$(cut -f2 "$cuota_lenta/cuota.cache" 2>/dev/null)"

  # De punta a punta: un lanzamiento real deja su línea lanzando y --estado
  # lo muestra terminado. El origen esperado se calcula aquí y no se fija en
  # `humano`: esta prueba puede correr dentro de un `claude -p /task-start`
  # de verdad, y entonces ese es el origen correcto.
  local origen_esperado
  origen_esperado=$(unset DEVKIT_ORIGEN; origen_lanzamiento)
  : >"$tmp/run/watch.log"
  env -u DEVKIT_ORIGEN DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-submit DEVKIT-7 >/dev/null 2>&1
  check "lanzamiento real: línea lanzando con el origen de sus ancestros" \
    "lanzando (origen=${origen_esperado:-?}): \"/task-submit DEVKIT-7\"" \
    "$(grep -oE 'lanzando \(origen=[^)]*\): "/task-submit DEVKIT-7"' "$tmp/run/watch.log" | head -1)"
  check "lanzamiento real: --estado lo muestra terminado" "terminó" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
        bash "$HERE/devkit-run.sh" --estado | awk '/DEVKIT-7/ {print $5}')"

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
    read -r modelo esfuerzo _ _ < <(model_effort_of "${2:-}" "${DEVKIT_RONDA:-}")
    [ -z "${DEVKIT_MODELO_FORZADO:-}" ] || modelo=$DEVKIT_MODELO_FORZADO
    modelo_valido "${modelo:-}" "${2:-}" || exit 65
    run_claude "${2:-}" "$modelo" "$esfuerzo"
    exit $?
    ;;
  --resumen)
    resumen "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    exit 0
    ;;
  --worker)
    # --worker <prompt> <log> <modelo> <esfuerzo> <presupuesto> [manual] [ronda]: ya
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
    prompt=${2:-} logf=${3:-} modelo=${4:-} esfuerzo=${5:-} presupuesto=${6:-} manual=${7:-} ronda=${8:--}
    modelo_valido "$modelo" "$prompt" || exit 65
    exec 9>"$LOCK"
    if ! flock -n 9; then
      printf '%s devkit-run "%s" espera: otra skill ocupa el workspace\n' "$(date +%FT%T%:z)" "$prompt" >> "$WATCH_LOG"
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
    resumen_txt="$(resumen "$logf" "$modelo" "$esfuerzo" "$presupuesto" "$ronda")"
    [ -z "$manual" ] || resumen_txt="$resumen_txt (anulación manual)"
    # `[<id>]` une el resumen con su línea "lanzando" para `--estado`: dos
    # lanzamientos del mismo prompt solo se distinguen por el log.
    printf '%s devkit-run "%s" %s [%s]: %s\n' "$(date +%FT%T%:z)" "$(prompt_en_linea "$prompt")" "$estado" \
      "$(basename "$logf" .log)" "$resumen_txt" >> "$WATCH_LOG"
    if [ $rc -eq 0 ]; then
      resultado=$(tail -1 "$logf" 2>/dev/null | jq -r '.result // ""' 2>/dev/null)
      if pregunta_abierta "$resultado"; then
        printf '%s devkit-run "%s" ALARMA: terminó con una pregunta abierta en vez de un estado observable\n' \
          "$(date +%FT%T%:z)" "$prompt" >> "$WATCH_LOG"
        forzar_task_block "$prompt" "$logf" \
          "terminó con una pregunta abierta en vez de un estado observable (barrera mecánica de DEVKIT-50 sobre DEVKIT-44)"
      elif notion_denegado "$logf"; then
        # La sonda de arriba vio Notion conectado, pero la CLI negó una
        # herramienta de Notion (DEVKIT-65): mismo remedio que la pregunta
        # abierta, la card queda sin resolver y necesita al humano. H11: con
        # su propio motivo, para que el humano no busque una pregunta que no
        # existe.
        printf '%s devkit-run "%s" ALARMA: terminó sin acceso a Notion (permission_denials)\n' \
          "$(date +%FT%T%:z)" "$prompt" >> "$WATCH_LOG"
        forzar_task_block "$prompt" "$logf" \
          "terminó sin acceso a Notion pese a que \`claude mcp list\` la vio conectada (DEVKIT-65)"
      elif result_sin_notion "$logf"; then
        # H13 de pr-review: el texto solo avisa; el humano mira el resultado.
        printf '%s devkit-run "%s" ALARMA: el resultado describe falta de acceso a Notion (ver resultado)\n' \
          "$(date +%FT%T%:z)" "$prompt" >> "$WATCH_LOG"
      fi
      # Respaldo de DEVKIT-77: ninguna barrera de arriba se disparó, pero eso
      # no prueba que `task-start` haya entregado. DEVKIT-63 dejó una rama
      # vacía, sin comentar el plan y sin PR, con la card `En progreso` y sin
      # bloquear -un corte silencioso que el humano descubrió por `--estado`
      # mostrando "terminó". Solo aplica a `task-start`: `task-fix`,
      # `task-submit` y `task-document` actúan sobre una card que ya tiene PR
      # o no le cambian el Estado.
      clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
      if task_start_sin_entregar "$prompt" "$clave"; then
        printf '%s devkit-run "%s" ALARMA: terminó sin entregar ni bloquear (%s): card sigue En progreso, sin PR ni bloqueo\n' \
          "$(date +%FT%T%:z)" "$prompt" "$clave" >> "$WATCH_LOG"
      fi
    elif [ "$rc" -ne 67 ]; then
      # rc=67 (sin Notion conectada) ya dejó su propia alarma en
      # `alarma_sin_notion`, dentro de `run_claude`; repetirla aquí es una
      # segunda alarma por el mismo evento (H5 de pr-review, DEVKIT-65).
      printf '%s devkit-run "%s" ALARMA: terminó con error (rc=%s): %s; ver %s\n' \
        "$(date +%FT%T%:z)" "$prompt" "$rc" "$resumen_txt" "$logf" >> "$WATCH_LOG"
    fi
    exit $rc
    ;;
  --otros-agentes)
    otros_agentes
    exit $?
    ;;
  --pregunta-abierta)
    # DEVKIT-77 H1: `watch.sh` lanza pr-review/task-fix/task-document con
    # `--sync`, un camino que no pasaba por `pregunta_abierta` (solo lo hacía
    # `--worker`) y se había quedado con el `grep` viejo de DEVKIT-50.
    # Subcomando puro, igual que `--resumen`/`--rol`, para que las dos
    # llamadas usen la misma regla.
    pregunta_abierta "${2:-}"
    exit $?
    ;;
  --estado)
    if [ "${2:-}" = --seguir ]; then seguir_estado; fi
    mostrar_estado
    exit 0
    ;;
  --agentes)
    # Para el segmento `agentes:<a>` del prompt: `agentes_en_curso_rapido`,
    # no `estado_filas` (ver el comentario junto a su definición). Tampoco
    # toca la red: solo lee watch.log y `ps`.
    agentes_en_curso_rapido "$WATCH_LOG" "${DEVKIT_AHORA:-$(date +%s)}"
    exit 0
    ;;
  --seguir)
    seguir_estado
    ;;
  --siguiente-modelo)
    siguiente_modelo "${2:-}"
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

# Antes de resolver el modelo: la sonda de frontera también necesita el
# token que el arranque todavía no terminó de cargar.
esperar_arranque "$prompt" || exit 69
avisar_atras_de_origin "$prompt"
mkdir -p "$RUN_DIR"
n=1
while [ -e "$RUN_DIR/$skill-$n.log" ]; do n=$((n + 1)); done
logf="$RUN_DIR/$skill-$n.log"
read -r modelo esfuerzo presupuesto ronda < <(model_effort_of "$prompt")
manual=""
if [ -n "$modelo_manual" ]; then modelo="$modelo_manual"; manual=1; fi
if [ -n "$esfuerzo_manual" ]; then esfuerzo="$esfuerzo_manual"; manual=1; fi
modelo_valido "${modelo:-}" "$prompt" || exit 65
# Con anulación manual no hay presupuesto de roles.toml que comparar con el
# turno real: el rol resuelto ya no aplica.
[ -z "$manual" ] || presupuesto="-"

# Sin DEVKIT_LANZADOR: la pone `watch.sh` solo a lo que lanza su bucle, y un
# `claude -p` lanzado por el bucle que a su vez llama a devkit-run no debe
# heredarla. Un task-fix lanzado así es manual y marca `manual=1` (DEVKIT-56).
#
# La línea "lanzando" va antes del `nohup`: desde ella el lanzamiento cuenta
# para `--estado`, aunque su `claude -p` todavía no exista (DEVKIT-57).
linea_lanzando "$(basename "$logf" .log)" "$(origen_lanzamiento)" "$prompt" "$logf" >> "$WATCH_LOG" 2>/dev/null
nohup env -u DEVKIT_LANZADOR -u DEVKIT_ORIGEN -u DEVKIT_MODELO_FORZADO -u DEVKIT_RONDA \
  "$HERE/devkit-run.sh" --worker "$prompt" "$logf" "$modelo" "$esfuerzo" "$presupuesto" "$manual" "$ronda" \
  >/dev/null 2>&1 &
worker=$!
disown
echo "lanzado: $prompt"
echo "modelo=$modelo esfuerzo=$esfuerzo ronda=$ronda log=$logf pid=$worker"
confirmar_arranque "$worker" "$prompt" "$logf" || exit 70

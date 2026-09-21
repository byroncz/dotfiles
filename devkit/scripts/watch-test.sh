#!/usr/bin/env bash
# Prueba de watch.sh sin tocar GitHub ni gastar cuota. Bloques: la tabla de
# decisión, donde cada caso es un PR sintético (head, reviews, comments) y la
# acción que se espera de `watch.sh --decide`; el relanzamiento por cuota
# agotada, con logs falsos y un doble de `claude`; las alarmas; y el ciclo
# OK -> documentar -> merge -> cerrar con task-close.sh y task-block.sh reales
# contra dobles de `gh` y de notion.sh (DEVKIT-55). Sale con 1 si algún caso
# falla.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/watch.sh"
export DEVKIT_WATCH_BOT="${DEVKIT_WATCH_BOT:-bot}"
export DEVKIT_WATCH_MAX_CYCLES="${DEVKIT_WATCH_MAX_CYCLES:-3}"
BOT="$DEVKIT_WATCH_BOT"
fail=0

# La prueba no escribe en /run/devkit ni en /workspace: los dos directorios que
# usa watch.sh salen a un temporal propio, así corre también fuera del
# contenedor.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVKIT_RUN_DIR="$TMP/run" DEVKIT_WS="$TMP"
# devkit-run.sh lee la ronda de task-fix y task-document desde la card en
# Notion (DEVKIT-61). Por defecto, un notion.sh que falla: ninguna prueba toca
# la card real, y la ronda cae a 1. Los bloques que necesitan otra cosa lo
# sobrescriben.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/notion-caido"
chmod +x "$TMP/notion-caido"
export DEVKIT_NOTION_BIN="$TMP/notion-caido"
# devkit-run.sh prueba con `claude mcp list` que Notion está conectada antes
# de lanzar, y arranca el `claude -p` con el entorno reducido a una lista
# blanca (DEVKIT-65). Los dobles de `claude` de este archivo no entienden
# `mcp list` y varios simulan su propio estado con variables sueltas (`FIX_DIR`,
# el contador de llamadas de la cuota agotada, ...) fuera de esa lista blanca.
# Las dos comprobaciones son de devkit-run.sh y ya tienen su propia autoprueba;
# aquí se apagan para no acoplar los dos archivos.
export DEVKIT_NOTION_CHECK=0
export DEVKIT_ENV_LIMPIO=0

# Constructores de JSON. Las fechas son etiquetas T01..T10: solo importa el orden
# y se comparan como texto, por eso llevan dos dígitos.
review() { printf '{"author":{"login":"%s"},"state":"%s","submittedAt":"%s","body":"%s"}' "$1" "$2" "$3" "$4"; }
comment() { printf '{"author":{"login":"%s"},"createdAt":"%s","body":"%s"}' "$1" "$2" "$3"; }
rev() { review humano COMMENTED "$1" "<!-- devkit-review sha=$2 verdict=$3 -->"; }
fix() { comment "$BOT" "$1" "<!-- devkit-fix sha=$2 review=$3 -->"; }
fixm() { comment "$BOT" "$1" "<!-- devkit-fix sha=$2 review=$3 manual=1 -->"; }
block() { comment "$BOT" "$1" "<!-- devkit-block sha=$2 -->"; }
closed() { comment "$BOT" "$1" "<!-- devkit-closed sha=$2 -->"; }
doc() { comment "$BOT" "$1" "<!-- devkit-doc sha=$2 -->"; }
join() { local IFS=,; printf '%s' "$*"; }

# check <nombre> <acción esperada> <head> <reviews...> -- <comments...>
check() {
  local name=$1 want=$2 head=$3; shift 3
  local reviews=() comments=() got
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do reviews+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  comments=("$@")
  got=$(printf '{"headRefOid":"%s","reviews":[%s],"comments":[%s]}' \
          "$head" "$(join "${reviews[@]}")" "$(join "${comments[@]}")" \
        | bash "$WATCH" --decide | cut -f1)
  if [ "$got" = "$want" ]; then
    printf 'ok   %-58s %s\n' "$name" "$got"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
    fail=1
  fi
}

# check_tsv <nombre> <campo> <esperado> <head> <reviews...> -- <comments...>:
# como check(), pero compara un campo cualquiera de la salida de --decide, no
# solo la acción (campo 1). La usa DEVKIT-101 para el campo 5 (informe).
check_tsv() {
  local name=$1 field=$2 want=$3 head=$4; shift 4
  local reviews=() comments=() got
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do reviews+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  comments=("$@")
  got=$(printf '{"headRefOid":"%s","reviews":[%s],"comments":[%s]}' \
          "$head" "$(join "${reviews[@]}")" "$(join "${comments[@]}")" \
        | bash "$WATCH" --decide | cut -f"$field")
  if [ "$got" = "$want" ]; then
    printf 'ok   %-58s %s\n' "$name" "$got"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
    fail=1
  fi
}

check "PR sin marcadores" revisar a1 --
check "CAMBIOS para el head, sin respuesta" fix a1 "$(rev T01 a1 CAMBIOS)" --
check "CAMBIOS respondido con head nuevo" revisar b2 "$(rev T01 a1 CAMBIOS)" -- "$(fix T02 b2 a1)"
check "CAMBIOS respondido sin cambiar el head (DEVKIT-22)" revisar a1 "$(rev T01 a1 CAMBIOS)" -- "$(fix T02 a1 a1)"
check "OK para el head, sin documentar (DEVKIT-55)" documentar a1 "$(rev T01 a1 OK)" --
check "OK para el head, ya documentado" nada a1 "$(rev T01 a1 OK)" -- "$(doc T02 a1)"
check "OK para un head nuevo, documentado solo el anterior" documentar b2 \
  "$(rev T01 a1 OK)" "$(rev T04 b2 OK)" -- "$(doc T02 a1)" "$(fix T03 b2 a1)"
check "OK y comentario humano antes de documentar: primero corrige" fix-humano a1 \
  "$(rev T01 a1 OK)" -- "$(comment humano T02 'cambia X')"
check "CAMBIOS con documentación de un OK anterior: no documenta" fix b2 \
  "$(rev T01 a1 OK)" "$(rev T03 b2 CAMBIOS)" -- "$(doc T02 a1)"
check "OK y comentario humano posterior" fix-humano a1 "$(rev T01 a1 OK)" -- "$(comment humano T02 'falta la prueba X')"
check "OK y approve humano con texto" nada a1 "$(rev T01 a1 OK)" "$(review humano APPROVED T02 'bien')" -- "$(doc T03 a1)"
check "comentario humano anterior al marcador" nada a1 "$(rev T02 a1 OK)" -- "$(comment humano T01 'antes')" "$(doc T03 a1)"
# Guarda de tres ciclos (DEVKIT-56): solo bloquea con el último CAMBIOS sobre
# el head vigente. Un CAMBIOS sobre un head ya superado se revisa primero.
check "tres ciclos respondidos, CAMBIOS sobre head superado: revisa" revisar d4 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fix T06 d4 c3)"
check "tres ciclos respondidos y CAMBIOS sobre el head vigente" bloquear d4 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" "$(rev T07 d4 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fix T06 d4 c3)"
check "tres ciclos, el último respondido sin push" bloquear c3 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fix T06 c3 c3)"
# Fix manual (PR 38): un task-fix que no lanzó el bucle marca `manual=1` y el
# conteo vuelve a cero. Su head nuevo se revisa, y un CAMBIOS sobre él se
# corrige en vez de bloquear, como sí pasa sin la marca (caso anterior a este).
check "fix manual tras tres CAMBIOS: revisa el head nuevo" revisar d4 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fixm T06 d4 c3)"
check "CAMBIOS sobre el head del fix manual: corrige, no bloquea" fix d4 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" "$(rev T07 d4 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fixm T06 d4 c3)"
check "fix manual sin push tras tres CAMBIOS: revisa" revisar c3 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fixm T06 c3 c3)"
check "tercer CAMBIOS todavía pendiente" fix c3 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)"
check "bloqueo posterior al último informe" bloqueado d4 \
  "$(rev T05 c3 CAMBIOS)" -- "$(fix T06 d4 c3)" "$(block T07 d4)"
check "bloqueo y comentario humano" fix-humano d4 \
  "$(rev T05 c3 CAMBIOS)" -- "$(fix T06 d4 c3)" "$(block T07 d4)" "$(comment humano T08 'sigue así')"
check "bloqueo, comentario humano y respuesta con head nuevo (caso J)" revisar e5 \
  "$(rev T05 c3 CAMBIOS)" -- "$(fix T06 d4 c3)" "$(block T07 d4)" "$(comment humano T08 'sigue así')" "$(fix T09 e5 d4)"
check "informe CAMBIOS nuevo tras el bloqueo reinicia el conteo" fix e5 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" "$(rev T10 e5 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fix T06 d4 c3)" "$(block T07 d4)" "$(comment humano T08 'sigue')" "$(fix T09 e5 d4)"

# --- El informe habilita un lanzamiento nuevo aunque el head no cambie
# (DEVKIT-101) ----------------------------------------------------------------
# PR 68 (DEVKIT-94): CAMBIOS en 1f31202 (22:23), task-fix respondió sin
# commits (22:30) y una segunda revisión CAMBIOS sobre el mismo head (22:31)
# no relanzaba task-fix, porque `launched` solo llevaba el sha y ya tenía
# `fix:68:1f31202` de la primera ronda. El campo 5 (informe) es el
# `submittedAt` del último devkit-review: cambia en cada ronda aunque el head
# se repita, así que la clave de `launched` que arma watch.sh (`fix:$num:$ref:
# $informe`) también cambia.
check_tsv "DEVKIT-101: informe de la primera ronda CAMBIOS" 5 T01 a1 "$(rev T01 a1 CAMBIOS)" --
check "DEVKIT-101: primera ronda, sin respuesta todavía" fix a1 "$(rev T01 a1 CAMBIOS)" --
check_tsv "DEVKIT-101: informe de la segunda ronda, tras fix sin push" 5 T03 a1 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 a1 CAMBIOS)" -- "$(fix T02 a1 a1)"
check "DEVKIT-101: segundo CAMBIOS sobre el mismo head vuelve a pedir fix" fix a1 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 a1 CAMBIOS)" -- "$(fix T02 a1 a1)"
# Tres rondas de CAMBIOS respondidas sin empujar nunca un commit (el head no
# cambia en ningún momento): la guarda de tres ciclos (DEVKIT-56) sigue
# contando igual y bloquea apenas se responde la tercera, sin esperar una
# cuarta revisión.
check "DEVKIT-101: tercer CAMBIOS respondido sin push bloquea por la guarda" bloquear a1 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 a1 CAMBIOS)" "$(rev T05 a1 CAMBIOS)" -- \
  "$(fix T02 a1 a1)" "$(fix T04 a1 a1)" "$(fix T06 a1 a1)"

# --- Un comentario humano manda sobre corregir, no solo sobre documentar
# (DEVKIT-101, ampliación del 2026-09-18 18:20) -------------------------------
# Antes, `fix-humano` solo salía con el último informe OK: con CAMBIOS
# vigente (respondido o no) el comentario se ignoraba y la rama fix seguía
# chocando con `launched` (PR 68, comentario del humano a las 18:08).
check "DEVKIT-101: CAMBIOS pendiente y comentario humano posterior: atiende el comentario" fix-humano a1 \
  "$(rev T01 a1 CAMBIOS)" -- "$(comment humano T02 'urgente: revierte esto')"
check "DEVKIT-101: CAMBIOS ya respondido y comentario humano posterior: atiende el comentario" fix-humano a1 \
  "$(rev T01 a1 CAMBIOS)" -- "$(fix T02 a1 a1)" "$(comment humano T03 'espera, no lo hagas así')"

# --- Un informe no consume un comentario humano pendiente (DEVKIT-101,
# ampliación del 2026-09-18 19:15) --------------------------------------------
# PR 68: comentario humano a las 19:09, informe OK a las 19:13. El corte para
# "qué comentario ya está atendido" era el último marcador de cualquier tipo
# (incluidas las revisiones), así que el informe posterior lo tapaba y el
# comentario se perdía. El corte correcto es el último devkit-fix (o
# devkit-block): un devkit-review no atiende comentarios, solo corrige.
check "DEVKIT-101: comentario humano tras un fix, con un OK posterior: no se pierde" fix-humano a1 \
  "$(rev T03 a1 OK)" -- "$(fix T01 a1 a0)" "$(comment humano T02 'falta validar el caso límite')"
# El caso ya cubierto por "comentario humano anterior al marcador" (arriba)
# sigue sin cambiar: sin ningún devkit-fix todavía, el corte sigue siendo el
# último devkit-review, para no reabrir un comentario que ya quedó atrás
# cuando el ciclo cerró con OK y se documentó.

# --- Rama de cierre: PRs ya mergeados (DEVKIT-24) ---------------------------
# Otra decisión y otra entrada: `--decide-merged` solo mira los comentarios,
# porque un PR mergeado ya no tiene head que revisar.
# check_merged <nombre> <acción esperada> <comments...>
check_merged() {
  local name=$1 want=$2; shift 2
  local got
  got=$(printf '{"comments":[%s]}' "$(join "$@")" \
        | bash "$WATCH" --decide-merged | cut -f1)
  if [ "$got" = "$want" ]; then
    printf 'ok   %-58s %s\n' "$name" "$got"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
    fail=1
  fi
}

check_merged "mergeado sin marcador de cierre" cerrar
check_merged "mergeado con el ciclo de revisión, sin cierre" cerrar \
  "$(fix T02 b2 a1)" "$(block T07 d4)" "$(comment humano T08 'gracias')"
check_merged "mergeado y ya cerrado" cerrada "$(closed T09 f6)"
check_merged "cerrado por el humano desde otra sesión" cerrada \
  "$(comment humano T09 '<!-- devkit-closed sha=f6 -->')"
check_merged "cerrado tras el ciclo completo" cerrada \
  "$(fix T02 b2 a1)" "$(closed T09 f6)"
# Un marcador sin sha hexadecimal no es evidencia de cierre: el bucle vuelve a
# lanzar task-close, que con el mismo patrón lo republica bien.
check_merged "marcador sin sha válido" cerrar \
  "$(comment "$BOT" T09 '<!-- devkit-closed sha=null -->')"
check_merged "marcador sin sha" cerrar \
  "$(comment "$BOT" T09 '<!-- devkit-closed -->')"

# El sha del marcador es lo que el bucle registra en el log: se comprueba
# aparte, porque un marcador que no devuelve su sha no serviría de evidencia.
sha=$(printf '{"comments":[%s]}' "$(closed T09 f6)" \
      | bash "$WATCH" --decide-merged | cut -f2)
if [ "$sha" = "f6" ]; then
  printf 'ok   %-58s %s\n' "sha del marcador de cierre" "$sha"
else
  printf 'FAIL %-58s esperado f6, obtenido %s\n' "sha del marcador de cierre" "${sha:-<vacío>}"
  fail=1
fi

# --- Cuota agotada: detección, hora de reinicio y relanzamiento (DEVKIT-27) --
# Nada de esto toca GitHub ni gasta cuota: los hooks `--quota-hit`,
# `--quota-reset` y `--run-skill` de watch.sh reciben logs falsos, y el
# relanzamiento corre contra un doble de `claude` que cuenta sus llamadas.

# check_quota_hit <nombre> <si|no> <texto del log>
check_quota_hit() {
  local name=$1 want=$2 text=$3 got=no
  printf '%s' "$text" | bash "$WATCH" --quota-hit && got=si
  if [ "$got" = "$want" ]; then
    printf 'ok   %-58s %s\n' "$name" "$got"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "$got"
    fail=1
  fi
}

check_quota_hit "aviso legible por máquina" si "Claude AI usage limit reached|1757558400"
check_quota_hit "aviso de sesión para el humano" si "You have hit your session limit. Your limit will reset at 3pm (America/Los_Angeles)."
check_quota_hit "aviso semanal" si "Weekly limit reached - resets Feb 3 at 10am"
check_quota_hit "fallo que no es de cuota" no "Error: connection refused al conectar con api.github.com"
check_quota_hit "log de una ejecución normal" no '{"result":"listo","total_cost_usd":0.42,"num_turns":7}'

# check_quota_reset <nombre> <epoch esperado o vacío> <texto del log>
check_quota_reset() {
  local name=$1 want=$2 text=$3 got
  got=$(printf '%s' "$text" | bash "$WATCH" --quota-reset)
  if [ "$got" = "$want" ]; then
    printf 'ok   %-58s %s\n' "$name" "${got:-<vacío>}"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "${want:-<vacío>}" "${got:-<vacío>}"
    fail=1
  fi
}

check_quota_reset "epoch en segundos" 1757558400 \
  '{"result":"Claude AI usage limit reached|1757558400","is_error":true}'
check_quota_reset "epoch en milisegundos" 1757558400 \
  '{"result":"Claude AI usage limit reached|1757558400000","is_error":true}'
check_quota_reset "sin hora legible" "" \
  "You have hit your usage limit. Try again later."
check_quota_reset "texto que no habla de límites" "" "Error: connection refused"

# La hora del humano se compara con el mismo cálculo de `date`, no con un epoch
# fijo: depende del día en que corra la prueba y de la zona del contenedor.
want_local() {  # want_local <zona o -> <hh:mm>
  local tz=$1 hhmm=$2 t now
  if [ "$tz" = "-" ]; then t=$(date -d "$hhmm" +%s); else t=$(TZ="$tz" date -d "$hhmm" +%s); fi
  now=$(date +%s)
  [ "$t" -le "$now" ] && t=$((t + 86400))
  printf '%s' "$t"
}
check_quota_reset "hora con zona explícita" "$(want_local America/Los_Angeles 15:00)" \
  "You have hit your session limit. Your limit will reset at 3pm (America/Los_Angeles)."
check_quota_reset "hora sin zona, con minutos" "$(want_local - 10:30)" \
  "5-hour limit reached - resets 10:30am"
check_quota_reset "fecha y hora del límite semanal" "$(date -d 'Feb 3 10:00' +%s)" \
  "Weekly limit reached - resets Feb 3 at 10am"

# Relanzamiento de punta a punta, con un doble de `claude` que cuenta sus
# llamadas. `DEVKIT_TEST_FAILS` dice cuántas de ellas mueren por cuota y
# `DEVKIT_TEST_MSG` con qué aviso; el resto responde como una ejecución normal.
DOBLE="$TMP/claude"
cat >"$DOBLE" <<'FIN'
#!/usr/bin/env bash
n=$(( $(cat "$DEVKIT_TEST_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$DEVKIT_TEST_COUNT"
if [ "$n" -le "${DEVKIT_TEST_FAILS:-1}" ]; then
  printf '{"result":"%s","is_error":true}\n' \
    "${DEVKIT_TEST_MSG:-Claude AI usage limit reached|@RESET@}" \
    | sed "s/@RESET@/$(( $(date +%s) + 2 ))/"
  exit 1
fi
[ "${DEVKIT_TEST_SLEEP:-0}" = "0" ] || sleep "$DEVKIT_TEST_SLEEP"
printf '{"result":"%s","total_cost_usd":0.01,"num_turns":3}\n' "${DEVKIT_TEST_RESULT:-listo}"
FIN
chmod +x "$DOBLE"

# Doble de review-prep.sh (DEVKIT-93): estas pruebas son sobre cuota, alarmas
# y el lanzador, no sobre la preparación de pr-review, así que siempre dice
# "hay algo que revisar" y no toca gh ni Notion. `run_claude` lo llama antes
# del doble de `claude` para cualquier prompt "/pr-review ...".
REVIEW_PREP_DOBLE="$TMP/review-prep"
cat >"$REVIEW_PREP_DOBLE" <<'FIN'
#!/usr/bin/env bash
echo "## Card
material de prueba"
FIN
chmod +x "$REVIEW_PREP_DOBLE"

# Cache de disponibilidad de frontera, precargada como "si" para los tres
# modelos de `devkit/agents/roles.toml` (DEVKIT-54): sin esto,
# `devkit-run.sh --rol` invocaría el doble una vez más solo para comprobar
# disponibilidad, y esa llamada de más contaría como un lanzamiento real y se
# llevaría el turno de "falla por cuota" que arman las pruebas de abajo.
FRONTERA_CACHE="$TMP/frontera-cache"
mkdir -p "$FRONTERA_CACHE"
for m in fable opus sonnet; do printf 'si' > "$FRONTERA_CACHE/$m"; done

OUT=""  # log de la última corrida del doble, que miran las comprobaciones
LLAMADAS=0

# corre_doble <fallos> [aviso]: una ejecución de run_skill contra el doble,
# en su propio RUN_DIR. Deja el log en $OUT y el conteo en $LLAMADAS.
# ROLES_OVERRIDE, NOTION_OVERRIDE, BLOCK_OVERRIDE y CLAVE_OVERRIDE (variables
# de entorno, vacías por defecto y sin efecto en ese caso): los usa el caso de
# presupuesto de turnos (DEVKIT-94) para forzar un roles.toml con un tope bajo
# y comprobar el bloqueo, sin tocar los casos de cuota de arriba.
corre_doble() {
  local dir
  dir=$(mktemp -d -p "$TMP")
  OUT="$dir/watch.log"
  # PRESEED simula lo que ya hay en `launched` cuando arranca la ejecución.
  if [ -n "${PRESEED:-}" ]; then mkdir -p "$dir/run"; echo "$PRESEED" > "$dir/run/launched"; fi
  DEVKIT_TEST_COUNT="$dir/llamadas" DEVKIT_TEST_FAILS="$1" DEVKIT_TEST_MSG="${2:-}" \
  DEVKIT_TEST_SLEEP="${DEVKIT_TEST_SLEEP:-0}" DEVKIT_TEST_RESULT="${DEVKIT_TEST_RESULT:-listo}" \
  DEVKIT_CLAUDE_BIN="$DOBLE" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_REVIEW_PREP_BIN="${REVIEW_PREP_OVERRIDE:-$REVIEW_PREP_DOBLE}" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
  DEVKIT_ROLES_FILE="${ROLES_OVERRIDE:-}" DEVKIT_NOTION_BIN="${NOTION_OVERRIDE:-}" \
  DEVKIT_TASK_BLOCK_BIN="${BLOCK_OVERRIDE:-}" \
  DEVKIT_WATCH_QUOTA_MIN_WAIT=1 DEVKIT_WATCH_QUOTA_WAIT=2 \
  DEVKIT_WATCH_QUOTA_RETRIES="${RETRIES:-3}" \
  DEVKIT_WATCH_SKILL_TIMEOUT="${DEVKIT_WATCH_SKILL_TIMEOUT:-1200}" \
  DEVKIT_WATCH_SKILL_POLL="${DEVKIT_WATCH_SKILL_POLL:-5}" \
    bash "$WATCH" --run-skill "${NOMBRE:-pr-review-9-abc1234}" "${PROMPT:-/pr-review 9}" "revisar:9:abc1234" \
    "${CLAVE_OVERRIDE:-}" \
    >"$OUT" 2>&1
  LLAMADAS=$(cat "$dir/llamadas" 2>/dev/null || echo 0)
  LAUNCHED_FILE="$dir/run/launched"
  # `forzar_task_block` (devkit-run.sh) escribe su ALARMA directo en
  # `$RUN_DIR/watch.log`, no por stdout: no queda en $OUT, que aquí es un
  # archivo distinto (DEVKIT-94).
  RUN_WATCH_LOG="$dir/run/watch.log"
}

# check_log <nombre> <patrón>
check_log() {
  if grep -qE "$2" "$OUT"; then
    printf 'ok   %-58s %s\n' "$1" "$(grep -oE "$2" "$OUT" | head -1)"
  else
    printf 'FAIL %-58s no aparece /%s/ en el log\n' "$1" "$2"
    fail=1
  fi
}

# check_igual <nombre> <esperado> <obtenido>
check_igual() {
  if [ "$2" = "$3" ]; then
    printf 'ok   %-58s %s\n' "$1" "$3"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$1" "$2" "${3:-<vacío>}"
    fail=1
  fi
}

# Caso normal: muere por cuota, espera a la hora del aviso y vuelve a correr.
corre_doble 1
check_log "línea de pausa por cuota" 'cuota agotada: pr-review-9-abc1234 en pausa hasta [0-9T:+-]+'
check_log "línea de reanudación" 'cuota reanudada: relanzando pr-review-9-abc1234'
check_log "la skill relanzada terminó bien" 'pr-review-9-abc1234 terminado'
check_igual "la skill se lanzó dos veces" 2 "$LLAMADAS"
# Durante la pausa la entrada de `launched` se reescribe como `cuota:<clave>` y
# al relanzar vuelve a su forma: así el bucle no lanza una segunda copia y la
# entrada tampoco impide el relanzamiento.
check_igual "launched restituido tras el relanzamiento" "revisar:9:abc1234" \
  "$(tr '\n' ' ' <"$LAUNCHED_FILE" 2>/dev/null | sed 's/ *$//')"

# Aviso sin hora legible: espera fija documentada y relanza igual.
corre_doble 1 "You have hit your usage limit. Try again later."
check_log "espera fija sin hora de reinicio" 'sin hora de reinicio legible en el aviso; espera fija de 2s'
check_igual "relanzada tras la espera fija" 2 "$LLAMADAS"

# Un solo relanzamiento en curso por skill y PR: si la entrada ya está en
# pausa, la segunda caída por cuota no programa otra espera.
PRESEED="cuota:revisar:9:abc1234" corre_doble 1
check_log "no se duplica el relanzamiento" 'ya tiene un relanzamiento programado; no se duplica'
check_igual "la skill se lanzó una sola vez" 1 "$LLAMADAS"

# Tope de intentos: con dos permitidos, el tercero no se programa.
RETRIES=2 corre_doble 9
check_log "tope de intentos alcanzado" 'cuota agotada: pr-review-9-abc1234 sin más intentos \(tope de 2\)'
check_igual "no pasa del tope" 2 "$LLAMADAS"

# --- devkit-run como único punto de lanzamiento (DEVKIT-45/DEVKIT-54) ------
# run_skill delega en devkit-run.sh, que resuelve modelo y esfuerzo por rol
# desde roles.toml; pr-review siempre cae en el rol "revision" (el segundo
# modelo de la lista `frontera`, DEVKIT-72), sin importar el Tipo de la card.
corre_doble 0
check_log "la línea de resumen trae el modelo del rol de revisión" \
  'modelo=opus esfuerzo=high'
# DEVKIT-57: la línea "lanzando" con origen, prompt y log, que lee
# `devkit-run --estado`.
check_log "run_skill deja la línea lanzando con origen, modelo y esfuerzo" \
  'pr-review-9-abc1234 lanzando \(origen=bucle\) modelo=opus esfuerzo=high ronda=-: "/pr-review 9" log=[^ ]+/pr-review-9-abc1234\.log$'

# --- Transcripción del claude -p real, junto al log (DEVKIT-102) -----------
# `guardar_transcripcion` (dentro de `run_skill`) copia el primer turno de
# usuario y el resultado del `.jsonl` de sesión real -el mismo que hubo que
# rastrear a mano para diagnosticar el PR 68- a
# `$RUN_DIR/<nombre>-transcript.jsonl`. `DEVKIT_CLAUDE_PROJECTS_DIR` apunta a
# un directorio de prueba en vez de `~/.claude/projects`.
trans_dir=$(mktemp -d -p "$TMP")
trans_slug=$(printf '%s' "$trans_dir" | tr '/' '-')
mkdir -p "$trans_dir/proyectos/$trans_slug" "$trans_dir/run"
cat >"$trans_dir/proyectos/$trans_slug/11111111-1111-1111-1111-111111111111.jsonl" <<'FIN'
{"type":"user","message":{"role":"user","content":"<command-message>task-fix</command-message>\n<command-args>DEVKIT-94\n67\thttps://github.com/o/r/pull/67\tDEVKIT-93 otro PR</command-args>"}}
{"type":"assistant","message":{"role":"assistant","content":"trabajando"}}
FIN
TRANS_DOBLE="$TMP/claude-transcripcion"
cat >"$TRANS_DOBLE" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":4,"session_id":"11111111-1111-1111-1111-111111111111"}\n'
FIN
chmod +x "$TRANS_DOBLE"
DEVKIT_CLAUDE_BIN="$TRANS_DOBLE" DEVKIT_RUN_DIR="$trans_dir/run" DEVKIT_WS="$trans_dir" \
  DEVKIT_CLAUDE_PROJECTS_DIR="$trans_dir/proyectos" DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
  bash "$WATCH" --run-skill "task-fix-68-abc1234" "/task-fix DEVKIT-94" "fix:68:abc1234" >/dev/null 2>&1
check_igual "transcripción: el archivo aparece junto al log" 1 \
  "$([ -f "$trans_dir/run/task-fix-68-abc1234-transcript.jsonl" ] && echo 1 || echo 0)"
check_igual "transcripción: trae el primer mensaje de usuario, argumento incluido" 1 \
  "$(grep -c 'DEVKIT-94.*67.*pull/67.*DEVKIT-93' "$trans_dir/run/task-fix-68-abc1234-transcript.jsonl" 2>/dev/null)"
check_igual "transcripción: trae el resultado (num_turns)" 1 \
  "$(grep -c '"num_turns":4' "$trans_dir/run/task-fix-68-abc1234-transcript.jsonl" 2>/dev/null)"
check_igual "transcripción: dos líneas, no la sesión entera" 2 \
  "$(wc -l <"$trans_dir/run/task-fix-68-abc1234-transcript.jsonl" 2>/dev/null | tr -d ' ')"

# Sin session_id en el resultado -un `claude -p` viejo, o uno que murió antes
# de terminar la respuesta-: no hay nada que copiar, y no debe fallar por eso.
TRANS_DOBLE_SIN_SESION="$TMP/claude-sin-sesion"
cat >"$TRANS_DOBLE_SIN_SESION" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":4}\n'
FIN
chmod +x "$TRANS_DOBLE_SIN_SESION"
DEVKIT_CLAUDE_BIN="$TRANS_DOBLE_SIN_SESION" DEVKIT_RUN_DIR="$trans_dir/run" DEVKIT_WS="$trans_dir" \
  DEVKIT_CLAUDE_PROJECTS_DIR="$trans_dir/proyectos" DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
  bash "$WATCH" --run-skill "task-fix-70-sinsesion" "/task-fix DEVKIT-70" "fix:70:sinsesion" >/dev/null 2>&1
check_igual "transcripción: sin session_id no revienta ni deja archivo" 0 \
  "$([ -e "$trans_dir/run/task-fix-70-sinsesion-transcript.jsonl" ] && echo 1 || echo 0)"

# --- review-prep.sh sin nada que revisar (DEVKIT-93) -------------------------
# `run_claude` corta con rc=3 antes de llamar a `claude -p`; `run_skill` debe
# leerlo como un cierre normal (sin ALARMA, sin reintento de cuota) y no como
# un error. Un PR de seis líneas de documentación pagó 33 turnos en Opus solo
# en "ya revisado" (DEVKIT-74); este es el caso que ya no debe costar nada.
REVIEW_PREP_NADA="$TMP/review-prep-nada"
cat >"$REVIEW_PREP_NADA" <<'FIN'
#!/usr/bin/env bash
echo "ya revisado en abc123"
exit 3
FIN
chmod +x "$REVIEW_PREP_NADA"
REVIEW_PREP_OVERRIDE="$REVIEW_PREP_NADA" corre_doble 0
check_log "nada que revisar: el motivo queda en watch.log sin ALARMA" \
  'pr-review-9-abc1234 no lanzó: nada que revisar \(ya revisado en abc123\)'
check_igual "nada que revisar: sin ALARMA en el log" 0 "$(grep -c ALARMA "$OUT")"
check_igual "nada que revisar: no llamó a claude -p (cero turnos de Opus)" 0 "$LLAMADAS"

# Un comentario humano con acentos de más de 120 bytes: el corte es por
# caracteres, así que la línea sigue siendo UTF-8 válido y --estado la muestra.
NOMBRE=fix-humano-9 PROMPT="/task-fix DEVKIT-9 $(printf 'á%.0s' $(seq 1 80))" corre_doble 0
check_igual "prompt acentuado largo: la línea lanzando es UTF-8 válido" 0 \
  "$(iconv -f UTF-8 -t UTF-8 "$OUT" >/dev/null 2>&1; echo $?)"
check_igual "prompt acentuado largo: devkit-run --estado lo muestra" 1 \
  "$(DEVKIT_WATCH_LOG="$OUT" DEVKIT_RUN_DIR="$(dirname "$OUT")/run" bash "$HERE/devkit-run.sh" --estado 2>&1 \
    | grep -c 'DEVKIT-9')"

# --- Presupuesto de turnos, meta que avisa sin bloquear (DEVKIT-94, DEVKIT-105)
# `run_skill` lanza pr-review con `devkit-run.sh --sync`, no con `--worker`:
# `presupuesto.<skill>` de roles.toml solo cortaba en `--worker` (task-start
# manual, task-close, epic-plan) y aquí se quedaba solo como aviso en la
# línea de resumen (H1 del informe sobre el PR #68). DEVKIT-105 quitó el
# corte por completo -exceder el presupuesto nunca bloquea la card, es una
# meta de optimización- así que ahora las dos rutas terminan igual: ALARMA en
# watch.log y un comentario en la card, sin llamar a task-block.sh. roles.toml
# real del template, con `presupuesto.pr-review` bajado a 1: el doble de
# `claude` de arriba siempre responde `num_turns=3`, así que lo excede.
# `/pr-review 9` no trae la Clave en el prompt (a diferencia de
# task-fix/task-document): CLAVE_OVERRIDE reproduce lo que `watch.sh` le
# pasaría desde el título del PR.
ROLES_PRESUPUESTO="$TMP/roles-presupuesto-pr-review.toml"
sed -E 's/^presupuesto\.pr-review = [0-9]+/presupuesto.pr-review = 1/' \
  "$HERE/../agents/roles.toml" > "$ROLES_PRESUPUESTO"
COMENTARIOS_PRESUPUESTO="$TMP/comentarios-presupuesto"
NOTION_PRESUPUESTO="$TMP/notion-presupuesto"
cat >"$NOTION_PRESUPUESTO" <<FIN
#!/usr/bin/env bash
case "\$1" in
  card) printf '{"id":"card-9","clave":"%s","estado":"Revisión automática"}\n' "\$2" ;;
  comentar) printf '%s\t%s\n' "\$2" "\$3" >>"$COMENTARIOS_PRESUPUESTO" ;;
esac
FIN
chmod +x "$NOTION_PRESUPUESTO"
BLOQUEO_PRESUPUESTO="$TMP/task-block-presupuesto"
cat >"$BLOQUEO_PRESUPUESTO" <<'FIN'
#!/usr/bin/env bash
printf '%s|' "$@" >"$DEVKIT_TEST_BLOQUEO"
FIN
chmod +x "$BLOQUEO_PRESUPUESTO"
BLOQUEO_PRESUPUESTO_LOG="$TMP/bloqueo-presupuesto.args"
rm -f "$BLOQUEO_PRESUPUESTO_LOG" "$COMENTARIOS_PRESUPUESTO"
ROLES_OVERRIDE="$ROLES_PRESUPUESTO" NOTION_OVERRIDE="$NOTION_PRESUPUESTO" \
  BLOCK_OVERRIDE="$BLOQUEO_PRESUPUESTO" CLAVE_OVERRIDE="DEVKIT-9" \
  DEVKIT_TEST_BLOQUEO="$BLOQUEO_PRESUPUESTO_LOG" corre_doble 0
check_igual "presupuesto: la ALARMA de exceso queda en el watch.log real" 1 \
  "$(grep -coE 'ALARMA: presupuesto excedido \(3 turnos, presupuesto 1\)' "$RUN_WATCH_LOG" 2>/dev/null)"
check_igual "presupuesto: no llama a task-block.sh" "" \
  "$(cat "$BLOQUEO_PRESUPUESTO_LOG" 2>/dev/null)"
check_igual "presupuesto: comenta en la Clave que pasó watch.sh, no la del prompt" "card-9" \
  "$(cut -f1 "$COMENTARIOS_PRESUPUESTO" 2>/dev/null)"
check_igual "presupuesto: el comentario cita el presupuesto y los turnos usados" 1 \
  "$(grep -coE 'Presupuesto excedido: 3 turnos contra 1 en pr-review; el ciclo sigue' "$COMENTARIOS_PRESUPUESTO" 2>/dev/null)"
ROLES_OVERRIDE="" NOTION_OVERRIDE="" BLOCK_OVERRIDE="" CLAVE_OVERRIDE=""

# --- Costo total del ciclo de un PR (DEVKIT-45) ------------------------------
# cycle_cost suma "costo=" de todas las líneas de un PR en watch.log, no solo
# la del último task-close: una card puede pasar por varias rondas.
CYCLE_LOG=$(mktemp -p "$TMP")
cat >"$CYCLE_LOG" <<'FIN'
2026-09-15T10:00:00Z pr-review-31-a1b2c3d terminado: modelo=claude-opus-5 esfuerzo=high costo=0.10 turnos=5 :: revisado
2026-09-15T10:05:00Z task-fix-31-a1b2c3d terminado: modelo=claude-sonnet-5 esfuerzo=medium costo=0.20 turnos=8 :: corregido
2026-09-15T10:10:00Z pr-review-31-e4f5g6h terminado: modelo=claude-opus-5 esfuerzo=high costo=0.15 turnos=4 :: revisado otra vez
2026-09-15T10:20:00Z task-close-31 terminado: modelo=claude-haiku-4-5-20251001 esfuerzo=low costo=0.01 turnos=2 :: cerrada
2026-09-15T09:00:00Z pr-review-310-zzzzzzz terminado: modelo=claude-opus-5 esfuerzo=high costo=9.00 turnos=1 :: otro PR, no debe sumar
2026-09-15T10:25:00Z task-fix-31-humano-20260915T102500Z terminado: modelo=claude-sonnet-5 esfuerzo=medium costo=0.05 turnos=3 :: comentario humano
FIN
CYCLE_TOTAL=$(bash "$WATCH" --cycle-cost 31 "$CYCLE_LOG")
check_igual "costo total del ciclo suma todas las rondas del PR" "0.5100" "$CYCLE_TOTAL"

CYCLE_EMPTY=$(bash "$WATCH" --cycle-cost 999 "$CYCLE_LOG")
check_igual "costo del ciclo de un PR sin líneas es 0" "0.0000" "$CYCLE_EMPTY"

# --- Monitoreo mínimo sin modelo: las cuatro alarmas (DEVKIT-46) ------------
# Un caso por alarma, sin gastar cuota ni tocar GitHub: las tres primeras
# contra el doble de `claude` de más arriba; la cuarta, contra la decisión
# pura `orphan_branch_alarm` vía el hook `--orphan-branch`.

# 1. Skill que termina con error, sin relación con la cuota: no dispara el
# relanzamiento (queda para ver en el log), solo la alarma.
corre_doble 1 "Error: algo se rompió, sin relación con la cuota"
check_log "alarma por skill con error" 'ALARMA: pr-review-9-abc1234 terminó con error \(rc=1\)'
check_igual "un error que no es de cuota no reintenta" 1 "$LLAMADAS"

# 2. Skill que supera el límite de tiempo mientras sigue corriendo: el doble
# duerme más que DEVKIT_WATCH_SKILL_TIMEOUT, sondeado cada DEVKIT_WATCH_SKILL_POLL.
DEVKIT_TEST_SLEEP=2 DEVKIT_WATCH_SKILL_TIMEOUT=1 DEVKIT_WATCH_SKILL_POLL=1 corre_doble 0
check_log "alarma por skill que excede el tiempo límite" \
  'ALARMA: pr-review-9-abc1234 lleva [0-9]+ min corriendo \(límite 1s\)'

# 3. `result` que termina en pregunta en vez de resolver en un estado
# observable (el defecto de DEVKIT-17/26/40 que AGENTS.md prohíbe).
DEVKIT_TEST_RESULT='¿Sigo con esto?' corre_doble 0
check_log "alarma por result que termina en pregunta" \
  'ALARMA: pr-review-9-abc1234 terminó con una pregunta abierta'

# 3b. DEVKIT-77: el mismo camino (`--sync` -> `pregunta_abierta` vía
# `devkit-run --pregunta-abierta`) también alarma un cierre que no termina en
# "?", como el incidente real de DEVKIT-63.
DEVKIT_TEST_RESULT='Terminé de revisar el conflicto. ¿Cómo quieres que siga? Antes de tocar nada, prefiero confirmarlo contigo.' corre_doble 0
check_log "alarma por result con pregunta que no termina en ?" \
  'ALARMA: pr-review-9-abc1234 terminó con una pregunta abierta'

# 4. Rama de una card sin PR y sin skill viva hace más de
# DEVKIT_WATCH_ORPHAN_AGE segundos (1800 por defecto, sin sobreescribir aquí).
# check_orphan <nombre> <esperado si|no> <edad> <tiene PR> <skill viva>
check_orphan() {
  local name=$1 want=$2 got
  got=$(bash "$WATCH" --orphan-branch "$3" "$4" "$5")
  if [ "$got" = "$want" ]; then
    printf 'ok   %-58s %s\n' "$name" "$got"
  else
    printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
    fail=1
  fi
}
check_orphan "rama vieja, sin PR, sin skill viva: huérfana" si 1900 no no
check_orphan "rama vieja, sin PR, pero con skill viva: no es huérfana" no 1900 no si
check_orphan "rama vieja, ya con PR: no es huérfana" no 1900 si no
check_orphan "rama reciente, sin PR, sin skill viva: todavía no" no 1000 no no

# 5. Comando que lista los agentes vivos, con PID, Clave y paso (contenido de
# DEVKIT-19). El doble no es `claude`: es el mismo patrón de línea de proceso
# que arma `devkit-run.sh --worker` ("--worker /<skill> <Clave> ..."), así que
# no hace falta lanzar un `claude -p` de verdad para probar el comando.
FAKE_WORKER="$TMP/fake-worker.sh"
cat >"$FAKE_WORKER" <<'FIN'
#!/usr/bin/env bash
sleep 5
FIN
chmod +x "$FAKE_WORKER"
"$FAKE_WORKER" --worker /task-fix DEVKIT-46 extra "$TMP/fake.log" modelo-x esfuerzo-x 10 &
FAKE_PID=$!
sleep 0.3
AGENTES=$(bash "$WATCH" --agentes-vivos)
kill "$FAKE_PID" 2>/dev/null
wait "$FAKE_PID" 2>/dev/null
if printf '%s\n' "$AGENTES" | grep -qE "^${FAKE_PID}[[:space:]]+DEVKIT-46[[:space:]]+task-fix$"; then
  printf 'ok   %-58s %s\n' "agentes-vivos lista PID, Clave y paso" "$FAKE_PID DEVKIT-46 task-fix"
else
  printf 'FAIL %-58s no encontró la línea esperada en: %s\n' "agentes-vivos lista PID, Clave y paso" "$AGENTES"
  fail=1
fi

# Lo que lanza el bucle corre con `--sync`, no con `--worker`: antes de
# DEVKIT-57, --agentes-vivos no lo veía.
"$FAKE_WORKER" --sync /pr-review 41 &
FAKE_PID=$!
sleep 0.3
AGENTES=$(bash "$WATCH" --agentes-vivos)
kill "$FAKE_PID" 2>/dev/null
wait "$FAKE_PID" 2>/dev/null
if printf '%s\n' "$AGENTES" | grep -qE "^${FAKE_PID}[[:space:]]+\?[[:space:]]+pr-review$"; then
  printf 'ok   %-58s %s\n' "agentes-vivos ve lo que lanza el bucle (--sync)" "$FAKE_PID pr-review"
else
  printf 'FAIL %-58s no encontró la línea esperada en: %s\n' "agentes-vivos ve lo que lanza el bucle (--sync)" "$AGENTES"
  fail=1
fi

# Sin agentes vivos: mensaje claro y código 0 (DEVKIT-50; antes salía sin
# texto). Se fuerza con un `ps` de mentira, primero en PATH, porque el propio
# proceso de esta prueba puede correr dentro de un `devkit-run --worker` de
# verdad.
FAKE_PS_DIR="$TMP/fake-ps"
mkdir -p "$FAKE_PS_DIR"
cat >"$FAKE_PS_DIR/ps" <<'FIN'
#!/usr/bin/env bash
echo "  PID COMMAND"
FIN
chmod +x "$FAKE_PS_DIR/ps"
AGENTES_VACIO=$(PATH="$FAKE_PS_DIR:$PATH" bash "$WATCH" --agentes-vivos)
RC_VACIO=$?
if [ "$RC_VACIO" -eq 0 ] && [ "$AGENTES_VACIO" = "sin agentes vivos" ]; then
  printf 'ok   %-58s %s\n' "agentes-vivos sin agentes: mensaje claro y rc 0" "$AGENTES_VACIO"
else
  printf 'FAIL %-58s rc=%s salida=%s\n' "agentes-vivos sin agentes: mensaje claro y rc 0" "$RC_VACIO" "$AGENTES_VACIO"
  fail=1
fi

# --- Cierre y bloqueo en bash, documentación al aprobar (DEVKIT-55) --------
# Ciclo completo OK -> documentar -> merge -> cerrar, sin GitHub ni Notion:
# un `gh` de mentira en PATH, un doble de notion.sh que responde desde
# archivos y anota cada llamada, y un doble de devkit-run.sh que anota los
# lanzamientos. task-close.sh y task-block.sh son los reales.
CICLO="$TMP/ciclo"
mkdir -p "$CICLO/bin" "$CICLO/notion" "$CICLO/gh" "$CICLO/ws/.devkit" "$CICLO/run"
printf '[devkit]\nproject = "DEVKIT"\n' >"$CICLO/ws/.devkit/devkit.toml"

cat >"$CICLO/notion.sh" <<'FIN'
#!/usr/bin/env bash
d=$FAKE_NOTION
printf '%s\n' "$*" >>"$d/llamadas"
case "$1" in
  card) cat "$d/card-$2.json" 2>/dev/null || exit 1 ;;
  pagina) cat "$d/pagina-$2.json" 2>/dev/null || exit 1 ;;
  hijas) cat "$d/hijas-$2.json" 2>/dev/null || exit 1 ;;
  documentacion) cat "$d/doc-$2.json" 2>/dev/null || exit 1 ;;
  criterios) cat "$d/criterios-$2.txt" 2>/dev/null ;;
  set|comentar) ;;
  *) exit 64 ;;
esac
FIN
cat >"$CICLO/devkit-run.sh" <<'FIN'
#!/usr/bin/env bash
[ "$1" = --otros-agentes ] && exit 0
printf '%s\n' "$*" >>"$FAKE_NOTION/lanzamientos"
FIN
# Doble de cola.sh (DEVKIT-120): task-close.sh ya no elige la siguiente hija
# por su cuenta, se la pregunta a cola.sh. `$FAKE_NOTION/cola-siguiente`
# controla la respuesta; vacío o ausente, como cola.sh real sin nada que
# sugerir.
cat >"$CICLO/cola.sh" <<'FIN'
#!/usr/bin/env bash
cat "$FAKE_NOTION/cola-siguiente" 2>/dev/null
exit 0
FIN
# Doble de task-document.sh (DEVKIT-92): task-close.sh ya no lanza el agente
# para una card de Nivel Tarea, así que aquí no hace falta un `claude` de
# mentira; basta con anotar la llamada y responder como si hubiera escrito la
# entrada. `$FAKE_NOTION/task-document-falla` simula que no pudo.
cat >"$CICLO/task-document.sh" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_NOTION/task-document-llamadas"
if [ -f "$FAKE_NOTION/task-document-falla" ]; then
  echo "task-document: fake fallo" >&2
  exit 1
fi
echo "task-document: $1 documentado: https://notion.so/doc-3"
FIN
# gh de mentira: `pr list` devuelve la línea ya formateada que produciría el
# --jq de watch.sh; `pr view` distingue la consulta de watch.sh (solo
# comentarios) de la de task-close.sh (estado y merge commit).
cat >"$CICLO/bin/gh" <<'FIN'
#!/usr/bin/env bash
d=$FAKE_GH
case "$1 $2" in
  "pr list") cat "$d/mergeados" 2>/dev/null ;;
  "pr view") case "$*" in *state*) cat "$d/pr.json" ;; *) jq '{comments}' "$d/pr.json" ;; esac ;;
  "pr comment") printf '%s\n' "$*" >>"$d/comentarios" ;;
  *) exit 1 ;;
esac
FIN
chmod +x "$CICLO/notion.sh" "$CICLO/devkit-run.sh" "$CICLO/cola.sh" "$CICLO/task-document.sh" "$CICLO/bin/gh"

# tarea <id> <numero> <estado> <orden> <depende (ids separados por coma)>
tarea() {
  jq -nc --arg id "$1" --argjson n "$2" --arg e "$3" --argjson o "$4" --arg dep "$5" \
    '{id: $id, url: "https://notion.so/\($id)", numero: $n, clave: "DEVKIT-\($n)", estado: $e,
      nivel: "Tarea", prioridad: "alta", orden: $o, pr: null,
      rama: "https://github.com/o/r/tree/feat/DEVKIT-\($n)-algo",
      padre: ["epica-1"], depende: ($dep | split(",") | map(select(. != ""))), documentacion: []}'
}
N="$CICLO/notion"
tarea card-3 3 "Lista para merge" 1 "" >"$N/card-DEVKIT-3.json"
jq -nc '{id: "epica-1", numero: 1, clave: "DEVKIT-1", estado: "En progreso", nivel: "Épica", padre: []}' >"$N/pagina-epica-1.json"
# Tras el cierre, DEVKIT-3 ya figura Hecha entre las hijas. DEVKIT-5 tiene
# menor Orden pero depende de DEVKIT-6, que espera su merge en Lista para
# merge: la siguiente libre es DEVKIT-4.
printf '[%s,%s,%s,%s]' "$(tarea card-3 3 Hecha 1 "")" "$(tarea card-4 4 Lista 3 card-3)" \
  "$(tarea card-5 5 Lista 2 card-6)" "$(tarea card-6 6 "Lista para merge" 2 "")" >"$N/hijas-epica-1.json"
printf '{"id":"doc-3","url":"https://notion.so/doc-3"}' >"$N/doc-card-3.json"

# `ps` sin procesos: la prueba puede correr dentro de un `devkit-run --worker
# /task-start` de verdad, que cola.sh tomaría por una card ya lanzada.
cat >"$CICLO/ps-vacio" <<'FIN'
#!/usr/bin/env bash
exit 0
FIN
chmod +x "$CICLO/ps-vacio"
ciclo_env=(FAKE_NOTION="$N" FAKE_GH="$CICLO/gh" PATH="$CICLO/bin:$PATH"
           DEVKIT_NOTION_BIN="$CICLO/notion.sh" DEVKIT_RUN_BIN="$CICLO/devkit-run.sh"
           DEVKIT_COLA_BIN="$CICLO/cola.sh"
           DEVKIT_TASK_DOCUMENT_BIN="$CICLO/task-document.sh"
           DEVKIT_PS_BIN="$CICLO/ps-vacio"
           DEVKIT_WS="$CICLO/ws" DEVKIT_RUN_DIR="$CICLO/run" DEVKIT_HOY=2026-09-16)

# 1. OK del revisor: el bucle decide documentar.
check "ciclo: OK sin documentar" documentar a1 "$(rev T01 a1 OK)" --

# task-document.sh en bash para la entrada "cambio"; el agente solo si el
# cuerpo del PR trae "Tipo: decisión" (DEVKIT-92, absorbe DEVKIT-83 y
# DEVKIT-84: ya no hay ronda, modelo ni segundo lanzamiento que evitar).
DOC_FAKE="$TMP/task-document-fake"
mkdir -p "$DOC_FAKE"
cat >"$DOC_FAKE/task-document.sh" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOC_FAKE_LOG"
echo "task-document: $1 documentado: https://notion.so/doc-x"
FIN
chmod +x "$DOC_FAKE/task-document.sh"

corre_documentar() {  # corre_documentar <cuerpo del PR>
  local dir
  dir=$(mktemp -d -p "$TMP")
  OUT="$dir/watch.log"
  DOC_LOG="$dir/doc-llamadas"
  DOC_FAKE_LOG="$DOC_LOG" DEVKIT_TASK_DOCUMENT_BIN="$DOC_FAKE/task-document.sh" \
  DEVKIT_TEST_COUNT="$dir/claude-llamadas" DEVKIT_TEST_FAILS=0 \
  DEVKIT_CLAUDE_BIN="$DOBLE" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
    bash "$WATCH" --documentar 40 DEVKIT-3 a1 "$1" >"$OUT" 2>&1
  CLAUDE_LLAMADAS=$(cat "$dir/claude-llamadas" 2>/dev/null || echo 0)
}

corre_documentar "## Qué cambia
algo"
check_log "ciclo: sin marca, task-document.sh corre en bash" 'task-document-40-a1 terminado: bash ::'
check_igual "ciclo: task-document.sh recibe la Clave y el número de PR" "DEVKIT-3 40" \
  "$(cat "$DOC_LOG" 2>/dev/null)"
check_igual "ciclo: sin marca, no lanza el agente" 0 "$CLAUDE_LLAMADAS"

corre_documentar "Tipo: decisión

## Qué cambia
algo"
check_log "ciclo: con \"Tipo: decisión\", lanza el agente task-document" \
  'task-document-40-a1 lanzando \(origen=bucle\).*"/task-document DEVKIT-3 40"'
check_igual "ciclo: con \"Tipo: decisión\", no llama al script" 0 \
  "$([ -s "$DOC_LOG" ] && echo 1 || echo 0)"
check_igual "ciclo: con \"Tipo: decisión\", el agente corre" 1 "$CLAUDE_LLAMADAS"

# 2. task-document deja su marcador: ya no hay nada que hacer hasta el merge.
check "ciclo: documentado, espera el merge" nada a1 "$(rev T01 a1 OK)" -- "$(doc T02 a1)"

# 3. Merge: el bucle de mergeados cierra con task-close.sh.
MERGED_AT=$(date -u -d '-5 seconds' +%FT%TZ)
# La siguiente card de la cola, para la última comprobación de este bloque
# (DEVKIT-120): el doble de cola.sh responde DEVKIT-4, como antes elegía
# task-next.sh. Se limpia después de usarla para no interferir con el resto
# del ciclo (candados de doc, comentarios sin entrada, marcas de modelo...).
printf 'DEVKIT-4\n' >"$N/cola-siguiente"
printf '40\thttps://github.com/o/r/pull/40\t%s\tDEVKIT-3 algo\n' "$MERGED_AT" >"$CICLO/gh/mergeados"
jq -nc '{state: "MERGED", number: 40, url: "https://github.com/o/r/pull/40", headRefOid: "a1",
         mergeCommit: {oid: "f1"}, comments: [{body: "<!-- devkit-doc sha=a1 -->"}],
         body: "## Card\nhttps://notion.so/card-3\n\nImplementado con opus, esfuerzo high\r\n",
         reviews: [{submittedAt: "T02", body: "<!-- devkit-review sha=a1 verdict=OK -->\nRevisado con fable, esfuerzo high\n## Revisión"},
                   {submittedAt: "T01", body: "<!-- devkit-review sha=a0 verdict=CAMBIOS -->\nRevisado con sonnet, esfuerzo low\n## Revisión"}]}' >"$CICLO/gh/pr.json"
env "${ciclo_env[@]}" bash "$WATCH" --merged-once >"$CICLO/watch.log" 2>&1
OUT="$CICLO/watch.log"
check_log "ciclo: cerrado en bash con la medida desde el merge" 'task-close-40 terminado: bash, cerrado [0-9]+s después del merge'
SEG=$(grep -oE 'cerrado [0-9]+s después' "$OUT" | grep -oE '[0-9]+')
check_igual "ciclo: cerrado en menos de un minuto desde el merge" si "$([ "${SEG:-99}" -lt 60 ] && echo si || echo no)"
check_igual "ciclo: card a Hecha con Cierre y PR" "set card-3 Estado=Hecha Cierre=2026-09-16 PR=https://github.com/o/r/pull/40" \
  "$(grep '^set card-3' "$N/llamadas" | head -1)"
# Las marcas de modelo (DEVKIT-58) salen del cuerpo del PR y del último
# informe por submittedAt, no del primero de la lista.
check_igual "ciclo: comentario con Documentación y marcas de modelo" "comentar card-3 Cerrada. Documentación: https://notion.so/doc-3. Implementado con opus, esfuerzo high. Revisado con fable, esfuerzo high. Cierre sin modelo (task-close.sh)." \
  "$(grep '^comentar card-3' "$N/llamadas" | head -1)"
check_igual "ciclo: marcador devkit-closed con sha y enlace" 1 \
  "$(grep -c 'pr comment 40 --body <!-- devkit-closed sha=f1 -->' "$CICLO/gh/comentarios" 2>/dev/null)"
check_igual "ciclo: lanza la siguiente card de la cola" "task-start DEVKIT-4" \
  "$(tail -1 "$N/lanzamientos" 2>/dev/null)"
: >"$N/cola-siguiente"
# 4. Una segunda pasada no repite el cierre: `launched` lo recuerda.
env "${ciclo_env[@]}" bash "$WATCH" --merged-once >>"$CICLO/watch.log" 2>&1
check_igual "ciclo: una segunda pasada no vuelve a cerrar" 1 "$(grep -c 'task-close-40 terminado' "$OUT")"

# task-close.sh idempotente: card ya Hecha y marcador publicado -> no toca nada.
: >"$N/llamadas"; : >"$N/lanzamientos"; : >"$CICLO/gh/comentarios"
tarea card-3 3 Hecha 1 "" >"$N/card-DEVKIT-3.json"
jq '.comments += [{body: "<!-- devkit-closed sha=f1 -->"}]' "$CICLO/gh/pr.json" >"$CICLO/gh/pr2.json" && mv "$CICLO/gh/pr2.json" "$CICLO/gh/pr.json"
env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: card ya Hecha no cambia ni lanza nada" "0 0 0" \
  "$(grep -cE '^(set|comentar)' "$N/llamadas") $(wc -l <"$N/lanzamientos" | tr -d ' ') $(wc -l <"$CICLO/gh/comentarios" | tr -d ' ')"

# PR sin merge: no cierra.
tarea card-3 3 "Lista para merge" 1 "" >"$N/card-DEVKIT-3.json"
jq '.state = "OPEN"' "$CICLO/gh/pr.json" >"$CICLO/gh/pr2.json" && mv "$CICLO/gh/pr2.json" "$CICLO/gh/pr.json"
: >"$N/llamadas"
check_igual "task-close: PR no mergeado no cierra" "task-close: PR no mergeado: 40" \
  "$(env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 2>&1 | tail -1)"
jq '.state = "MERGED" | .comments = []' "$CICLO/gh/pr.json" >"$CICLO/gh/pr2.json" && mv "$CICLO/gh/pr2.json" "$CICLO/gh/pr.json"

# Sin entrada de Documentación (merge antes de que el bucle documentara, o
# task-document.sh no pudo escribirla): se cierra igual, llamando siempre al
# script -ya no al agente, ni con la guarda por proceso vivo que pedía
# DEVKIT-55 H3, innecesaria con un script bash idempotente (DEVKIT-92)- y el
# comentario dice que sigue faltando.
rm -f "$N/doc-card-3.json"; : >"$N/llamadas"; : >"$N/task-document-llamadas"
env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: llama a task-document.sh con la Clave y el PR" "DEVKIT-3 https://github.com/o/r/pull/40" \
  "$(cat "$N/task-document-llamadas" 2>/dev/null)"
check_igual "task-close: sin entrada, el comentario dice que falta" 1 \
  "$(grep -c '^comentar card-3 Cerrada. Falta la entrada de Documentación: task-document.sh no pudo escribirla.' "$N/llamadas")"

# task-document.sh es idempotente (DEVKIT-92): con la entrada ya escrita para
# el head vigente, task-close.sh lo llama igual -es bash, no cuesta nada- y
# el comentario trae la URL de siempre, sin relanzar ni un agente ni nada más.
printf '{"id":"doc-3","url":"https://notion.so/doc-3"}' >"$N/doc-card-3.json"
tarea card-3 3 "Lista para merge" 1 "" >"$N/card-DEVKIT-3.json"
: >"$N/llamadas"; : >"$N/task-document-llamadas"
env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: entrada ya escrita, llama igual al script y comenta con su URL" \
  "DEVKIT-3 https://github.com/o/r/pull/40 1" \
  "$(cat "$N/task-document-llamadas" 2>/dev/null) $(grep -c '^comentar card-3 Cerrada. Documentación: https://notion.so/doc-3.' "$N/llamadas")"

# PR sin marcas (anterior a DEVKIT-58, o una sesión interactiva que no las
# escribió): el comentario lo dice, no inventa un modelo.
cp "$CICLO/gh/pr.json" "$CICLO/gh/pr-con-marcas.json"
jq '.body = "sin marca" | .reviews = []' "$CICLO/gh/pr-con-marcas.json" >"$CICLO/gh/pr.json"
tarea card-3 3 "Lista para merge" 1 "" >"$N/card-DEVKIT-3.json"
printf '{"id":"doc-3","url":"https://notion.so/doc-3"}' >"$N/doc-card-3.json"
: >"$N/llamadas"; : >"$N/lanzamientos"
env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: sin marcas lo dice en el comentario" "comentar card-3 Cerrada. Documentación: https://notion.so/doc-3. Implementado: sin marca en el PR. Revisado: sin marca en el último informe. Cierre sin modelo (task-close.sh)." \
  "$(grep '^comentar card-3' "$N/llamadas" | head -1)"
mv "$CICLO/gh/pr-con-marcas.json" "$CICLO/gh/pr.json"

# Última hija: la Épica se cierra si está En progreso y tiene criterios, y
# task-document escribe la entrada consolidada.
printf '[%s,%s]' "$(tarea card-3 3 Hecha 1 "")" "$(tarea card-4 4 Hecha 2 "")" >"$N/hijas-epica-1.json"
printf 'uno\ndos\n' >"$N/criterios-epica-1.txt"
tarea card-3 3 "Lista para merge" 1 "" >"$N/card-DEVKIT-3.json"
: >"$N/llamadas"; : >"$N/lanzamientos"
env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: última hija cierra la Épica" "set epica-1 Estado=Hecha Cierre=2026-09-16" \
  "$(grep '^set epica-1' "$N/llamadas")"
check_igual "task-close: la Épica recibe su task-document" "task-document DEVKIT-1" \
  "$(grep 'DEVKIT-1$' "$N/lanzamientos")"
# Regla de DEVKIT-44: sin criterios no se cierra, se comenta.
printf 'Pendientes de definir\n' >"$N/criterios-epica-1.txt"
: >"$N/llamadas"; : >"$N/lanzamientos"
env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: Épica sin criterios no se cierra" "0 1" \
  "$(grep -c '^set epica-1' "$N/llamadas") $(grep -c '^comentar epica-1 Sus hijas terminaron' "$N/llamadas")"

# --- La siguiente card de la cola (DEVKIT-120) ------------------------------
# lanzar_cola generaliza chain_next/task-next.sh (DEVKIT-56): en vez de mirar
# solo las hermanas de la Épica de una card, pregunta a cola.sh por la
# siguiente de todo el proyecto. watch.sh la llama con el hook --lanzar-cola
# tanto al OK del revisor (dentro de procesar_pr) como en cada pasada del
# sondeo sin nada en curso; task-close.sh la llama al cerrar (ver el bloque
# "ciclo" de arriba). Acá se prueba el hook directo, con el doble de cola.sh
# del mismo ciclo.
: >"$N/llamadas"; : >"$N/lanzamientos"
printf 'DEVKIT-12\n' >"$N/cola-siguiente"
env "${ciclo_env[@]}" bash "$WATCH" --lanzar-cola 50 >"$CICLO/cola-hook.log" 2>&1
OUT="$CICLO/cola-hook.log"
check_igual "cola: con una Clave, lanza task-start" "task-start DEVKIT-12" \
  "$(cat "$N/lanzamientos")"
check_log "cola: la línea cola-<n> queda en watch.log" \
  'cola-50 terminado: bash, lanzada la siguiente card: task-start DEVKIT-12'

# Sin nada que sugerir: cola.sh (que ya trae su propia guarda de "algo en
# curso") devuelve vacío, y no se lanza ni se registra nada.
: >"$N/lanzamientos"
: >"$N/cola-siguiente"
env "${ciclo_env[@]}" bash "$WATCH" --lanzar-cola 51 >"$CICLO/cola-hook.log" 2>&1
OUT="$CICLO/cola-hook.log"
check_igual "cola: sin Clave, no lanza nada" "" "$(cat "$N/lanzamientos")"
check_igual "cola: sin Clave, sin línea en watch.log" 0 "$(grep -c 'cola-51' "$OUT")"

# cola.sh falla (Notion caído, por ejemplo): ALARMA en vez de lanzar algo a
# ciegas.
COLA_ROTO="$CICLO/cola-roto.sh"
cat >"$COLA_ROTO" <<'FIN'
#!/usr/bin/env bash
echo "no pude leer Notion" >&2
exit 1
FIN
chmod +x "$COLA_ROTO"
: >"$N/lanzamientos"
env "${ciclo_env[@]}" DEVKIT_COLA_BIN="$COLA_ROTO" bash "$WATCH" --lanzar-cola 52 >"$CICLO/cola-hook.log" 2>&1
OUT="$CICLO/cola-hook.log"
check_log "cola: cola.sh falla, ALARMA sin lanzar nada" \
  'ALARMA: cola-52 no pudo leer la cola \(rc=1\): no pude leer Notion'
check_igual "cola: cola.sh falla, no lanza nada" "" "$(cat "$N/lanzamientos")"

# Idempotente (criterio de aceptación): dos llamadas seguidas no lanzan dos
# veces. Un doble con estado propio lo reproduce sin tocar Notion: la
# primera llamada lanza y marca un archivo; la segunda ya no ve la card
# libre, igual que cola.sh real deja de sugerirla en cuanto queda En
# progreso o con un `task-start` vivo (mismas guardas de cola.sh --test).
IDEMP_COLA="$TMP/idemp-cola"
mkdir -p "$IDEMP_COLA"
cat >"$IDEMP_COLA/cola" <<FIN
#!/usr/bin/env bash
[ -f "$IDEMP_COLA/lanzada" ] && exit 0
echo DEVKIT-90
FIN
chmod +x "$IDEMP_COLA/cola"
cat >"$IDEMP_COLA/devkit-run" <<FIN
#!/usr/bin/env bash
[ "\$1" = --otros-agentes ] && exit 0
printf '%s\n' "\$*" >>"$IDEMP_COLA/lanzamientos"
touch "$IDEMP_COLA/lanzada"
FIN
chmod +x "$IDEMP_COLA/devkit-run"
env DEVKIT_COLA_BIN="$IDEMP_COLA/cola" DEVKIT_RUN_BIN="$IDEMP_COLA/devkit-run" \
    DEVKIT_RUN_DIR="$IDEMP_COLA/run" DEVKIT_WS="$IDEMP_COLA" \
  bash "$WATCH" --lanzar-cola 1 >"$IDEMP_COLA/watch1.log" 2>&1
env DEVKIT_COLA_BIN="$IDEMP_COLA/cola" DEVKIT_RUN_BIN="$IDEMP_COLA/devkit-run" \
    DEVKIT_RUN_DIR="$IDEMP_COLA/run" DEVKIT_WS="$IDEMP_COLA" \
  bash "$WATCH" --lanzar-cola 2 >"$IDEMP_COLA/watch2.log" 2>&1
check_igual "cola: idempotente, dos llamadas seguidas no lanzan dos veces" "task-start DEVKIT-90" \
  "$(cat "$IDEMP_COLA/lanzamientos" 2>/dev/null)"

# --- Caso "card suelta en Lista arranca sola" (DEVKIT-120) ------------------
# Fin a fin con cola.sh real (no doblado): sin nada En progreso/Revisión
# automática en el proyecto, una card suelta (sin Épica) en Lista arranca
# con --lanzar-cola, la misma llamada que watch.sh hace en cada pasada del
# sondeo sin card activa. `notion.sh` es un doble mínimo que solo entiende
# `activas` y `sueltas`, lo que cola.sh necesita para el grupo de sueltas.
SUELTA=$(mktemp -d -p "$TMP")
mkdir -p "$SUELTA/run" "$SUELTA/ws/.devkit"
printf 'project = "DEVKIT"\n' >"$SUELTA/ws/.devkit/devkit.toml"
printf '[{"clave":"DEVKIT-90","estado":"Lista","nivel":"Tarea"}]' >"$SUELTA/activas.json"
printf '[{"id":"card-90","clave":"DEVKIT-90","estado":"Lista","prioridad":"alta","orden":1,"agente":"claude","depende":[],"titulo":"suelta"}]' \
  >"$SUELTA/sueltas.json"
cat >"$SUELTA/notion.sh" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "activas DEVKIT") cat "$SUELTA/activas.json" ;;
  "sueltas DEVKIT") cat "$SUELTA/sueltas.json" ;;
  "epicas-backlog DEVKIT") echo '[]' ;;
  "sueltas-backlog DEVKIT") echo '[]' ;;
esac
FIN
chmod +x "$SUELTA/notion.sh"
cat >"$SUELTA/ps-vacio" <<'FIN'
#!/usr/bin/env bash
exit 0
FIN
chmod +x "$SUELTA/ps-vacio"
cat >"$SUELTA/devkit-run" <<FIN
#!/usr/bin/env bash
[ "\$1" = --otros-agentes ] && exit 0
printf '%s\n' "\$*" >>"$SUELTA/lanzamientos"
FIN
chmod +x "$SUELTA/devkit-run"

env DEVKIT_NOTION_BIN="$SUELTA/notion.sh" DEVKIT_PS_BIN="$SUELTA/ps-vacio" \
    DEVKIT_RUN_BIN="$SUELTA/devkit-run" DEVKIT_RUN_DIR="$SUELTA/run" DEVKIT_WS="$SUELTA/ws" \
  bash "$WATCH" --lanzar-cola 90 >"$SUELTA/watch.log" 2>&1
OUT="$SUELTA/watch.log"
check_igual "card suelta en Lista arranca sola" "task-start DEVKIT-90" \
  "$(cat "$SUELTA/lanzamientos" 2>/dev/null)"
check_log "card suelta en Lista arranca sola: línea cola-<n> en watch.log" \
  'cola-90 terminado: bash, lanzada la siguiente card: task-start DEVKIT-90'

# Workspace sucio: no se lanza nada, solo queda "cola-<n> espera" en
# watch.log (DEVKIT-120, H1). Antes, un archivo sin commit hacía fallar
# `task-start` en cada pasada del sondeo y `task_begin_fallo` bloqueaba la
# card en Lista, y la siguiente pasada bloqueaba la que seguía: la cola
# entera se apagaba card por card en minutos.
SUCIO=$(mktemp -d -p "$TMP")
mkdir -p "$SUCIO/run" "$SUCIO/ws/.devkit"
printf 'project = "DEVKIT"\n' >"$SUCIO/ws/.devkit/devkit.toml"
git init -q "$SUCIO/ws"
touch "$SUCIO/ws/sin-commit.txt"
cat >"$SUCIO/devkit-run" <<FIN
#!/usr/bin/env bash
[ "\$1" = --otros-agentes ] && exit 0
printf '%s\n' "\$*" >>"$SUCIO/lanzamientos"
FIN
chmod +x "$SUCIO/devkit-run"
env DEVKIT_NOTION_BIN="$SUELTA/notion.sh" DEVKIT_PS_BIN="$SUELTA/ps-vacio" \
    DEVKIT_RUN_BIN="$SUCIO/devkit-run" DEVKIT_RUN_DIR="$SUCIO/run" DEVKIT_WS="$SUCIO/ws" \
  bash "$WATCH" --lanzar-cola 92 >"$SUCIO/watch.log" 2>&1
OUT="$SUCIO/watch.log"
check_igual "workspace sucio: no lanza task-start" "" \
  "$(cat "$SUCIO/lanzamientos" 2>/dev/null)"
check_log "workspace sucio: cola-<n> espera queda en watch.log" \
  'cola-92 espera: workspace sucio'

# Idempotente: con la card ya En progreso (lo que Notion reflejaría tras el
# lanzamiento real), cola.sh no vuelve a sugerirla y una segunda pasada no
# lanza otra vez.
printf '[{"clave":"DEVKIT-90","estado":"En progreso","nivel":"Tarea"}]' >"$SUELTA/activas.json"
: >"$SUELTA/lanzamientos"
env DEVKIT_NOTION_BIN="$SUELTA/notion.sh" DEVKIT_PS_BIN="$SUELTA/ps-vacio" \
    DEVKIT_RUN_BIN="$SUELTA/devkit-run" DEVKIT_RUN_DIR="$SUELTA/run" DEVKIT_WS="$SUELTA/ws" \
  bash "$WATCH" --lanzar-cola 91 >>"$SUELTA/watch.log" 2>&1
check_igual "card suelta en Lista arranca sola: idempotente, no la relanza" "" \
  "$(cat "$SUELTA/lanzamientos" 2>/dev/null)"

# --- Arrastre de hijas de Backlog a Lista (DEVKIT-121) ----------------------
# Doble de notion.sh con dos Épicas: DEVKIT-50 (con una hija en Backlog con
# Criterios de verdad y otra ya en Lista, que no se toca) y DEVKIT-60 (con
# una hija en Backlog con Criterios "Pendientes de definir" -no se mueve, y
# se nombra en el comentario; misma regla de cierre de Épica que DEVKIT-44
# en task-close.sh). "hijas epica-50" deja de listar DEVKIT-51 en Backlog en
# cuanto "set" la mueve (el archivo "movida-51"), como la Notion real.
ARRASTRE=$(mktemp -d -p "$TMP")
mkdir -p "$ARRASTRE/run" "$ARRASTRE/ws/.devkit"
printf 'project = "DEVKIT"\n' >"$ARRASTRE/ws/.devkit/devkit.toml"
cat >"$ARRASTRE/notion.sh" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "epicas-abiertas DEVKIT")
    echo '[{"id":"epica-50","clave":"DEVKIT-50"},{"id":"epica-60","clave":"DEVKIT-60"}]' ;;
  "hijas epica-50")
    if [ -f "$ARRASTRE/movida-51" ]; then
      echo '[{"id":"card-51","clave":"DEVKIT-51","nivel":"Tarea","estado":"Lista"},{"id":"card-52","clave":"DEVKIT-52","nivel":"Tarea","estado":"Lista"}]'
    else
      echo '[{"id":"card-51","clave":"DEVKIT-51","nivel":"Tarea","estado":"Backlog"},{"id":"card-52","clave":"DEVKIT-52","nivel":"Tarea","estado":"Lista"}]'
    fi ;;
  "hijas epica-60")
    echo '[{"id":"card-61","clave":"DEVKIT-61","nivel":"Tarea","estado":"Backlog"}]' ;;
  "criterios card-51") echo "Un criterio de verdad." ;;
  "criterios card-61") echo "Pendientes de definir" ;;
  "set card-51") touch "$ARRASTRE/movida-51"; printf '%s %s\n' "\$2" "\$3" >>"$ARRASTRE/llamadas-set" ;;
  "set card-61") printf '%s %s\n' "\$2" "\$3" >>"$ARRASTRE/llamadas-set" ;;
  "comentar epica-50") printf '%s\n' "\$3" >>"$ARRASTRE/comentario-50" ;;
  "comentar epica-60") printf '%s\n' "\$3" >>"$ARRASTRE/comentario-60" ;;
esac
FIN
chmod +x "$ARRASTRE/notion.sh"

env DEVKIT_NOTION_BIN="$ARRASTRE/notion.sh" DEVKIT_RUN_DIR="$ARRASTRE/run" DEVKIT_WS="$ARRASTRE/ws" \
  bash "$WATCH" --arrastrar-hijas 1 >"$ARRASTRE/watch.log" 2>&1
check_igual "arrastre: hija en Backlog con Criterios pasa a Lista" "card-51 Estado=Lista" \
  "$(cat "$ARRASTRE/llamadas-set" 2>/dev/null)"
check_igual "arrastre: comenta en la Épica las Claves movidas" "Arrastradas de Backlog a Lista: DEVKIT-51." \
  "$(cat "$ARRASTRE/comentario-50" 2>/dev/null)"
check_igual "arrastre: hija con Criterios pendientes de definir no se mueve" 0 \
  "$(grep -c 'card-61' "$ARRASTRE/llamadas-set" 2>/dev/null)"
check_igual "arrastre: la hija pendiente se nombra en el comentario" \
  "Con Criterios de aceptación pendientes de definir, sin mover: DEVKIT-61." \
  "$(cat "$ARRASTRE/comentario-60" 2>/dev/null)"

# Segunda pasada: DEVKIT-51 ya no aparece en Backlog (la Notion real ya la
# movió) y DEVKIT-61 sigue pendiente -mismo comentario que la primera vez, la
# guarda de `launched` evita repetirlo.
env DEVKIT_NOTION_BIN="$ARRASTRE/notion.sh" DEVKIT_RUN_DIR="$ARRASTRE/run" DEVKIT_WS="$ARRASTRE/ws" \
  bash "$WATCH" --arrastrar-hijas 2 >"$ARRASTRE/watch.log" 2>&1
check_igual "arrastre: idempotente, no repite el comentario de la hija pendiente" 1 \
  "$(wc -l <"$ARRASTRE/comentario-60" 2>/dev/null | tr -d ' ')"
check_igual "arrastre: idempotente, no vuelve a mover una hija ya en Lista" 1 \
  "$(wc -l <"$ARRASTRE/llamadas-set" 2>/dev/null | tr -d ' ')"

# Bloqueo por tres ciclos sin OK: marcador en el PR y task-block.sh real.
tarea card-3 3 "Revisión automática" 1 "" >"$N/card-DEVKIT-3.json"
: >"$N/llamadas"; : >"$CICLO/gh/comentarios"
env "${ciclo_env[@]}" bash "$WATCH" --block-pr 41 DEVKIT-3 https://github.com/o/r/pull/41 d4 3 >"$CICLO/block.log" 2>&1
OUT="$CICLO/block.log"
check_log "bloqueo: línea de resumen en bash" 'task-block-41 terminado: bash :: task-block: DEVKIT-3 Bloqueada desde Revisión automática'
check_igual "bloqueo: marcador devkit-block en el PR" 1 "$(grep -c 'devkit-block sha=d4' "$CICLO/gh/comentarios")"
check_igual "bloqueo: card a Bloqueada" "set card-3 Estado=Bloqueada" "$(grep '^set' "$N/llamadas")"
check_igual "bloqueo: comenta el estado anterior y el motivo" "comentar card-3 Bloqueada desde Revisión automática." \
  "$(grep '^comentar' "$N/llamadas" | head -1)"
tarea card-3 3 Bloqueada 1 "" >"$N/card-DEVKIT-3.json"
: >"$N/llamadas"
env "${ciclo_env[@]}" bash "$HERE/task-block.sh" DEVKIT-3 otra vez >/dev/null 2>&1
check_igual "task-block: card ya Bloqueada no se toca" 0 "$(grep -cE '^(set|comentar)' "$N/llamadas")"
check_igual "task-block: sin motivo sale con 64" 64 \
  "$(env "${ciclo_env[@]}" bash "$HERE/task-block.sh" DEVKIT-3 >/dev/null 2>&1; echo $?)"
# DEVKIT-57: el bloqueo deja su motivo en watch.log para `devkit-run --estado`.
check_igual "task-block: motivo en watch.log" \
  "task-block.sh DEVKIT-3 Bloqueada desde Revisión automática: Tres ciclos de revisión y corrección sin veredicto OK en el PR https://github.com/o/r/pull/41; el bucle no lo toca hasta que decidas." \
  "$(grep -oE 'task-block.sh DEVKIT-3 Bloqueada desde .*' "$CICLO/run/watch.log" | head -1)"

# DEVKIT-76: una card ya Hecha (cerrada, mergeada y documentada) no se mueve
# a Bloqueada por un `task-block.sh` invocado a mano; un bloqueo ahí no lo
# lee nadie.
tarea card-3 3 Hecha 1 "" >"$N/card-DEVKIT-3.json"
: >"$N/llamadas"
salida=$(env "${ciclo_env[@]}" bash "$HERE/task-block.sh" DEVKIT-3 otra vez 2>&1); rc=$?
check_igual "task-block: card Hecha no se toca" 0 "$(grep -cE '^(set|comentar)' "$N/llamadas")"
check_igual "task-block: card Hecha se niega con error" "1 task-block: DEVKIT-3 ya está Hecha; no se bloquea" \
  "$rc $salida"

# --- task-fix vacío con CAMBIOS vigente (DEVKIT-57) --------------------------
# El caso `fix` completo por el hook --fix: devkit-run.sh real, un doble de
# `claude` que anota el modelo con que lo llaman y responde lo que diga cada
# caso, un `gh` que devuelve el último informe CAMBIOS sobre FIX_HEAD y un
# doble de task-block.sh. Con roles.toml del template y un PR sin devkit-fix,
# task-fix va por la ronda 1, `sonnet` (DEVKIT-61), y el siguiente de la
# frontera tras `sonnet`, el último, es `fable`. La card en Notion (doble)
# trae la URL del PR; gh devuelve los comentarios de FIX_COMENTARIOS.
FIX="$TMP/fix"
mkdir -p "$FIX/bin"
cat >"$FIX/bin/gh" <<'FIN'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    printf '{"headRefOid":"%s","reviews":[{"author":{"login":"otro"},"state":"COMMENTED","submittedAt":"T01","body":"<!-- devkit-review sha=a1b2c3d verdict=CAMBIOS -->"}],"comments":[%s]}' "$FIX_HEAD" "${FIX_COMENTARIOS:-}" ;;
  "pr comment") printf '%s\n' "$*" >>"$FIX_DIR/comentarios" ;;
  *) exit 1 ;;
esac
FIN
cat >"$FIX/claude" <<'FIN'
#!/usr/bin/env bash
modelo=""
while [ $# -gt 0 ]; do case "$1" in --model) modelo=$2; shift 2 ;; *) shift ;; esac; done
n=$(( $(cat "$FIX_DIR/llamadas" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FIX_DIR/llamadas"
echo "$modelo" >>"$FIX_DIR/modelos"
if [ "$n" -eq 1 ]; then r=$FIX_R1; else r=$FIX_R2; fi
printf '{"result":"%s","total_cost_usd":0.01,"num_turns":2}\n' "$r"
FIN
cat >"$FIX/task-block" <<'FIN'
#!/usr/bin/env bash
printf '%s|' "$@" >"$FIX_DIR/bloqueo"
FIN
cat >"$FIX/notion.sh" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) printf '{"id":"card-9","clave":"%s","pr":"https://github.com/o/r/pull/45"}\n' "$2" ;;
  comentar) printf '%s\t%s\n' "$2" "$3" >>"$FIX_DIR/notion-comentarios" ;;
esac
FIN
chmod +x "$FIX/bin/gh" "$FIX/claude" "$FIX/task-block" "$FIX/notion.sh"

corre_fix() {  # corre_fix <resultado 1> <resultado 2> [head que ve gh]
  local dir
  dir=$(mktemp -d -p "$TMP")
  FIX_DIR_ACTUAL=$dir
  OUT="$dir/watch.log"
  # ROLES_OVERRIDE (vacía por defecto, sin efecto): la usa el caso de
  # presupuesto de turnos (DEVKIT-94) para forzar un roles.toml con un tope
  # bajo, sin tocar los casos de fix vacío de arriba.
  FIX_DIR="$dir" FIX_R1="$1" FIX_R2="$2" FIX_HEAD="${3:-a1b2c3d}" PATH="$FIX/bin:$PATH" \
  DEVKIT_CLAUDE_BIN="$FIX/claude" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" DEVKIT_TASK_BLOCK_BIN="$FIX/task-block" \
  DEVKIT_NOTION_BIN="$FIX/notion.sh" DEVKIT_ROLES_FILE="${ROLES_OVERRIDE:-}" \
    bash "$WATCH" --fix 45 DEVKIT-9 https://github.com/o/r/pull/45 a1b2c3d a1b2c3d >"$OUT" 2>&1
}

# Dos veces "nada que corregir": alarma, relanzamiento con fable y bloqueo.
corre_fix "nada que corregir" "nada que corregir"
check_log "fix vacío: ALARMA con la frase y el modelo siguiente" \
  'ALARMA: task-fix-45-a1b2c3d terminó con "nada que corregir" con CAMBIOS vigente sobre a1b2c3d; relanzo task-fix con fable \(antes sonnet\)'
check_igual "fix vacío: relanza una vez, con el siguiente modelo" "sonnet fable" \
  "$(tr '\n' ' ' <"$FIX_DIR_ACTUAL/modelos" | sed 's/ $//')"
check_log "fix vacío: el reintento repite y se registra" 'ALARMA: task-fix-45-a1b2c3d-reintento también terminó con "nada que corregir"'
check_igual "fix vacío: bloquea la card con task-block.sh" "DEVKIT-9" \
  "$(cut -d'|' -f1 "$FIX_DIR_ACTUAL/bloqueo" 2>/dev/null)"
check_igual "fix vacío: marcador devkit-block en el PR" 1 \
  "$(grep -c 'devkit-block sha=a1b2c3d' "$FIX_DIR_ACTUAL/comentarios" 2>/dev/null)"

# El segundo modelo sí corrige: una alarma, sin bloqueo.
corre_fix "informe desactualizado, esperando a pr-review" "H1 | atendido | 1234abc"
check_log "fix vacío: informe desactualizado también dispara la alarma" \
  'ALARMA: task-fix-45-a1b2c3d terminó con "informe desactualizado"'
check_igual "fix vacío: si el reintento corrige, no bloquea" "2 no" \
  "$(cat "$FIX_DIR_ACTUAL/llamadas") $([ -e "$FIX_DIR_ACTUAL/bloqueo" ] && echo si || echo no)"

# "informe desactualizado" legítimo: el head ya cambió, no hay CAMBIOS vigente
# sobre el head atendido. Ni alarma ni relanzamiento.
corre_fix "informe desactualizado, esperando a pr-review" "no debe correr" b2c3d4e
check_igual "fix vacío: con el head ya cambiado no hay alarma" "0 1" \
  "$(grep -c 'ALARMA' "$OUT") $(cat "$FIX_DIR_ACTUAL/llamadas")"

# --- Guarda de `launched` con el informe incluido (DEVKIT-101) --------------
# `caso_fix`/`caso_revisar` son las mismas funciones que usa el bucle
# principal: con el mismo informe ya lanzado, avisan una sola vez y no
# relanzan nada; con un informe nuevo, marcan y lanzan de verdad. Reutilizan
# los dobles de `--fix` (task-fix) y de `corre_doble` (pr-review), en un
# directorio propio por escenario para que `launched` persista entre las dos
# llamadas de cada prueba.
corre_caso_fix_dos_veces() {  # corre_caso_fix_dos_veces <dir> <informe 1> <informe 2>
  local dir=$1 informe1=$2 informe2=$3
  OUT="$dir/watch.log"
  FIX_DIR="$dir" FIX_R1="H1 | atendido | 1234abc" FIX_R2="no debe correr" FIX_HEAD="a1b2c3d" \
  PATH="$FIX/bin:$PATH" DEVKIT_CLAUDE_BIN="$FIX/claude" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" DEVKIT_TASK_BLOCK_BIN="$FIX/task-block" \
  DEVKIT_NOTION_BIN="$FIX/notion.sh" \
    bash "$WATCH" --caso-fix 45 DEVKIT-9 https://github.com/o/r/pull/45 a1b2c3d a1b2c3d "$informe1" >"$OUT" 2>&1
  FIX_DIR="$dir" FIX_R1="H1 | atendido | 1234abc" FIX_R2="no debe correr" FIX_HEAD="a1b2c3d" \
  PATH="$FIX/bin:$PATH" DEVKIT_CLAUDE_BIN="$FIX/claude" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" DEVKIT_TASK_BLOCK_BIN="$FIX/task-block" \
  DEVKIT_NOTION_BIN="$FIX/notion.sh" \
    bash "$WATCH" --caso-fix 45 DEVKIT-9 https://github.com/o/r/pull/45 a1b2c3d a1b2c3d "$informe2" >>"$OUT" 2>&1
}

DIR_MISMO_INFORME=$(mktemp -d -p "$TMP")
corre_caso_fix_dos_veces "$DIR_MISMO_INFORME" T01 T01
check_igual "DEVKIT-101 (fix): mismo informe, no relanza task-fix" 1 \
  "$(cat "$DIR_MISMO_INFORME/llamadas" 2>/dev/null || echo 0)"
check_log "DEVKIT-101 (fix): avisa una vez que ya está lanzada para este informe" \
  'PR #45 \(DEVKIT-9\) fix ya lanzada para este informe; esperando'
check_igual "DEVKIT-101 (fix): el aviso no se repite" 1 \
  "$(grep -c 'ya lanzada para este informe; esperando' "$OUT")"

DIR_INFORME_NUEVO=$(mktemp -d -p "$TMP")
corre_caso_fix_dos_veces "$DIR_INFORME_NUEVO" T01 T03
check_igual "DEVKIT-101 (fix): informe nuevo relanza task-fix" 2 \
  "$(cat "$DIR_INFORME_NUEVO/llamadas" 2>/dev/null || echo 0)"
check_igual "DEVKIT-101 (fix): informe nuevo, sin aviso de 'ya lanzada'" 0 \
  "$(grep -c 'ya lanzada para este informe' "$OUT")"

corre_caso_revisar_dos_veces() {  # corre_caso_revisar_dos_veces <dir> <ref 1> <informe 1> <ref 2> <informe 2>
  local dir=$1 ref1=$2 informe1=$3 ref2=$4 informe2=$5
  OUT="$dir/watch.log"
  DEVKIT_TEST_COUNT="$dir/llamadas" DEVKIT_TEST_FAILS=0 DEVKIT_TEST_RESULT=listo \
  DEVKIT_CLAUDE_BIN="$DOBLE" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_REVIEW_PREP_BIN="$REVIEW_PREP_DOBLE" DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
    bash "$WATCH" --caso-revisar 9 DEVKIT-9 abc1234 "$ref1" "$informe1" >"$OUT" 2>&1
  DEVKIT_TEST_COUNT="$dir/llamadas" DEVKIT_TEST_FAILS=0 DEVKIT_TEST_RESULT=listo \
  DEVKIT_CLAUDE_BIN="$DOBLE" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_REVIEW_PREP_BIN="$REVIEW_PREP_DOBLE" DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
    bash "$WATCH" --caso-revisar 9 DEVKIT-9 abc1234 "$ref2" "$informe2" >>"$OUT" 2>&1
}

DIR_REVISAR_MISMO=$(mktemp -d -p "$TMP")
corre_caso_revisar_dos_veces "$DIR_REVISAR_MISMO" abc1234 T01 abc1234 T01
check_igual "DEVKIT-101 (revisar): mismo informe, no relanza pr-review" 1 \
  "$(cat "$DIR_REVISAR_MISMO/llamadas" 2>/dev/null || echo 0)"
check_log "DEVKIT-101 (revisar): avisa una vez que ya está lanzada para este informe" \
  'PR #9 \(DEVKIT-9\) revisar ya lanzada para este informe; esperando'

DIR_REVISAR_NUEVO=$(mktemp -d -p "$TMP")
corre_caso_revisar_dos_veces "$DIR_REVISAR_NUEVO" abc1234 T01 abc1234 T03
check_igual "DEVKIT-101 (revisar): informe nuevo relanza pr-review" 2 \
  "$(cat "$DIR_REVISAR_NUEVO/llamadas" 2>/dev/null || echo 0)"

# `caso_fix_humano` pasa por la misma guarda (DEVKIT-101 H1): antes, un
# comentario humano ya lanzado se descartaba en silencio si el task-fix
# correspondiente no llegaba a publicar nada (cuota, error, corte de
# presupuesto), y como la clave solo lleva $ref, nada lo destrababa. Ahora
# avisa una vez, igual que `fix` y `revisar`.
corre_caso_fix_humano_dos_veces() {  # corre_caso_fix_humano_dos_veces <dir> <ref>
  local dir=$1 ref=$2 extra
  extra=$(printf 'comentario humano' | base64)
  OUT="$dir/watch.log"
  FIX_DIR="$dir" FIX_R1="H1 | atendido | 1234abc" FIX_R2="no debe correr" FIX_HEAD="a1b2c3d" \
  PATH="$FIX/bin:$PATH" DEVKIT_CLAUDE_BIN="$FIX/claude" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" DEVKIT_TASK_BLOCK_BIN="$FIX/task-block" \
  DEVKIT_NOTION_BIN="$FIX/notion.sh" \
    bash "$WATCH" --caso-fix-humano 45 DEVKIT-9 "$ref" "$extra" >"$OUT" 2>&1
  FIX_DIR="$dir" FIX_R1="H1 | atendido | 1234abc" FIX_R2="no debe correr" FIX_HEAD="a1b2c3d" \
  PATH="$FIX/bin:$PATH" DEVKIT_CLAUDE_BIN="$FIX/claude" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" DEVKIT_TASK_BLOCK_BIN="$FIX/task-block" \
  DEVKIT_NOTION_BIN="$FIX/notion.sh" \
    bash "$WATCH" --caso-fix-humano 45 DEVKIT-9 "$ref" "$extra" >>"$OUT" 2>&1
}

DIR_FIX_HUMANO_MISMO=$(mktemp -d -p "$TMP")
corre_caso_fix_humano_dos_veces "$DIR_FIX_HUMANO_MISMO" a1b2c3d
check_igual "DEVKIT-101 H1 (fix-humano): mismo comentario, no relanza dos veces" 1 \
  "$(cat "$DIR_FIX_HUMANO_MISMO/llamadas" 2>/dev/null || echo 0)"
check_log "DEVKIT-101 H1 (fix-humano): avisa una vez que ya está lanzada" \
  'PR #45 \(DEVKIT-9\) fix-humano ya lanzada para este informe; esperando'
check_igual "DEVKIT-101 H1 (fix-humano): el aviso no se repite" 1 \
  "$(grep -c 'ya lanzada para este informe; esperando' "$OUT")"

DIR_FIX_HUMANO_NUEVO=$(mktemp -d -p "$TMP")
corre_caso_fix_humano_dos_veces "$DIR_FIX_HUMANO_NUEVO" a1b2c3d
corre_caso_fix_humano_dos_veces "$DIR_FIX_HUMANO_NUEVO" e5f6a7b
check_igual "DEVKIT-101 H1 (fix-humano): comentario nuevo (otro \$ref) relanza" 2 \
  "$(cat "$DIR_FIX_HUMANO_NUEVO/llamadas" 2>/dev/null || echo 0)"

# --- Presupuesto de turnos, meta que avisa sin bloquear, vía task-fix
# (DEVKIT-94, DEVKIT-105) ---------------------------------------------------
# atender_fix también lanza con `run_skill`/`--sync`: mismo aviso que el caso
# de pr-review de arriba, con `/task-fix DEVKIT-9` (la Clave sí viaja en el
# prompt, a diferencia de `/pr-review <N>`). roles.toml del template con
# `presupuesto.task-fix` bajado a 1: el doble de `claude` de `corre_fix`
# siempre responde `num_turns=2`, así que lo excede desde el primer llamado y
# no llega a la lógica de "fix vacío" (H1 del informe sobre el PR #68).
# Exceder el presupuesto no bloquea (DEVKIT-105): task-block.sh no se llama.
ROLES_PRESUPUESTO_FIX="$TMP/roles-presupuesto-task-fix.toml"
sed -E 's/^presupuesto\.task-fix = [0-9]+/presupuesto.task-fix = 1/' \
  "$HERE/../agents/roles.toml" > "$ROLES_PRESUPUESTO_FIX"
ROLES_OVERRIDE="$ROLES_PRESUPUESTO_FIX" \
  corre_fix "H1 | atendido | 1234abc" "no debe correr"
check_igual "presupuesto (task-fix): la ALARMA de exceso queda en el watch.log real" 1 \
  "$(grep -coE 'ALARMA: presupuesto excedido \(2 turnos, presupuesto 1\)' "$FIX_DIR_ACTUAL/run/watch.log" 2>/dev/null)"
check_igual "presupuesto (task-fix): un solo llamado, no llega al reintento de fix vacío" 1 \
  "$(cat "$FIX_DIR_ACTUAL/llamadas")"
check_igual "presupuesto (task-fix): no bloquea con task-block.sh" "" \
  "$(cat "$FIX_DIR_ACTUAL/bloqueo" 2>/dev/null)"
check_igual "presupuesto (task-fix): el comentario cita el presupuesto y los turnos usados" 1 \
  "$(grep -coE 'Presupuesto excedido: 2 turnos contra 1 en task-fix; el ciclo sigue' "$FIX_DIR_ACTUAL/notion-comentarios" 2>/dev/null)"
ROLES_OVERRIDE=""

# --- Escalera de modelos por ronda (DEVKIT-61) -------------------------------
# El PR ya tiene dos devkit-fix: el task-fix que lanza el bucle es la ronda 3,
# que en el roles.toml del template es `opus:high`.
FIX_COMENTARIOS='{"author":{"login":"bot"},"createdAt":"T02","body":"<!-- devkit-fix sha=b2 review=a1 -->"},{"author":{"login":"bot"},"createdAt":"T04","body":"<!-- devkit-fix sha=c3 review=b2 -->"}' \
  corre_fix "H1 | atendido | 1234abc" "no debe correr"
check_igual "rondas: el task-fix de la tercera ronda corre con opus" "opus" \
  "$(tr '\n' ' ' <"$FIX_DIR_ACTUAL/modelos" | sed 's/ $//')"
check_log "rondas: watch.log dice ronda=3 con modelo y esfuerzo" \
  'task-fix-45-a1b2c3d terminado: modelo=opus esfuerzo=high ronda=3 '
# La línea con ronda= sigue sumando en el costo del ciclo.
check_igual "rondas: cycle_cost suma la línea con ronda=" "0.0100" \
  "$(bash "$WATCH" --cycle-cost 45 "$OUT")"

# --- Limpieza local de task-close.sh: los tres silencios pasan a una línea de
# watch.log (DEVKIT-63). Repositorio real (origin bare + clon), porque el
# bug -el candado ocupado por el `task-start` de la siguiente hija, que la
# "Limpieza local" toma sin que el bucle de merges lo sepa, ver el comentario
# junto a `no_limpia` en task-close.sh- solo se ve con `git` de verdad.
LIMP="$TMP/limpieza"
mkdir -p "$LIMP"
git init -q --bare "$LIMP/origin.git"
git init -q "$LIMP/seed"
git -C "$LIMP/seed" config user.email t@t.com
git -C "$LIMP/seed" config user.name t
git -C "$LIMP/seed" commit -q --allow-empty -m base
git -C "$LIMP/seed" branch -M main
git -C "$LIMP/seed" remote add origin "$LIMP/origin.git"
git -C "$LIMP/seed" push -q origin main
git clone -q "$LIMP/origin.git" "$LIMP/ws"
git -C "$LIMP/ws" config user.email t@t.com
git -C "$LIMP/ws" config user.name t
git -C "$LIMP/ws" switch -q -c feat/DEVKIT-3-algo
git -C "$LIMP/ws" commit -q --allow-empty -m rama
git -C "$LIMP/ws" push -q origin feat/DEVKIT-3-algo
LIMP_SHA=$(git -C "$LIMP/ws" rev-parse HEAD)

# Card ya Hecha y marcador `devkit-closed` ya publicado: task-close.sh entra
# directo a la sección de Limpieza local sin tocar Notion ni GitHub de nuevo.
tarea card-3 3 Hecha 1 "" >"$N/card-DEVKIT-3.json"
jq -nc --arg sha "$LIMP_SHA" '{state:"MERGED", number:40, url:"https://github.com/o/r/pull/40",
    headRefOid:$sha, mergeCommit:{oid:"f9"}, comments:[{body:"<!-- devkit-closed sha=f9 -->"}],
    body:"", reviews:[]}' >"$CICLO/gh/pr.json"

limp_run() {  # limp_run <run-dir>
  env FAKE_NOTION="$N" FAKE_GH="$CICLO/gh" PATH="$CICLO/bin:$PATH" \
      DEVKIT_NOTION_BIN="$CICLO/notion.sh" DEVKIT_RUN_BIN="$CICLO/devkit-run.sh" \
      DEVKIT_PS_BIN="$CICLO/ps-vacio" DEVKIT_WS="$LIMP/ws" DEVKIT_RUN_DIR="$1" DEVKIT_HOY=2026-09-16 \
      bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
}
limp_sin_linea() {  # limp_sin_linea <watch.log>
  [ -f "$1" ] && grep -c 'no limpia el workspace' "$1" || echo 0
}

# 1. Árbol sucio: no toca nada, la rama sigue viva y el motivo queda en
#    watch.log.
echo cambio >"$LIMP/ws/sucio.txt"
R1="$TMP/limp-sucio"; mkdir -p "$R1"
limp_run "$R1"
OUT="$R1/watch.log"
check_log "limpieza: árbol sucio queda en watch.log" \
  'task-close\.sh DEVKIT-3 no limpia el workspace: árbol sucio'
check_igual "limpieza: árbol sucio no cambia de rama" feat/DEVKIT-3-algo \
  "$(git -C "$LIMP/ws" rev-parse --abbrev-ref HEAD)"
rm -f "$LIMP/ws/sucio.txt"

# 2. Candado ocupado por otra skill (el caso real del 2026-09-16): tampoco
#    toca nada, y también queda dicho.
R2="$TMP/limp-candado"; mkdir -p "$R2"
(
  exec 9>"$R2/skill.lock"
  flock 9
  touch "$R2/tomado"
  sleep 3
) &
holder=$!
i=0
while [ ! -e "$R2/tomado" ] && [ "$i" -lt 50 ]; do sleep 0.05; i=$((i + 1)); done
limp_run "$R2"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
OUT="$R2/watch.log"
check_log "limpieza: candado ocupado queda en watch.log" \
  'task-close\.sh DEVKIT-3 no limpia el workspace: candado ocupado'
check_igual "limpieza: candado ocupado no cambia de rama" feat/DEVKIT-3-algo \
  "$(git -C "$LIMP/ws" rev-parse --abbrev-ref HEAD)"

# 3. Árbol limpio y candado libre: el caso feliz, sin ninguna línea de aviso.
R3="$TMP/limp-limpio"; mkdir -p "$R3"
limp_run "$R3"
check_igual "limpieza: árbol limpio vuelve a main" main \
  "$(git -C "$LIMP/ws" rev-parse --abbrev-ref HEAD)"
check_igual "limpieza: árbol limpio borra la rama local" "" \
  "$(git -C "$LIMP/ws" branch --list feat/DEVKIT-3-algo)"
check_igual "limpieza: árbol limpio no deja línea de no-limpia" 0 \
  "$(limp_sin_linea "$R3/watch.log")"

# --- Reacción inmediata (DEVKIT-108) ----------------------------------------
# `sleep_or_poke` corta la espera apenas aparece /run/devkit/poke, sin
# esperar el resto de los segundos pedidos: es lo que hace que tocar el
# archivo desde review-publish.sh/task-submit.sh/devkit-run.sh --worker
# despierte al bucle en vez de esperar el resto del intervalo.
POKE_DIR=$(mktemp -d -p "$TMP")
( sleep 0.3; touch "$POKE_DIR/poke" ) &
POKE_MS=$(DEVKIT_RUN_DIR="$POKE_DIR" bash "$WATCH" --sleep-or-poke 20)
if [ "$POKE_MS" -lt 15000 ]; then
  printf 'ok   %-58s %sms\n' "poke: sleep_or_poke corta la espera antes de los 20s" "$POKE_MS"
else
  printf 'FAIL %-58s tardó %sms, no cortó\n' "poke: sleep_or_poke corta la espera antes de los 20s" "$POKE_MS"
  fail=1
fi
check_igual "poke: sleep_or_poke borra el archivo al despertar" 0 \
  "$([ -e "$POKE_DIR/poke" ] && echo 1 || echo 0)"

# `procesar_pr` encadena decide+actúa sin dormir hasta un estado terminal: un
# PR nuevo pasa por pr-review (CAMBIOS) -> task-fix -> pr-review (OK) ->
# task-document.sh + lanzar_cola -> nada, todo en una sola llamada. `gh` y
# `devkit-run.sh` son dobles con estado propio en $PP_STATE: el segundo
# simula lo que review-publish.sh/fix-publish.sh publicarían de verdad
# (nuevo devkit-review o devkit-fix) para que la siguiente vuelta de `decide`
# dentro de la misma llamada vea el cambio, igual que pasaría contra GitHub.
PP=$(mktemp -d -p "$TMP")
PP_STATE="$PP/state"
mkdir -p "$PP_STATE" "$PP/bin" "$PP/run"
echo a1b2c3d >"$PP_STATE/head"
: >"$PP_STATE/reviews"
: >"$PP_STATE/comments"
: >"$PP_STATE/gh-calls"

cat >"$PP/bin/gh" <<'FIN'
#!/usr/bin/env bash
d="$PP_STATE"
printf '%s %s\n' "$1" "$2" >>"$d/gh-calls"
case "$1 $2" in
  "pr view")
    head=$(cat "$d/head")
    revs=$(paste -sd',' "$d/reviews" 2>/dev/null)
    coms=$(paste -sd',' "$d/comments" 2>/dev/null)
    printf '{"headRefOid":"%s","reviews":[%s],"comments":[%s],"body":"## Qué cambia\\nalgo"}' \
      "$head" "$revs" "$coms"
    ;;
  "pr comment") cat >/dev/null ;;
  *) exit 1 ;;
esac
FIN
chmod +x "$PP/bin/gh"

cat >"$PP/devkit-run" <<'FIN'
#!/usr/bin/env bash
d="$PP_STATE"
case "$1" in
  --rol)
    echo "sonnet medium - 1"
    ;;
  --sync)
    head=$(cat "$d/head")
    case "$2" in
      "/pr-review "*)
        n=$(( $(cat "$d/pr-calls" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$d/pr-calls"
        if [ "$n" -eq 1 ]; then
          printf '{"author":{"login":"humano"},"state":"COMMENTED","submittedAt":"T01","body":"<!-- devkit-review sha=%s verdict=CAMBIOS -->"}\n' \
            "$head" >>"$d/reviews"
        else
          printf '{"author":{"login":"humano"},"state":"COMMENTED","submittedAt":"T03","body":"<!-- devkit-review sha=%s verdict=OK -->"}\n' \
            "$head" >>"$d/reviews"
        fi
        ;;
      "/task-fix "*)
        printf '{"author":{"login":"bot"},"createdAt":"T02","body":"<!-- devkit-fix sha=%s review=%s -->"}\n' \
          "$head" "$head" >>"$d/comments"
        ;;
    esac
    printf '{"result":"listo","total_cost_usd":0.01,"num_turns":3}\n'
    ;;
  --resumen) echo "resumen" ;;
  --guardar-transcripcion) exit 0 ;;
  --pregunta-abierta) exit 1 ;;
  --presupuesto-corte) exit 0 ;;
  --siguiente-modelo) echo fable ;;
  *) exit 0 ;;
esac
FIN
chmod +x "$PP/devkit-run"

cat >"$PP/task-document" <<'FIN'
#!/usr/bin/env bash
d="$PP_STATE"
head=$(cat "$d/head")
printf '%s %s\n' "$1" "$2" >>"$d/task-document-llamadas"
printf '{"author":{"login":"bot"},"createdAt":"T04","body":"<!-- devkit-doc sha=%s -->"}\n' \
  "$head" >>"$d/comments"
echo "task-document: $1 documentado: https://notion.so/doc-x"
FIN
chmod +x "$PP/task-document"

cat >"$PP/cola" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PP_STATE/cola-llamadas"
FIN
chmod +x "$PP/cola"

PP_INICIO=$(date +%s%N)
PP_STATE="$PP_STATE" PATH="$PP/bin:$PATH" DEVKIT_RUN_BIN="$PP/devkit-run" \
DEVKIT_TASK_DOCUMENT_BIN="$PP/task-document" DEVKIT_COLA_BIN="$PP/cola" \
DEVKIT_RUN_DIR="$PP/run" DEVKIT_WS="$PP" \
  bash "$WATCH" --procesar-pr 77 https://github.com/o/r/pull/77 "DEVKIT-9 algo" "" \
  >"$PP/watch.log" 2>&1
PP_FIN=$(date +%s%N)
PP_MS=$(( (PP_FIN - PP_INICIO) / 1000000 ))

if [ "$PP_MS" -lt 10000 ]; then
  printf 'ok   %-58s %sms\n' "procesar_pr: cadena completa en menos de 10s" "$PP_MS"
else
  printf 'FAIL %-58s tardó %sms\n' "procesar_pr: cadena completa en menos de 10s" "$PP_MS"
  fail=1
fi
OUT="$PP/watch.log"
check_log "procesar_pr: sin informe, lanza pr-review" \
  'PR #77 \(DEVKIT-9\) head a1b2c3d sin informe: lanzando pr-review'
check_log "procesar_pr: CAMBIOS lanza task-fix en el mismo tick" \
  'PR #77 \(DEVKIT-9\) CAMBIOS en a1b2c3d: lanzando task-fix'
check_log "procesar_pr: respuesta sin push lanza pr-review otra vez, en el mismo tick" \
  'PR #77 \(DEVKIT-9\) head a1b2c3d con respuesta sin push: lanzando pr-review otra vez'
check_log "procesar_pr: OK lanza task-document.sh en el mismo tick" \
  'PR #77 \(DEVKIT-9\) OK en a1b2c3d: task-document\.sh'
check_igual "procesar_pr: pr-review corrió dos veces (CAMBIOS y OK)" 2 \
  "$(cat "$PP_STATE/pr-calls" 2>/dev/null || echo 0)"
check_igual "procesar_pr: task-fix corrió una sola vez" 1 \
  "$(grep -c 'devkit-fix' "$PP_STATE/comments" 2>/dev/null || echo 0)"
check_igual "procesar_pr: task-document.sh corrió una sola vez" 1 \
  "$(wc -l <"$PP_STATE/task-document-llamadas" 2>/dev/null | tr -d ' ')"
check_igual "procesar_pr: OK encadena vía cola.sh (lanzar_cola) una sola vez, en el mismo tick" 1 \
  "$(wc -l <"$PP_STATE/cola-llamadas" 2>/dev/null | tr -d ' ')"
# Cinco vueltas de la cadena (revisar, fix, revisar, documentar, nada), más
# la consulta que hace `atender_fix` para saber si task-fix respondió vacío
# (DEVKIT-57): seis en total, y ninguna más -la cadena para sola al llegar a
# `nada`, sin seguir consultando GitHub.
check_igual "procesar_pr: se detiene tras llegar a nada, sin de más" 6 \
  "$(grep -c '^pr view$' "$PP_STATE/gh-calls" 2>/dev/null || echo 0)"

exit $fail

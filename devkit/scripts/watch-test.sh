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
corre_doble() {
  local dir
  dir=$(mktemp -d -p "$TMP")
  OUT="$dir/watch.log"
  # PRESEED simula lo que ya hay en `launched` cuando arranca la ejecución.
  if [ -n "${PRESEED:-}" ]; then mkdir -p "$dir/run"; echo "$PRESEED" > "$dir/run/launched"; fi
  DEVKIT_TEST_COUNT="$dir/llamadas" DEVKIT_TEST_FAILS="$1" DEVKIT_TEST_MSG="${2:-}" \
  DEVKIT_TEST_SLEEP="${DEVKIT_TEST_SLEEP:-0}" DEVKIT_TEST_RESULT="${DEVKIT_TEST_RESULT:-listo}" \
  DEVKIT_CLAUDE_BIN="$DOBLE" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
  DEVKIT_WATCH_QUOTA_MIN_WAIT=1 DEVKIT_WATCH_QUOTA_WAIT=2 \
  DEVKIT_WATCH_QUOTA_RETRIES="${RETRIES:-3}" \
  DEVKIT_WATCH_SKILL_TIMEOUT="${DEVKIT_WATCH_SKILL_TIMEOUT:-1200}" \
  DEVKIT_WATCH_SKILL_POLL="${DEVKIT_WATCH_SKILL_POLL:-5}" \
    bash "$WATCH" --run-skill "pr-review-9-abc1234" "/pr-review 9" "revisar:9:abc1234" \
    >"$OUT" 2>&1
  LLAMADAS=$(cat "$dir/llamadas" 2>/dev/null || echo 0)
  LAUNCHED_FILE="$dir/run/launched"
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
check_log "línea de pausa por cuota" 'cuota agotada: pr-review-9-abc1234 en pausa hasta [0-9T:-]+Z'
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
# desde roles.toml; pr-review siempre cae en el rol "revision" (el primer
# modelo de la lista `frontera`), sin importar el Tipo de la card.
corre_doble 0
check_log "la línea de resumen trae el modelo del rol de revisión" \
  'modelo=fable esfuerzo=high'

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
printf '%s\n' "$*" >>"$FAKE_NOTION/lanzamientos"
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
chmod +x "$CICLO/notion.sh" "$CICLO/devkit-run.sh" "$CICLO/bin/gh"

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
# /task-start` de verdad, que task-next.sh tomaría por una hija ya lanzada.
cat >"$CICLO/ps-vacio" <<'FIN'
#!/usr/bin/env bash
exit 0
FIN
chmod +x "$CICLO/ps-vacio"
ciclo_env=(FAKE_NOTION="$N" FAKE_GH="$CICLO/gh" PATH="$CICLO/bin:$PATH"
           DEVKIT_NOTION_BIN="$CICLO/notion.sh" DEVKIT_RUN_BIN="$CICLO/devkit-run.sh"
           DEVKIT_PS_BIN="$CICLO/ps-vacio"
           DEVKIT_WS="$CICLO/ws" DEVKIT_RUN_DIR="$CICLO/run" DEVKIT_HOY=2026-09-16)

# 1. OK del revisor: el bucle decide documentar y task-document corre con el
#    rol de implementación (segundo modelo de la frontera).
check "ciclo: OK sin documentar" documentar a1 "$(rev T01 a1 OK)" --
corre_documentar() {
  local dir
  dir=$(mktemp -d -p "$TMP")
  OUT="$dir/watch.log"
  DEVKIT_TEST_COUNT="$dir/llamadas" DEVKIT_TEST_FAILS=0 \
  DEVKIT_CLAUDE_BIN="$DOBLE" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_FRONTERA_CACHE_DIR="$FRONTERA_CACHE" \
    bash "$WATCH" --run-skill "task-document-40-a1" "/task-document DEVKIT-3 40" "documentar:40:a1" >"$OUT" 2>&1
}
corre_documentar
check_log "ciclo: task-document corre con el segundo modelo" 'task-document-40-a1 terminado: modelo=opus esfuerzo=high'
# 2. task-document deja su marcador: ya no hay nada que hacer hasta el merge.
check "ciclo: documentado, espera el merge" nada a1 "$(rev T01 a1 OK)" -- "$(doc T02 a1)"

# 3. Merge: el bucle de mergeados cierra con task-close.sh.
MERGED_AT=$(date -u -d '-5 seconds' +%FT%TZ)
printf '40\thttps://github.com/o/r/pull/40\t%s\tDEVKIT-3 algo\n' "$MERGED_AT" >"$CICLO/gh/mergeados"
jq -nc '{state: "MERGED", number: 40, url: "https://github.com/o/r/pull/40", headRefOid: "a1",
         mergeCommit: {oid: "f1"}, comments: [{body: "<!-- devkit-doc sha=a1 -->"}]}' >"$CICLO/gh/pr.json"
env "${ciclo_env[@]}" bash "$WATCH" --merged-once >"$CICLO/watch.log" 2>&1
OUT="$CICLO/watch.log"
check_log "ciclo: cerrado en bash con la medida desde el merge" 'task-close-40 terminado: bash, cerrado [0-9]+s después del merge'
SEG=$(grep -oE 'cerrado [0-9]+s después' "$OUT" | grep -oE '[0-9]+')
check_igual "ciclo: cerrado en menos de un minuto desde el merge" si "$([ "${SEG:-99}" -lt 60 ] && echo si || echo no)"
check_igual "ciclo: card a Hecha con Cierre y PR" "set card-3 Estado=Hecha Cierre=2026-09-16 PR=https://github.com/o/r/pull/40" \
  "$(grep '^set card-3' "$N/llamadas" | head -1)"
check_igual "ciclo: comentario con el enlace a la Documentación" "comentar card-3 Cerrada. Documentación: https://notion.so/doc-3" \
  "$(grep '^comentar card-3' "$N/llamadas" | head -1)"
check_igual "ciclo: marcador devkit-closed con sha y enlace" 1 \
  "$(grep -c 'pr comment 40 --body <!-- devkit-closed sha=f1 -->' "$CICLO/gh/comentarios" 2>/dev/null)"
check_igual "ciclo: lanza la siguiente hija libre por Orden y dependencias" "task-start DEVKIT-4" \
  "$(cat "$N/lanzamientos" 2>/dev/null)"
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

# Sin entrada de Documentación (merge antes de que el bucle documentara): se
# cierra igual y se lanza task-document.
rm -f "$N/doc-card-3.json"; : >"$N/llamadas"; : >"$N/lanzamientos"
env "${ciclo_env[@]}" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: sin Documentación lanza task-document" "task-document DEVKIT-3" \
  "$(head -1 "$N/lanzamientos")"
# Con task-document ya corriendo para la Clave (merge aprobado mientras escribe
# la entrada): no se relanza y el comentario no dice que falta.
cat >"$CICLO/ps-documentando" <<'FIN'
#!/usr/bin/env bash
echo "bash /workspace/devkit/scripts/devkit-run.sh --sync /task-document DEVKIT-3 40"
FIN
chmod +x "$CICLO/ps-documentando"
tarea card-3 3 "Lista para merge" 1 "" >"$N/card-DEVKIT-3.json"
: >"$N/llamadas"; : >"$N/lanzamientos"
env "${ciclo_env[@]}" DEVKIT_PS_BIN="$CICLO/ps-documentando" bash "$HERE/task-close.sh" DEVKIT-3 40 >/dev/null 2>&1
check_igual "task-close: con task-document en curso no lo relanza" "0 comentar card-3 Cerrada. La entrada de Documentación la está escribiendo task-document." \
  "$(grep -c '^task-document' "$N/lanzamientos") $(grep '^comentar card-3' "$N/llamadas" | head -1)"

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

# --- Siguiente hija al OK del revisor (DEVKIT-56) ----------------------------
# task-next.sh real, llamado por el hook --chain-next de watch.sh, contra los
# mismos dobles. Épica 2 con dos hijas en Lista detrás de DEVKIT-10, que acaba
# de recibir OK: DEVKIT-11 depende de ella (tocan los mismos archivos) y
# DEVKIT-12 no. Arranca DEVKIT-12 aunque DEVKIT-11 tenga menor Orden.
hija() {  # hija <id> <numero> <estado> <orden> <depende>, en la Épica 2
  tarea "$@" | jq -c '.padre = ["epica-2"]'
}
hija card-10 10 "Lista para merge" 1 "" >"$N/card-DEVKIT-10.json"
printf '[%s,%s,%s]' "$(hija card-10 10 "Lista para merge" 1 "")" "$(hija card-11 11 Lista 2 card-10)" \
  "$(hija card-12 12 Lista 3 "")" >"$N/hijas-epica-2.json"
: >"$N/llamadas"; : >"$N/lanzamientos"
env "${ciclo_env[@]}" bash "$WATCH" --chain-next 50 DEVKIT-10 >"$CICLO/chain.log" 2>&1
OUT="$CICLO/chain.log"
check_igual "encadenar: al OK arranca la hija que no depende de la aprobada" "task-start DEVKIT-12" \
  "$(cat "$N/lanzamientos")"
check_log "encadenar: la línea de watch.log lo registra" \
  'task-next-50 terminado: bash, DEVKIT-10 en Lista para merge :: task-next: lanzada la siguiente hija: task-start DEVKIT-12'

# Solo queda la dependiente: espera el merge, sin lanzar ni comentar en la
# Épica, porque el cierre de DEVKIT-10 vuelve a llamar a task-next.sh.
printf '[%s,%s]' "$(hija card-10 10 "Lista para merge" 1 "")" "$(hija card-11 11 Lista 2 card-10)" >"$N/hijas-epica-2.json"
: >"$N/llamadas"; : >"$N/lanzamientos"
check_igual "encadenar: la dependiente espera a Hecha" "task-next: sin hija libre; DEVKIT-11 esperan dependencias" \
  "$(env "${ciclo_env[@]}" bash "$HERE/task-next.sh" DEVKIT-10 2>&1 | tail -1)"
check_igual "encadenar: esperar un merge no comenta en la Épica" "0 0" \
  "$(wc -l <"$N/lanzamientos" | tr -d ' ') $(grep -c '^comentar' "$N/llamadas")"

# Una hija ya en curso: no se arranca otra encima.
printf '[%s,%s,%s]' "$(hija card-10 10 "Lista para merge" 1 "")" "$(hija card-11 11 "En progreso" 2 "")" \
  "$(hija card-12 12 Lista 3 "")" >"$N/hijas-epica-2.json"
: >"$N/lanzamientos"
check_igual "encadenar: con una hermana En progreso no lanza" "task-next: no lanzo otra hija: DEVKIT-11 (En progreso) sigue en curso" \
  "$(env "${ciclo_env[@]}" bash "$HERE/task-next.sh" DEVKIT-10 2>&1 | tail -1)"

# task-start ya lanzado al OK, esperando el candado, y el merge llega antes de
# que cambie el Estado: task-close.sh no lo lanza dos veces.
printf '[%s,%s]' "$(hija card-10 10 "Lista para merge" 1 "")" "$(hija card-12 12 Lista 3 "")" >"$N/hijas-epica-2.json"
cat >"$CICLO/ps-arrancando" <<'FIN'
#!/usr/bin/env bash
echo "bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-12 /run/devkit/task-start-1.log opus high 40"
FIN
chmod +x "$CICLO/ps-arrancando"
: >"$N/lanzamientos"
check_igual "encadenar: task-start vivo para la hermana no se duplica" "task-next: no lanzo otra hija: task-start DEVKIT-12 ya corre o espera el candado" \
  "$(env "${ciclo_env[@]}" DEVKIT_PS_BIN="$CICLO/ps-arrancando" bash "$HERE/task-next.sh" DEVKIT-10 2>&1 | tail -1)"
check_igual "encadenar: sin segundo lanzamiento" 0 "$(wc -l <"$N/lanzamientos" | tr -d ' ')"

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

exit $fail

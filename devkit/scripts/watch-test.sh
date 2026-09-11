#!/usr/bin/env bash
# Prueba de watch.sh sin tocar GitHub ni gastar cuota. Dos bloques: la tabla de
# decisión, donde cada caso es un PR sintético (head, reviews, comments) y la
# acción que se espera de `watch.sh --decide`, y el relanzamiento por cuota
# agotada, con logs falsos y un doble de `claude`. Sale con 1 si algún caso
# falla.
# Uso: bash watch-test.sh
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
block() { comment "$BOT" "$1" "<!-- devkit-block sha=$2 -->"; }
closed() { comment "$BOT" "$1" "<!-- devkit-closed sha=$2 -->"; }
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
check "CAMBIOS respondido sin cambiar el head (DEVKIT-22)" nada a1 "$(rev T01 a1 CAMBIOS)" -- "$(fix T02 a1 a1)"
check "OK para el head" nada a1 "$(rev T01 a1 OK)" --
check "OK y comentario humano posterior" fix-humano a1 "$(rev T01 a1 OK)" -- "$(comment humano T02 'falta la prueba X')"
check "OK y approve humano con texto" nada a1 "$(rev T01 a1 OK)" "$(review humano APPROVED T02 'bien')" --
check "comentario humano anterior al marcador" nada a1 "$(rev T02 a1 OK)" -- "$(comment humano T01 'antes')"
check "tres CAMBIOS respondidos y head nuevo" bloquear d4 \
  "$(rev T01 a1 CAMBIOS)" "$(rev T03 b2 CAMBIOS)" "$(rev T05 c3 CAMBIOS)" -- \
  "$(fix T02 b2 a1)" "$(fix T04 c3 b2)" "$(fix T06 d4 c3)"
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
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":3}\n'
FIN
chmod +x "$DOBLE"

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
  DEVKIT_CLAUDE_BIN="$DOBLE" DEVKIT_RUN_DIR="$dir/run" DEVKIT_WS="$dir" \
  DEVKIT_WATCH_QUOTA_MIN_WAIT=1 DEVKIT_WATCH_QUOTA_WAIT=2 \
  DEVKIT_WATCH_QUOTA_RETRIES="${RETRIES:-3}" \
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

exit $fail

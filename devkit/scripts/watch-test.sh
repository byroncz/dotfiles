#!/usr/bin/env bash
# Prueba de la tabla de decisión de watch.sh sin tocar GitHub. Cada caso es
# un PR sintético (head, reviews, comments) y la acción que se espera de
# `watch.sh --decide`. Sale con 1 si algún caso falla.
# Uso: bash watch-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/watch.sh"
export DEVKIT_WATCH_BOT="${DEVKIT_WATCH_BOT:-bot}"
export DEVKIT_WATCH_MAX_CYCLES="${DEVKIT_WATCH_MAX_CYCLES:-3}"
BOT="$DEVKIT_WATCH_BOT"
fail=0

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

exit $fail

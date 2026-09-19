#!/usr/bin/env bash
# Convierte el título de una card en el slug corto de su rama (DEVKIT-100):
# las primeras cinco palabras del título, sin artículos ni preposiciones de
# una a tres letras, en minúsculas, sin acentos, unidas por guiones y
# recortadas a 40 caracteres sin partir una palabra.
# Uso: slugify.sh "texto libre"
#      slugify.sh --test   (corre la tabla de autoprueba y sale 1 si falla)
set -u

MAX=40

# Artículos (sin límite de largo) y preposiciones de una a tres letras,
# incluidas las contracciones "al" y "del": sin estas dos, "PR review
# proporcional al diff" dejaba "al" como cuarta palabra en vez de descartarla.
STOPWORDS=" el la los las un una unos unas lo al del a de en con por sin so "

es_stopword() {
  case "$STOPWORDS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Quita acentos y diéresis, y deja solo minúsculas, dígitos y espacios como
# separadores de palabra (cualquier otro símbolo -puntuación, guiones del
# propio título- separa palabras igual que un espacio).
normalizar() {
  local s="$1"
  s="${s,,}"
  s="$(printf '%s' "$s" | sed -e 's/á/a/g; s/é/e/g; s/í/i/g; s/ó/o/g; s/ú/u/g; s/ñ/n/g; s/ü/u/g')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/ /g; s/^ +//; s/ +$//')"
  printf '%s\n' "$s"
}

slugify() {
  local titulo="$1"
  local normalizado
  normalizado=$(normalizar "$titulo")
  local -a palabras primeras resultado
  read -r -a palabras <<<"$normalizado"
  primeras=("${palabras[@]:0:5}")
  local p
  for p in "${primeras[@]}"; do
    es_stopword "$p" || resultado+=("$p")
  done
  local slug
  slug=$(IFS=-; printf '%s' "${resultado[*]:-}")
  if [ "${#slug}" -gt "$MAX" ]; then
    local corte="${slug:0:$MAX}"
    local siguiente="${slug:$MAX:1}"
    if [ -n "$siguiente" ] && [ "$siguiente" != "-" ]; then
      corte="${corte%-*}"
    fi
    slug="${corte%-}"
  fi
  printf '%s\n' "$slug"
}

run_tests() {
  local fail=0
  check() {
    local input=$1 want=$2 got
    got=$(slugify "$input")
    if [ "$want" = "$got" ]; then
      printf 'ok   %-30s -> %s\n' "$input" "$got"
    else
      printf 'FAIL %-30s esperado %s, obtenido %s\n' "$input" "$want" "$got"
      fail=1
    fi
  }
  check "Hola Mundo" "hola-mundo"
  check "  Café   con   Leche!! " "cafe-leche"
  check "DEVKIT-3 Skills del flujo" "devkit-3-skills-flujo"
  check "2026" "2026"
  # Título largo real (DEVKIT-93): "al" es la cuarta palabra y se descarta
  # por ser una contracción de artículo+preposición; el resto del título
  # ni siquiera entra en las primeras cinco palabras.
  check "PR review proporcional al diff: preparación y comprobaciones mecánicas por script" \
    "pr-review-proporcional-diff"
  # Título con acentos: valida que "según" se recorte por longitud (>3) y
  # se conserve, mientras "de" (preposición corta) se descarta.
  check "Depuración rápida según el pipeline de ingestión" \
    "depuracion-rapida-segun-pipeline"
  return $fail
}

if [ "${1:-}" = "--test" ]; then
  run_tests
  exit $?
fi

slugify "${1:-}"

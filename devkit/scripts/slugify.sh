#!/usr/bin/env bash
# Convierte un texto libre en un slug de minúsculas separado por guiones,
# el mismo formato que usan las ramas de las cards (ver AGENTS.md).
# Uso: slugify.sh "texto libre"
#      slugify.sh --test   (corre la tabla de autoprueba y sale 1 si falla)
set -u

slugify() {
  local s="$1"
  s="${s,,}"
  s="$(printf '%s' "$s" | sed -e 's/á/a/g; s/é/e/g; s/í/i/g; s/ó/o/g; s/ú/u/g; s/ñ/n/g; s/ü/u/g')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g')"
  s="$(printf '%s' "$s" | sed -E 's/-+/-/g; s/^-//; s/-$//')"
  printf '%s\n' "$s"
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
  check "  Café   con   Leche!! " "cafe-con-leche"
  check "DEVKIT-3 Skills del flujo" "devkit-3-skills-del-flujo"
  return $fail
}

if [ "${1:-}" = "--test" ]; then
  run_tests
  exit $?
fi

slugify "${1:-}"

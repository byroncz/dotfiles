#!/usr/bin/env bash
# Hook PostToolUse para Edit|Write (DEVKIT-91): corrige formato y sintaxis en
# cuanto el archivo se escribe, en vez de esperar a que lo encuentre `pr-review`
# en Opus (Épica DEVKIT-86, Contexto 4). Sobre un `.py` corre `ruff format` y
# `ruff check --fix`, y devuelve lo que no pudo arreglar solo; sobre un `.sh`
# corre `bash -n` y devuelve el error de sintaxis si lo hay. Cualquier otra
# extensión, nada. Nunca bloquea: el archivo ya se escribió, así que esto es
# información para el agente, no una barrera -a diferencia de `pr-guard.sh`,
# que sí bloquea comandos antes de que corran.
#
# Uso normal: recibe por stdin el JSON del hook (`tool_input.file_path`) y, si
# hay algo que informar, lo imprime en stdout. Sale 0 siempre.
set -u
RUFF="${DEVKIT_RUFF_BIN:-ruff}"

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$file_path" ] && [ -f "$file_path" ] || exit 0

salida=""
case "$file_path" in
  *.py)
    salida="$("$RUFF" format -q "$file_path" 2>&1)"
    salida="$salida
$("$RUFF" check --fix "$file_path" 2>&1)"
    ;;
  *.sh)
    salida="$(bash -n "$file_path" 2>&1)"
    ;;
  *)
    exit 0
    ;;
esac

salida="$(printf '%s' "$salida" | sed '/^[[:space:]]*$/d')"
[ -n "$salida" ] || exit 0
printf '%s\n' "$salida"
exit 0

#!/bin/sh
# ---------------------------------------------------------------------------
#  devkit: línea de extensiones de la sección Stack del README, generada
#  desde devkit/vscode/extensions.toml.
#
#    gen-stack.sh              imprime la línea
#    gen-stack.sh --check      sale con 1 si el README quedó viejo
#    gen-stack.sh --test       autoprueba, sin tocar el README
#
#  Un "latest" se imprime tal cual, sin resolver contra Open VSX: esa
#  resolución vive en devkit.sh (resolve_extensions), al construir. Aquí solo
#  se refleja lo que declara el archivo.
# ---------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # devkit/

linea() {  # linea <extensions.toml>
  ids="$(sed -n 's/^"\([^"]*\)"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1 \2/p' "$1" \
    | awk '{printf "%s%s %s", (NR>1?", ":""), $1, $2}')"
  printf 'Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: %s.\n' "$ids"
}

# --- Autoprueba --------------------------------------------------------------
if [ "${1:-}" = "--test" ]; then
  fail=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  check() {  # check <nombre> <esperado> <obtenido>
    if [ "$2" = "$3" ]; then
      printf 'ok   %-45s %s\n' "$1" "$3"
    else
      printf 'FAIL %-45s esperado "%s", obtenido "%s"\n' "$1" "$2" "$3"
      fail=1
    fi
  }

  printf '"Anthropic.claude-code" = "latest"\n' > "$tmp/una.toml"
  check "una extensión en latest" \
    'Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: Anthropic.claude-code latest.' \
    "$(linea "$tmp/una.toml")"

  printf '# comentario\n"Anthropic.claude-code" = "2.1.270"\n"ms.otra" = "latest"\n' > "$tmp/dos.toml"
  check "dos extensiones, comentario ignorado" \
    'Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: Anthropic.claude-code 2.1.270, ms.otra latest.' \
    "$(linea "$tmp/dos.toml")"

  printf '"Anthropic.claude-code" = "latest"\n' > "$tmp/toml"
  printf '%s\n' "$(linea "$tmp/toml")" > "$tmp/README.md"
  DEVKIT_GEN_STACK_TOML="$tmp/toml" DEVKIT_GEN_STACK_README="$tmp/README.md" \
    sh "$HERE/scripts/gen-stack.sh" --check >/dev/null 2>&1
  check "--check con el README al día sale 0" 0 "$?"

  printf 'algo viejo\n' > "$tmp/README.md"
  DEVKIT_GEN_STACK_TOML="$tmp/toml" DEVKIT_GEN_STACK_README="$tmp/README.md" \
    sh "$HERE/scripts/gen-stack.sh" --check >/dev/null 2>&1
  check "--check con el README viejo sale 1" 1 "$?"

  exit $fail
fi

# --- Uso normal / --check -----------------------------------------------------
TOML="${DEVKIT_GEN_STACK_TOML:-$HERE/vscode/extensions.toml}"
README="${DEVKIT_GEN_STACK_README:-$(pwd)/README.md}"
[ -f "$TOML" ] || { echo "gen-stack.sh: no existe $TOML" >&2; exit 2; }

if [ "${1:-}" = "--check" ]; then
  [ -f "$README" ] || { echo "gen-stack.sh: no existe $README" >&2; exit 2; }
  if grep -qF "$(linea "$TOML")" "$README"; then
    exit 0
  fi
  echo "gen-stack.sh: el README no refleja $TOML; corre gen-stack.sh y pega la línea en la sección Stack" >&2
  exit 1
fi

linea "$TOML"

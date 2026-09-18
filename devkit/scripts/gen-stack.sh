#!/bin/sh
# ---------------------------------------------------------------------------
#  devkit: líneas de versiones de la sección Stack del README, generadas
#  desde devkit/vscode/extensions.toml y devkit/Dockerfile. Las usa
#  gen-readme.sh al armar el README completo.
#
#    gen-stack.sh              imprime la línea de extensiones
#    gen-stack.sh --versiones  imprime la línea de versiones del Dockerfile
#    gen-stack.sh --check      sale con 1 si el README quedó viejo
#    gen-stack.sh --test       autoprueba, sin tocar el README
#
#  Un "latest" se imprime tal cual, sin resolver contra Open VSX: esa
#  resolución vive en devkit.sh (resolve_extensions), al construir. Aquí solo
#  se refleja lo que declara el archivo.
# ---------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # devkit/

# Una línea no vacía y sin comentario que no calce con "id" = "versión" (sin
# comillas, con sangría, comilla simple...) se ignoraba en silencio y la
# extensión desaparecía de la lista sin que --check lo notara (H5,
# DEVKIT-67). Avisa por stderr; devkit.sh (resolve_extensions) repite este
# mismo aviso al resolver. El comentario final es opcional: el `sed` de abajo
# ya lo tolera (H9, DEVKIT-67), así que la validación admite el mismo formato.
advertir_lineas_invalidas() {  # advertir_lineas_invalidas <extensions.toml>
  malas="$(grep -vE '^[[:space:]]*(#.*)?$' "$1" | grep -vE '^"[^"]*"[[:space:]]*=[[:space:]]*"[^"]*"[[:space:]]*(#.*)?$')"
  [ -n "$malas" ] || return 0
  echo "gen-stack.sh: aviso: $1 tiene líneas que no calzan con \"id\" = \"versión\" y se ignoran:" >&2
  printf '%s\n' "$malas" | sed 's/^/  /' >&2
}

linea() {  # linea <extensions.toml>
  advertir_lineas_invalidas "$1"
  ids="$(sed -n 's/^"\([^"]*\)"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1 \2/p' "$1" \
    | awk '{printf "%s%s %s", (NR>1?", ":""), $1, $2}')"
  printf 'Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: %s.\n' "$ids"
}

# Las herramientas listadas son las que trae la imagen con una versión fija en
# el Dockerfile (ARG ..._VERSION); no incluye Debian ni Python, sin versión
# propia fijada ahí.
versiones() {  # versiones <Dockerfile>
  uv="$(sed -n 's/^ARG UV_VERSION=\(.*\)/\1/p' "$1")"
  gh="$(sed -n 's/^ARG GH_VERSION=\(.*\)/\1/p' "$1")"
  rclone="$(sed -n 's/^ARG RCLONE_VERSION=\(.*\)/\1/p' "$1")"
  bws="$(sed -n 's/^ARG BWS_VERSION=\(.*\)/\1/p' "$1")"
  starship="$(sed -n 's/^ARG STARSHIP_VERSION=\(.*\)/\1/p' "$1")"
  openvscode="$(sed -n 's/^ARG OPENVSCODE_VERSION=\(.*\)/\1/p' "$1")"
  printf 'Versiones fijadas en `devkit/Dockerfile`: uv %s, gh %s, rclone %s, bws %s, starship %s, openvscode-server %s.\n' \
    "$uv" "$gh" "$rclone" "$bws" "$starship" "$openvscode"
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

  printf '"Anthropic.claude-code" = "latest"\n  '"'"'ms.otra'"'"' = '"'"'1.0.0'"'"'\n' > "$tmp/mala.toml"
  salida="$(linea "$tmp/mala.toml" 2>&1 >/dev/null)"
  check "línea que no calza avisa por stderr" si \
    "$(printf '%s' "$salida" | grep -q 'no calzan' && echo si || echo no)"
  check "línea que no calza no rompe la extensión válida" \
    'Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: Anthropic.claude-code latest.' \
    "$(linea "$tmp/mala.toml" 2>/dev/null)"

  printf '"Anthropic.claude-code" = "1.2.3"  # fija\n' > "$tmp/comentario.toml"
  salida="$(linea "$tmp/comentario.toml" 2>&1 >/dev/null)"
  check "línea válida con comentario al final no avisa" no \
    "$(printf '%s' "$salida" | grep -q 'no calzan' && echo si || echo no)"
  check "línea válida con comentario al final se usa" \
    'Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: Anthropic.claude-code 1.2.3.' \
    "$(linea "$tmp/comentario.toml" 2>/dev/null)"

  printf '"Anthropic.claude-code" = "latest"\n' > "$tmp/toml"
  printf '%s\n' "$(linea "$tmp/toml")" > "$tmp/README.md"
  DEVKIT_GEN_STACK_TOML="$tmp/toml" DEVKIT_GEN_STACK_README="$tmp/README.md" \
    sh "$HERE/scripts/gen-stack.sh" --check >/dev/null 2>&1
  check "--check con el README al día sale 0" 0 "$?"

  printf 'algo viejo\n' > "$tmp/README.md"
  DEVKIT_GEN_STACK_TOML="$tmp/toml" DEVKIT_GEN_STACK_README="$tmp/README.md" \
    sh "$HERE/scripts/gen-stack.sh" --check >/dev/null 2>&1
  check "--check con el README viejo sale 1" 1 "$?"

  printf 'ARG UV_VERSION=1.2.3\nARG GH_VERSION=4.5.6\nARG RCLONE_VERSION=7.8.9\nARG BWS_VERSION=1.0.0\nARG STARSHIP_VERSION=2.0.0\nARG OPENVSCODE_VERSION=3.0.0\n' > "$tmp/Dockerfile"
  check "versiones desde el Dockerfile" \
    'Versiones fijadas en `devkit/Dockerfile`: uv 1.2.3, gh 4.5.6, rclone 7.8.9, bws 1.0.0, starship 2.0.0, openvscode-server 3.0.0.' \
    "$(versiones "$tmp/Dockerfile")"

  exit $fail
fi

# --- Uso normal / --check -----------------------------------------------------
TOML="${DEVKIT_GEN_STACK_TOML:-$HERE/vscode/extensions.toml}"
README="${DEVKIT_GEN_STACK_README:-$(pwd)/README.md}"
DOCKERFILE="${DEVKIT_GEN_STACK_DOCKERFILE:-$HERE/Dockerfile}"

if [ "${1:-}" = "--versiones" ]; then
  [ -f "$DOCKERFILE" ] || { echo "gen-stack.sh: no existe $DOCKERFILE" >&2; exit 2; }
  versiones "$DOCKERFILE"
  exit 0
fi

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

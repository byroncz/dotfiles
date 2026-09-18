#!/bin/sh
# ---------------------------------------------------------------------------
#  devkit: tabla y líneas de versiones de la sección Stack del README,
#  generadas desde devkit/scripts/stack.tsv, devkit/Dockerfile,
#  devkit/proxy/Dockerfile y devkit/vscode/extensions.toml. Las usa
#  gen-readme.sh al armar el README completo.
#
#    gen-stack.sh              imprime la línea de extensiones
#    gen-stack.sh --versiones  imprime la línea de versiones del Dockerfile
#    gen-stack.sh --tabla      imprime la tabla Herramienta/Descripción/Versión
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

# Lee el valor de un ARG del Dockerfile; falla si no existe o quedó vacío
# (un ARG renombrado no debe pasar desapercibido como versión en blanco,
# H2 DEVKIT-88).
arg_valor() {  # arg_valor <Dockerfile> <ARG>
  valor="$(sed -n "s/^ARG $2=\\(.*\\)/\\1/p" "$1" | head -1)"
  if [ -z "$valor" ]; then
    echo "gen-stack.sh: $1 no define ARG $2" >&2
    return 1
  fi
  printf '%s' "$valor"
}

# Las herramientas listadas son las que trae la imagen con una versión fija en
# el Dockerfile (ARG ..._VERSION); no incluye Debian ni Python, sin versión
# propia fijada ahí.
versiones() {  # versiones <Dockerfile>
  uv="$(arg_valor "$1" UV_VERSION)" || return 1
  gh="$(arg_valor "$1" GH_VERSION)" || return 1
  rclone="$(arg_valor "$1" RCLONE_VERSION)" || return 1
  bws="$(arg_valor "$1" BWS_VERSION)" || return 1
  starship="$(arg_valor "$1" STARSHIP_VERSION)" || return 1
  openvscode="$(arg_valor "$1" OPENVSCODE_VERSION)" || return 1
  printf 'Versiones fijadas en `devkit/Dockerfile`: uv %s, gh %s, rclone %s, bws %s, starship %s, openvscode-server %s.\n' \
    "$uv" "$gh" "$rclone" "$bws" "$starship" "$openvscode"
}

# Versión de cada fila de stack.tsv, por id. Los ids sin versión propia
# fijada en este repo muestran `—`; sumar una fila con un id nuevo exige
# sumarlo aquí, o falla en vez de quedar en blanco. Cuando el nombre de la
# fila no deja claro a qué componente pertenece la versión (p. ej. "zsh +
# starship" o "rclone + Dropbox"), el valor lleva el nombre del componente
# delante, para no publicar un número sin decir de qué es (H6, DEVKIT-88).
version_de() {  # version_de <id> <Dockerfile> <proxy_dockerfile>
  case "$1" in
    debian)
      valor="$(arg_valor "$2" BASE_IMAGE)" || return 1
      case "$valor" in
        *:*) printf '%s' "$valor" ;;
        *) printf -- '—' ;;
      esac ;;
    tinyproxy)
      valor="$(sed -n 's/^FROM alpine:\(.*\)/\1/p' "$3" | head -1)"
      if [ -z "$valor" ]; then
        echo "gen-stack.sh: $3 no tiene un FROM alpine:<versión>" >&2
        return 1
      fi
      printf 'alpine %s' "$valor" ;;
    uv) arg_valor "$2" UV_VERSION ;;
    openvscode) arg_valor "$2" OPENVSCODE_VERSION ;;
    zsh)
      valor="$(arg_valor "$2" STARSHIP_VERSION)" || return 1
      printf 'starship %s' "$valor" ;;
    github)
      valor="$(arg_valor "$2" GH_VERSION)" || return 1
      printf 'gh %s' "$valor" ;;
    bws)
      valor="$(arg_valor "$2" BWS_VERSION)" || return 1
      printf 'bws %s' "$valor" ;;
    rclone)
      valor="$(arg_valor "$2" RCLONE_VERSION)" || return 1
      printf 'rclone %s' "$valor" ;;
    docker | python | claude | codex | git | notion | terminal)
      printf -- '—' ;;
    *)
      echo "gen-stack.sh: id de stack.tsv sin mapeo de versión en version_de: $1" >&2
      return 1 ;;
  esac
}

# Arma la tabla Herramienta/Descripción/Versión desde stack.tsv. Falla si
# alguna fila no puede resolver su versión (no imprime una tabla a medias sin
# avisar).
tabla() {  # tabla <stack.tsv> <Dockerfile> <proxy_dockerfile>
  echo "| Herramienta | Para qué se usa aquí | Versión |"
  echo "|---|---|---|"
  filas="$(mktemp)"
  awk -F ' \\| ' '/^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next } { print $1 "\t" $2 "\t" $3 }' "$1" > "$filas"
  while IFS="$(printf '\t')" read -r id herramienta descripcion; do
    v="$(version_de "$id" "$2" "$3")" || { rm -f "$filas"; return 1; }
    printf '| %s | %s | %s |\n' "$herramienta" "$descripcion" "$v"
  done < "$filas"
  rm -f "$filas"
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

  printf 'ARG UV_RENOMBRADO=1.2.3\nARG GH_VERSION=4.5.6\nARG RCLONE_VERSION=7.8.9\nARG BWS_VERSION=1.0.0\nARG STARSHIP_VERSION=2.0.0\nARG OPENVSCODE_VERSION=3.0.0\n' > "$tmp/Dockerfile-sin-uv"
  versiones "$tmp/Dockerfile-sin-uv" >/dev/null 2>&1
  check "versiones falla si un ARG se renombró (H2b)" 1 "$?"

  printf 'ARG BASE_IMAGE=debian:trixie-slim\nARG UV_VERSION=1.2.3\nARG GH_VERSION=4.5.6\nARG RCLONE_VERSION=7.8.9\nARG BWS_VERSION=1.0.0\nARG STARSHIP_VERSION=2.0.0\nARG OPENVSCODE_VERSION=3.0.0\n' > "$tmp/Dockerfile-tabla"
  printf 'FROM alpine:3.22\n' > "$tmp/proxy-Dockerfile"
  printf 'docker | Docker | Sin versión propia.\ndebian | Debian | Base sin lenguaje.\ntinyproxy | tinyproxy | Proxy de salida.\nuv | uv | Gestiona Python.\n' > "$tmp/stack.tsv"
  esperado='| Herramienta | Para qué se usa aquí | Versión |
|---|---|---|
| Docker | Sin versión propia. | — |
| Debian | Base sin lenguaje. | debian:trixie-slim |
| tinyproxy | Proxy de salida. | alpine 3.22 |
| uv | Gestiona Python. | 1.2.3 |'
  check "tabla con versiones por id, con el componente delante (H6)" "$esperado" \
    "$(tabla "$tmp/stack.tsv" "$tmp/Dockerfile-tabla" "$tmp/proxy-Dockerfile")"

  printf 'algo-sin-mapeo | Algo | Descripción.\n' > "$tmp/stack-malo.tsv"
  tabla "$tmp/stack-malo.tsv" "$tmp/Dockerfile-tabla" "$tmp/proxy-Dockerfile" >/dev/null 2>&1
  check "tabla falla si un id no tiene mapeo de versión" 1 "$?"

  printf 'ARG BASE_IMAGE=debian\nARG UV_VERSION=1.2.3\nARG GH_VERSION=4.5.6\nARG RCLONE_VERSION=7.8.9\nARG BWS_VERSION=1.0.0\nARG STARSHIP_VERSION=2.0.0\nARG OPENVSCODE_VERSION=3.0.0\n' > "$tmp/Dockerfile-sin-tag"
  printf 'debian | Debian | Base sin lenguaje.\n' > "$tmp/stack-debian.tsv"
  esperado='| Herramienta | Para qué se usa aquí | Versión |
|---|---|---|
| Debian | Base sin lenguaje. | — |'
  check "BASE_IMAGE sin etiqueta muestra — en vez de un dato falso (H6)" "$esperado" \
    "$(tabla "$tmp/stack-debian.tsv" "$tmp/Dockerfile-sin-tag" "$tmp/proxy-Dockerfile")"

  exit $fail
fi

# --- Uso normal / --check -----------------------------------------------------
TOML="${DEVKIT_GEN_STACK_TOML:-$HERE/vscode/extensions.toml}"
README="${DEVKIT_GEN_STACK_README:-$(pwd)/README.md}"
DOCKERFILE="${DEVKIT_GEN_STACK_DOCKERFILE:-$HERE/Dockerfile}"
STACK_TSV="${DEVKIT_GEN_STACK_TSV:-$HERE/scripts/stack.tsv}"
PROXY_DOCKERFILE="${DEVKIT_GEN_STACK_PROXY_DOCKERFILE:-$HERE/proxy/Dockerfile}"

if [ "${1:-}" = "--versiones" ]; then
  [ -f "$DOCKERFILE" ] || { echo "gen-stack.sh: no existe $DOCKERFILE" >&2; exit 2; }
  versiones "$DOCKERFILE" || exit 2
  exit 0
fi

if [ "${1:-}" = "--tabla" ]; then
  [ -f "$STACK_TSV" ] || { echo "gen-stack.sh: no existe $STACK_TSV" >&2; exit 2; }
  [ -f "$DOCKERFILE" ] || { echo "gen-stack.sh: no existe $DOCKERFILE" >&2; exit 2; }
  [ -f "$PROXY_DOCKERFILE" ] || { echo "gen-stack.sh: no existe $PROXY_DOCKERFILE" >&2; exit 2; }
  tabla "$STACK_TSV" "$DOCKERFILE" "$PROXY_DOCKERFILE" || exit 2
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

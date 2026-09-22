#!/bin/sh
# ---------------------------------------------------------------------------
#  devkit: instanciar un proyecto desde el Mac. Solo necesita Docker y curl.
#
#    curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/new-project.sh \
#      | sh -s -- <proyecto> [--version 0.1.0 | --ref <rama>] \
#                  [--vscode-port <puerto>] [--oauth-port <puerto>]
#
#  Deja en ~/.devkit/<proyecto>/:
#    template/    copia del template (contexto de build)
#    compose.yaml
#    .env         variables de compose (proyecto, versión, ruta del token,
#                  puertos de host del editor y del retorno OAuth)
#    devkit.env   variables del contenedor: EDÍTALO antes del primer arranque
#  y el comando ~/.devkit/bin/devkit.
#
#  Este script no toca el repo del proyecto: no tiene forma de hacerlo, solo
#  descarga el template. `.devkit/devkit.toml` (versión de template, código de
#  Notion) lo crea `entrypoint.sh` dentro del contenedor, en el primer
#  arranque, una vez que el repo existe.
# ---------------------------------------------------------------------------
set -eu
REPO="${DEVKIT_TEMPLATE_REPO:-byroncz/dotfiles}"
ROOT="${DEVKIT_HOME:-$HOME/.devkit}"
proj="${1:-}"; shift || true
version=""; ref=""; vscode_port=""; oauth_port=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version)      version="$2"; shift 2 ;;
    --ref)          ref="$2"; shift 2 ;;
    --vscode-port)  vscode_port="$2"; shift 2 ;;
    --oauth-port)   oauth_port="$2"; shift 2 ;;
    *) echo "opción desconocida: $1" >&2; exit 1 ;;
  esac
done
[ -n "$proj" ] || { echo "uso: new-project.sh <proyecto> [--version X.Y.Z | --ref rama] [--vscode-port puerto] [--oauth-port puerto]" >&2; exit 1; }
command -v docker >/dev/null || { echo "falta Docker" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "falta el plugin compose de Docker" >&2; exit 1; }
for p in "$vscode_port" "$oauth_port"; do
  [ -z "$p" ] && continue
  case "$p" in
    ''|*[!0-9]*) valido=0 ;;
    *) [ "$p" -ge 1 ] && [ "$p" -le 65535 ] && valido=1 || valido=0 ;;
  esac
  [ "$valido" -eq 1 ] || { echo "puerto inválido: $p (debe ser un entero entre 1 y 65535)" >&2; exit 1; }
done

if [ -n "$ref" ]; then
  tarball="https://github.com/$REPO/archive/refs/heads/$ref.tar.gz"; label="$ref"
else
  [ -n "$version" ] || version="$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/devkit/VERSION")"
  tarball="https://github.com/$REPO/archive/refs/tags/v$version.tar.gz"; label="$version"
fi

dir="$ROOT/$proj"
mkdir -p "$ROOT/bin" "$dir"; chmod 700 "$ROOT"
if [ ! -s "$ROOT/bws-token" ]; then
  touch "$ROOT/bws-token"; chmod 600 "$ROOT/bws-token"
  echo "aviso: $ROOT/bws-token está vacío; el contenedor arrancará sin secretos" >&2
fi

# Valor numérico de <var> en <file>, o falla si el archivo no existe, no
# trae la variable o su valor no es un entero.
port_from_env() {  # port_from_env <file> <var>
  [ -f "$1" ] || return 1
  val="$(sed -n "s/^${2}=//p" "$1" | head -1)"
  case "$val" in
    ''|*[!0-9]*) return 1 ;;
  esac
  echo "$val"
}

# Primer puerto libre de una familia (DEVKIT_VSCODE_PORT o DEVKIT_OAUTH_PORT):
# recorre el .env de los demás proyectos en ~/.devkit, toma el mayor puerto ya
# usado y suma 1. Sin otros proyectos, arranca en $2 (3000 o 54545, los mismos
# defaults que devkit/compose.yaml).
next_port() {  # next_port <var> <base>
  var="$1"; base="$2"; max=0
  for env in "$ROOT"/*/.env; do
    [ -f "$env" ] || continue
    [ "$env" = "$dir/.env" ] && continue
    # Un .env sin la variable (todo proyecto instalado antes de este cambio)
    # sigue arrancando con $base por default en compose.yaml: cuenta como si
    # ya la usara, o el siguiente proyecto choca contra él (DEVKIT-155, H1).
    val="$(port_from_env "$env" "$var")" || val="$base"
    [ "$val" -gt "$max" ] && max="$val"
  done
  [ "$max" -eq 0 ] && echo "$base" || echo $((max + 1))
}
# Reinstalar un proyecto existente conserva su puerto: si se recalculara
# contra los demás .env cada vez, cambiaría según qué otros proyectos estén
# instalados en ese momento (DEVKIT-155, H3).
[ -n "$vscode_port" ] || vscode_port="$(port_from_env "$dir/.env" DEVKIT_VSCODE_PORT)" || vscode_port="$(next_port DEVKIT_VSCODE_PORT 3000)"
[ -n "$oauth_port" ]  || oauth_port="$(port_from_env "$dir/.env" DEVKIT_OAUTH_PORT)"  || oauth_port="$(next_port DEVKIT_OAUTH_PORT 54545)"

echo "devkit: descargando template ($label)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$tarball" | tar -xz -C "$tmp"
src="$(find "$tmp" -maxdepth 2 -type d -name devkit | head -1)"
[ -d "$src" ] || { echo "el tarball no contiene devkit/" >&2; exit 1; }
rm -rf "$dir/template"; cp -R "$src" "$dir/template"
cp "$dir/template/compose.yaml" "$dir/compose.yaml"
cp "$dir/template/host/devkit.sh" "$ROOT/bin/devkit"; chmod +x "$ROOT/bin/devkit"
if [ ! -f "$dir/devkit.env" ]; then
  sed "s/^DEVKIT_PROJECT=.*/DEVKIT_PROJECT=$proj/" "$dir/template/devkit.env.example" > "$dir/devkit.env"
  # Con --ref el template es el propio workspace (modo dev) y el repo se
  # clona en esa rama.
  [ -n "$ref" ] && printf 'DEVKIT_REPO_REF=%s\n' "$ref" >> "$dir/devkit.env"
fi
{
  echo "DEVKIT_PROJECT=$proj"
  echo "DEVKIT_VERSION=$( [ -n "$ref" ] && echo dev || echo "$version" )"
  echo "DEVKIT_BWS_TOKEN_FILE=$ROOT/bws-token"
  echo "DEVKIT_VSCODE_PORT=$vscode_port"
  echo "DEVKIT_OAUTH_PORT=$oauth_port"
} > "$dir/.env"

cat <<EOF

listo. Ahora:
  1. edita $dir/devkit.env
  2. añade ~/.devkit/bin al PATH:  echo 'export PATH="\$HOME/.devkit/bin:\$PATH"' >> ~/.zprofile
  3. levanta:  devkit up $proj
  puertos asignados: editor $vscode_port, retorno OAuth $oauth_port (en $dir/.env)
EOF

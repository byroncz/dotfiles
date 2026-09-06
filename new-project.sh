#!/bin/sh
# ---------------------------------------------------------------------------
#  devkit: instanciar un proyecto desde el Mac. Solo necesita Docker y curl.
#
#    curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/new-project.sh \
#      | sh -s -- <proyecto> [--version 0.1.0 | --ref <rama>]
#
#  Deja en ~/.devkit/<proyecto>/:
#    template/    copia del template (contexto de build)
#    compose.yaml
#    .env         variables de compose (proyecto, versión, ruta del token)
#    devkit.env   variables del contenedor: EDÍTALO antes del primer arranque
#  y el comando ~/.devkit/bin/devkit.
# ---------------------------------------------------------------------------
set -eu
REPO="${DEVKIT_TEMPLATE_REPO:-byroncz/dotfiles}"
ROOT="${DEVKIT_HOME:-$HOME/.devkit}"
proj="${1:-}"; shift || true
version=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --ref)     ref="$2"; shift 2 ;;
    *) echo "opción desconocida: $1" >&2; exit 1 ;;
  esac
done
[ -n "$proj" ] || { echo "uso: new-project.sh <proyecto> [--version X.Y.Z | --ref rama]" >&2; exit 1; }
command -v docker >/dev/null || { echo "falta Docker" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "falta el plugin compose de Docker" >&2; exit 1; }

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
} > "$dir/.env"

cat <<EOF

listo. Ahora:
  1. edita $dir/devkit.env
  2. añade ~/.devkit/bin al PATH:  echo 'export PATH="\$HOME/.devkit/bin:\$PATH"' >> ~/.zprofile
  3. levanta:  devkit up $proj
EOF

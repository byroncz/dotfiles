#!/bin/sh
# devkit: comandos del día a día, desde el Mac. Lo instala new-project.sh en
# ~/.devkit/bin/devkit. Solo necesita Docker.
#
#   devkit up <proyecto>        levantar (construye la imagen si falta) y entrar
#   devkit attach <proyecto>    entrar a la sesión de tmux
#   devkit stop <proyecto>      detener sin perder nada
#   devkit down <proyecto>      destruir el contenedor (el código no committeado se pierde)
#   devkit recreate <proyecto>  recrear los contenedores: relee secretos y devkit.env, y
#                               reconstruye solo las capas de imagen que cambiaron
#   devkit rebuild <proyecto>   reconstruir las imágenes desde cero y recrear
#   devkit update <proyecto>    subir a la versión de template que pide devkit.toml
#   devkit logs <proyecto>      ver el arranque y los bucles
#   devkit net-open <proyecto>  red abierta en esta sesión (solo depuración)
#   devkit ls                   proyectos instanciados
set -eu
ROOT="${DEVKIT_HOME:-$HOME/.devkit}"
REPO="${DEVKIT_TEMPLATE_REPO:-byroncz/dotfiles}"
cmd="${1:-}"; proj="${2:-}"
usage() { sed -n '2,17p' "$0"; exit 1; }
[ -n "$cmd" ] || usage
if [ "$cmd" = "ls" ]; then ls -1 "$ROOT" 2>/dev/null | grep -v -e '^bin$' -e '^bws-token$' -e '^cache$'; exit 0; fi
[ -n "$proj" ] || usage
dir="$ROOT/$proj"; [ -d "$dir" ] || { echo "no existe $dir; usa new-project.sh" >&2; exit 1; }
cd "$dir"
# devkit.toml es plano (una tabla [devkit], valores de una línea): se lee con
# expresiones regulares, no con un parser de TOML.
toml_field() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\\(.*\\)\".*/\\1/p" | head -1; }
toml_list() {
  sed -n "s/^$1[[:space:]]*=[[:space:]]*\\[\\(.*\\)\\].*/\\1/p" \
    | tr ',' '\n' | sed -E 's/^[[:space:]"]*//; s/[[:space:]"]*$//' | tr '\n' ' ' | sed 's/ *$//'
}
# `apt` y `domains` de devkit.toml alimentan el build y el proxy vía compose,
# que los interpola desde este .env: sin esto, editar devkit.toml no hacía
# nada (DEVKIT-6). Solo si el contenedor ya existe: en el primer `up` el
# proyecto aún no está clonado.
sync_toml_env() {
  toml="$(docker exec "devkit-$proj" cat /workspace/devkit.toml 2>/dev/null)" || return 0
  apt="$(printf '%s\n' "$toml" | toml_list apt)"
  domains="$(printf '%s\n' "$toml" | toml_list domains)"
  grep -v -e '^DEVKIT_EXTRA_APT=' -e '^DEVKIT_ALLOW_DOMAINS=' "$dir/.env" > "$dir/.env.tmp" 2>/dev/null || : > "$dir/.env.tmp"
  { cat "$dir/.env.tmp"; printf 'DEVKIT_EXTRA_APT=%s\n' "$apt"; printf 'DEVKIT_ALLOW_DOMAINS=%s\n' "$domains"; } > "$dir/.env"
  rm -f "$dir/.env.tmp"
}
compose() { docker compose --project-directory "$dir" "$@"; }
attach() {
  # El arranque tarda unos segundos (lee secretos, clona). Esperar al marcador
  # evita abrir un shell sin las variables cargadas.
  i=0
  until docker exec "devkit-$proj" test -f /run/devkit/ready 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 120 ] && { echo "el arranque no terminó en 120 s; mira 'devkit logs $proj'" >&2; return 1; }
    [ "$i" -eq 1 ] && printf 'esperando el arranque del contenedor'
    printf '.'; sleep 1
  done
  [ "$i" -gt 0 ] && echo
  docker exec -it "devkit-$proj" tmux new-session -A -s main
}
confirm() { printf 'Se destruye el contenedor actual. Lo no committeado fuera de sandbox.local se pierde. Escribe "si": '; read -r ok; [ "$ok" = "si" ]; }
case "$cmd" in
  up)       compose up -d --build && attach ;;
  attach)   attach ;;
  stop)     compose stop ;;
  down)     confirm && compose down ;;
  recreate) confirm && sync_toml_env && compose up -d --build --force-recreate && attach ;;
  rebuild)  confirm && sync_toml_env && compose build --no-cache && compose up -d --force-recreate && attach ;;
  update)
    toml="$(docker exec "devkit-$proj" cat /workspace/devkit.toml 2>/dev/null)" \
      || { echo "el contenedor no responde; arráncalo con 'devkit up $proj' primero" >&2; exit 1; }
    target="$(printf '%s\n' "$toml" | toml_field template)"
    [ -n "$target" ] || { echo "devkit.toml no declara 'template'" >&2; exit 1; }
    current="$(sed -n 's/^DEVKIT_VERSION=//p' "$dir/.env" | head -1)"
    if [ "$target" = "$current" ]; then echo "ya en $target"; exit 0; fi
    echo "devkit: actualizando template $current -> $target"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://github.com/$REPO/archive/refs/tags/v$target.tar.gz" | tar -xz -C "$tmp"
    src="$(find "$tmp" -maxdepth 2 -type d -name devkit | head -1)"
    [ -d "$src" ] || { echo "el tarball no contiene devkit/" >&2; exit 1; }
    rm -rf "$dir/template"; cp -R "$src" "$dir/template"
    grep -v '^DEVKIT_VERSION=' "$dir/.env" > "$dir/.env.tmp"
    { cat "$dir/.env.tmp"; printf 'DEVKIT_VERSION=%s\n' "$target"; } > "$dir/.env"; rm -f "$dir/.env.tmp"
    sync_toml_env && compose up -d --build --force-recreate && attach
    ;;
  logs)     compose logs -f --tail 100 ;;
  net-open) DEVKIT_NET_OPEN=1 compose up -d --force-recreate proxy && echo "red abierta hasta el próximo 'devkit up'" ;;
  *)        usage ;;
esac

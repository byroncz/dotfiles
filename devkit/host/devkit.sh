#!/bin/sh
# devkit: comandos del día a día, desde el Mac. Lo instala new-project.sh en
# ~/.devkit/bin/devkit. Solo necesita Docker.
#
#   devkit up <proyecto>        levantar (construye la imagen si falta) y entrar
#   devkit attach <proyecto>    entrar a la sesión de tmux
#   devkit stop <proyecto>      detener sin perder nada
#   devkit down <proyecto>      destruir el contenedor (el código no committeado se pierde)
#   devkit recreate <proyecto>  recrear los contenedores: relee secretos y devkit.env, y
#                               reconstruye las capas que cambiaron (en modo dev,
#                               con el devkit/ del workspace)
#   devkit rebuild <proyecto>   reconstruir las imágenes desde cero y recrear
#   devkit update <proyecto>    subir a la versión de template que pide devkit.toml
#   devkit logs <proyecto>      ver el arranque y los bucles
#   devkit net-open <proyecto>  red abierta en esta sesión (solo depuración)
#   devkit ls                   proyectos instanciados
set -eu
ROOT="${DEVKIT_HOME:-$HOME/.devkit}"
REPO="${DEVKIT_TEMPLATE_REPO:-byroncz/dotfiles}"
cmd="${1:-}"; proj="${2:-}"
usage() { sed -n '2,16p' "$0"; exit 1; }  # el bloque de comentario de la cabecera
[ -n "$cmd" ] || usage
if [ "$cmd" = "ls" ]; then ls -1 "$ROOT" 2>/dev/null | grep -v -e '^bin$' -e '^bws-token$' -e '^cache$'; exit 0; fi
[ -n "$proj" ] || usage
dir="$ROOT/$proj"; [ -d "$dir" ] || { echo "no existe $dir; usa new-project.sh" >&2; exit 1; }
cd "$dir"
# devkit.toml es plano (una tabla [devkit], valores de una línea): se lee con
# expresiones regulares, no con un parser de TOML.
toml_field() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
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
# El contexto de build es $dir/template, una copia del template que solo
# new-project.sh y `devkit update` refrescan. En modo dev el template es el
# `devkit/` del workspace, que vive únicamente dentro del contenedor: no hay
# bind mount desde el Mac, así que `docker cp` es la única vía para llevarlo al
# contexto. Sin esto, un cambio en nvim/, zsh/, tmux/, proxy/ o el Dockerfile
# se mergeaba y la imagen seguía construyéndose con la copia vieja (DEVKIT-30).
sync_dev_template() {
  [ "$(sed -n 's/^DEVKIT_VERSION=//p' "$dir/.env" | head -1)" = dev ] || return 0
  if ! docker exec "devkit-$proj" test -d /workspace/devkit 2>/dev/null; then
    echo "devkit: aviso: el contenedor no responde; se construye con la copia de $dir/template" >&2
    return 0
  fi
  rm -rf "$dir/template.tmp"; mkdir -p "$dir/template.tmp"
  if docker cp "devkit-$proj:/workspace/devkit/." "$dir/template.tmp" >/dev/null; then
    rm -rf "$dir/template"; mv "$dir/template.tmp" "$dir/template"
    echo "devkit: modo dev: contexto de build actualizado desde el workspace"
    warn_host_stale
  else
    rm -rf "$dir/template.tmp"
    echo "devkit: aviso: no se pudo copiar devkit/ del workspace; se construye con la copia de $dir/template" >&2
  fi
}
# Lo que new-project.sh instaló en el Mac desde el template (el compose.yaml del
# proyecto y el propio comando devkit) no lo refresca nadie. Reemplazarlo aquí
# no es seguro: el script se sobrescribiría a sí mismo mientras corre. Se avisa
# y se deja la decisión al humano.
warn_host_stale() {
  if [ -f "$dir/template/compose.yaml" ] && ! cmp -s "$dir/template/compose.yaml" "$dir/compose.yaml"; then
    echo "devkit: aviso: $dir/compose.yaml difiere del template; reinstala con new-project.sh --ref <rama>" >&2
  fi
  if [ -f "$ROOT/bin/devkit" ] && [ -f "$dir/template/host/devkit.sh" ] \
     && ! cmp -s "$dir/template/host/devkit.sh" "$ROOT/bin/devkit"; then
    echo "devkit: aviso: el comando devkit difiere del template; reinstala con new-project.sh --ref <rama>" >&2
  fi
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
  up)       sync_dev_template; compose up -d --build && attach ;;
  attach)   attach ;;
  stop)     compose stop ;;
  down)     confirm && compose down ;;
  recreate) confirm && sync_toml_env && sync_dev_template && compose up -d --build --force-recreate && attach ;;
  rebuild)  confirm && sync_toml_env && sync_dev_template && compose build --no-cache && compose up -d --force-recreate && attach ;;
  update)
    toml="$(docker exec "devkit-$proj" cat /workspace/devkit.toml 2>/dev/null)" \
      || { echo "el contenedor no responde; arráncalo con 'devkit up $proj' primero" >&2; exit 1; }
    target="$(printf '%s\n' "$toml" | toml_field template)"
    [ -n "$target" ] || { echo "devkit.toml no declara 'template'" >&2; exit 1; }
    current="$(sed -n 's/^DEVKIT_VERSION=//p' "$dir/.env" | head -1)"
    if [ "$target" = "$current" ]; then
      # En modo dev no hay etiqueta que descargar: el template es el workspace y
      # quien lo lleva a la imagen es `recreate`. Decirlo evita creer que este
      # comando ya aplicó lo mergeado (DEVKIT-30).
      if [ "$target" = dev ]; then
        echo "en modo dev el template es el workspace; usa 'devkit recreate $proj' para llevar devkit/ a la imagen"
      else
        echo "ya en $target"
      fi
      exit 0
    fi
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

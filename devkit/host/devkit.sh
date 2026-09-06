#!/bin/sh
# devkit: comandos del día a día, desde el Mac. Lo instala new-project.sh en
# ~/.devkit/bin/devkit. Solo necesita Docker.
#
#   devkit up <proyecto>        levantar (construye la imagen si falta) y entrar
#   devkit attach <proyecto>    entrar a la sesión de tmux
#   devkit stop <proyecto>      detener sin perder nada
#   devkit down <proyecto>      destruir el contenedor (el código no committeado se pierde)
#   devkit recreate <proyecto>  recrear el contenedor con la misma imagen: relee secretos y devkit.env
#   devkit rebuild <proyecto>   reconstruir la imagen y recrear el contenedor
#   devkit logs <proyecto>      ver el arranque y los bucles
#   devkit net-open <proyecto>  red abierta en esta sesión (solo depuración)
#   devkit ls                   proyectos instanciados
set -eu
ROOT="${DEVKIT_HOME:-$HOME/.devkit}"
cmd="${1:-}"; proj="${2:-}"
usage() { sed -n '2,16p' "$0"; exit 1; }
[ -n "$cmd" ] || usage
if [ "$cmd" = "ls" ]; then ls -1 "$ROOT" 2>/dev/null | grep -v -e '^bin$' -e '^bws-token$' -e '^cache$'; exit 0; fi
[ -n "$proj" ] || usage
dir="$ROOT/$proj"; [ -d "$dir" ] || { echo "no existe $dir; usa new-project.sh" >&2; exit 1; }
cd "$dir"
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
  recreate) confirm && compose up -d --force-recreate && attach ;;
  rebuild)  confirm && compose build --no-cache dev && compose up -d --force-recreate && attach ;;
  logs)     compose logs -f --tail 100 ;;
  net-open) DEVKIT_NET_OPEN=1 compose up -d --force-recreate proxy && echo "red abierta hasta el próximo 'devkit up'" ;;
  *)        usage ;;
esac

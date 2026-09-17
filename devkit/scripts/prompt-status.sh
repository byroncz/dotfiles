#!/usr/bin/env bash
# Segmento dinámico del prompt de starship (DEVKIT-63): un solo módulo
# `custom` en vez de uno por dato, porque cada módulo de starship paga su
# propio `sh -c`. Todo sale de fuentes baratas -variables de entorno, git
# local, /run/devkit y `devkit-run --agentes`, que solo lee watch.log y `ps`
# (ver devkit-run.sh)- para quedar por debajo de los 50 ms por módulo que
# mide `starship timings`. Ningún segmento toca la red.
#
# Forma: "[arrancando ]<proyecto>:<template> [<rama> [±<n>] [↑<m>]] [agentes:<a>] [!<k>]"
# Cada segmento entre paréntesis se omite cuando no aplica o vale 0. El color
# de la rama va embebido como ANSI crudo en la salida: starship.toml deja
# `style = ""` en `[custom.devkit]` para no envolverlo con el suyo.
set -u

VERDE=$'\033[32m'
ROJO=$'\033[31m'
AMARILLO=$'\033[33m'
CIAN=$'\033[36m'
AZUL=$'\033[34m'
ROJO_NEGRITA=$'\033[1;31m'
RESET=$'\033[0m'

# linea [<ws>]: toda la lógica en una función para poder probarla sin tocar
# stdout directamente (--test la llama con un workspace de prueba).
linea() {
  local run_dir scripts_dir devkit_run_bin ready_file watch_log alarmas_vistas
  run_dir="${DEVKIT_RUN_DIR:-/run/devkit}"
  scripts_dir="${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}"
  devkit_run_bin="${DEVKIT_RUN_BIN:-$scripts_dir/devkit-run.sh}"
  ready_file="${DEVKIT_READY_FILE:-$run_dir/ready}"
  watch_log="${DEVKIT_WATCH_LOG:-$run_dir/watch.log}"
  alarmas_vistas="${DEVKIT_ALARMAS_VISTAS:-$run_dir/alarmas-vistas}"

  local ws=${1:-${DEVKIT_WS:-/workspace}} out rama color corta cambios adelante agentes vistas alarmas
  out=""
  [ -e "$ready_file" ] || out+="${ROJO_NEGRITA}arrancando${RESET} "
  out+="${DEVKIT_PROJECT:-?}:${DEVKIT_VERSION:-?} "

  rama=$(git -C "$ws" symbolic-ref --quiet --short HEAD 2>/dev/null)
  if [ -n "$rama" ]; then
    color="" corta=$rama
    case "$rama" in
      main) color=$CIAN ;;
      feat/*) color=$VERDE
        corta=$(printf '%s' "$rama" | sed -E 's#^(feat/[A-Z][A-Z0-9]*-[0-9]+)-.*#\1#') ;;
      fix/*) color=$ROJO
        corta=$(printf '%s' "$rama" | sed -E 's#^(fix/[A-Z][A-Z0-9]*-[0-9]+)-.*#\1#') ;;
      chore/*) color=$AMARILLO
        corta=$(printf '%s' "$rama" | sed -E 's#^(chore/[A-Z][A-Z0-9]*-[0-9]+)-.*#\1#') ;;
    esac
    if [ -n "$color" ]; then
      out+="${color}${corta}${RESET} "
    else
      out+="${corta} "
    fi

    cambios=$(git -C "$ws" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "${cambios:-0}" -gt 0 ] 2>/dev/null && out+="${AMARILLO}±${cambios}${RESET} "

    if [ "$rama" != main ]; then
      adelante=$(git -C "$ws" rev-list --count main..HEAD 2>/dev/null)
      [ -n "${adelante:-}" ] && [ "$adelante" -gt 0 ] 2>/dev/null && out+="${CIAN}↑${adelante}${RESET} "
    fi
  fi

  agentes=$("$devkit_run_bin" --agentes 2>/dev/null)
  [ -n "${agentes:-}" ] && [ "$agentes" -gt 0 ] 2>/dev/null && out+="${AZUL}agentes:${agentes}${RESET} "

  vistas=0
  if [ -f "$alarmas_vistas" ]; then
    read -r vistas <"$alarmas_vistas" 2>/dev/null
    case "$vistas" in '' | *[!0-9]*) vistas=0 ;; esac
  fi
  alarmas=0
  [ -f "$watch_log" ] && alarmas=$(tail -n "+$((vistas + 1))" "$watch_log" 2>/dev/null | grep -c 'ALARMA:')
  [ "${alarmas:-0}" -gt 0 ] 2>/dev/null && out+="${ROJO_NEGRITA}!${alarmas}${RESET} "

  printf '%s' "${out% }"
}

# --- Autoprueba --------------------------------------------------------------
run_tests() {
  local fail=0 tmp
  check() {
    local name=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
      printf 'ok   %-58s %s\n' "$name" "$got"
    else
      printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
      fail=1
    fi
  }
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  git init -q "$tmp/ws"
  git -C "$tmp/ws" config user.email t@t.com
  git -C "$tmp/ws" config user.name t
  git -C "$tmp/ws" commit -q --allow-empty -m base
  git -C "$tmp/ws" branch -M main

  local doble_agentes doble_agentes_n
  doble_agentes_n="$tmp/agentes-n"
  echo 0 >"$doble_agentes_n"
  doble_agentes="$tmp/devkit-run-doble.sh"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$doble_agentes_n" >"$doble_agentes"
  chmod +x "$doble_agentes"

  export DEVKIT_RUN_DIR="$tmp/run" DEVKIT_RUN_BIN="$doble_agentes" \
    DEVKIT_READY_FILE="$tmp/run/ready" DEVKIT_WATCH_LOG="$tmp/run/watch.log" \
    DEVKIT_ALARMAS_VISTAS="$tmp/run/alarmas-vistas" DEVKIT_PROJECT=devkit DEVKIT_VERSION=dev
  mkdir -p "$tmp/run"

  check "arrancando mientras no existe ready" "${ROJO_NEGRITA}arrancando${RESET} devkit:dev ${CIAN}main${RESET}" \
    "$(linea "$tmp/ws")"
  : >"$tmp/run/ready"
  check "sin arrancando con ready presente" "devkit:dev ${CIAN}main${RESET}" "$(linea "$tmp/ws")"

  git -C "$tmp/ws" switch -q -c feat/DEVKIT-57-skills-del-flujo
  check "rama feat: corta y en verde" "devkit:dev ${VERDE}feat/DEVKIT-57${RESET}" "$(linea "$tmp/ws")"
  git -C "$tmp/ws" switch -q -c fix/DEVKIT-30-recreate 2>/dev/null || git -C "$tmp/ws" checkout -q main
  git -C "$tmp/ws" switch -q -c fix/DEVKIT-30-recreate-desde-workspace
  check "rama fix: corta y en rojo" "devkit:dev ${ROJO}fix/DEVKIT-30${RESET}" "$(linea "$tmp/ws")"
  git -C "$tmp/ws" switch -q -c chore/DEVKIT-10-renombrar-skills
  check "rama chore: corta y en amarillo" "devkit:dev ${AMARILLO}chore/DEVKIT-10${RESET}" "$(linea "$tmp/ws")"
  git -C "$tmp/ws" switch -q -c sandbox/algo-suelto
  check "rama sin prefijo conocido: se muestra tal cual" "devkit:dev sandbox/algo-suelto" "$(linea "$tmp/ws")"

  git -C "$tmp/ws" switch -q -c feat/DEVKIT-63-prompt-una-linea
  echo cambio >"$tmp/ws/archivo.txt"
  check "±n cuenta los cambios sin commit" "devkit:dev ${VERDE}feat/DEVKIT-63${RESET} ${AMARILLO}±1${RESET}" \
    "$(linea "$tmp/ws")"
  git -C "$tmp/ws" add archivo.txt
  git -C "$tmp/ws" commit -q -m uno
  check "↑m cuenta los commits sobre main" \
    "devkit:dev ${VERDE}feat/DEVKIT-63${RESET} ${CIAN}↑1${RESET}" "$(linea "$tmp/ws")"
  git -C "$tmp/ws" checkout -q main
  check "en main no hay ↑m aunque haya ramas adelante" "devkit:dev ${CIAN}main${RESET}" "$(linea "$tmp/ws")"
  # Rama nueva y limpia para agentes/alarmas: sin ±n ni ↑m de por medio.
  git -C "$tmp/ws" switch -q -c feat/DEVKIT-63-agentes

  echo 3 >"$doble_agentes_n"
  check "agentes:a con devkit-run --agentes > 0" \
    "devkit:dev ${VERDE}feat/DEVKIT-63${RESET} ${AZUL}agentes:3${RESET}" "$(linea "$tmp/ws")"
  echo 0 >"$doble_agentes_n"

  printf '%s ALARMA: uno\n%s ALARMA: dos\n' "$(date -u +%FT%TZ)" "$(date -u +%FT%TZ)" >"$tmp/run/watch.log"
  check "!k cuenta las ALARMA sin marcador de vistas" \
    "devkit:dev ${VERDE}feat/DEVKIT-63${RESET} ${ROJO_NEGRITA}!2${RESET}" "$(linea "$tmp/ws")"
  echo 1 >"$tmp/run/alarmas-vistas"
  check "!k solo cuenta las ALARMA posteriores al marcador" \
    "devkit:dev ${VERDE}feat/DEVKIT-63${RESET} ${ROJO_NEGRITA}!1${RESET}" "$(linea "$tmp/ws")"
  echo 2 >"$tmp/run/alarmas-vistas"
  check "!k se omite cuando ya se vieron todas" \
    "devkit:dev ${VERDE}feat/DEVKIT-63${RESET}" "$(linea "$tmp/ws")"

  return $fail
}

case "${1:-}" in
  --test) run_tests; exit $? ;;
  *) linea ;;
esac

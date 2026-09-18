#!/usr/bin/env bash
# Hook Stop (DEVKIT-91): barrera de entrega para `task-start` y `task-fix`.
# Reemplaza, para esas dos skills, a la barrera de "pregunta abierta" de
# `devkit-run` (que sigue viva como red para las demás, ver `pregunta_abierta`
# en devkit-run.sh): en vez de detectar después de terminado que el resultado
# quedó en una pregunta, esto impide terminar la sesión mientras el trabajo
# quede sin entregar -commit sin subir, rama sin push, o card todavía `En
# progreso` sin PR-.
#
# Solo actúa cuando `DEVKIT_SKILL` (que exporta `devkit-run` al `claude -p`,
# DEVKIT-91) vale `task-start` o `task-fix`: las demás skills (pr-review,
# task-document, epic-plan) no dejan una card a medio entregar de la misma
# forma y siguen solo bajo la red de `devkit-run`.
#
# Máximo dos bloqueos por sesión, contados en /run/devkit/stop-<pid del
# proceso `claude` que corre esta sesión>: sin este tope, una sesión que no
# logra resolver el motivo (por ejemplo, sin acceso a git o a Notion) se
# quedaría reintentando para siempre. Al tercer intento deja salir, para que
# la barrera de `devkit-run` (o el humano) se haga cargo.
#
# Uso normal: recibe por stdin el JSON del hook Stop. Si bloquea, imprime
# {"decision":"block","reason":"..."} y sale 0.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
SCRIPTS_DIR="${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}"

cat >/dev/null  # consume el JSON del hook; ningún campo de entrada hace falta

case "${DEVKIT_SKILL:-}" in
  task-start|task-fix) ;;
  *) exit 0 ;;
esac

# DEVKIT_STOP_ID, si viene, pisa el pid real: cada llamada de la autoprueba
# corre en su propio subshell de pipeline, con un $PPID distinto, así que sin
# esta puerta no hay forma de probar el conteo entre llamadas sucesivas.
contador="$RUN_DIR/stop-${DEVKIT_STOP_ID:-$PPID}"
bloqueos=$(cat "$contador" 2>/dev/null || echo 0)
case "$bloqueos" in ''|*[!0-9]*) bloqueos=0 ;; esac
if [ "$bloqueos" -ge 2 ]; then
  exit 0
fi

rama=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
clave=$(printf '%s' "$rama" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
[ -n "$clave" ] || exit 0

motivo=""
if [ -n "$(git -C "$WS" status --porcelain 2>/dev/null)" ]; then
  motivo="hay cambios sin commitear"
else
  remoto_sha=$(git -C "$WS" ls-remote origin "refs/heads/$rama" 2>/dev/null | cut -f1)
  if [ -z "$remoto_sha" ]; then
    motivo="la rama $rama no está subida a origin"
  elif [ "$remoto_sha" != "$(git -C "$WS" rev-parse HEAD 2>/dev/null)" ]; then
    motivo="hay commits sin subir a origin"
  else
    card=$("$NOTION" card "$clave" 2>/dev/null) || exit 0
    estado=$(jq -r '.estado // ""' <<<"$card")
    pr=$(jq -r '.pr // ""' <<<"$card")
    if [ "$estado" = "En progreso" ] && [ -z "$pr" ]; then
      motivo="la card $clave sigue En progreso sin PR"
    fi
  fi
fi
[ -n "$motivo" ] || exit 0

echo $((bloqueos + 1)) > "$contador" 2>/dev/null
if [ "${DEVKIT_SKILL:-}" = task-fix ]; then
  instruccion="Comitea lo pendiente y haz \"git push origin $rama\""
else
  instruccion="Ejecuta \"$SCRIPTS_DIR/task-submit.sh\" --mensaje \"<tipo>($clave): <resumen>\""
fi
razon="La sesión termina sin entregar $clave: $motivo. $instruccion para entregarlo; si no puedes terminarlo, bloquéalo con \"$SCRIPTS_DIR/task-block.sh\" $clave \"<motivo>\"."
jq -nc --arg r "$razon" '{decision: "block", reason: $r}'
exit 0

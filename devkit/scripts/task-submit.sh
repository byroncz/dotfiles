#!/usr/bin/env bash
# Entrega para revisión el trabajo de una card en progreso (DEVKIT-91): de los
# 9 pasos de la skill task-submit, ocho eran bash que un agente ejecutaba uno
# por uno (verificar, comitear, abrir el PR, activar auto-merge, tocar
# Notion, comentar, avisar al bucle). Este script los hace todos en segundos;
# a la skill le queda solo redactar el cuerpo del PR, que es lo único que
# necesita criterio.
#
# Uso:
#   task-submit.sh [Clave] --mensaje "<tipo>(<Clave>): <resumen>"
#
# Sin Clave, la deduce de la rama actual (`feat/DEVKIT-3-...` -> `DEVKIT-3`).
# `--mensaje` es obligatorio: el mensaje del commit de lo pendiente, en
# Conventional Commits con la Clave como ámbito (lo redacta la skill, no este
# script).
#
# Pasos, en orden, deteniéndose con salida 1 y el error en el primero que
# falle:
#   1. Localiza la card por Notion y verifica que está `En progreso`.
#   2. Verificación local: `ruff check .` y `ruff format --check .` si hay
#      Python (pyproject.toml en la raíz); `uv run pytest` si hay `tests/` o
#      `pytest` mencionado en pyproject.toml; `bash -n` sobre cada `.sh`
#      tocado en esta rama (diff contra `main` más los cambios sin commit).
#   3. Comitea lo pendiente con `--mensaje` y hace push.
#   4. Lee `.devkit/pr-body.md` (las secciones `## Qué cambia`, `## Cómo
#      probarlo` y `## Cambios requeridos`, que escribió la skill), le agrega
#      `## Card` con la URL de la card en Notion y la línea "Implementado con
#      ..." (DEVKIT-58, de `DEVKIT_MODEL`/`DEVKIT_EFFORT`, las que exporta
#      `devkit-run` al `claude -p` que lanzó esta sesión). Si el diff contra
#      `origin/main` supera 300 líneas, agrega el aviso "Diff grande: N
#      líneas" (DEVKIT-94): no bloquea, solo lo anota para quien revisa. Crea
#      el PR si no existe uno para la rama, o actualiza su cuerpo si ya existe.
#   5. Activa auto-merge (`gh pr merge --auto --squash`). Si GitHub lo
#      rechaza porque el repo no lo permite, comenta el motivo en la card y
#      sigue: no es un fallo de este script.
#   6. `PR` y `Estado=Revisión automática` en la card.
#   7. Comenta en la card las dos primeras líneas de "Qué cambia".
#   8. `touch /run/devkit/poke`, para que `watch.sh` no espere el resto del
#      intervalo antes de lanzar `pr-review`.
#   9. Borra `.devkit/pr-body.md` (vive fuera de git, en `.gitignore`).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
RUFF="${DEVKIT_RUFF_BIN:-ruff}"
UV="${DEVKIT_UV_BIN:-uv}"
PR_BODY_FILE="$WS/.devkit/pr-body.md"

err() { printf 'task-submit: %s\n' "$*" >&2; }

mensaje="" clave_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mensaje)
      if [ $# -lt 2 ]; then
        echo 'uso: task-submit.sh [Clave] --mensaje "<tipo>(<Clave>): <resumen>"' >&2
        exit 64
      fi
      mensaje="$2"; shift 2 ;;
    *)
      clave_arg="$1"; shift ;;
  esac
done
if [ -z "$mensaje" ]; then
  echo 'uso: task-submit.sh [Clave] --mensaje "<tipo>(<Clave>): <resumen>"' >&2
  exit 64
fi

rama=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$rama" ]; then
  err "no pude leer la rama actual en $WS"
  exit 1
fi
clave="${clave_arg:-$(printf '%s' "$rama" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)}"
if [ -z "$clave" ]; then
  err "no pude deducir la Clave de la rama $rama; pásala como primer argumento"
  exit 1
fi
if [ "$rama" = main ] || ! printf '%s' "$rama" | grep -qE "^(feat|fix|chore)/${clave}-"; then
  err "la rama $rama no es una rama de card válida para $clave (se espera feat/, fix/ o chore/ con /$clave- en el nombre)"
  exit 1
fi

# --- 1. La card, En progreso ------------------------------------------------
card=$("$NOTION" card "$clave") || { err "no pude leer $clave en Notion"; exit 1; }
id=$(jq -r .id <<<"$card")
card_url=$(jq -r .url <<<"$card")
titulo=$(jq -r '.titulo // ""' <<<"$card")
estado=$(jq -r '.estado // ""' <<<"$card")
if [ "$estado" != "En progreso" ]; then
  err "$clave no está En progreso (está ${estado:-vacío}); no se puede entregar"
  exit 1
fi

# --- 2. Verificación local ---------------------------------------------------
if [ -f "$WS/pyproject.toml" ]; then
  if ! salida=$(cd "$WS" && "$RUFF" check . 2>&1); then
    err "ruff check . falló:"; printf '%s\n' "$salida" >&2
    exit 1
  fi
  if ! salida=$(cd "$WS" && "$RUFF" format --check . 2>&1); then
    err "ruff format --check . falló:"; printf '%s\n' "$salida" >&2
    exit 1
  fi
fi
if [ -d "$WS/tests" ] || { [ -f "$WS/pyproject.toml" ] && grep -qi pytest "$WS/pyproject.toml"; }; then
  if ! salida=$(cd "$WS" && "$UV" run pytest 2>&1); then
    err "uv run pytest falló:"; printf '%s\n' "$salida" >&2
    exit 1
  fi
fi
# .sh tocados en esta rama: el diff contra main (lo ya comiteado) más lo que
# el árbol de trabajo todavía no comiteó, unido y sin duplicados. Sin la
# segunda mitad, un script recién editado y sin commitear todavía pasaría sin
# revisar.
sh_tocados() {
  local base
  base=$(git -C "$WS" merge-base main HEAD 2>/dev/null)
  {
    [ -z "$base" ] || git -C "$WS" diff --name-only --diff-filter=ACMR "$base"...HEAD -- '*.sh' 2>/dev/null
    git -C "$WS" status --porcelain --untracked-files=all -- '*.sh' 2>/dev/null | sed -E 's/^...//'
  } | sort -u
}
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$WS/$f" ] || continue
  if ! salida=$(bash -n "$WS/$f" 2>&1); then
    err "bash -n falló en $f:"; printf '%s\n' "$salida" >&2
    exit 1
  fi
done < <(sh_tocados)

# El cuerpo del PR, antes de comitear y subir nada: si falta o le faltan
# secciones, mejor fallar aquí que dejar la rama subida sin PR (H7).
if [ ! -f "$PR_BODY_FILE" ]; then
  err "falta $PR_BODY_FILE; escribe primero las secciones Qué cambia, Cómo probarlo y Cambios requeridos"
  exit 1
fi
for encabezado in "## Qué cambia" "## Cómo probarlo" "## Cambios requeridos"; do
  grep -qF "$encabezado" "$PR_BODY_FILE" || {
    err "$PR_BODY_FILE no tiene la sección \"$encabezado\""
    exit 1
  }
done

# --- 3. Commit y push --------------------------------------------------------
if [ -n "$(git -C "$WS" status --porcelain 2>/dev/null)" ]; then
  # `git add -A -- . ':!.devkit/pr-body.md'` (la forma obvia de excluirlo)
  # falla con git 2.47: negar un pathspec que además está en .gitignore hace
  # que `git add` reporte el archivo como ignorado y salga con 1, aunque la
  # exclusión sí se aplique. Se evita ese caso agregando todo y desagregando
  # el archivo después: funciona igual si el .gitignore de un proyecto viejo
  # todavía no tiene la regla (queda sin comitear, sin más).
  git -C "$WS" add -A -- . || { err "git add falló"; exit 1; }
  git -C "$WS" reset -q -- .devkit/pr-body.md 2>/dev/null
  git -C "$WS" commit -q -m "$mensaje" || { err "git commit falló"; exit 1; }
fi
push_err=$(mktemp)
if ! git -C "$WS" push -q origin "HEAD:$rama" 2>"$push_err"; then
  if grep -qi 'workflow.*scope' "$push_err"; then
    err "push rechazado por falta del scope workflow; card bloqueada, no reintentes"
    cat "$push_err" >&2
    rm -f "$push_err"
    "$HERE/task-block.sh" "$clave" "Qué intenté: push de la rama; GitHub lo rechazó porque el token del bot no tiene el scope workflow. Qué necesito: añade el scope workflow al token del bot, mueve la card $clave a En progreso y relanza con dk task-start $clave" \
      || err "$clave: push sin scope workflow, pero no pude bloquear la card"
    exit 1
  fi
  err "git push falló:"; cat "$push_err" >&2; rm -f "$push_err"
  exit 1
fi
rm -f "$push_err"

# --- 4. Cuerpo del PR y creación/actualización -------------------------------
# Diff grande (DEVKIT-94): un aviso, no un bloqueo. `--numstat` da líneas
# añadidas/borradas por archivo; un binario marca "-" en vez de un número,
# se cuenta como 0 en vez de romper la suma con `awk`.
diff_lineas=$(git -C "$WS" diff --numstat origin/main...HEAD 2>/dev/null \
  | awk '{a=$1; d=$2; if (a !~ /^[0-9]+$/) a=0; if (d !~ /^[0-9]+$/) d=0; suma+=a+d} END{print suma+0}')

cuerpo="$(cat "$PR_BODY_FILE")

## Card
$card_url

Implementado con ${DEVKIT_MODEL:-sin registrar}, esfuerzo ${DEVKIT_EFFORT:-sin registrar}"
if [ "$diff_lineas" -gt 300 ] 2>/dev/null; then
  # Después de "## Card", nunca antes: `task-document.sh` (`seccion`) corta
  # cada sección del cuerpo hasta el siguiente "## ", y este aviso no es
  # parte de "Cambios requeridos" (H2 del informe sobre el PR #68).
  cuerpo="$cuerpo

Diff grande: $diff_lineas líneas"
fi

pr_existente=$(cd "$WS" && "$GH" pr view "$rama" --json url,number 2>/dev/null)
if [ -n "$pr_existente" ]; then
  pr_url=$(jq -r .url <<<"$pr_existente")
  pr_num=$(jq -r .number <<<"$pr_existente")
  if ! printf '%s' "$cuerpo" | (cd "$WS" && "$GH" pr edit "$pr_num" --body-file -) >/dev/null; then
    err "gh pr edit falló sobre $pr_url"
    exit 1
  fi
else
  if ! pr_url=$(printf '%s' "$cuerpo" | (cd "$WS" && "$GH" pr create --base main --title "$clave $titulo" --head "$rama" --body-file -)); then
    err "gh pr create falló"
    exit 1
  fi
  pr_url=$(printf '%s' "$pr_url" | tail -1)
fi

# --- 5. Auto-merge ------------------------------------------------------------
if ! (cd "$WS" && "$GH" pr merge --auto --squash "$pr_url") >/dev/null 2>&1; then
  "$NOTION" comentar "$id" "task-submit: no pude activar auto-merge en el PR; falta habilitar \"Allow auto-merge\" en el repositorio." \
    || err "no pude comentar en la card que falta Allow auto-merge"
fi

# --- 6. Card: PR y Estado -----------------------------------------------------
"$NOTION" set "$id" "PR=$pr_url" "Estado=Revisión automática" \
  || { err "no pude actualizar PR/Estado de $clave en Notion"; exit 1; }

# --- 7. Comentario -------------------------------------------------------------
que_cambia=$(awk '
  $0 == "## Qué cambia" { activo=1; next }
  /^## / { activo=0 }
  activo && NF { print }
' "$PR_BODY_FILE" | head -2)
"$NOTION" comentar "$id" "$que_cambia" || err "no pude comentar en $clave"

# --- 8. Poke --------------------------------------------------------------------
touch "$RUN_DIR/poke" 2>/dev/null || true

# --- 9. Limpieza ------------------------------------------------------------------
rm -f "$PR_BODY_FILE"

echo "task-submit: $clave entregada, PR $pr_url, Revisión automática"

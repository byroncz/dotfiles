#!/usr/bin/env bash
# Pasos 8 a 10 de `pr-review` en bash (DEVKIT-93): publicar el informe que
# escribió el agente, mover la card según el veredicto, pedir el review al
# humano cuando corresponde y borrar el worktree. Lo único que necesita
# criterio -leer el diff, juzgar la rúbrica, redactar el informe- ya quedó
# hecho antes de llamar a este script; de acá para abajo es mecánico.
#
# Uso:
#   review-publish.sh [--conservar] <número de PR> <archivo del informe>
#
# <archivo> es el informe que escribió la skill en `.devkit/review-<N>.md`,
# con el formato de la rúbrica: el marcador `<!-- devkit-review sha=<head>
# verdict=<OK|CAMBIOS> -->` en la primera línea, la tabla de Criterios de
# aceptación, la lectura adversarial, el Veredicto y, si hay hallazgos, el
# bloque `<!-- devkit-findings -->`.
#
# Borra <archivo> al salir, publicación exitosa o no (DEVKIT-99): un residuo
# de ese informe en el workspace deja el árbol sucio y bloquea la siguiente
# card (`task-begin.sh` rechaza con árbol sucio antes de mirar Notion). Con
# `--conservar` lo deja, para depurar un informe que falló al publicarse.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
WORKTREE_DIR="${DEVKIT_REVIEW_WORKTREE_DIR:-/tmp}"

err() { printf 'review-publish: %s\n' "$*" >&2; }

conservar=0
if [ "${1:-}" = --conservar ]; then
  conservar=1
  shift
fi
numero="${1:-}"
archivo="${2:-}"
if [ -z "$numero" ] || [ -z "$archivo" ]; then
  echo "uso: review-publish.sh [--conservar] <número de PR> <archivo del informe>" >&2
  exit 64
fi
[ -f "$archivo" ] || { err "no existe $archivo"; exit 1; }

limpiar() {
  [ "$conservar" = 1 ] && return
  rm -f "$archivo"
}
trap limpiar EXIT

marcador=$(grep -m1 -oE '<!-- devkit-review sha=[0-9a-f]+ verdict=(OK|CAMBIOS) -->' "$archivo")
if [ -z "$marcador" ]; then
  err "$archivo no empieza con el marcador <!-- devkit-review sha=... verdict=... -->"
  exit 1
fi
verdict=$(printf '%s' "$marcador" | sed -nE 's/.*verdict=([A-Z]+).*/\1/p')

# --- Publica la review --------------------------------------------------------
# Idempotente: si un paso de más abajo (gh pr view, Notion) falla y la skill
# manda repetir este script (paso 4 de `pr-review`), no publica el mismo
# informe dos veces sobre el mismo head (H4 de la revisión del PR 67). El
# reintento vuelve a necesitar `archivo` en disco: el trap de arriba ya lo
# borró al salir, así que la skill lo reescribe (o corre con `--conservar`
# para depurar) antes de repetir (DEVKIT-99).
# Compara el cuerpo completo, no solo el marcador: dos informes sobre el
# mismo head y el mismo veredicto pueden tener marcadores idénticos y no ser
# el mismo informe -por ejemplo, uno posterior a una respuesta de task-fix
# sin push (H7 de la revisión del PR 67)-, y ese sí hay que publicarlo.
ultimo_cuerpo=$("$GH" pr view "$numero" --json reviews \
  --jq '[.reviews[] | select(.body | test("<!-- devkit-review "))] | sort_by(.submittedAt) | last | .body' 2>/dev/null)
if [ -n "$ultimo_cuerpo" ] && [ "$ultimo_cuerpo" = "$(cat "$archivo")" ]; then
  echo "review-publish: PR $numero, informe ya publicado para ese head, no lo repito"
elif ! "$GH" pr review --comment --body-file "$archivo" "$numero" >/dev/null; then
  err "gh pr review --comment falló sobre el PR $numero"
  exit 1
fi

# --- Borra el worktree, si existe (una card de código lo crea; una de
# documentación no) --------------------------------------------------------
git -C "$WS" worktree remove --force "$WORKTREE_DIR/devkit-review-$numero" 2>/dev/null || true

if [ "$verdict" != OK ]; then
  # CAMBIOS: la card se queda en Revisión automática, task-fix lee los
  # hallazgos directamente del PR. Nada más que hacer.
  echo "review-publish: PR $numero, veredicto CAMBIOS, informe publicado"
  exit 0
fi

# --- OK: mueve la card, pide review al humano y comenta ---------------------
pr_json=$("$GH" pr view "$numero" --json title,body 2>/dev/null) || { err "gh pr view $numero no respondió"; exit 1; }
titulo=$(jq -r '.title // ""' <<<"$pr_json")
cuerpo_pr=$(jq -r '.body // ""' <<<"$pr_json")
clave=$(printf '%s' "$titulo" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | head -1)
if [ -z "$clave" ]; then
  err "no pude deducir la Clave del título \"$titulo\"; no muevo ninguna card"
  exit 1
fi
card=$("$NOTION" card "$clave" 2>/dev/null) || { err "no pude leer $clave en Notion"; exit 1; }
card_id=$(jq -r '.id // ""' <<<"$card")
"$NOTION" set "$card_id" "Estado=Lista para merge" || { err "no pude pasar $clave a Lista para merge"; exit 1; }

# --- Revisor humano, de .devkit/devkit.toml o del dueño del repo ------------
reviewer=$(sed -n 's/^reviewer[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/.devkit/devkit.toml" 2>/dev/null | head -1)
bot_login=$("$GH" api user --jq .login 2>/dev/null)
sin_revisor=""
if [ -z "$reviewer" ]; then
  owner_type=$("$GH" api "repos/{owner}/{repo}" --jq .owner.type 2>/dev/null)
  if [ "$owner_type" = User ]; then
    reviewer=$("$GH" api "repos/{owner}/{repo}" --jq .owner.login 2>/dev/null)
  fi
fi
if [ -z "$reviewer" ] || [ "$reviewer" = "$bot_login" ]; then
  sin_revisor="Sin revisor declarado (\`reviewer\` en .devkit/devkit.toml): el humano debe agregarlo."
  reviewer=""
fi
if [ -n "$reviewer" ]; then
  "$GH" pr edit "$numero" --add-reviewer "$reviewer" >/dev/null 2>&1 \
    || err "no pude pedir review a $reviewer en el PR $numero"
fi

# --- Comentario para el humano, mecánico: reusa lo que ya escribió el autor
# (sección "## Qué cambia" del cuerpo del PR, DEVKIT-91) y lo que ya juzgó el
# informe (Criterios "No verificado" y hallazgos baja del bloque
# devkit-findings), sin redactar nada nuevo de criterio.
que_cambia=$(awk '
  $0 == "## Qué cambia" { activo = 1; next }
  /^## / { activo = 0 }
  activo && NF { print }
' <<<"$cuerpo_pr" | head -2)
[ -n "$que_cambia" ] || que_cambia="(el PR no trae la sección \"## Qué cambia\")"

no_verificado=$(awk '
  /^### Criterios de aceptación/ { activo = 1; next }
  /^### / { activo = 0 }
  activo && /No verificado/ { print }
' "$archivo" | sed -E 's/^\|\s*//; s/\s*\|.*$//' | paste -sd', ' -)

hallazgos_baja=$(sed -n '/<!-- devkit-findings -->/,/<!-- \/devkit-findings -->/p' "$archivo" \
  | grep -E '^[A-Za-z0-9]+ \| baja \|' | head -1)

{
  echo "Listo para tu aprobación."
  echo "Qué hace: $que_cambia"
  if [ -n "$no_verificado" ]; then
    echo "Qué se verificó: todos los criterios, salvo (No verificado): $no_verificado."
  else
    echo "Qué se verificó: todos los criterios de aceptación, ver la review."
  fi
  if [ -n "$hallazgos_baja" ]; then
    id_baja=$(cut -d'|' -f1 <<<"$hallazgos_baja" | tr -d ' ')
    ruta_baja=$(cut -d'|' -f3 <<<"$hallazgos_baja" | tr -d ' ')
    echo "Qué mirar primero: $id_baja en $ruta_baja."
    echo "Recomendación: aprobar. $id_baja puede ir a una card aparte."
  else
    echo "Qué mirar primero: nada en particular."
    echo "Recomendación: aprobar."
  fi
  [ -z "$sin_revisor" ] || echo "$sin_revisor"
} | "$GH" pr comment --body-file - "$numero" >/dev/null \
  || err "no pude comentar en el PR $numero para el humano"

echo "review-publish: PR $numero, veredicto OK, $clave en Lista para merge"

#!/usr/bin/env bash
# Guarda mecánica del paso 8 de `task-fix` (DEVKIT-102), mismo patrón que
# `review-publish.sh`: antes de comentar en el PR, compara cada id de la
# respuesta contra los ids `H<n>` del bloque `devkit-findings` del informe
# que ese `devkit-fix` declara atender (su propio `review=`). Si ese sha es
# de verdad un informe CAMBIOS y la respuesta trae un id que no está entre
# sus hallazgos -un `C<n>` inventado, por ejemplo, colado porque `claude -p`
# se comió una fila ajena de una tubería (DEVKIT-102)-, aborta antes de
# publicar: así una lectura equivocada del modelo no puede cerrar un informe
# con hallazgos reales sin atender. Cuando `review=` no coincide con ningún
# informe CAMBIOS -la respuesta a un comentario humano, que no tiene
# `devkit-findings` que cumplir (paso 3, tercera viñeta de
# task-fix/SKILL.md)- no hay nada que comparar y se publica igual.
#
# Uso:
#   fix-publish.sh [--conservar] <número de PR> <archivo de la respuesta>
#
# <archivo> es lo que escribió la skill: el marcador `<!-- devkit-fix
# sha=<head nuevo> review=<sha del marcador atendido><marca manual> -->` en
# la primera línea y el bloque `<!-- devkit-fixes --> ... <!-- /devkit-fixes
# -->` con una línea por hallazgo (paso 8 de task-fix/SKILL.md).
#
# Borra <archivo> al salir, publicación exitosa o no (mismo criterio que
# review-publish.sh, DEVKIT-99): un residuo deja el árbol sucio y bloquea la
# siguiente card (`task-begin.sh` rechaza con árbol sucio antes de mirar
# Notion). Con `--conservar` lo deja, para depurar una publicación que falló.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
WATCH_LOG="${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}"

err() { printf 'fix-publish: %s\n' "$*" >&2; }

conservar=0
if [ "${1:-}" = --conservar ]; then
  conservar=1
  shift
fi
numero="${1:-}"
archivo="${2:-}"
if [ -z "$numero" ] || [ -z "$archivo" ]; then
  echo "uso: fix-publish.sh [--conservar] <número de PR> <archivo de la respuesta>" >&2
  exit 64
fi
[ -f "$archivo" ] || { err "no existe $archivo"; exit 1; }

limpiar() {
  [ "$conservar" = 1 ] && return
  rm -f "$archivo"
}
trap limpiar EXIT

marcador=$(grep -m1 -oE '<!-- devkit-fix sha=[0-9a-f]+ review=[0-9a-f]+( manual=1)? -->' "$archivo")
if [ -z "$marcador" ]; then
  err "$archivo no empieza con el marcador <!-- devkit-fix sha=... review=... -->"
  exit 1
fi
review_sha=$(printf '%s' "$marcador" | sed -nE 's/.*review=([0-9a-f]+).*/\1/p')

alarma() {  # alarma <motivo>
  printf '%s ALARMA: fix-publish PR #%s aborta: %s\n' "$(date +%FT%T%:z)" "$numero" "$1" \
    >> "$WATCH_LOG" 2>/dev/null
}

# Comenta el motivo en la Notion card de la Clave del título del PR. No hace
# fallar el script si algo de esto no responde: el motivo ya quedó en
# stderr y en watch.log, que es lo que no depende de Notion.
comentar_card() {  # comentar_card <texto>
  local titulo clave card card_id
  titulo=$("$GH" pr view "$numero" --json title --jq '.title // ""' 2>/dev/null)
  clave=$(printf '%s' "$titulo" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  [ -n "$clave" ] || return 0
  card=$("$NOTION" card "$clave" 2>/dev/null) || return 0
  card_id=$(jq -r '.id // ""' <<<"$card")
  [ -n "$card_id" ] || return 0
  "$NOTION" comentar "$card_id" "$1" >/dev/null 2>&1
}

abortar() {  # abortar <motivo>
  err "$1"
  alarma "$1"
  comentar_card "fix-publish: $1"
  exit 1
}

# --- Ids válidos: devkit-findings del informe CAMBIOS que este devkit-fix
# declara atender, si existe uno con ese sha exacto -----------------------
pr_json=$("$GH" pr view "$numero" --json reviews 2>/dev/null) || { err "gh pr view $numero no respondió"; exit 1; }
informe=$(jq -r --arg sha "$review_sha" '
  [.reviews[] | select(.body | test("<!-- devkit-review sha=" + $sha + " verdict=CAMBIOS -->"))]
  | sort_by(.submittedAt) | last | .body // ""
' <<<"$pr_json")

if [ -n "$informe" ]; then
  ids_validos=$(printf '%s\n' "$informe" | sed -n '/<!-- devkit-findings -->/,/<!-- \/devkit-findings -->/p' \
    | grep -oE '^H[0-9]+')
  if [ -z "$ids_validos" ]; then
    abortar "el informe sobre $review_sha no trae ids H<n> en su bloque devkit-findings"
  fi
  ids_respuesta=$(sed -n '/<!-- devkit-fixes -->/,/<!-- \/devkit-fixes -->/p' "$archivo" | grep -oE '^[A-Za-z0-9]+')
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    grep -qxF "$id" <<<"$ids_validos" && continue
    abortar "la respuesta trae \"$id\", que no está entre los hallazgos ($(tr '\n' ' ' <<<"$ids_validos" | sed -E 's/ +$//')) del informe sobre $review_sha"
  done <<<"$ids_respuesta"
fi

# --- Publica, idempotente por cuerpo completo (mismo criterio que
# review-publish.sh: dos respuestas con el mismo marcador pueden no ser la
# misma si una es posterior a otra ronda) -----------------------------------
ultimo_cuerpo=$("$GH" pr view "$numero" --json comments \
  --jq '[.comments[] | select(.body | test("<!-- devkit-fix "))] | sort_by(.createdAt) | last | .body' 2>/dev/null)
if [ -n "$ultimo_cuerpo" ] && [ "$ultimo_cuerpo" = "$(cat "$archivo")" ]; then
  echo "fix-publish: PR $numero, respuesta ya publicada para ese sha, no la repito"
elif ! "$GH" pr comment --body-file "$archivo" "$numero" >/dev/null; then
  err "gh pr comment falló sobre el PR $numero"
  exit 1
fi

echo "fix-publish: PR $numero, respuesta publicada (review=$review_sha)"

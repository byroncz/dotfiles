#!/usr/bin/env bash
# Pasos 1 a 5 de `pr-review` en bash (DEVKIT-93): leer el PR, encontrar el
# marcador, comprobar el devkit-fix, delimitar el diff y, para PRs de código,
# crear el worktree y correr ahí las comprobaciones mecánicas de la rúbrica
# (bash -n, ruff, pytest, devkit-run.sh --test, watch-test.sh, git grep de
# nombres viejos). Un PR de seis líneas de documentación pagó 33 turnos en
# Opus solo en preparar y comprobar lo que este script hace en segundos y sin
# modelo (DEVKIT-74, Épica DEVKIT-86 Contexto 4).
#
# Uso:
#   review-prep.sh <número de PR>
#
# Sale con 0 si hay algo que revisar: imprime en stdout el bloque Markdown
# que `devkit-run.sh` agrega al prompt del agente bajo `## Material` (card,
# cuerpo del PR, diff delimitado, hallazgos anteriores y respuesta
# devkit-fix, y el resultado de cada comprobación mecánica). Sale con 3 si no
# hay nada que revisar -PR no abierto, sin card, o ya revisado en ese head
# sin respuesta del corrector, los mismos tres criterios del paso 1 a 3 de la
# skill- con el motivo en stdout, una sola línea. Cualquier otra salida
# distinta de cero es un fallo real (gh o Notion no respondieron): el motivo
# va en stderr, y quien llama no debe tratarlo como "nada que revisar".
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
RUFF="${DEVKIT_RUFF_BIN:-ruff}"
UV="${DEVKIT_UV_BIN:-uv}"
# /tmp por defecto, igual que el paso 4 actual de la skill; sustituible para
# que la autoprueba no deje worktrees de verdad.
WORKTREE_DIR="${DEVKIT_REVIEW_WORKTREE_DIR:-/tmp}"

# Este script corre antes de que `run_claude` arme el entorno limpio del
# `claude -p` hijo (DEVKIT-93, H2 de la revisión del PR 67): hereda tal cual
# lo que `watch.sh:495` exportó para su propio `--sync`. Sin anularlas, las
# comprobaciones mecánicas de más abajo (devkit-run.sh --test, watch-test.sh)
# ven una ronda o un modelo forzado que no es el suyo y reportan `Falla` que
# no existen.
unset DEVKIT_RONDA DEVKIT_MODELO_FORZADO DEVKIT_LOCK_HELD DEVKIT_LANZADOR DEVKIT_ORIGEN

err() { printf 'review-prep: %s\n' "$*" >&2; }

numero="${1:-}"
if [ -z "$numero" ]; then
  echo "uso: review-prep.sh <número de PR>" >&2
  exit 64
fi

# --- Paso 1: el PR ----------------------------------------------------------
pr_json=$("$GH" pr view "$numero" --json number,title,state,url,headRefOid,headRefName,body,reviews,comments 2>/dev/null) \
  || { err "gh pr view $numero no respondió"; exit 1; }
estado_pr=$(jq -r '.state // ""' <<<"$pr_json")
if [ "$estado_pr" != "OPEN" ]; then
  echo "PR no abierto"
  exit 3
fi
titulo=$(jq -r '.title // ""' <<<"$pr_json")
cuerpo_pr=$(jq -r '.body // ""' <<<"$pr_json")
head=$(jq -r '.headRefOid // ""' <<<"$pr_json")

# --- Paso 2: la card ---------------------------------------------------------
codigo_proyecto=$(sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/.devkit/devkit.toml" 2>/dev/null | head -1)
clave=$(printf '%s' "$titulo" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | head -1)
codigo=${clave%-*}
numero_card=${clave##*-}
if [ -z "$clave" ] || [ -z "$codigo_proyecto" ] || [ "$codigo" != "$codigo_proyecto" ] || [ "$numero_card" = 0 ]; then
  echo "sin card que revisar"
  exit 3
fi
card=$("$NOTION" card "$clave" 2>/dev/null) || { err "no pude leer $clave en Notion"; exit 1; }
estado_card=$(jq -r '.estado // ""' <<<"$card")
card_id=$(jq -r '.id // ""' <<<"$card")
if [ "$estado_card" != "Revisión automática" ]; then
  echo "$estado_card"
  exit 3
fi

# --- Paso 3: el último marcador ---------------------------------------------
marcador=$(jq -r '
  [.reviews[] | select(.body | test("<!-- devkit-review "))] | sort_by(.submittedAt) | last
  | if . == null then "" else "\(.submittedAt)\t\(.body)" end
' <<<"$pr_json")
marcador_sha="" marcador_verdict="" marcador_at="" ciclo_previo=""
if [ -n "$marcador" ]; then
  marcador_at=${marcador%%$'\t'*}
  marcador_body=${marcador#*$'\t'}
  linea_marcador=$(printf '%s' "$marcador_body" | grep -oE '<!-- devkit-review sha=[0-9a-f]+ verdict=(OK|CAMBIOS) -->' | head -1)
  marcador_sha=$(printf '%s' "$linea_marcador" | sed -nE 's/.*sha=([0-9a-f]+).*/\1/p')
  marcador_verdict=$(printf '%s' "$linea_marcador" | sed -nE 's/.*verdict=([A-Z]+).*/\1/p')
fi

# Cualquier marcador previo es un ciclo siguiente (diff incremental), no solo
# el caso de un head igual al del marcador: un head nuevo (código empujado
# tras el informe) también se lee desde el marcador, no desde el principio.
respuesta_fix=""
if [ -n "$marcador_sha" ]; then
  respuesta_fix=$(jq -r --arg sha "$marcador_sha" --arg at "$marcador_at" '
    [.comments[] | select(.body | test("<!-- devkit-fix sha=[0-9a-f]+ review=" + $sha + "( manual=1)? -->"))
                  | select(.createdAt > $at)] | sort_by(.createdAt) | last
    | if . == null then "" else .body end
  ' <<<"$pr_json")
  if [ "$marcador_sha" = "$head" ] && [ -z "$respuesta_fix" ]; then
    echo "ya revisado en $marcador_sha"
    exit 3
  fi
  ciclo_previo=1
fi

# --- Paso 5: delimitar el diff -----------------------------------------------
if ! git -C "$WS" fetch -q origin "pull/$numero/head" 2>/dev/null; then
  err "no pude hacer git fetch del PR $numero"
  exit 1
fi
head_sha=$(git -C "$WS" rev-parse FETCH_HEAD 2>/dev/null)
if [ -z "$head_sha" ]; then
  err "FETCH_HEAD vacío tras el fetch del PR $numero"
  exit 1
fi
archivos=$(git -C "$WS" diff --name-only "origin/main...$head_sha" 2>/dev/null)
diff_completo=$(git -C "$WS" diff "origin/main...$head_sha" 2>/dev/null)
if [ -n "$ciclo_previo" ]; then
  diff_mostrado=$(git -C "$WS" diff "$marcador_sha" "$head_sha" 2>/dev/null)
else
  diff_mostrado="$diff_completo"
fi

# --- Clasificación: docs si el diff solo toca .md, .toml de documentación o
# SKILL.md; código en cualquier otro caso. Un archivo .toml "de
# documentación" es uno fuera del control de comportamiento del devkit: vive
# bajo un directorio docs/documentacion o su nombre lo dice.
es_docs() {
  case "$1" in
    *.md) return 0 ;;
    */SKILL.md) return 0 ;;
    *.toml)
      case "$1" in
        */docs/*|*/documentacion/*|*doc.toml|*documentacion*.toml) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
clasificacion=docs
if [ -z "$archivos" ]; then
  clasificacion=docs
else
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    es_docs "$f" || { clasificacion=codigo; break; }
  done <<<"$archivos"
fi

# --- Paso 4: worktree, solo para código --------------------------------------
worktree=""
resultado_mecanico=""
if [ "$clasificacion" = codigo ]; then
  worktree="$WORKTREE_DIR/devkit-review-$numero"
  git -C "$WS" worktree remove --force "$worktree" 2>/dev/null
  rm -rf "$worktree" 2>/dev/null
  git -C "$WS" worktree prune 2>/dev/null
  if ! git -C "$WS" worktree add --detach "$worktree" "$head_sha" >/dev/null 2>&1; then
    err "no pude crear el worktree en $worktree"
    exit 1
  fi

  check_ok=0
  check_fail=0
  filas=""
  agregar_fila() {  # agregar_fila <comprobación> <Verificado|Falla> [salida]
    local nombre=$1 resultado=$2 salida=${3:-}
    if [ "$resultado" = Verificado ]; then check_ok=$((check_ok + 1)); else check_fail=$((check_fail + 1)); fi
    filas="$filas
- **$nombre**: $resultado${salida:+
\`\`\`
$salida
\`\`\`}"
  }

  # Para una autoprueba (devkit-run.sh --test, watch-test.sh) la salida
  # completa en `Falla` puede ser cientos de líneas (H6 de la revisión del PR
  # 67): se recorta a las líneas `FAIL` y las últimas diez, que es lo que
  # hace falta para juzgar el hallazgo.
  resumen_autoprueba() {
    { grep -E '^FAIL ' <<<"$1"; tail -n10 <<<"$1"; } | awk '!v[$0]++'
  }

  # bash -n de cada .sh tocado.
  while IFS= read -r f; do
    case "$f" in
      *.sh)
        [ -f "$worktree/$f" ] || continue
        if salida=$(bash -n "$worktree/$f" 2>&1); then
          agregar_fila "bash -n $f" Verificado
        else
          agregar_fila "bash -n $f" Falla "$salida"
        fi
        ;;
    esac
  done <<<"$archivos"

  # ruff y pytest, solo si el worktree trae Python.
  if [ -f "$worktree/pyproject.toml" ]; then
    if salida=$(cd "$worktree" && "$RUFF" check . 2>&1); then
      agregar_fila "ruff check ." Verificado
    else
      agregar_fila "ruff check ." Falla "$salida"
    fi
    if salida=$(cd "$worktree" && "$RUFF" format --check . 2>&1); then
      agregar_fila "ruff format --check ." Verificado
    else
      agregar_fila "ruff format --check ." Falla "$salida"
    fi
    if [ -d "$worktree/tests" ] || grep -qi pytest "$worktree/pyproject.toml" 2>/dev/null; then
      if salida=$(cd "$worktree" && "$UV" run pytest 2>&1); then
        agregar_fila "uv run pytest" Verificado
      else
        agregar_fila "uv run pytest" Falla "$salida"
      fi
    fi
  fi

  # devkit-run.sh --test y watch-test.sh, solo si el diff los toca.
  if grep -qxF "devkit/scripts/devkit-run.sh" <<<"$archivos"; then
    if salida=$(bash "$worktree/devkit/scripts/devkit-run.sh" --test 2>&1); then
      agregar_fila "devkit-run.sh --test" Verificado
    else
      agregar_fila "devkit-run.sh --test" Falla "$(resumen_autoprueba "$salida")"
    fi
  fi
  if grep -qE '^devkit/scripts/watch(-test)?\.sh$' <<<"$archivos"; then
    if salida=$(bash "$worktree/devkit/scripts/watch-test.sh" 2>&1); then
      agregar_fila "watch-test.sh" Verificado
    else
      agregar_fila "watch-test.sh" Falla "$(resumen_autoprueba "$salida")"
    fi
  fi

  # git grep de cada identificador que el diff renombra o borra: nombres de
  # función bash (`nombre() {`) o variables en mayúsculas (`NOMBRE=`) que
  # aparecen en una línea borrada y no en ninguna línea agregada. Si sobrevive
  # una referencia al nombre viejo en el árbol nuevo, es un hallazgo (H1 de
  # pr-review típico de un rename a medias).
  #
  # `definiciones_de` solo cuenta una definición real: la línea entera es
  # `nombre() {` (con `function` opcional) o una sola asignación `NOMBRE=`
  # (con `readonly`/`export`/`local` opcional) sin otra asignación después.
  # Descarta así una lista de variables delante de un comando, ej.
  # `DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \` (H3 de la revisión del PR
  # 67): esa línea no define nada, solo arma el entorno de una invocación.
  definiciones_de() {
    awk '
      {
        linea = $0
        if (match(linea, /^[[:space:]]*(function[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{?[[:space:]]*$/)) {
          resto = linea
          sub(/^[[:space:]]*(function[[:space:]]+)?/, "", resto)
          sub(/\(\).*/, "", resto)
          print resto
          next
        }
        resto = linea
        sub(/^[[:space:]]*(readonly[[:space:]]+|export[[:space:]]+|local[[:space:]]+)?/, "", resto)
        if (match(resto, /^[A-Z_][A-Z0-9_]*=/)) {
          nombre = substr(resto, 1, RLENGTH - 1)
          despues = substr(resto, RLENGTH + 1)
          if (despues !~ /[[:space:]][A-Za-z_][A-Za-z0-9_]*=/) print nombre
        }
      }
    '
  }
  borrados=$(printf '%s\n' "$diff_completo" | grep -E '^-[^-]' | sed -E 's/^-//' | definiciones_de | sort -u)
  agregados=$(printf '%s\n' "$diff_completo" | grep -E '^\+[^+]' | sed -E 's/^\+//' | definiciones_de | sort -u)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    grep -qxF "$id" <<<"$agregados" && continue
    # Sigue definido en el árbol nuevo, aunque no en una línea agregada de
    # este diff (ej. se borró una reasignación duplicada y la definición de
    # verdad vive sin tocar en otra parte del archivo): no es un rename a
    # medias, nada que reportar.
    if git -C "$worktree" grep -qE "^[[:space:]]*(function[[:space:]]+)?${id}\\(\\)|^[[:space:]]*(readonly[[:space:]]+|export[[:space:]]+|local[[:space:]]+)?${id}=" -- . 2>/dev/null; then
      continue
    fi
    if sobrevive=$(git -C "$worktree" grep -n -F -w "$id" -- . 2>/dev/null); then
      agregar_fila "git grep $id (renombrado o borrado)" Falla "$sobrevive"
    else
      agregar_fila "git grep $id (renombrado o borrado)" Verificado
    fi
  done <<<"$borrados"

  resultado_mecanico="Comprobaciones mecánicas ($check_ok Verificado, $check_fail Falla):$filas"
  [ -n "$filas" ] || resultado_mecanico="Comprobaciones mecánicas: nada que ejecutar (sin .sh, sin Python, sin devkit-run.sh/watch.sh tocados, sin identificadores borrados)."
else
  resultado_mecanico="PR de documentación: sin worktree, sin comprobaciones mecánicas."
fi

# --- Card: Objetivo y Criterios, sin Notas ni Comentarios --------------------
card_md=$("$NOTION" contenido "$card_id" 2>/dev/null | awk '
  /^## / { activo = ($0 == "## Objetivo" || $0 ~ /^## Criterios/) }
  activo { print }
')

# --- El bloque final ----------------------------------------------------------
{
  echo "## Card"
  echo "$card_md"
  echo
  echo "## Cuerpo del PR"
  echo "$cuerpo_pr"
  echo
  if [ -n "$ciclo_previo" ]; then
    echo "## Diff (desde el marcador $marcador_sha)"
  else
    echo "## Diff (completo)"
  fi
  echo '```diff'
  echo "$diff_mostrado"
  echo '```'
  if [ -n "$ciclo_previo" ]; then
    echo
    echo "## Hallazgos anteriores y respuesta devkit-fix"
    hallazgos_previos=$(printf '%s\n' "$marcador_body" | sed -n '/<!-- devkit-findings -->/,/<!-- \/devkit-findings -->/p')
    if [ -n "$hallazgos_previos" ]; then
      echo "$hallazgos_previos"
    else
      echo "(el informe anterior no traía hallazgos)"
    fi
    if [ -n "$respuesta_fix" ]; then
      echo "$respuesta_fix"
    else
      echo "(sin respuesta devkit-fix todavía sobre ese informe)"
    fi
  fi
  echo
  echo "## Comprobaciones mecánicas"
  echo "$resultado_mecanico"
  if [ -n "$worktree" ]; then
    echo
    echo "Worktree: $worktree (bórralo con \`git worktree remove --force $worktree\` solo si no vas a usar review-publish.sh)."
  fi
}
exit 0

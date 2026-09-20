#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  devkit: arma devkit/vscode/cheatsheet/cheatsheet.html, la chuleta de
#  comandos que la extensión local devkit.cheatsheet (DEVKIT-96) muestra al
#  arrancar el editor. Fuente: devkit/scripts/comandos.txt (DEVKIT-88), que
#  trae tres columnas por fila: `comando | ejemplo | descripción`.
#
#  La chuleta no muestra el manifiesto completo, solo los comandos que un
#  ingeniero nuevo necesita el primer día, agrupados en cuatro bloques fijos
#  (BLOQUES, abajo). Un comando que no calce exacto con la primera columna de
#  comandos.txt corta la generación (mismo criterio que SKILLS_ORDEN en
#  gen-readme.sh): un typo no debe desaparecer la tarjeta en silencio.
#
#    gen-cheatsheet.sh          escribe cheatsheet.html
#    gen-cheatsheet.sh --check  sale con 1 si el HTML commiteado quedó viejo
#    gen-cheatsheet.sh --test   autoprueba, con fixtures propios
# ---------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # devkit/

COMANDOS="${DEVKIT_GEN_CHEATSHEET_COMANDOS:-$HERE/scripts/comandos.txt}"
SALIDA="${DEVKIT_GEN_CHEATSHEET_SALIDA:-$HERE/vscode/cheatsheet/cheatsheet.html}"

BLOQUES_ORDEN="contenedor agentes cards Python"
declare -A BLOQUES
BLOQUES[contenedor]="devkit code <proyecto>
devkit shell <proyecto>
devkit recreate <proyecto>
devkit rebuild <proyecto>
devkit awake <proyecto>"
BLOQUES[agentes]="devkit-run --estado --seguir
devkit-run --tablero --seguir
devkit-run --seguir <skill> <Clave>
devkit-run pr-review <N>
devkit-run task-fix <N>"
BLOQUES[cards]="task-close.sh <Clave> [PR]
task-block.sh <Clave> <motivo>
devkit-net-denied"
BLOQUES[Python]="uv add <paquete>
uv sync
uv run <comando>"

# Entidades HTML mínimas, sin dependencias (los comandos traen `<...>`). Un
# "&" sin escapar en el reemplazo de "${var/pat/repl}" es el texto que
# calzó, como en sed: hay que escaparlo a mano o "&lt;" sale "<lt;".
escapar() {
  local s=$1
  s=${s//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  printf '%s' "$s"
}

cargar_filas() {  # cargar_filas <comandos.txt>: llena FILAS[comando]="ejemplo<TAB>descripcion"
  declare -gA FILAS=()
  local linea c e d
  while IFS='|' read -r c e d; do
    c="$(printf '%s' "$c" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    e="$(printf '%s' "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    d="$(printf '%s' "$d" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$c" ] || continue
    FILAS["$c"]="$e"$'\t'"$d"
  done < <(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/' "$1")
}

# Corta con error si un comando de BLOQUES no existe en FILAS: mismo criterio
# que la validación de SKILLS_ORDEN en gen-readme.sh.
validar_bloques() {
  local bloque comando faltan=0
  for bloque in $BLOQUES_ORDEN; do
    while IFS= read -r comando; do
      [ -n "$comando" ] || continue
      if [ -z "${FILAS[$comando]+x}" ]; then
        echo "gen-cheatsheet.sh: [$bloque] \"$comando\" no está en $COMANDOS" >&2
        faltan=1
      fi
    done <<< "${BLOQUES[$bloque]}"
  done
  [ "$faltan" -eq 0 ]
}

armar() {
  cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>devkit: comandos</title>
<style>
  body {
    font-family: var(--vscode-font-family, sans-serif);
    font-size: var(--vscode-font-size, 13px);
    color: var(--vscode-foreground);
    background-color: var(--vscode-editor-background);
    padding: 2rem 3rem 4rem;
    max-width: 900px;
    margin: 0 auto;
  }
  h1 { font-size: 1.4rem; margin-bottom: 0.2rem; }
  p.intro { color: var(--vscode-descriptionForeground); margin-top: 0; }
  h2 {
    font-size: 0.85rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--vscode-descriptionForeground);
    border-bottom: 1px solid var(--vscode-panel-border);
    padding-bottom: 0.3rem;
    margin-top: 2rem;
  }
  .tarjeta {
    border: 1px solid var(--vscode-panel-border);
    border-radius: 4px;
    padding: 0.6rem 0.9rem;
    margin: 0.6rem 0;
  }
  .comando {
    font-family: var(--vscode-editor-font-family, monospace);
    font-weight: 600;
  }
  .ejemplo {
    font-family: var(--vscode-editor-font-family, monospace);
    color: var(--vscode-textLink-foreground);
    background: var(--vscode-textCodeBlock-background);
    padding: 0.15rem 0.4rem;
    border-radius: 3px;
    display: inline-block;
    margin: 0.35rem 0;
  }
  .descripcion { margin: 0.2rem 0 0; }
</style>
</head>
<body>
<h1>devkit: comandos</h1>
<p class="intro">Generada de <code>devkit/scripts/comandos.txt</code> por <code>gen-cheatsheet.sh</code>. Ctrl+Shift+P → <code>devkit: comandos</code> la vuelve a abrir.</p>
HTML_HEAD

  local bloque comando fila ejemplo descripcion
  for bloque in $BLOQUES_ORDEN; do
    echo "<h2>$(escapar "$bloque")</h2>"
    while IFS= read -r comando; do
      [ -n "$comando" ] || continue
      fila="${FILAS[$comando]}"
      ejemplo="${fila%%$'\t'*}"
      descripcion="${fila#*$'\t'}"
      printf '<div class="tarjeta">\n  <div class="comando">%s</div>\n  <div class="ejemplo">$ %s</div>\n  <p class="descripcion">%s</p>\n</div>\n' \
        "$(escapar "$comando")" "$(escapar "$ejemplo")" "$(escapar "$descripcion")"
    done <<< "${BLOQUES[$bloque]}"
  done

  cat <<'HTML_TAIL'
</body>
</html>
HTML_TAIL
}

# --- Autoprueba --------------------------------------------------------------
if [ "${1:-}" = "--test" ]; then
  fail=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  check() {  # check <nombre> <esperado> <obtenido>
    if [ "$2" = "$3" ]; then
      printf 'ok   %-55s\n' "$1"
    else
      printf 'FAIL %-55s esperado "%s", obtenido "%s"\n' "$1" "$2" "$3"
      fail=1
    fi
  }

  printf '# comentario\n\n## Grupo\nfoo <x> | foo 1 | hace foo\nbar | bar | hace bar\n' > "$tmp/comandos.txt"
  cargar_filas "$tmp/comandos.txt"
  check "parsea comando con placeholder" "foo 1	hace foo" "${FILAS['foo <x>']:-}"
  check "parsea comando simple" "bar	hace bar" "${FILAS['bar']:-}"

  BLOQUES_ORDEN="uno"
  declare -A BLOQUES=( [uno]="foo <x>
bar" )
  validar_bloques
  check "BLOQUES completo valida sin avisos" 0 "$?"

  declare -A BLOQUES=( [uno]="foo <x>
no-existe" )
  validar_bloques >/dev/null 2>&1
  check "comando de BLOQUES ausente en comandos.txt corta (código != 0)" 1 "$?"

  BLOQUES_ORDEN="uno"
  declare -A BLOQUES=( [uno]="foo <x>
bar" )
  out="$(armar)"
  case "$out" in
    *'<h2>uno</h2>'*'<div class="comando">foo &lt;x&gt;</div>'*'$ foo 1'*'hace foo'*) \
      check "arma HTML con bloque, comando escapado y ejemplo" si si ;;
    *) check "arma HTML con bloque, comando escapado y ejemplo" si no ;;
  esac

  # De aquí en más, contra el comandos.txt real: BLOQUES no se puede anular
  # por variable de entorno (a diferencia de SKILLS_ORDEN en gen-readme.sh),
  # así que --check necesita el manifiesto real para validar sin cortar.
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" bash "$HERE/scripts/gen-cheatsheet.sh" >/dev/null 2>&1
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el HTML al día sale 0" 0 "$?"

  echo "viejo" > "$tmp/cheatsheet.html"
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el HTML viejo sale 1" 1 "$?"

  bash "$HERE/scripts/gen-cheatsheet.sh" --chek >/dev/null 2>&1
  check "argumento desconocido se rechaza" 2 "$?"

  exit $fail
fi

case "${1:-}" in
  '' | --check) ;;
  *) echo "uso: gen-cheatsheet.sh [--check]" >&2; exit 2 ;;
esac

[ -f "$COMANDOS" ] || { echo "gen-cheatsheet.sh: no existe $COMANDOS" >&2; exit 2; }
cargar_filas "$COMANDOS"
validar_bloques || exit 2

if [ "${1:-}" = "--check" ]; then
  [ -f "$SALIDA" ] || { echo "gen-cheatsheet.sh: no existe $SALIDA" >&2; exit 2; }
  nuevo="$(mktemp)"; trap 'rm -f "$nuevo"' EXIT
  armar > "$nuevo"
  if diff -q "$nuevo" "$SALIDA" >/dev/null 2>&1; then
    exit 0
  fi
  echo "gen-cheatsheet.sh: $SALIDA quedó vieja; corre gen-cheatsheet.sh y commitea el resultado" >&2
  exit 1
fi

nuevo="$(mktemp)"; trap 'rm -f "$nuevo"' EXIT
armar > "$nuevo"
chmod 644 "$nuevo"
mv "$nuevo" "$SALIDA"

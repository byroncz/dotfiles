#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  devkit: arma devkit/vscode/cheatsheet/cheatsheet.{html,svg}, la chuleta de
#  comandos. El HTML lo abre a pedido la extensión local devkit.cheatsheet
#  (DEVKIT-96, comando "devkit: comandos"); el SVG lo pone el Dockerfile como
#  marca de agua del editor vacío (DEVKIT-143), en lugar del logo de
#  openvscode-server. Fuente: devkit/scripts/comandos.txt (DEVKIT-88), que
#  trae tres columnas por fila: `comando | ejemplo | descripción`.
#
#  La chuleta no muestra el manifiesto completo, solo los comandos que un
#  ingeniero nuevo necesita el primer día, agrupados en cuatro bloques fijos
#  (BLOQUES, abajo). Un comando que no calce exacto con la primera columna de
#  comandos.txt corta la generación (mismo criterio que SKILLS_ORDEN en
#  gen-readme.sh): un typo no debe desaparecer la tarjeta en silencio.
#
#    gen-cheatsheet.sh          escribe cheatsheet.html y cheatsheet.svg
#    gen-cheatsheet.sh --check  sale con 1 si alguno de los dos quedó viejo
#    gen-cheatsheet.sh --test   autoprueba, con fixtures propios
# ---------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # devkit/

COMANDOS="${DEVKIT_GEN_CHEATSHEET_COMANDOS:-$HERE/scripts/comandos.txt}"
SALIDA="${DEVKIT_GEN_CHEATSHEET_SALIDA:-$HERE/vscode/cheatsheet/cheatsheet.html}"
SALIDA_SVG="${DEVKIT_GEN_CHEATSHEET_SALIDA_SVG:-$HERE/vscode/cheatsheet/cheatsheet.svg}"

BLOQUES_ORDEN="contenedor agentes cards Python"
declare -A BLOQUES
BLOQUES[contenedor]="devkit code <proyecto>
devkit shell <proyecto>
devkit recreate <proyecto>
devkit rebuild <proyecto>
devkit awake <proyecto>"
BLOQUES[agentes]="devkit-run --estado [--seguir]
devkit-run --tablero [--seguir]
devkit-run <skill> <Clave>
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

# Convierte pares de comillas invertidas de markdown ("`texto`") en
# <code>texto</code>, para que comandos.txt siga sirviendo tal cual al
# README (que sí entiende markdown) y a la chuleta (que no). Se llama
# después de escapar(), así que "texto" ya trae entidades HTML. Si al
# terminar quedó una comilla sin cerrar, imprime igual lo que armó hasta ahí
# pero devuelve 1: el resto del documento no debe convertirse en código en
# silencio por un typo (mismo criterio que cargar_filas).
codigo_en_linea() {
  local s=$1 out="" tramo abierto=0
  while [[ $s == *'`'* ]]; do
    tramo="${s%%\`*}"
    s="${s#*\`}"
    if [ "$abierto" -eq 0 ]; then
      out+="$tramo<code>"
      abierto=1
    else
      out+="$tramo</code>"
      abierto=0
    fi
  done
  out+="$s"
  printf '%s' "$out"
  return "$abierto"
}

# Recorta <texto> a <max> caracteres para que quepa en una línea de SVG (no
# hay wrapping automático como en el HTML); agrega "…" cuando corta. Cuenta
# caracteres, no bytes, para no partir una tilde a la mitad (requiere locale
# UTF-8, ya fijado por el Dockerfile con LANG=C.UTF-8).
recortar() {
  local s=$1 max=$2
  if [ "${#s}" -le "$max" ]; then
    printf '%s' "$s"
  else
    printf '%s…' "${s:0:$((max-1))}"
  fi
}

cargar_filas() {  # cargar_filas <comandos.txt>: llena FILAS[comando]="ejemplo<TAB>descripcion"
  declare -gA FILAS=()
  local c e d resto
  while IFS='|' read -r c e d resto; do
    c="$(printf '%s' "$c" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    e="$(printf '%s' "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    d="$(printf '%s' "$d" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    # Una fila que no trae exactamente tres campos no vacíos (por ejemplo,
    # una fila vieja de dos columnas: "comando | descripción") no debe
    # desaparecer contenido en silencio -gen-readme.sh sí acepta esa forma,
    # pero acá "ejemplo" y "descripción" quedarían pisados uno por el otro-.
    if [ -z "$c" ] || [ -z "$e" ] || [ -z "$d" ] || [ -n "$resto" ]; then
      echo "gen-cheatsheet.sh: fila inválida en $1 (se esperan tres campos \`comando | ejemplo | descripción\`): $c|$e|$d|$resto" >&2
      return 2
    fi
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
      descripcion_html="$(codigo_en_linea "$(escapar "$descripcion")")" || {
        echo "gen-cheatsheet.sh: comillas invertidas sin cerrar en la descripción de \"$comando\": $descripcion" >&2
        exit 2
      }
      printf '<div class="tarjeta">\n  <div class="comando">%s</div>\n  <div class="ejemplo">$ %s</div>\n  <p class="descripcion">%s</p>\n</div>\n' \
        "$(escapar "$comando")" "$(escapar "$ejemplo")" "$descripcion_html"
    done <<< "${BLOQUES[$bloque]}"
  done

  cat <<'HTML_TAIL'
</body>
</html>
HTML_TAIL
}

# Ancho y alto del lienzo del SVG: el Dockerfile lee el atributo width/height
# de la etiqueta raíz para calcular el aspect-ratio que le pone a la regla
# CSS .letterpress (DEVKIT-143), así que cambiar estos números no requiere
# tocar nada más.
SVG_ANCHO=1200
SVG_ALTO=700

# Arma la chuleta como SVG: mismos BLOQUES y FILAS que el HTML, pero en dos
# columnas por dos filas (una por bloque) para que el comando más largo entre
# sin envolver línea -un SVG no envuelve texto solo-. El color se declara dos
# veces (por defecto y bajo @media prefers-color-scheme:dark) porque el
# Dockerfile copia este mismo archivo sobre los cuatro letterpress-*.svg de
# openvscode-server: no hay una versión por tema, así que la única señal de
# clara/oscura disponible en tiempo de carga es la preferencia del navegador.
armar_svg() {
  cat <<SVG_HEAD
<svg xmlns="http://www.w3.org/2000/svg" width="$SVG_ANCHO" height="$SVG_ALTO" viewBox="0 0 $SVG_ANCHO $SVG_ALTO">
<style>
  text { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  .t { font-size: 34px; font-weight: 700; fill: #3b3b3b; fill-opacity: .55; }
  .g { font-size: 16px; font-weight: 700; letter-spacing: .06em; fill: #3b3b3b; fill-opacity: .4; }
  .c { font-size: 16px; font-weight: 700; fill: #3b3b3b; fill-opacity: .5; }
  .d { font-size: 13px; fill: #3b3b3b; fill-opacity: .32; }
  @media (prefers-color-scheme: dark) {
    .t, .g, .c, .d { fill: #d4d4d4; }
  }
</style>
<text x="60" y="70" class="t">$(escapar 'devkit: comandos')</text>
SVG_HEAD

  local -a xs=(60 620)
  local -a ys=(150 430)
  local i=0 bloque comando fila descripcion col row x y j yc yd
  for bloque in $BLOQUES_ORDEN; do
    col=$(( i % 2 ))
    row=$(( i / 2 ))
    x=${xs[$col]}
    y=${ys[$row]}
    printf '<text x="%s" y="%s" class="g">%s</text>\n' "$x" "$y" "$(escapar "$bloque")"
    j=0
    while IFS= read -r comando; do
      [ -n "$comando" ] || continue
      fila="${FILAS[$comando]}"
      descripcion="${fila#*$'\t'}"
      descripcion="${descripcion//\`/}"
      yc=$((y + 34 + j*46))
      yd=$((yc + 18))
      printf '<text x="%s" y="%s" class="c">%s</text>\n' "$x" "$yc" "$(escapar "$(recortar "$comando" 44)")"
      printf '<text x="%s" y="%s" class="d">%s</text>\n' "$x" "$yd" "$(escapar "$(recortar "$descripcion" 58)")"
      j=$((j+1))
    done <<< "${BLOQUES[$bloque]}"
    i=$((i+1))
  done

  echo '</svg>'
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

  printf 'foo <x> | foo 1 | hace foo\nbar | hace bar\n' > "$tmp/comandos-degradado.txt"
  cargar_filas "$tmp/comandos-degradado.txt" >/dev/null 2>&1
  check "fila de dos columnas corta (código 2)" 2 "$?"
  cargar_filas "$tmp/comandos.txt"  # restaura FILAS para los checks de abajo

  check "codigo_en_linea convierte un par de comillas invertidas" \
    "revisa el <code>PR</code> número" "$(codigo_en_linea 'revisa el `PR` número')"
  check "codigo_en_linea convierte varios pares" \
    "<code>a</code> y <code>b</code>" "$(codigo_en_linea '`a` y `b`')"

  codigo_en_linea 'usa `pyproject.toml para todo' >/dev/null
  check "codigo_en_linea con comilla sin cerrar devuelve 1" 1 "$?"

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

  BLOQUES_ORDEN="uno"
  declare -A BLOQUES=( [uno]="foo <x>" )
  declare -A FILAS=( ["foo <x>"]="foo 1"$'\t'"usa \`pyproject.toml para todo" )
  ( armar ) >/dev/null 2>&1
  check "descripción con comilla sin cerrar corta armar (código 2)" 2 "$?"

  check "recortar deja intacto un texto corto" "hola" "$(recortar hola 10)"
  check "recortar corta y agrega elipsis" "ho…" "$(recortar hola 3)"

  BLOQUES_ORDEN="uno"
  declare -A BLOQUES=( [uno]="foo <x>
bar" )
  declare -A FILAS=( ["foo <x>"]="foo 1"$'\t'"hace foo" ["bar"]="bar 1"$'\t'"hace bar" )
  out="$(armar_svg)"
  case "$out" in
    *'<text x="60" y="150" class="g">uno</text>'*'<text x="60" y="184" class="c">foo &lt;x&gt;</text>'*'<text x="60" y="202" class="d">hace foo</text>'*) \
      check "arma SVG con bloque, comando escapado y descripción" si si ;;
    *) check "arma SVG con bloque, comando escapado y descripción" si no ;;
  esac

  # De aquí en más, contra el comandos.txt real: BLOQUES no se puede anular
  # por variable de entorno (a diferencia de SKILLS_ORDEN en gen-readme.sh),
  # así que --check necesita el manifiesto real para validar sin cortar.
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" DEVKIT_GEN_CHEATSHEET_SALIDA_SVG="$tmp/cheatsheet.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" >/dev/null 2>&1
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" DEVKIT_GEN_CHEATSHEET_SALIDA_SVG="$tmp/cheatsheet.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el HTML y el SVG al día sale 0" 0 "$?"

  echo "viejo" > "$tmp/cheatsheet.html"
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" DEVKIT_GEN_CHEATSHEET_SALIDA_SVG="$tmp/cheatsheet.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el HTML viejo sale 1" 1 "$?"

  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" DEVKIT_GEN_CHEATSHEET_SALIDA_SVG="$tmp/cheatsheet.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" >/dev/null 2>&1  # restaura el HTML
  echo "viejo" > "$tmp/cheatsheet.svg"
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" DEVKIT_GEN_CHEATSHEET_SALIDA_SVG="$tmp/cheatsheet.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el SVG viejo sale 1" 1 "$?"

  bash "$HERE/scripts/gen-cheatsheet.sh" --chek >/dev/null 2>&1
  check "argumento desconocido se rechaza" 2 "$?"

  exit $fail
fi

case "${1:-}" in
  '' | --check) ;;
  *) echo "uso: gen-cheatsheet.sh [--check]" >&2; exit 2 ;;
esac

[ -f "$COMANDOS" ] || { echo "gen-cheatsheet.sh: no existe $COMANDOS" >&2; exit 2; }
cargar_filas "$COMANDOS" || exit 2
validar_bloques || exit 2

# Genera <salida> con <armar_fn> (armar o armar_svg); en --check compara
# contra lo commiteado sin escribir nada. Separada del cuerpo principal
# porque HTML y SVG comparten exactamente esta lógica de verificación.
generar() {  # generar <salida> <armar_fn>
  local salida=$1 armar_fn=$2 nuevo
  if [ "$MODO" = "--check" ]; then
    [ -f "$salida" ] || { echo "gen-cheatsheet.sh: no existe $salida" >&2; return 2; }
    nuevo="$(mktemp)"
    "$armar_fn" > "$nuevo"
    if diff -q "$nuevo" "$salida" >/dev/null 2>&1; then
      rm -f "$nuevo"
      return 0
    fi
    rm -f "$nuevo"
    echo "gen-cheatsheet.sh: $salida quedó vieja; corre gen-cheatsheet.sh y commitea el resultado" >&2
    return 1
  fi
  nuevo="$(mktemp)"
  "$armar_fn" > "$nuevo"
  chmod 644 "$nuevo"
  mv "$nuevo" "$salida"
}

MODO="${1:-}"
estado=0
generar "$SALIDA" armar || estado=1
generar "$SALIDA_SVG" armar_svg || estado=1
exit "$estado"

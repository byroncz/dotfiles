#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  devkit: arma devkit/vscode/cheatsheet/cheatsheet.html y los dos SVG
#  cheatsheet-{light,dark}.svg, la chuleta de comandos. El HTML lo abre a
#  pedido la extensión local devkit.cheatsheet (DEVKIT-96, comando "devkit:
#  comandos"); los SVG los pone el Dockerfile como marca de agua del editor
#  vacío (DEVKIT-143), uno por tema claro/oscuro, en lugar del logo de
#  openvscode-server. Fuente: devkit/scripts/comandos.txt (DEVKIT-88), que
#  trae tres columnas por fila: `comando | ejemplo | descripción`.
#
#  La chuleta no muestra el manifiesto completo, solo los comandos que un
#  ingeniero nuevo necesita el primer día, agrupados en cinco bloques fijos
#  (BLOQUES, abajo). Un comando que no calce exacto con la primera columna de
#  comandos.txt corta la generación (mismo criterio que SKILLS_ORDEN en
#  gen-readme.sh): un typo no debe desaparecer la tarjeta en silencio.
#
#    gen-cheatsheet.sh          escribe el HTML y los dos SVG
#    gen-cheatsheet.sh --check  sale con 1 si alguno de los tres quedó viejo
#    gen-cheatsheet.sh --test   autoprueba, con fixtures propios
# ---------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # devkit/

COMANDOS="${DEVKIT_GEN_CHEATSHEET_COMANDOS:-$HERE/scripts/comandos.txt}"
SALIDA="${DEVKIT_GEN_CHEATSHEET_SALIDA:-$HERE/vscode/cheatsheet/cheatsheet.html}"
SALIDA_SVG_CLARO="${DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO:-$HERE/vscode/cheatsheet/cheatsheet-light.svg}"
SALIDA_SVG_OSCURO="${DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO:-$HERE/vscode/cheatsheet/cheatsheet-dark.svg}"

BLOQUES_ORDEN="contenedor agentes cards Python Proyecto"
# BLOQUES_ORDEN son claves de una sola palabra (se recorren con `for bloque in
# $BLOQUES_ORDEN`, que separa por espacio); el rótulo visible de cada bloque
# vive en BLOQUES_TITULO y sí puede llevar espacios. Un bloque sin entrada
# acá muestra su clave tal cual (ver el `${BLOQUES_TITULO[$bloque]:-$bloque}`
# en armar() y armar_svg()).
declare -A BLOQUES_TITULO
BLOQUES_TITULO[contenedor]="En el host"
BLOQUES_TITULO[agentes]="Agentes"
BLOQUES_TITULO[cards]="Cards"
declare -A BLOQUES
BLOQUES[contenedor]="devkit code <proyecto>
devkit shell <proyecto>
devkit recreate <proyecto>
devkit rebuild <proyecto>
devkit awake <proyecto>"
BLOQUES[agentes]="dk --estado [--foto]
dk --tablero [--foto]
dk <skill> <Clave>
dk pr-review <N>
dk task-fix <N>"
BLOQUES[cards]="task-close.sh <Clave> [PR]
task-block.sh <Clave> <motivo>"
BLOQUES[Python]="uv add <paquete>
uv sync
uv run <comando>"
BLOQUES[Proyecto]="dk --declarar <clave> <valor>...
devkit-net-denied"

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

# Recorta <texto> a <max> caracteres para que quepa en una línea de SVG (el
# comando, que nunca debe envolverse); agrega "…" cuando corta. Cuenta
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

# Parte las palabras de "$@" en líneas de hasta <ancho> caracteres, una por
# línea de salida (envoltorio "greedy": cada palabra va en la línea actual si
# cabe). Una palabra más larga que <ancho> ocupa una línea sola.
partir() {  # partir <ancho> <palabra>...
  local ancho=$1 linea="" p
  shift
  for p in "$@"; do
    if [ -z "$linea" ]; then
      linea=$p
    elif [ $(( ${#linea} + 1 + ${#p} )) -le "$ancho" ]; then
      linea+=" $p"
    else
      printf '%s\n' "$linea"
      linea=$p
    fi
  done
  if [ -n "$linea" ]; then printf '%s\n' "$linea"; fi
  return 0
}

# Envuelve <texto> por palabras en líneas de hasta <ancho> caracteres, una por
# línea de salida (un SVG no envuelve texto solo, a diferencia del HTML). Si
# pasa de <max> líneas, corta en el último punto seguido (una palabra que
# termina en ".") que quepa en esas <max> líneas: nunca a media frase ni con
# "…". Si ni la primera frase cabe, devuelve 1 sin imprimir nada: acortar el
# texto en comandos.txt es mejor que una descripción trunca en silencio.
envolver() {  # envolver <texto> <ancho> <max>
  local texto=$1 ancho=$2 max=$3
  local -a palabras lineas usadas_en
  local linea n=0 k
  read -ra palabras <<< "$texto"
  mapfile -t lineas < <(partir "$ancho" "${palabras[@]}")
  if [ "${#lineas[@]}" -le "$max" ]; then
    printf '%s\n' "${lineas[@]}"
    return 0
  fi
  for linea in "${lineas[@]:0:max}"; do
    read -ra usadas_en <<< "$linea"
    n=$(( n + ${#usadas_en[@]} ))
  done
  for (( k = n - 1; k >= 0; k-- )); do
    [[ ${palabras[k]} == *. ]] && break
  done
  [ "$k" -ge 0 ] || return 1
  partir "$ancho" "${palabras[@]:0:k+1}"
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
    echo "<h2>$(escapar "${BLOQUES_TITULO[$bloque]:-$bloque}")</h2>"
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

# Ancho del lienzo del SVG y ancho/alto máximo de una línea de descripción. El
# alto no es fijo: armar_svg lo calcula según las líneas que ocupan los
# bloques. El Dockerfile lee el atributo width/height de la etiqueta raíz para
# calcular el aspect-ratio que le pone a la regla CSS .letterpress
# (DEVKIT-143), así que cambiar estos números no requiere tocar nada más.
SVG_ANCHO=1200
SVG_LINEA=58     # caracteres por línea de descripción (13px monoespaciado ≈ 452px)
SVG_LINEAS=3     # líneas por descripción; si no cabe, corta en el último punto seguido

# Arma la chuleta como SVG: mismos BLOQUES y FILAS que el HTML, en dos columnas
# que se llenan de arriba abajo: cada bloque va en la columna más corta hasta
# ese momento, así el alto sale de lo que ocupan los textos y no se solapan.
# Cada comando lleva su nombre, su ejemplo ("$ ...") y la descripción envuelta
# por palabras (un <tspan> por línea; ver envolver). <tema> es "claro" u
# "oscuro"; fija el color como texto plano, sin @media (prefers-color-scheme),
# que en un SVG usado como background-image de openvscode-server sigue al
# sistema operativo o al navegador, no al tema del editor -el criterio pide
# los colores de los temas vs y vs-dark, uno por archivo (DEVKIT-143 H1)-. El
# Dockerfile copia esta salida sobre los letterpress-*.svg que le
# correspondan a cada tema.
#
# La opacidad de cada clase también depende del tema: son las que dan al
# menos WCAG AA (4.5:1, texto normal) o AAA (7:1, para .c que hace de
# subtítulo) contra el fondo real del editor (#1f1f1f oscuro, #ffffff claro),
# con color efectivo = fondo + (texto − fondo) × opacidad (DEVKIT-157). Antes
# había un solo juego de valores, calculado a ojo, que en oscuro quedaba muy
# por debajo del mínimo.
armar_svg() {
  local tema=$1 color op_t op_g op_c op_d
  case "$tema" in
    claro) color=#3b3b3b; op_t=.70; op_g=.70; op_c=.85; op_d=.70 ;;
    oscuro) color=#d4d4d4; op_t=.60; op_g=.60; op_c=.76; op_d=.60 ;;
    *) echo "armar_svg: tema desconocido \"$tema\" (se esperaba claro u oscuro)" >&2; return 2 ;;
  esac

  # El cuerpo se arma primero: el alto del lienzo (etiqueta raíz) se sabe al final.
  local -a xs=(60 620)
  local -a ys=(150 150)
  local cuerpo="" bloque comando fila ejemplo descripcion col x y yc alto
  local -a lineas
  local l
  for bloque in $BLOQUES_ORDEN; do
    col=0
    [ "${ys[1]}" -lt "${ys[0]}" ] && col=1
    x=${xs[$col]}
    y=${ys[$col]}
    cuerpo+="$(printf '<text x="%s" y="%s" class="g">%s</text>' "$x" "$y" "$(escapar "${BLOQUES_TITULO[$bloque]:-$bloque}")")"$'\n'
    yc=$((y + 34))
    while IFS= read -r comando; do
      [ -n "$comando" ] || continue
      fila="${FILAS[$comando]}"
      ejemplo="${fila%%$'\t'*}"
      descripcion="${fila#*$'\t'}"
      descripcion="${descripcion//\`/}"
      mapfile -t lineas < <(envolver "$descripcion" "$SVG_LINEA" "$SVG_LINEAS") || true
      if [ "${#lineas[@]}" -eq 0 ]; then
        echo "armar_svg: la primera frase de la descripción de \"$comando\" no cabe en $SVG_LINEAS líneas de $SVG_LINEA caracteres; acórtala en $COMANDOS" >&2
        return 2
      fi
      cuerpo+="$(printf '<text x="%s" y="%s" class="c">%s</text>' "$x" "$yc" "$(escapar "$(recortar "$comando" 44)")")"$'\n'
      cuerpo+="$(printf '<text x="%s" y="%s" class="e">$ %s</text>' "$x" "$((yc + 18))" "$(escapar "$ejemplo")")"$'\n'
      cuerpo+="$(printf '<text x="%s" y="%s" class="d">' "$x" "$((yc + 36))")"
      for l in "${!lineas[@]}"; do
        if [ "$l" -eq 0 ]; then
          cuerpo+="$(printf '<tspan x="%s">%s</tspan>' "$x" "$(escapar "${lineas[$l]}")")"
        else
          cuerpo+="$(printf '<tspan x="%s" dy="17">%s</tspan>' "$x" "$(escapar "${lineas[$l]}")")"
        fi
      done
      cuerpo+="</text>"$'\n'
      yc=$((yc + 36 + (${#lineas[@]} - 1) * 17 + 34))
    done <<< "${BLOQUES[$bloque]}"
    ys[$col]=$((yc - 34 + 30))   # baja hasta el fin del bloque y deja aire antes del siguiente
  done

  alto=${ys[0]}
  [ "${ys[1]}" -gt "$alto" ] && alto=${ys[1]}

  cat <<SVG_HEAD
<svg xmlns="http://www.w3.org/2000/svg" width="$SVG_ANCHO" height="$alto" viewBox="0 0 $SVG_ANCHO $alto">
<style>
  text { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  .t { font-size: 34px; font-weight: 700; fill: $color; fill-opacity: $op_t; }
  .g { font-size: 16px; font-weight: 700; letter-spacing: .06em; fill: $color; fill-opacity: $op_g; }
  .c { font-size: 16px; font-weight: 700; fill: $color; fill-opacity: $op_c; }
  .e { font-size: 13px; fill: $color; fill-opacity: $op_d; }
  .d { font-size: 13px; fill: $color; fill-opacity: $op_d; }
</style>
<text x="60" y="70" class="t">$(escapar 'devkit: comandos')</text>
SVG_HEAD
  printf '%s' "$cuerpo"
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

  # comprobar_opacidad <nombre> <svg> <clase> <mínimo>: extrae el
  # fill-opacity de la regla CSS ".<clase> { ... }" del <svg> y falla si no
  # alcanza el <mínimo> de contraste WCAG (comparación numérica, no de texto:
  # la implementación puede usar cualquier valor que cumpla el mínimo).
  comprobar_opacidad() {
    local nombre=$1 svg=$2 clase=$3 minimo=$4 valor
    valor="$(printf '%s' "$svg" | grep -oE "\.$clase \{[^}]*fill-opacity: [0-9.]+" | grep -oE '[0-9.]+$')"
    if [ -n "$valor" ] && awk -v a="$valor" -v b="$minimo" 'BEGIN{exit !(a>=b)}'; then
      printf 'ok   %-55s\n' "$nombre ($valor >= $minimo)"
    else
      printf 'FAIL %-55s valor "%s", mínimo "%s"\n' "$nombre" "$valor" "$minimo"
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

  check "envolver deja un texto corto en una línea" "hace foo" "$(envolver 'hace foo' 58 3)"

  largo="Uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciséis diecisiete dieciocho diecinueve veinte veintiuno."
  out="$(envolver "$largo" 58 3)"
  check "envolver parte un texto largo en tres líneas" 3 "$(printf '%s\n' "$out" | wc -l)"
  check "envolver no pasa el ancho en ninguna línea" 0 "$(printf '%s\n' "$out" | awk 'length($0) > 58' | wc -l)"
  check "envolver conserva todas las palabras" "$largo" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"

  out="$(envolver 'Uno dos tres. Cuatro cinco seis. Siete ocho nueve diez.' 20 2)"
  check "envolver corta en el último punto seguido que cabe" \
    "Uno dos tres. Cuatro
cinco seis." "$out"
  case "$out" in
    *…*) check "envolver no agrega elipsis al cortar" si no ;;
    *) check "envolver no agrega elipsis al cortar" si si ;;
  esac

  envolver 'uno dos tres cuatro cinco seis siete' 10 2 >/dev/null
  check "envolver sin ningún punto que quepa devuelve 1" 1 "$?"

  BLOQUES_ORDEN="uno"
  declare -A BLOQUES=( [uno]="foo <x>
bar" )
  declare -A FILAS=( ["foo <x>"]="foo 1"$'\t'"hace foo" ["bar"]="bar 1"$'\t'"$largo" )
  out="$(armar_svg claro)"
  case "$out" in
    *'fill: #3b3b3b'*'<text x="60" y="150" class="g">uno</text>'*'<text x="60" y="184" class="c">foo &lt;x&gt;</text>'*'<text x="60" y="202" class="e">$ foo 1</text>'*'<text x="60" y="220" class="d"><tspan x="60">hace foo</tspan></text>'*) \
      check "arma SVG claro con bloque, comando, ejemplo y descripción" si si ;;
    *) check "arma SVG claro con bloque, comando, ejemplo y descripción" si no ;;
  esac
  check "SVG: descripción larga, un <tspan> por línea (tres)" 3 "$(printf '%s' "$out" | grep -o '<tspan' | wc -l | awk '{print $1 - 1}')"
  alto="$(printf '%s' "$out" | grep -o '<svg [^>]*' | sed -E 's/.* height="([0-9]+)".*/\1/')"
  check "SVG: el alto sale de las líneas, no es fijo" si "$([ "$alto" != 700 ] && echo si || echo no)"
  check "SVG: viewBox usa el mismo alto" 1 "$(printf '%s' "$out" | grep -c "viewBox=\"0 0 $SVG_ANCHO $alto\"")"

  declare -A FILAS=( ["foo <x>"]="foo 1"$'\t'"hace foo" ["bar"]="bar 1"$'\t'"una sola frase interminable sin ningún punto seguido en toda la descripción que sobrepasa por mucho las tres líneas de cincuenta y ocho caracteres cada una y que además sigue y sigue para que ni siquiera tres líneas completas alcancen a contenerla del todo" )
  armar_svg claro >/dev/null 2>&1
  check "SVG: una primera frase que no cabe corta la generación (2)" 2 "$?"
  declare -A FILAS=( ["foo <x>"]="foo 1"$'\t'"hace foo" ["bar"]="bar 1"$'\t'"hace bar" )
  out="$(armar_svg claro)"
  case "$out" in
    *'@media'*) check "SVG claro sin @media prefers-color-scheme" si no ;;
    *) check "SVG claro sin @media prefers-color-scheme" si si ;;
  esac
  comprobar_opacidad "SVG claro .d cumple WCAG AA (4.5:1) sobre #ffffff" "$out" d .70
  comprobar_opacidad "SVG claro .c cumple WCAG AAA (7:1) sobre #ffffff" "$out" c .85
  comprobar_opacidad "SVG claro .g cumple WCAG AA (4.5:1) sobre #ffffff" "$out" g .70
  comprobar_opacidad "SVG claro .e cumple WCAG AA (4.5:1) sobre #ffffff" "$out" e .70
  comprobar_opacidad "SVG claro .t cumple WCAG AA (4.5:1) sobre #ffffff" "$out" t .70

  out="$(armar_svg oscuro)"
  case "$out" in
    *'fill: #d4d4d4'*) check "arma SVG oscuro con el color del tema oscuro" si si ;;
    *) check "arma SVG oscuro con el color del tema oscuro" si no ;;
  esac
  comprobar_opacidad "SVG oscuro .d cumple WCAG AA (4.5:1) sobre #1f1f1f" "$out" d .60
  comprobar_opacidad "SVG oscuro .c cumple WCAG AAA (7:1) sobre #1f1f1f" "$out" c .76
  comprobar_opacidad "SVG oscuro .g cumple WCAG AA (4.5:1) sobre #1f1f1f" "$out" g .60
  comprobar_opacidad "SVG oscuro .e cumple WCAG AA (4.5:1) sobre #1f1f1f" "$out" e .60
  comprobar_opacidad "SVG oscuro .t cumple WCAG AA (4.5:1) sobre #1f1f1f" "$out" t .60

  armar_svg no-existe >/dev/null 2>&1
  check "armar_svg con tema desconocido corta (código 2)" 2 "$?"

  # De aquí en más, contra el comandos.txt real: BLOQUES no se puede anular
  # por variable de entorno (a diferencia de SKILLS_ORDEN en gen-readme.sh),
  # así que --check necesita el manifiesto real para validar sin cortar.
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/cheatsheet-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" >/dev/null 2>&1
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/cheatsheet-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el HTML y los dos SVG al día sale 0" 0 "$?"

  check "HTML real: título de bloque Agentes" 1 "$(grep -c '<h2>Agentes</h2>' "$tmp/cheatsheet.html")"
  check "HTML real: título de bloque Cards" 1 "$(grep -c '<h2>Cards</h2>' "$tmp/cheatsheet.html")"
  check "SVG claro real: título de bloque Agentes" 1 "$(grep -c 'class="g">Agentes<' "$tmp/cheatsheet-light.svg")"
  check "SVG claro real: título de bloque Cards" 1 "$(grep -c 'class="g">Cards<' "$tmp/cheatsheet-light.svg")"
  check "SVG oscuro real: título de bloque Agentes" 1 "$(grep -c 'class="g">Agentes<' "$tmp/cheatsheet-dark.svg")"
  check "SVG oscuro real: título de bloque Cards" 1 "$(grep -c 'class="g">Cards<' "$tmp/cheatsheet-dark.svg")"

  # Los cinco títulos de bloque (contenedor, agentes, cards, Python, Proyecto)
  # van con mayúscula inicial en el HTML y en los dos SVG (DEVKIT-157).
  check "HTML real: título de bloque Proyecto" 1 "$(grep -c '<h2>Proyecto</h2>' "$tmp/cheatsheet.html")"
  check "SVG claro real: título de bloque Proyecto" 1 "$(grep -c 'class="g">Proyecto<' "$tmp/cheatsheet-light.svg")"
  check "SVG oscuro real: título de bloque Proyecto" 1 "$(grep -c 'class="g">Proyecto<' "$tmp/cheatsheet-dark.svg")"

  # dk --declarar y devkit-net-denied viven en Proyecto; net-denied ya no está en Cards (DEVKIT-272).
  html_real="$(cat "$tmp/cheatsheet.html")"
  proyecto_html="${html_real#*<h2>Proyecto</h2>}"
  check "HTML real: dk --declarar dentro de Proyecto" 1 "$(printf '%s' "$proyecto_html" | grep -c 'dk --declarar &lt;clave&gt; &lt;valor&gt;...')"
  check "HTML real: devkit-net-denied dentro de Proyecto" 1 "$(printf '%s' "$proyecto_html" | grep -c '<div class="comando">devkit-net-denied</div>')"
  cards_html="${html_real#*<h2>Cards</h2>}"
  cards_html="${cards_html%%<h2>Python</h2>*}"
  check "HTML real: devkit-net-denied ya no está en Cards" 0 "$(printf '%s' "$cards_html" | grep -c 'devkit-net-denied')"

  for tema in light dark; do
    svg="$tmp/cheatsheet-$tema.svg"
    check "SVG $tema real: muestra el ejemplo de dk --declarar" 1 "$(grep -c 'class="e">\$ dk --declarar extensions ms-python.python charliermarsh.ruff<' "$svg")"
    plano="$(sed 's/<[^>]*>/ /g' "$svg" | tr -s ' \n' ' ')"
    check "SVG $tema real: forma extensions de dk --declarar" 1 "$(printf '%s' "$plano" | grep -c 'dk --declarar extensions ms-python.python, dk')"
    check "SVG $tema real: forma domains de dk --declarar" 1 "$(printf '%s' "$plano" | grep -c 'dk --declarar domains pypi.org files.pythonhosted.org, dk')"
    check "SVG $tema real: forma apt de dk --declarar" 1 "$(printf '%s' "$plano" | grep -c 'dk --declarar apt jq\.')"
    check "SVG $tema real: ninguna descripción termina en elipsis" 0 "$(grep -c '…</tspan>' "$svg")"
    # Las dos columnas arrancan en x=60 y x=620: una línea de más de 66
    # caracteres (13px monoespaciado ≈ 7,8 px cada uno, 515 px) pisaría la otra columna.
    check "SVG $tema real: ninguna línea pasa de 66 caracteres" 0 \
      "$(grep -oE '(<tspan[^>]*>|class="e">)[^<]*' "$svg" | sed -E 's/^(<tspan[^>]*>|class="e">)//' | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/&/g' | awk 'length($0) > 66' | wc -l)"
  done

  # Un comando de BLOQUES ausente de comandos.txt corta la generación entera.
  printf 'foo | foo 1 | hace foo\n' > "$tmp/comandos-corto.txt"
  DEVKIT_GEN_CHEATSHEET_COMANDOS="$tmp/comandos-corto.txt" \
    DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/x.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/x-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/x-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" >/dev/null 2>&1
  check "un comando de BLOQUES ausente en comandos.txt corta la generación (2)" 2 "$?"
  check "...y no escribe ningún archivo" 0 "$(ls "$tmp"/x* 2>/dev/null | wc -l)"


  echo "viejo" > "$tmp/cheatsheet.html"
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/cheatsheet-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el HTML viejo sale 1" 1 "$?"

  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/cheatsheet-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" >/dev/null 2>&1  # restaura el HTML
  echo "viejo" > "$tmp/cheatsheet-light.svg"
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/cheatsheet-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el SVG claro viejo sale 1" 1 "$?"

  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/cheatsheet-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" >/dev/null 2>&1  # restaura el SVG claro
  echo "viejo" > "$tmp/cheatsheet-dark.svg"
  DEVKIT_GEN_CHEATSHEET_SALIDA="$tmp/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$tmp/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$tmp/cheatsheet-dark.svg" \
    bash "$HERE/scripts/gen-cheatsheet.sh" --check >/dev/null 2>&1
  check "--check con el SVG oscuro viejo sale 1" 1 "$?"

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

# Genera <salida> con <armar_fn> [args...] (armar, o armar_svg claro/oscuro);
# en --check compara contra lo commiteado sin escribir nada. Separada del
# cuerpo principal porque HTML y los dos SVG comparten exactamente esta
# lógica de verificación.
generar() {  # generar <salida> <armar_fn> [args...]
  local salida=$1 armar_fn=$2 nuevo
  shift 2
  if [ "$MODO" = "--check" ]; then
    [ -f "$salida" ] || { echo "gen-cheatsheet.sh: no existe $salida" >&2; return 2; }
    nuevo="$(mktemp)"
    "$armar_fn" "$@" > "$nuevo" || { rm -f "$nuevo"; return 2; }
    if diff -q "$nuevo" "$salida" >/dev/null 2>&1; then
      rm -f "$nuevo"
      return 0
    fi
    rm -f "$nuevo"
    echo "gen-cheatsheet.sh: $salida quedó vieja; corre gen-cheatsheet.sh y commitea el resultado" >&2
    return 1
  fi
  nuevo="$(mktemp)"
  "$armar_fn" "$@" > "$nuevo" || { rm -f "$nuevo"; return 2; }
  chmod 644 "$nuevo"
  mv "$nuevo" "$salida"
}

MODO="${1:-}"
estado=0
generar "$SALIDA" armar || estado=1
generar "$SALIDA_SVG_CLARO" armar_svg claro || estado=1
generar "$SALIDA_SVG_OSCURO" armar_svg oscuro || estado=1
exit "$estado"

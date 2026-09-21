#!/usr/bin/env bash
# Cliente mínimo de la API de Notion para bash (DEVKIT-55). Existe para que
# cerrar o bloquear una card no cueste un agente: el plugin de Notion vive
# dentro de Claude Code, así que hasta aquí cada cambio de Estado o comentario
# necesitaba un `claude -p` entero. Con un token de conexión interna, bash
# habla directo con la API; la API no cobra por llamada, solo limita
# peticiones por minuto.
#
# Uso:
#   notion.sh card <Clave>                    la card como JSON normalizado
#   notion.sh pagina <page_id>                lo mismo, por id de página
#   notion.sh set <page_id> Prop=valor...     cambia propiedades
#   notion.sh comentar <page_id> <texto>      comenta en la página
#   notion.sh documentacion <page_id> [clave] entrada de Documentación de la
#                                             card (relación Tarea): {id,url}.
#                                             Con <clave>, solo cuenta la
#                                             entrada cuyo Título empieza por
#                                             "<clave>:" (descarta entradas de
#                                             referencia con la misma Tarea)
#   notion.sh crear-doc <tarea_id> <proyecto_id> <titulo> <tipo> [rama] [pr]
#                                             crea una página en Documentación
#                                             con esas propiedades y el cuerpo
#                                             Markdown que llega por stdin
#                                             como bloques: {id,url}
#                                             (task-document.sh, DEVKIT-92)
#   notion.sh reemplazar-doc <page_id> [rama] [pr]
#                                             vacía los bloques de una página
#                                             de Documentación y los reemplaza
#                                             por el Markdown de stdin;
#                                             actualiza Rama/PR si llegan:
#                                             {id,url} (DEVKIT-92)
#   notion.sh hijas <page_id>                 hijas de una Épica (relación
#                                             Padre), como lista JSON
#   notion.sh sueltas <código>                Tareas del proyecto en Lista
#                                             sin Padre, como lista JSON
#                                             (grupo 2 de `cola.sh`, DEVKIT-119)
#   notion.sh criterios <page_id>             texto de la sección "Criterios
#                                             de aceptación" de la página
#   notion.sh contenido <page_id>             toda la página en Markdown
#                                             plano: encabezados y texto de
#                                             cada bloque, en orden (lo usa
#                                             task-begin.sh, DEVKIT-90, para
#                                             pasarle Objetivo, Criterios de
#                                             aceptación y Notas al agente sin
#                                             que consulte Notion)
#   notion.sh comentarios <page_id>           todos los comentarios de la
#                                             página, en orden cronológico,
#                                             uno por bloque de texto
#   notion.sh bloqueos <código>               por cada card en Lista para
#                                             merge del proyecto, las Claves
#                                             en Lista que dependen de ella
#                                             (columna "bloquea a" de
#                                             `devkit-run --estado`, DEVKIT-63)
#   notion.sh epicas <código>                 por cada Épica En progreso del
#                                             proyecto, una entrada de sí
#                                             misma, y por cada Tarea que no
#                                             está Hecha con esa Épica como
#                                             Padre, su Clave y título; una
#                                             Tarea ya Hecha no aparece aunque
#                                             su Épica siga activa (agrupación
#                                             de `devkit-run --estado`,
#                                             DEVKIT-80)
#   notion.sh activas <código>                cards activas del proyecto
#                                             (Lista, En progreso, Revisión
#                                             automática, Lista para merge,
#                                             Bloqueada) con Clave, Estado,
#                                             Tipo y PR, en una sola consulta
#                                             (tablero de `devkit-run
#                                             --tablero`, DEVKIT-82)
#   notion.sh epicas-abiertas <código>        Épicas del proyecto en Lista o
#                                             En progreso, normalizadas (con
#                                             id, para pedir después sus
#                                             hijas), como lista JSON
#                                             (arrastre de hijas de Backlog a
#                                             Lista de `watch.sh`, DEVKIT-121)
#   notion.sh epicas-backlog <código>         Épicas del proyecto en Backlog,
#                                             normalizadas (con id), como
#                                             lista JSON (grupo 3 de
#                                             `cola.sh`, DEVKIT-122, sin
#                                             bandera desde DEVKIT-128; misma
#                                             forma que `epicas-abiertas`, con
#                                             Estado Backlog en vez de
#                                             Lista/En progreso)
#   notion.sh sueltas-backlog <código>        Tareas del proyecto en Backlog
#                                             sin Padre, como lista JSON
#                                             (grupo 4 de `cola.sh`,
#                                             DEVKIT-122, sin bandera desde
#                                             DEVKIT-128; misma forma que
#                                             `sueltas`, con Estado Backlog
#                                             en vez de Lista)
#   notion.sh --test                          autoprueba, sin red
#
# Las cuatro primeras operaciones son las del criterio de aceptación (leer una
# card por ID y Proyecto, cambiar propiedades, comentar, buscar la entrada de
# Documentación); `pagina`, `hijas` y `criterios` las necesita task-close.sh
# para la regla de cierre de Épica (DEVKIT-44) y la siguiente hija.
#
# JSON normalizado de una card: {id, url, clave, numero, titulo, estado,
# nivel, tipo, prioridad, orden, pr, rama, padre[], depende[],
# documentacion[]}. `clave` sale del código del proyecto de la card y de su
# ID, igual que la fórmula `Clave`, que la API no devuelve calculada.
#
# `set` lee el tipo de cada propiedad de la propia página antes de escribir,
# así quien llama no arma JSON de la API: `Estado=Hecha`, `Cierre=2026-09-16`,
# `PR=https://...`. Un valor vacío (`PR=`) borra la propiedad.
#
# El token. Vive en /run/devkit/notion_token (tmpfs, 600), lo escribe
# entrypoint.sh desde Bitwarden y nunca pasa a variable de entorno: una
# variable la heredan todos los procesos hijos y se lee en /proc/<pid>/environ
# (regla de DEVKIT-51). Tampoco viaja por argumento, que `ps` muestra: curl
# recibe la cabecera por un descriptor (`-H @<(printf ...)`), y `printf` es un
# builtin de bash que no crea proceso. Un error imprime el código HTTP y el
# mensaje de Notion, nunca la petición.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
TOKEN_FILE="${DEVKIT_NOTION_TOKEN_FILE:-$RUN_DIR/notion_token}"
API="${DEVKIT_NOTION_API:-https://api.notion.com/v1}"
# 2022-06-28 trabaja por database_id, que es lo que guarda notion.json. Las
# bases del devkit tienen una sola fuente de datos, así que no hace falta la
# versión de data sources.
NOTION_VERSION="2022-06-28"
CURL="${DEVKIT_CURL_BIN:-curl}"
RETRIES="${DEVKIT_NOTION_RETRIES:-3}"

# Identificadores de las bases: el mismo notion.json que leen las skills.
ids_file() {
  local f
  for f in "${DEVKIT_NOTION_IDS:-}" "$WS/.claude/devkit-notion.json" \
           "$HERE/../agents/notion.json" /opt/devkit/template/agents/notion.json; do
    [ -n "$f" ] && [ -r "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

db_id() {  # db_id <tareas|proyectos|documentacion>
  local f
  f=$(ids_file) || { echo "notion.sh: no encuentro notion.json" >&2; return 1; }
  jq -r --arg k "$1" '.[$k].database_id // empty' "$f"
}

err() { printf 'notion.sh: %s\n' "$*" >&2; }

# api <método> <ruta> [cuerpo JSON]. Imprime el cuerpo de la respuesta; sale 1
# con el código y el mensaje de Notion si no es 2xx. Reintenta un 429 o un 5xx
# con espera creciente: el límite de la API es por minuto y se recupera solo.
api() {
  local method=$1 path=$2 body=${3:-} token out code intento=1
  if [ ! -s "$TOKEN_FILE" ]; then
    err "falta el secreto notion_token ($TOKEN_FILE); ver README, sección Integraciones"
    return 3
  fi
  token=$(tr -d '[:space:]' <"$TOKEN_FILE")
  while :; do
    if [ -n "$body" ]; then
      out=$("$CURL" -sS -X "$method" "$API$path" \
        -H @<(printf 'Authorization: Bearer %s\n' "$token") \
        -H "Notion-Version: $NOTION_VERSION" -H "Content-Type: application/json" \
        --data-binary "$body" -w '\n%{http_code}' 2>&1)
    else
      out=$("$CURL" -sS -X "$method" "$API$path" \
        -H @<(printf 'Authorization: Bearer %s\n' "$token") \
        -H "Notion-Version: $NOTION_VERSION" -w '\n%{http_code}' 2>&1)
    fi
    code=${out##*$'\n'}
    out=${out%$'\n'*}
    case "$code" in
      2??) printf '%s' "$out"; return 0 ;;
      429|5??)
        if [ "$intento" -lt "$RETRIES" ]; then
          sleep "$intento"
          intento=$((intento + 1))
          continue
        fi
        ;;
    esac
    case "$code" in
      # Sin respuesta del servidor (proxy, DNS, conexión rechazada): el
      # único texto útil es el de curl, que no es JSON.
      000|"") err "$method $path: HTTP ${code:-?}: $(printf '%s' "$out" | head -1 | cut -c1-200)" ;;
      *) err "$method $path: HTTP ${code:-?}: $(printf '%s' "$out" | jq -r '.message // empty' 2>/dev/null | cut -c1-200)" ;;
    esac
    return 1
  done
}

# query_all <database_id> <filtro JSON>: todas las filas, siguiendo la
# paginación, como una sola lista JSON.
query_all() {
  local db=$1 filter=$2 cursor="" page acc='[]' body
  while :; do
    body=$(jq -nc --argjson f "$filter" --arg c "$cursor" \
      '{filter: $f, page_size: 100} + (if $c == "" then {} else {start_cursor: $c} end)')
    page=$(api POST "/databases/$db/query" "$body") || return
    acc=$(jq -c --argjson p "$page" '. + $p.results' <<<"$acc")
    [ "$(jq -r '.has_more' <<<"$page")" = "true" ] || break
    cursor=$(jq -r '.next_cursor' <<<"$page")
  done
  printf '%s' "$acc"
}

# Normaliza una página de Tareas. El código del proyecto no viene en la página
# (es un rollup que la API no calcula), así que llega como argumento.
NORMALIZA='
def texto: (. // []) | map(.plain_text) | join("");
def ids: (. // []) | map(.id);
.properties as $p
| {id, url,
   numero: $p.ID.unique_id.number,
   clave: (if $codigo != "" and $p.ID.unique_id.number != null
           then "\($codigo)-\($p.ID.unique_id.number)" else null end),
   titulo: ($p["Título"].title | texto),
   estado: $p.Estado.select.name,
   nivel: $p.Nivel.select.name,
   tipo: $p.Tipo.select.name,
   prioridad: $p.Prioridad.select.name,
   orden: $p.Orden.number,
   agente: $p.Agente.select.name,
   creado: .created_time,
   pr: $p.PR.url,
   rama: $p.Rama.url,
   padre: ($p.Padre.relation | ids),
   depende: ($p["Depende de"].relation | ids),
   documentacion: ($p["Documentación"].relation | ids),
   proyecto: ($p.Proyecto.relation | ids)}
'

proyecto_id() {  # proyecto_id <código>
  local filas
  filas=$(query_all "$(db_id proyectos)" \
    "$(jq -nc --arg c "$1" '{property: "Código", rich_text: {equals: $c}}')") || return
  jq -r '.[0].id // empty' <<<"$filas"
}

# Código del proyecto a partir de su página, para armar la Clave de una
# página de Tareas leída por id.
codigo_de_proyecto() {  # codigo_de_proyecto <page_id>
  [ -n "$1" ] || return 0
  api GET "/pages/$1" | jq -r '.properties["Código"].rich_text | map(.plain_text) | join("")'
}

cmd_card() {  # cmd_card <Clave>
  local clave=$1 codigo numero proy filas
  codigo=${clave%-*}
  numero=${clave##*-}
  case "$numero" in ''|*[!0-9]*) err "Clave inválida: $clave"; return 64 ;; esac
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --argjson n "$numero" --arg p "$proy" \
    '{and: [{property: "ID", unique_id: {equals: $n}}, {property: "Proyecto", relation: {contains: $p}}]}')") || return
  [ "$(jq 'length' <<<"$filas")" -gt 0 ] || { err "no hay card $clave"; return 1; }
  jq -c --arg codigo "$codigo" ".[0] | $NORMALIZA" <<<"$filas"
}

cmd_pagina() {  # cmd_pagina <page_id>
  local page codigo
  page=$(api GET "/pages/$1") || return
  codigo=$(codigo_de_proyecto "$(jq -r '.properties.Proyecto.relation[0].id // empty' <<<"$page")")
  jq -c --arg codigo "$codigo" "$NORMALIZA" <<<"$page"
}

# Propiedades de la API a partir de pares Prop=valor y del tipo que tiene cada
# una en la página. Puro: recibe la página y los pares, para la autoprueba.
PROPIEDADES='
reduce $pares[] as $par ({};
  ($par | index("=")) as $i
  | ($par[:$i]) as $k | ($par[$i+1:]) as $v
  | ($pagina.properties[$k].type // error("propiedad desconocida: \($k)")) as $t
  | . + {($k):
      (if $t == "select" then {select: (if $v == "" then null else {name: $v} end)}
       elif $t == "status" then {status: {name: $v}}
       elif $t == "date" then {date: (if $v == "" then null else {start: $v} end)}
       elif $t == "url" then {url: (if $v == "" then null else $v end)}
       elif $t == "number" then {number: (if $v == "" then null else ($v | tonumber) end)}
       elif $t == "checkbox" then {checkbox: ($v == "true" or $v == "si")}
       elif $t == "rich_text" then {rich_text: [{text: {content: $v}}]}
       elif $t == "title" then {title: [{text: {content: $v}}]}
       elif $t == "relation" then {relation: ($v | split(",") | map(select(. != "") | {id: .}))}
       else error("tipo no soportado: \($t) en \($k)") end)})
'

cmd_set() {  # cmd_set <page_id> Prop=valor...
  local page_id=$1 pagina props par
  shift
  [ $# -gt 0 ] || { err "set sin propiedades"; return 64; }
  for par in "$@"; do
    case "$par" in *=*) ;; *) err "par sin '=': $par"; return 64 ;; esac
  done
  pagina=$(api GET "/pages/$page_id") || return
  if ! props=$(jq -nc --argjson pagina "$pagina" \
         '$ARGS.positional as $pares | {properties: ('"$PROPIEDADES"')}' --args "$@" 2>&1); then
    err "$(printf '%s' "$props" | head -1)"
    return 64
  fi
  api PATCH "/pages/$page_id" "$props" >/dev/null
}

# Un texto a objetos rich_text de Notion: las URL como enlaces, el resto
# como texto, y cada tramo en trozos de 2000 caracteres, el tope de la API
# por objeto `text.content`. Compartido con MD_BLOQUES (DEVKIT-92): un
# bloque de Documentación largo -código, párrafo, viñeta- necesita el mismo
# recorte que ya aplicaba el comentario del PR.
TRAMOS_DEF='
def tramos($t):
  ($t | [match("https?://[^\\s<>()\"]*[^\\s<>()\".,;:]"; "g")]) as $ms
  | (reduce $ms[] as $m ({pos: 0, out: []};
       .out += (if $m.offset > .pos then [{text: {content: $t[.pos:$m.offset]}}] else [] end)
               + [{text: {content: $m.string, link: {url: $m.string}}}]
       | .pos = $m.offset + $m.length)) as $r
  | $r.out + (if ($t | length) > $r.pos then [{text: {content: $t[$r.pos:]}}] else [] end);
def recortar($t):
  [ tramos($t)[] | . as $s
    | range(0; ($s.text.content | length); 2000) as $i
    | $s | .text.content = $s.text.content[$i:$i + 2000] ];
'

RICH_TEXT="$TRAMOS_DEF"'
recortar($texto)
'

cmd_comentar() {  # cmd_comentar <page_id> <texto>
  local body
  [ -n "${2:-}" ] || { err "comentario vacío"; return 64; }
  body=$(jq -nc --arg p "$1" --arg texto "$2" "{parent: {page_id: \$p}, rich_text: ($RICH_TEXT)}")
  api POST "/comments" "$body" >/dev/null
}

cmd_documentacion() {  # cmd_documentacion <page_id> [clave]
  local filas fila
  filas=$(query_all "$(db_id documentacion)" \
    "$(jq -nc --arg p "$1" '{property: "Tarea", relation: {contains: $p}}')") || return
  if [ -n "${2:-}" ]; then
    # Filtra por la convención de título de task-document (paso 5):
    # "<Clave>: ...". Sin esto, una entrada de referencia con la misma
    # relación Tarea (p. ej. una decisión congelada) se confunde con la
    # entrada de la card y task-document la sobrescribe (DEVKIT-87).
    fila=$(jq -c --arg pref "$2:" \
      'map(select((.properties["Título"].title // []) | map(.plain_text) | join("") | startswith($pref))) | .[0] // empty' \
      <<<"$filas")
  else
    fila=$(jq -c '.[0] // empty' <<<"$filas")
  fi
  [ -n "$fila" ] || return 1
  jq -c '{id, url}' <<<"$fila"
}

# Markdown de línea a bloque de Notion (DEVKIT-92): task-document.sh compone
# el cuerpo de una entrada de Documentación en Markdown plano -lo mismo que ya
# arma a mano, sin plugin- y esto lo convierte a los cuatro tipos de bloque
# que ese cuerpo usa: encabezado (#/##/###), párrafo, lista (- o número.) y
# código (```lenguaje ... ```). Cualquier otra sintaxis de Markdown (tablas,
# negrita, enlaces) cae a párrafo con el texto tal cual: task-document.sh no
# la genera, así que no hace falta cubrirla. Una línea que no abre un bloque
# nuevo (no es encabezado, viñeta, número ni cerca de código) continúa el
# párrafo o el ítem de lista anterior, unida con un espacio: los cuerpos de
# PR llegan con las líneas cortadas a columna fija, y sin esto cada una
# quedaba como su propio párrafo. Una línea en blanco corta esa continuación
# (flag `corte`, H7 del informe del PR 66): sin ella, dos párrafos separados
# por línea en blanco -como "Por qué" o "Modelos"- se pegaban en uno solo,
# porque la línea en blanco no tocaba el estado y la siguiente línea seguía
# viendo el párrafo anterior como continuable.
MD_BLOQUES="$TRAMOS_DEF"'
def bloque($tipo; $contenido):
  {object: "block", type: $tipo, ($tipo): {rich_text: (recortar($contenido) | map(. + {type: "text"}))}};
def es_continuable: . == "paragraph" or . == "bulleted_list_item" or . == "numbered_list_item";
($md | split("\n")) as $lineas
| (reduce $lineas[] as $l
    ({items: [], en_codigo: false, codigo: "", lenguaje: "", corte: false};
      if .en_codigo then
        if ($l | test("^```")) then
          .items += [{tipo: "code", contenido: (.codigo | rtrimstr("\n")),
                      lenguaje: (if .lenguaje == "" then "plain text" else .lenguaje end)}]
          | .en_codigo = false | .codigo = "" | .lenguaje = "" | .corte = false
        else
          .codigo += ($l + "\n")
        end
      elif ($l | test("^```")) then
        .en_codigo = true | .lenguaje = ($l | ltrimstr("```"))
      elif ($l | test("^### ")) then .items += [{tipo: "heading_3", contenido: ($l | ltrimstr("### "))}] | .corte = false
      elif ($l | test("^## "))  then .items += [{tipo: "heading_2", contenido: ($l | ltrimstr("## "))}] | .corte = false
      elif ($l | test("^# "))   then .items += [{tipo: "heading_1", contenido: ($l | ltrimstr("# "))}] | .corte = false
      elif ($l | test("^[-*] ")) then .items += [{tipo: "bulleted_list_item", contenido: $l[2:]}] | .corte = false
      elif ($l | test("^[0-9]+\\. ")) then .items += [{tipo: "numbered_list_item", contenido: ($l | sub("^[0-9]+\\. ";""))}] | .corte = false
      elif ($l | test("^\\s*$")) then .corte = true
      elif (.corte == false and (.items | length) > 0 and (.items[-1].tipo | es_continuable)) then
        .items[-1].contenido += (" " + ($l | sub("^\\s+";"")))
      else
        .items += [{tipo: "paragraph", contenido: $l}] | .corte = false
      end)) as $acc
| [ $acc.items[] | if .tipo == "code" then
      {object: "block", type: "code",
       code: {rich_text: (recortar(.contenido) | map(. + {type: "text"})), language: .lenguaje}}
    else
      bloque(.tipo; .contenido)
    end ]
'

# Borra los bloques hijos de una página, uno por uno (DELETE los archiva:
# Notion no ofrece "vaciar" de una sola llamada).
vaciar_bloques() {  # vaciar_bloques <page_id>
  local id=$1 cursor="" page ids bid
  while :; do
    page=$(api GET "/blocks/$id/children?page_size=100${cursor:+&start_cursor=$cursor}") || return
    ids=$(jq -r '.results[].id' <<<"$page")
    while IFS= read -r bid; do
      [ -n "$bid" ] || continue
      api DELETE "/blocks/$bid" >/dev/null || return
    done <<<"$ids"
    [ "$(jq -r '.has_more' <<<"$page")" = "true" ] || break
    cursor=$(jq -r '.next_cursor' <<<"$page")
  done
}

# Agrega el Markdown como bloques hijos, en tandas de 100 (el tope de la API
# por llamada a /children).
agregar_bloques() {  # agregar_bloques <page_id> <markdown>
  local id=$1 md=$2 bloques n total chunk
  bloques=$(jq -nc --arg md "$md" "$MD_BLOQUES") || return
  n=$(jq 'length' <<<"$bloques")
  total=0
  while [ "$total" -lt "$n" ]; do
    chunk=$(jq -c ".[$total:$((total + 100))]" <<<"$bloques")
    api PATCH "/blocks/$id/children" "$(jq -nc --argjson c "$chunk" '{children: $c}')" >/dev/null || return
    total=$((total + 100))
  done
}

cmd_crear_doc() {  # cmd_crear_doc <tarea_id> <proyecto_id> <titulo> <tipo> [rama] [pr]  (cuerpo Markdown por stdin)
  local tarea=$1 proyecto=$2 titulo=$3 tipo=$4 rama=${5:-} pr=${6:-} cuerpo props page id
  cuerpo=$(cat)
  props=$(jq -nc --arg titulo "$titulo" --arg tarea "$tarea" --arg proyecto "$proyecto" \
    --arg tipo "$tipo" --arg rama "$rama" --arg pr "$pr" --arg db "$(db_id documentacion)" '
    {parent: {database_id: $db},
     properties: ({
       "Título": {title: [{text: {content: $titulo}}]},
       "Proyecto": {relation: [{id: $proyecto}]},
       "Tarea": {relation: [{id: $tarea}]},
       "Tipo": {select: {name: $tipo}}
     } + (if $rama == "" then {} else {"Rama": {url: $rama}} end)
       + (if $pr == "" then {} else {"PR": {url: $pr}} end))}') || return
  page=$(api POST "/pages" "$props") || return
  id=$(jq -r .id <<<"$page")
  agregar_bloques "$id" "$cuerpo" || return
  jq -c '{id, url}' <<<"$page"
}

cmd_reemplazar_doc() {  # cmd_reemplazar_doc <page_id> [rama] [pr]  (cuerpo Markdown por stdin)
  local id=$1 rama=${2:-} pr=${3:-} cuerpo props page
  cuerpo=$(cat)
  vaciar_bloques "$id" || return
  agregar_bloques "$id" "$cuerpo" || return
  if [ -n "$rama" ] || [ -n "$pr" ]; then
    props=$(jq -nc --arg rama "$rama" --arg pr "$pr" \
      '{properties: ((if $rama == "" then {} else {"Rama": {url: $rama}} end)
                    + (if $pr == "" then {} else {"PR": {url: $pr}} end))}')
    api PATCH "/pages/$id" "$props" >/dev/null || return
  fi
  page=$(api GET "/pages/$id") || return
  jq -c '{id, url}' <<<"$page"
}

cmd_hijas() {  # cmd_hijas <page_id>
  local filas codigo
  filas=$(query_all "$(db_id tareas)" \
    "$(jq -nc --arg p "$1" '{property: "Padre", relation: {contains: $p}}')") || return
  codigo=$(codigo_de_proyecto "$(jq -r '.[0].properties.Proyecto.relation[0].id // empty' <<<"$filas")")
  jq -c --arg codigo "$codigo" "map($NORMALIZA)" <<<"$filas"
}

# Tareas sueltas: sin Épica, en Lista (DEVKIT-119, grupo 2 de `cola.sh`).
# `hijas` parte de una Épica conocida y `activas`/`epicas` no traen Padre, así
# que ninguna de las dos sirve para encontrar una Tarea sin Padre; de ahí la
# consulta aparte que pedían las Notas de la card. El filtro va en un solo
# "and" de cuatro condiciones (Padre con `is_empty`, no una lista de valores),
# sin anidar "or": mismo límite de dos niveles que documentan `bloqueos` y
# `epicas`.
cmd_sueltas() {  # cmd_sueltas <código>
  local codigo=$1 proy filas
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --arg p "$proy" \
    '{and: [{property: "Proyecto", relation: {contains: $p}},
            {property: "Nivel", select: {equals: "Tarea"}},
            {property: "Estado", select: {equals: "Lista"}},
            {property: "Padre", relation: {is_empty: true}}]}')") || return
  jq -c --arg codigo "$codigo" "map($NORMALIZA)" <<<"$filas"
}

# Tareas sueltas en Backlog (DEVKIT-122, grupo 4 de `cola.sh`, sin bandera
# desde DEVKIT-128): misma consulta que `sueltas`, acotada a Backlog en vez
# de Lista.
cmd_sueltas_backlog() {  # cmd_sueltas_backlog <código>
  local codigo=$1 proy filas
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --arg p "$proy" \
    '{and: [{property: "Proyecto", relation: {contains: $p}},
            {property: "Nivel", select: {equals: "Tarea"}},
            {property: "Estado", select: {equals: "Backlog"}},
            {property: "Padre", relation: {is_empty: true}}]}')") || return
  jq -c --arg codigo "$codigo" "map($NORMALIZA)" <<<"$filas"
}

# Quién frena a quién (DEVKIT-63, ampliación de la card): una sola consulta
# por refresco (el proyecto entero, Lista y Lista para merge juntas) para que
# `devkit-run --estado` no pague una llamada a Notion por fila. El cruce
# "Depende de" se hace acá, en jq, no con una consulta por card.
cmd_bloqueos() {  # cmd_bloqueos <código>
  local codigo=$1 proy filas
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --arg p "$proy" \
    '{and: [{property: "Proyecto", relation: {contains: $p}},
            {or: [{property: "Estado", select: {equals: "Lista para merge"}},
                  {property: "Estado", select: {equals: "Lista"}}]}]}')") || return
  jq -c --arg codigo "$codigo" '
    def clave($n): "\($codigo)-\($n)";
    (map({id, numero: .properties.ID.unique_id.number, estado: .properties.Estado.select.name,
          depende: (.properties["Depende de"].relation // [] | map(.id))})) as $todas
    | [ $todas[] | select(.estado == "Lista para merge") | . as $f
        | {clave: clave($f.numero),
           bloquea_a: [ $todas[] | select(.estado == "Lista" and ((.depende | index($f.id)) != null))
                        | clave(.numero) ]}
        | select(.bloquea_a | length > 0) ]
  ' <<<"$filas"
}

# Épica de origen de cada Tarea (DEVKIT-80, ampliación de DEVKIT-63 que
# quedó pendiente en el PR #53): una sola consulta -las Épicas En progreso
# del proyecto y sus Tareas que no están Hecha- porque `estado_filas` no
# sabe de antemano cuáles Épicas están activas, y acotar el Estado evita
# traer las cards ya cerradas en cada refresco. El filtro repite la rama de
# Proyecto en cada lado del "or" para no anidar tres niveles: la API de
# Notion solo acepta dos (hallazgo H5 de `pr-review` sobre este PR; con tres
# niveles responde 400 y `epicas.cache` nunca se escribe). El cruce
# Tarea → Padre → Épica se hace en jq, mismo patrón que `bloqueos` con
# "Depende de". Cada Épica En progreso también sale como entrada de sí misma
# (epica == epica_titulo de su propia Clave): un lanzamiento sobre la Épica
# (por ejemplo `epic-plan`) se agrupa bajo su propio encabezado, no en
# "(sin Épica)". Acotar las Tareas a Estado != Hecha (en vez de traer las
# hijas de cada Épica activa con una consulta aparte) es una decisión
# deliberada, no un olvido (hallazgo H6 de `pr-review`): una Tarea ya Hecha
# cuya Épica sigue activa cae en "(sin Épica)" en vez de agruparse.
cmd_epicas() {  # cmd_epicas <código>
  local codigo=$1 proy filas
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --arg p "$proy" \
    '{or: [{and: [{property: "Proyecto", relation: {contains: $p}},
                  {property: "Nivel", select: {equals: "Épica"}},
                  {property: "Estado", select: {equals: "En progreso"}}]},
           {and: [{property: "Proyecto", relation: {contains: $p}},
                  {property: "Nivel", select: {equals: "Tarea"}},
                  {property: "Estado", select: {does_not_equal: "Hecha"}}]}]}')") || return
  jq -c --arg codigo "$codigo" '
    def clave($n): "\($codigo)-\($n)";
    def titulo: (.properties["Título"].title // []) | map(.plain_text) | join("");
    (map({id, numero: .properties.ID.unique_id.number, estado: .properties.Estado.select.name,
          nivel: .properties.Nivel.select.name, titulo: titulo,
          padre: ((.properties.Padre.relation // [])[0].id)})) as $todas
    | (reduce ($todas[] | select(.nivel == "Épica" and .estado == "En progreso")) as $e
        ({}; . + {($e.id): {clave: clave($e.numero), titulo: $e.titulo}})) as $epicas
    | ([ $todas[] | select(.nivel == "Tarea" and .padre != null and ($epicas[.padre] // null) != null)
        | {clave: clave(.numero), epica: $epicas[.padre].clave, epica_titulo: $epicas[.padre].titulo} ]
      + [ $epicas[] | {clave: .clave, epica: .clave, epica_titulo: .titulo} ])
  ' <<<"$filas"
}

# Texto de la sección "Criterios de aceptación": los bloques entre ese
# encabezado y el siguiente encabezado, uno por línea. Puro sobre la lista de
# bloques, para la autoprueba.
CRITERIOS='
def texto: (.[.type].rich_text // []) | map(.plain_text) | join("");
def encabezado: .type | test("^heading_[123]$");
(to_entries
 | map(select((.value | encabezado)
              and (.value | texto | ascii_downcase | test("^\\s*criterios de aceptaci")))))
  as $inicio
| if ($inicio | length) == 0 then ""
  else
    .[($inicio[0].key + 1):] as $resto
    | ([$resto | to_entries[] | select(.value | encabezado) | .key] | first // ($resto | length)) as $fin
    | $resto[:$fin] | map(texto) | map(select(. != "")) | join("\n")
  end
'

# Cards activas del proyecto para el tablero de `devkit-run --tablero`
# (DEVKIT-82): una sola consulta, sin cruces -"bloquea a" y la Épica de
# origen ya los trae `devkit-run` por su cuenta con `bloqueos`/`epicas`,
# cacheados y compartidos con `--estado`, así que repetirlos aquí duplicaría
# la llamada a Notion sin necesidad.
cmd_activas() {  # cmd_activas <código>
  local codigo=$1 proy filas
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --arg p "$proy" \
    '{and: [{property: "Proyecto", relation: {contains: $p}},
            {or: [{property: "Estado", select: {equals: "Lista"}},
                  {property: "Estado", select: {equals: "En progreso"}},
                  {property: "Estado", select: {equals: "Revisión automática"}},
                  {property: "Estado", select: {equals: "Lista para merge"}},
                  {property: "Estado", select: {equals: "Bloqueada"}}]}]}')") || return
  jq -c --arg codigo "$codigo" '
    def clave($n): "\($codigo)-\($n)";
    [ .[] | {clave: clave(.properties.ID.unique_id.number), numero: .properties.ID.unique_id.number,
             estado: .properties.Estado.select.name, tipo: .properties.Tipo.select.name,
             nivel: .properties.Nivel.select.name, pr: (.properties.PR.url // "")} ]
    | sort_by(.numero) | map(del(.numero))
  ' <<<"$filas"
}

# Épicas en Lista o En progreso (DEVKIT-121): las que pueden tener hijas
# esperando en Backlog. A diferencia de `epicas`, que solo mira las En
# progreso y no trae `id` (arma la agrupación del tablero en jq), esta sí lo
# necesita: quien llama pide después las hijas de cada una con `hijas <id>`.
cmd_epicas_abiertas() {  # cmd_epicas_abiertas <código>
  local codigo=$1 proy filas
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --arg p "$proy" \
    '{and: [{property: "Proyecto", relation: {contains: $p}},
            {property: "Nivel", select: {equals: "Épica"}},
            {or: [{property: "Estado", select: {equals: "Lista"}},
                  {property: "Estado", select: {equals: "En progreso"}}]}]}')") || return
  jq -c --arg codigo "$codigo" "map($NORMALIZA)" <<<"$filas"
}

# Épicas en Backlog (DEVKIT-122, grupo 3 de `cola.sh`, sin bandera desde
# DEVKIT-128): misma forma que `epicas-abiertas`, acotada a Backlog en vez
# de Lista/En progreso.
cmd_epicas_backlog() {  # cmd_epicas_backlog <código>
  local codigo=$1 proy filas
  proy=$(proyecto_id "$codigo") || return
  [ -n "$proy" ] || { err "no hay proyecto con Código $codigo"; return 1; }
  filas=$(query_all "$(db_id tareas)" "$(jq -nc --arg p "$proy" \
    '{and: [{property: "Proyecto", relation: {contains: $p}},
            {property: "Nivel", select: {equals: "Épica"}},
            {property: "Estado", select: {equals: "Backlog"}}]}')") || return
  jq -c --arg codigo "$codigo" "map($NORMALIZA)" <<<"$filas"
}

cmd_criterios() {  # cmd_criterios <page_id>
  local cursor="" page acc='[]'
  while :; do
    page=$(api GET "/blocks/$1/children?page_size=100${cursor:+&start_cursor=$cursor}") || return
    acc=$(jq -c --argjson p "$page" '. + $p.results' <<<"$acc")
    [ "$(jq -r '.has_more' <<<"$page")" = "true" ] || break
    cursor=$(jq -r '.next_cursor' <<<"$page")
  done
  jq -r "$CRITERIOS" <<<"$acc"
}

# Toda la página en Markdown plano (DEVKIT-90): a diferencia de CRITERIOS, que
# recorta a una sección, esto recorre todos los bloques de nivel superior y
# los vuelca en orden. Cubre los tipos de bloque que aparecen en una card
# (encabezados, párrafos, listas, cita, código); cualquier otro tipo cae al
# texto plano de su rich_text, que suele bastar.
#
# No desciende a los hijos de un bloque (una sub-viñeta, un toggle, una
# columna): H5 de pr-review en esta misma card. En vez de perder ese
# contenido en silencio, marca la línea para que quien lea el volcado (el
# agente de task-start, sin acceso a Notion) sepa que falta algo en vez de
# asumir que el bloque no tenía más que su primera línea.
CONTENIDO='
def texto: (.[.type].rich_text // []) | map(.plain_text) | join("");
def linea:
  if .type == "heading_1" then "# " + texto
  elif .type == "heading_2" then "## " + texto
  elif .type == "heading_3" then "### " + texto
  elif .type == "bulleted_list_item" or .type == "numbered_list_item" or .type == "to_do" then "- " + texto
  elif .type == "quote" then "> " + texto
  else texto
  end;
[ .[] | linea as $l |
  if $l != "" then
    if .has_children then $l + "\n  (bloque con contenido anidado omitido)" else $l end
  elif .has_children then "(bloque con contenido anidado omitido)"
  else empty
  end
] | join("\n")
'

cmd_contenido() {  # cmd_contenido <page_id>
  local cursor="" page acc='[]'
  while :; do
    page=$(api GET "/blocks/$1/children?page_size=100${cursor:+&start_cursor=$cursor}") || return
    acc=$(jq -c --argjson p "$page" '. + $p.results' <<<"$acc")
    [ "$(jq -r '.has_more' <<<"$page")" = "true" ] || break
    cursor=$(jq -r '.next_cursor' <<<"$page")
  done
  jq -r "$CONTENIDO" <<<"$acc"
}

# Comentarios de la página, en orden cronológico (el orden que ya devuelve la
# API). Paginado aparte de query_all: /comments no va por POST con filtro,
# sino por GET con start_cursor en la query string.
cmd_comentarios() {  # cmd_comentarios <page_id>
  local cursor="" page acc='[]'
  while :; do
    page=$(api GET "/comments?block_id=$1&page_size=100${cursor:+&start_cursor=$cursor}") || return
    acc=$(jq -c --argjson p "$page" '. + $p.results' <<<"$acc")
    [ "$(jq -r '.has_more' <<<"$page")" = "true" ] || break
    cursor=$(jq -r '.next_cursor' <<<"$page")
  done
  jq -r '[ .[] | ((.rich_text // []) | map(.plain_text) | join("")) | select(. != "") ] | join("\n\n")' <<<"$acc"
}

run_tests() {
  local fail=0 tmp got
  check() {
    if [ "$2" = "$3" ]; then
      printf 'ok   %-58s %s\n' "$1" "$(printf '%s' "$3" | head -1 | cut -c1-60)"
    else
      printf 'FAIL %-58s esperado %s, obtenido %s\n' "$1" "$2" "${3:-<vacío>}"
      fail=1
    fi
  }
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Un doble de curl que anota cada llamada (método, ruta, cuerpo y la
  # cabecera de autorización que recibió por descriptor) y responde según la
  # ruta con archivos de $tmp/resp. Ninguna llamada sale a la red.
  mkdir -p "$tmp/resp"
  cat >"$tmp/curl" <<'FIN'
#!/usr/bin/env bash
metodo=GET url="" cuerpo="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) metodo=$2; shift 2 ;;
    -H) case "$2" in @*) auth=$(cat "${2#@}") ;; esac; shift 2 ;;
    --data-binary) cuerpo=$2; shift 2 ;;
    -w|-o) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
ruta=${url#*v1}
printf '%s %s %s\n' "$metodo" "$ruta" "$cuerpo" >>"$FAKE_DIR/llamadas"
printf '%s\n' "$auth" >>"$FAKE_DIR/auth"
clave=$(printf '%s %s' "$metodo" "${ruta%%\?*}" | tr '/ ' '__')
if [ -f "$FAKE_DIR/resp/$clave" ]; then
  cat "$FAKE_DIR/resp/$clave"; printf '\n%s' "$(cat "$FAKE_DIR/resp/$clave.code" 2>/dev/null || echo 200)"
else
  printf '{"object":"error","message":"sin respuesta de prueba para %s"}\n404' "$clave"
fi
FIN
  chmod +x "$tmp/curl"
  printf 'secreto-de-prueba\n' >"$tmp/token"
  cat >"$tmp/ids.json" <<'FIN'
{"proyectos": {"database_id": "dbproy"}, "tareas": {"database_id": "dbtareas"},
 "documentacion": {"database_id": "dbdoc"}}
FIN
  local entorno=(FAKE_DIR="$tmp" DEVKIT_CURL_BIN="$tmp/curl" DEVKIT_NOTION_TOKEN_FILE="$tmp/token"
                 DEVKIT_NOTION_IDS="$tmp/ids.json" DEVKIT_NOTION_RETRIES=2)
  resp() { printf '%s' "$2" >"$tmp/resp/$1"; [ -z "${3:-}" ] || printf '%s' "$3" >"$tmp/resp/$1.code"; }

  resp POST__databases_dbproy_query '{"results":[{"id":"proy-1","properties":{"Código":{"rich_text":[{"plain_text":"DEVKIT"}]}}}],"has_more":false}'
  local card='{"id":"card-55","url":"https://www.notion.so/card55","properties":{
    "ID":{"type":"unique_id","unique_id":{"number":55}},
    "Título":{"type":"title","title":[{"plain_text":"Notion por token"}]},
    "Estado":{"type":"select","select":{"name":"Lista para merge"}},
    "Nivel":{"type":"select","select":{"name":"Tarea"}},
    "Tipo":{"type":"select","select":{"name":"feature"}},
    "Prioridad":{"type":"select","select":{"name":"alta"}},
    "Orden":{"type":"number","number":2},
    "PR":{"type":"url","url":null},
    "Rama":{"type":"url","url":"https://github.com/o/r/tree/feat/DEVKIT-55-x"},
    "Cierre":{"type":"date","date":null},
    "Padre":{"type":"relation","relation":[{"id":"epica-52"}]},
    "Depende de":{"type":"relation","relation":[{"id":"card-54"}]},
    "Documentación":{"type":"relation","relation":[]},
    "Proyecto":{"type":"relation","relation":[{"id":"proy-1"}]}}}'
  resp POST__databases_dbtareas_query "{\"results\":[$card],\"has_more\":false}"

  got=$(env "${entorno[@]}" bash "$HERE/notion.sh" card DEVKIT-55)
  check "card: clave armada con Código e ID" "DEVKIT-55" "$(jq -r .clave <<<"$got")"
  check "card: estado, nivel y padre" "Lista para merge Tarea epica-52" \
    "$(jq -r '"\(.estado) \(.nivel) \(.padre[0])"' <<<"$got")"
  check "card: filtra por ID y por Proyecto, no por la fórmula Clave" \
    '{"and":[{"property":"ID","unique_id":{"equals":55}},{"property":"Proyecto","relation":{"contains":"proy-1"}}]}' \
    "$(grep 'dbtareas' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"
  check "el token viaja como cabecera por descriptor" "Authorization: Bearer secreto-de-prueba" \
    "$(tail -1 "$tmp/auth")"
  check "el token no aparece en ningún argumento de curl" 0 \
    "$(grep -c 'secreto-de-prueba' "$tmp/llamadas")"

  env "${entorno[@]}" bash "$HERE/notion.sh" card DEVKIT-x >/dev/null 2>&1
  check "card: Clave sin número sale con 64" 64 "$?"

  # set: el tipo de cada propiedad sale de la página.
  resp GET__pages_card-55 "$card"
  resp PATCH__pages_card-55 '{"object":"page"}'
  env "${entorno[@]}" bash "$HERE/notion.sh" set card-55 Estado=Hecha Cierre=2026-09-16 PR=https://github.com/o/r/pull/9 Rama=
  check "set: arma cada propiedad según su tipo" \
    '{"properties":{"Estado":{"select":{"name":"Hecha"}},"Cierre":{"date":{"start":"2026-09-16"}},"PR":{"url":"https://github.com/o/r/pull/9"},"Rama":{"url":null}}}' \
    "$(grep '^PATCH' "$tmp/llamadas" | tail -1 | cut -d' ' -f3-)"
  env "${entorno[@]}" bash "$HERE/notion.sh" set card-55 Inventada=1 >/dev/null 2>&1
  check "set: propiedad desconocida sale con 64 sin escribir" "64 1" \
    "$? $(grep -c '^PATCH' "$tmp/llamadas")"

  # comentar: las URL como enlace, sin la puntuación final.
  resp POST__comments '{"object":"comment"}'
  env "${entorno[@]}" bash "$HERE/notion.sh" comentar card-55 "Cerrada. Documentación: https://www.notion.so/doc1."
  check "comentar: URL como enlace y el punto final fuera" \
    '[{"text":{"content":"Cerrada. Documentación: "}},{"text":{"content":"https://www.notion.so/doc1","link":{"url":"https://www.notion.so/doc1"}}},{"text":{"content":"."}}]' \
    "$(grep '^POST /comments' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .rich_text)"
  got=$(jq -nc --arg texto "$(printf 'a%.0s' $(seq 1 4500))" "$RICH_TEXT" | jq -c 'map(.text.content | length)')
  check "comentar: tramos de 2000 caracteres como máximo" "[2000,2000,500]" "$got"

  # documentacion: por la relación Tarea.
  resp POST__databases_dbdoc_query '{"results":[{"id":"doc-1","url":"https://www.notion.so/doc1"}],"has_more":false}'
  check "documentacion: encuentra la entrada por la relación Tarea" \
    '{"id":"doc-1","url":"https://www.notion.so/doc1"}' \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" documentacion card-55)"
  check "documentacion: filtro por Tarea" '{"property":"Tarea","relation":{"contains":"card-55"}}' \
    "$(grep 'dbdoc' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"
  resp POST__databases_dbdoc_query '{"results":[],"has_more":false}'
  env "${entorno[@]}" bash "$HERE/notion.sh" documentacion card-55 >/dev/null
  check "documentacion: sin entrada sale con 1" 1 "$?"

  # documentacion: con clave, descarta una entrada de referencia que
  # comparte la relación Tarea con la entrada de la card (DEVKIT-87).
  resp POST__databases_dbdoc_query '{"results":[
    {"id":"doc-ref","url":"https://www.notion.so/docref","properties":{"Título":{"title":[{"plain_text":"Arquitectura del devkit (referencia congelada)"}]}}},
    {"id":"doc-1","url":"https://www.notion.so/doc1","properties":{"Título":{"title":[{"plain_text":"DEVKIT-55: Notion por token"}]}}}
  ],"has_more":false}'
  check "documentacion: con clave, elige la entrada '<Clave>: ...'" \
    '{"id":"doc-1","url":"https://www.notion.so/doc1"}' \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" documentacion card-55 DEVKIT-55)"
  env "${entorno[@]}" bash "$HERE/notion.sh" documentacion card-55 DEVKIT-99 >/dev/null
  check "documentacion: con clave sin entrada propia sale con 1" 1 "$?"

  # MD_BLOQUES: Markdown de task-document.sh a bloques de Notion (DEVKIT-92).
  # Puro, sin red: encabezados, párrafo, lista y código, con el resto del
  # Markdown que no genera task-document.sh cayendo a párrafo.
  got=$(jq -nc --arg md '## Qué cambió
Una línea de párrafo.
- uno
- dos
```sh
echo hola
echo chau
```
### Enlaces' "$MD_BLOQUES")
  check "MD_BLOQUES: tipos de bloque en orden" \
    '["heading_2","paragraph","bulleted_list_item","bulleted_list_item","code","heading_3"]' \
    "$(jq -c '[.[].type]' <<<"$got")"
  check "MD_BLOQUES: el código conserva las dos líneas y el lenguaje" \
    '{"lang":"sh","texto":"echo hola\necho chau"}' \
    "$(jq -c '.[4].code | {lang: .language, texto: (.rich_text[0].text.content)}' <<<"$got")"
  check "MD_BLOQUES: una línea en blanco no deja bloque vacío" 6 "$(jq 'length' <<<"$got")"

  # H3 (informe del PR 66): líneas cortadas a columna fija -como las que
  # arma task-document.sh a partir del cuerpo del PR- se unen al párrafo o al
  # ítem de lista anterior, no quedan como bloques sueltos.
  got=$(jq -nc --arg md 'Primero.
Segundo.
Tercero.
- uno
  continuación de uno' "$MD_BLOQUES")
  check "MD_BLOQUES: líneas seguidas de un párrafo se unen con un espacio" \
    '"Primero. Segundo. Tercero."' \
    "$(jq -c '.[0].paragraph.rich_text[0].text.content' <<<"$got")"
  check "MD_BLOQUES: la continuación sangrada de una viñeta se une a su ítem" \
    '"uno continuación de uno"' \
    "$(jq -c '.[1].bulleted_list_item.rich_text[0].text.content' <<<"$got")"

  # H7 (informe del PR 66): la línea en blanco corta la continuación, aun
  # cuando el texto que sigue podría unirse a un párrafo o a una viñeta.
  got=$(jq -nc --arg md 'Primero.

Segundo.' "$MD_BLOQUES")
  check "MD_BLOQUES: dos párrafos separados por una línea en blanco no se unen" \
    '["Primero.","Segundo."]' \
    "$(jq -c '[.[].paragraph.rich_text[0].text.content]' <<<"$got")"
  got=$(jq -nc --arg md '- uno

Después de la lista.' "$MD_BLOQUES")
  check "MD_BLOQUES: una viñeta seguida de línea en blanco y párrafo no se pegan" \
    '["bulleted_list_item","paragraph"]' \
    "$(jq -c '[.[].type]' <<<"$got")"
  check "MD_BLOQUES: el párrafo tras la línea en blanco conserva su propio texto" \
    '"Después de la lista."' \
    "$(jq -c '.[1].paragraph.rich_text[0].text.content' <<<"$got")"

  # H2 (informe del PR 66): un bloque de más de 2000 caracteres -código o
  # texto- se corta en varios objetos rich_text, como ya hacía RICH_TEXT
  # para los comentarios del PR.
  largo=$(printf 'a%.0s' $(seq 1 2500))
  got=$(jq -nc --arg md "\`\`\`
$largo
\`\`\`" "$MD_BLOQUES")
  check "MD_BLOQUES: un bloque de código de más de 2000 caracteres se corta en tramos" \
    "[2000,500]" \
    "$(jq -c '.[0].code.rich_text | map(.text.content | length)' <<<"$got")"

  # crear-doc: crea la página con sus propiedades y agrega el Markdown como
  # bloques hijos.
  resp POST__pages '{"id":"doc-nueva","url":"https://www.notion.so/docnueva"}'
  resp PATCH__blocks_doc-nueva_children '{"results":[]}'
  got=$(printf '## Qué cambió\nAlgo nuevo.' \
    | env "${entorno[@]}" bash "$HERE/notion.sh" crear-doc card-55 proy-1 "DEVKIT-55: Notion por token" cambio \
        https://github.com/o/r/tree/feat/DEVKIT-55-x https://github.com/o/r/pull/9)
  check "crear-doc: {id,url} de la página nueva" '{"id":"doc-nueva","url":"https://www.notion.so/docnueva"}' "$got"
  check "crear-doc: propiedades con Tarea, Proyecto, Tipo, Rama y PR" \
    '{"parent":{"database_id":"dbdoc"},"properties":{"Título":{"title":[{"text":{"content":"DEVKIT-55: Notion por token"}}]},"Proyecto":{"relation":[{"id":"proy-1"}]},"Tarea":{"relation":[{"id":"card-55"}]},"Tipo":{"select":{"name":"cambio"}},"Rama":{"url":"https://github.com/o/r/tree/feat/DEVKIT-55-x"},"PR":{"url":"https://github.com/o/r/pull/9"}}}' \
    "$(grep '^POST /pages ' "$tmp/llamadas" | tail -1 | cut -d' ' -f3-)"
  check "crear-doc: agrega el cuerpo como bloques hijos de la página nueva" 1 \
    "$(grep -c '^PATCH /blocks/doc-nueva/children' "$tmp/llamadas")"

  # reemplazar-doc: vacía los bloques existentes (DELETE, uno por uno),
  # agrega los nuevos y solo toca Rama/PR si llegan.
  resp GET__blocks_doc-1_children '{"results":[{"id":"b1"},{"id":"b2"}],"has_more":false}'
  resp DELETE__blocks_b1 '{"id":"b1"}'
  resp DELETE__blocks_b2 '{"id":"b2"}'
  resp PATCH__blocks_doc-1_children '{"results":[]}'
  resp PATCH__pages_doc-1 '{"object":"page"}'
  resp GET__pages_doc-1 '{"id":"doc-1","url":"https://www.notion.so/doc1"}'
  : >"$tmp/llamadas"
  got=$(printf '## Qué cambió\nOtra vez.' \
    | env "${entorno[@]}" bash "$HERE/notion.sh" reemplazar-doc doc-1 "" https://github.com/o/r/pull/10)
  check "reemplazar-doc: {id,url} de la página" '{"id":"doc-1","url":"https://www.notion.so/doc1"}' "$got"
  check "reemplazar-doc: borra cada bloque existente" 2 "$(grep -cE '^DELETE /blocks/b[12] ' "$tmp/llamadas")"
  check "reemplazar-doc: agrega el Markdown nuevo" 1 "$(grep -c '^PATCH /blocks/doc-1/children' "$tmp/llamadas")"
  check "reemplazar-doc: sin Rama, solo actualiza PR" '{"properties":{"PR":{"url":"https://github.com/o/r/pull/10"}}}' \
    "$(grep '^PATCH /pages/doc-1 ' "$tmp/llamadas" | cut -d' ' -f3-)"
  : >"$tmp/llamadas"
  got=$(printf 'x' | env "${entorno[@]}" bash "$HERE/notion.sh" reemplazar-doc doc-1)
  check "reemplazar-doc: sin Rama ni PR no toca las propiedades de la página" 0 \
    "$(grep -c '^PATCH /pages/doc-1 ' "$tmp/llamadas")"

  # criterios: la sección entre su encabezado y el siguiente.
  local bloques='[
    {"type":"heading_2","heading_2":{"rich_text":[{"plain_text":"Objetivo"}]}},
    {"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"algo"}]}},
    {"type":"heading_2","heading_2":{"rich_text":[{"plain_text":"Criterios de aceptación"}]}},
    {"type":"numbered_list_item","numbered_list_item":{"rich_text":[{"plain_text":"uno"}]}},
    {"type":"paragraph","paragraph":{"rich_text":[]}},
    {"type":"bulleted_list_item","bulleted_list_item":{"rich_text":[{"plain_text":"dos"}]}},
    {"type":"heading_2","heading_2":{"rich_text":[{"plain_text":"Notas"}]}},
    {"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"fuera"}]}}]'
  check "criterios: solo los bloques de la sección" "uno
dos" "$(jq -r "$CRITERIOS" <<<"$bloques")"
  check "criterios: sin sección, vacío" "" \
    "$(jq -r "$CRITERIOS" <<<'[{"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"x"}]}}]')"
  check "criterios: sección al final de la página" "tres" \
    "$(jq -r "$CRITERIOS" <<<'[{"type":"heading_3","heading_3":{"rich_text":[{"plain_text":"Criterios de aceptación"}]}},{"type":"to_do","to_do":{"rich_text":[{"plain_text":"tres"}]}}]')"

  # contenido: toda la página, no solo una sección (DEVKIT-90).
  resp GET__blocks_card-90_children "{\"results\":$bloques,\"has_more\":false}"
  check "contenido: encabezados y texto de toda la página, en orden" \
    "## Objetivo
algo
## Criterios de aceptación
- uno
- dos
## Notas
fuera" \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" contenido card-90)"

  # contenido: un bloque con hijos (sub-viñeta, toggle, columna) no desciende
  # a ellos, así que avisa en vez de perder ese contenido en silencio (H5 de
  # pr-review en DEVKIT-90).
  resp GET__blocks_card-91_children '{"results":[
    {"type":"bulleted_list_item","has_children":true,"bulleted_list_item":{"rich_text":[{"plain_text":"uno con hijos"}]}},
    {"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"sin hijos"}]}}],"has_more":false}'
  check "contenido: un bloque con hijos avisa que quedó contenido anidado sin volcar" \
    "- uno con hijos
  (bloque con contenido anidado omitido)
sin hijos" \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" contenido card-91)"

  # contenido: un bloque sin texto propio (column_list, table, toggle vacío)
  # también avisa en vez de desaparecer sin dejar rastro (H8 de pr-review en
  # DEVKIT-90, reapertura de H5: `select($l != "")` lo descartaba antes de
  # mirar has_children).
  resp GET__blocks_card-92_children '{"results":[
    {"type":"column_list","has_children":true,"column_list":{}},
    {"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"después"}]}}],"has_more":false}'
  check "contenido: un bloque sin texto propio pero con hijos avisa igual" \
    "(bloque con contenido anidado omitido)
después" \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" contenido card-92)"

  # comentarios: orden cronológico, tal como los devuelve la API.
  resp GET__comments '{"results":[
    {"rich_text":[{"plain_text":"Primer comentario"}]},
    {"rich_text":[{"plain_text":"Segundo, con "},{"plain_text":"dos tramos"}]}
  ],"has_more":false}'
  check "comentarios: todos, en el orden de la API" \
    "Primer comentario

Segundo, con dos tramos" \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" comentarios card-90)"
  check "comentarios: filtra por block_id en la query" 1 \
    "$(grep -c '^GET /comments?block_id=card-90' "$tmp/llamadas")"

  # Errores: el mensaje de Notion, sin la petición; reintento en 429.
  resp GET__pages_roto '{"object":"error","message":"Could not find page"}' 404
  got=$(env "${entorno[@]}" bash "$HERE/notion.sh" pagina roto 2>&1 >/dev/null)
  check "error: código y mensaje de Notion" "notion.sh: GET /pages/roto: HTTP 404: Could not find page" "$got"
  # Sin conexión curl no trae JSON y el código es 000: el error lleva el texto
  # de curl, que es lo que permite reconocer un "connection refused" del proxy.
  resp GET__pages_sin-red 'curl: (7) Failed to connect to api.notion.com port 443: Connection refused' 000
  got=$(env "${entorno[@]}" bash "$HERE/notion.sh" pagina sin-red 2>&1 >/dev/null)
  check "error: sin conexión muestra el texto de curl" \
    "notion.sh: GET /pages/sin-red: HTTP 000: curl: (7) Failed to connect to api.notion.com port 443: Connection refused" "$got"
  resp GET__pages_lento '{"object":"error","message":"rate limited"}' 429
  : >"$tmp/llamadas"
  env "${entorno[@]}" bash "$HERE/notion.sh" pagina lento >/dev/null 2>&1
  check "429: reintenta hasta el tope y falla" 2 "$(grep -c 'pages/lento' "$tmp/llamadas")"
  env "${entorno[@]}" DEVKIT_NOTION_TOKEN_FILE="$tmp/no-existe" bash "$HERE/notion.sh" pagina x >/dev/null 2>&1
  check "sin token: sale con 3 sin llamar a la API" 3 "$?"

  # bloqueos: DEVKIT-62 (Lista para merge) frena a DEVKIT-63 (Lista, depende
  # de ella). DEVKIT-70 depende de DEVKIT-61, que no está Lista para merge en
  # este recorte: no cuenta. DEVKIT-99 no frena a nadie: no sale en la lista.
  tarea() {  # tarea <id> <numero> <estado> <depende (ids separados por coma)>
    jq -nc --arg id "$1" --argjson n "$2" --arg e "$3" --arg dep "$4" \
      '{id: $id, properties: {ID: {unique_id: {number: $n}}, Estado: {select: {name: $e}},
        "Depende de": {relation: ($dep | split(",") | map(select(. != "") | {id: .}))}}}'
  }
  resp POST__databases_dbtareas_query "{\"results\":[$(tarea card-62 62 "Lista para merge" ""),\
$(tarea card-63 63 Lista card-62),$(tarea card-70 70 Lista card-61),\
$(tarea card-99 99 "Lista para merge" "")],\"has_more\":false}"
  check "bloqueos: DEVKIT-62 frena a DEVKIT-63" '[{"clave":"DEVKIT-62","bloquea_a":["DEVKIT-63"]}]' \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" bloqueos DEVKIT)"

  # epicas: DEVKIT-57 y DEVKIT-58 son hijas de la Épica DEVKIT-50, En
  # progreso: salen con su Clave y título. DEVKIT-59 es hija de DEVKIT-51,
  # que no está En progreso: no sale. DEVKIT-60 no tiene Padre: no sale.
  # DEVKIT-50 también sale como entrada de sí misma (H4 de pr-review sobre
  # el PR #57): un lanzamiento sobre la Épica se agrupa bajo su encabezado.
  epica() {  # epica <id> <numero> <estado>
    jq -nc --arg id "$1" --argjson n "$2" --arg e "$3" \
      '{id: $id, properties: {ID: {unique_id: {number: $n}}, Nivel: {select: {name: "Épica"}},
        Estado: {select: {name: $e}}, "Título": {title: [{plain_text: ("Épica " + ($n | tostring))}]},
        Padre: {relation: []}}}'
  }
  hija() {  # hija <id> <numero> <padre_id o vacío>
    jq -nc --arg id "$1" --argjson n "$2" --arg padre "$3" \
      '{id: $id, properties: {ID: {unique_id: {number: $n}}, Nivel: {select: {name: "Tarea"}},
        Estado: {select: {name: "En progreso"}}, "Título": {title: [{plain_text: "hija"}]},
        Padre: {relation: ($padre | if . == "" then [] else [{id: .}] end)}}}'
  }
  resp POST__databases_dbtareas_query "{\"results\":[$(epica epica-50 50 "En progreso"),\
$(epica epica-51 51 Lista),$(hija card-57 57 epica-50),$(hija card-58 58 epica-50),\
$(hija card-59 59 epica-51),$(hija card-60 60 "")],\"has_more\":false}"
  check "epicas: Tareas de una Épica En progreso, con Clave y título, y la Épica misma" \
    '[{"clave":"DEVKIT-57","epica":"DEVKIT-50","epica_titulo":"Épica 50"},{"clave":"DEVKIT-58","epica":"DEVKIT-50","epica_titulo":"Épica 50"},{"clave":"DEVKIT-50","epica":"DEVKIT-50","epica_titulo":"Épica 50"}]' \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" epicas DEVKIT)"
  # El filtro repite la rama de Proyecto en cada lado del "or" para no
  # anidar tres niveles: la API de Notion solo acepta dos y con tres
  # responde 400 sin que el doble de curl -que no valida el cuerpo- lo note
  # (hallazgo H5 de `pr-review` sobre el PR #57).
  check "epicas: el filtro no anida tres niveles" \
    '{"or":[{"and":[{"property":"Proyecto","relation":{"contains":"proy-1"}},{"property":"Nivel","select":{"equals":"Épica"}},{"property":"Estado","select":{"equals":"En progreso"}}]},{"and":[{"property":"Proyecto","relation":{"contains":"proy-1"}},{"property":"Nivel","select":{"equals":"Tarea"}},{"property":"Estado","select":{"does_not_equal":"Hecha"}}]}]}' \
    "$(grep 'dbtareas' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"

  # activas: tablero de `devkit-run --tablero` (DEVKIT-82). El filtro de
  # Estado lo aplica la API real; el doble de curl no filtra por cuerpo, así
  # que la prueba solo pone en el fixture lo que ese filtro dejaría pasar
  # (DEVKIT-90, Hecha, quedaría fuera y por eso no entra aquí) y comprueba el
  # filtro enviado aparte, como hace la prueba de `epicas`.
  activa() {  # activa <id> <numero> <estado> <tipo> <pr> <nivel>
    jq -nc --arg id "$1" --argjson n "$2" --arg e "$3" --arg t "$4" --arg pr "$5" --arg nv "$6" \
      '{id: $id, properties: {ID: {unique_id: {number: $n}}, Estado: {select: {name: $e}},
        Tipo: {select: {name: $t}}, Nivel: {select: {name: $nv}},
        PR: {url: (if $pr == "" then null else $pr end)}}}'
  }
  resp POST__databases_dbtareas_query "{\"results\":[$(activa card-89 89 "Lista para merge" bug https://github.com/o/r/pull/9 Tarea),\
$(activa card-88 88 "En progreso" feature "" Épica)],\"has_more\":false}"
  check "activas: ordenadas por número, con Clave/Estado/Tipo/Nivel/PR" \
    '[{"clave":"DEVKIT-88","estado":"En progreso","tipo":"feature","nivel":"Épica","pr":""},{"clave":"DEVKIT-89","estado":"Lista para merge","tipo":"bug","nivel":"Tarea","pr":"https://github.com/o/r/pull/9"}]' \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" activas DEVKIT)"
  check "activas: el filtro cubre los cinco Estados activos" \
    '{"and":[{"property":"Proyecto","relation":{"contains":"proy-1"}},{"or":[{"property":"Estado","select":{"equals":"Lista"}},{"property":"Estado","select":{"equals":"En progreso"}},{"property":"Estado","select":{"equals":"Revisión automática"}},{"property":"Estado","select":{"equals":"Lista para merge"}},{"property":"Estado","select":{"equals":"Bloqueada"}}]}]}' \
    "$(grep 'dbtareas' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"

  # epicas-abiertas (DEVKIT-121): Épicas en Lista o En progreso, con id -a
  # diferencia de `epicas`, que solo trae las En progreso y sin id-, para que
  # `watch.sh` pida después sus hijas.
  resp POST__databases_dbtareas_query "{\"results\":[$(epica epica-50 50 "En progreso"),\
$(epica epica-51 51 Lista)],\"has_more\":false}"
  check "epicas-abiertas: las Épicas en Lista y En progreso, con id" \
    '[{"id":"epica-50","clave":"DEVKIT-50","estado":"En progreso"},{"id":"epica-51","clave":"DEVKIT-51","estado":"Lista"}]' \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" epicas-abiertas DEVKIT | jq -c '[.[] | {id, clave, estado}]')"
  check "epicas-abiertas: el filtro es Nivel Épica y Estado Lista o En progreso" \
    '{"and":[{"property":"Proyecto","relation":{"contains":"proy-1"}},{"property":"Nivel","select":{"equals":"Épica"}},{"or":[{"property":"Estado","select":{"equals":"Lista"}},{"property":"Estado","select":{"equals":"En progreso"}}]}]}' \
    "$(grep 'dbtareas' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"

  # sueltas (DEVKIT-119): Tareas en Lista sin Padre, grupo 2 de `cola.sh`. El
  # filtro es un solo "and" de cuatro condiciones (sin "or" que anidar) y
  # Padre va por `is_empty`, no por una lista de valores a excluir.
  resp POST__databases_dbtareas_query '{"results":[{"id":"card-70","created_time":"2026-01-02T00:00:00.000Z",
    "properties":{"ID":{"unique_id":{"number":70}},"Título":{"title":[{"plain_text":"suelta"}]},
    "Estado":{"select":{"name":"Lista"}},"Nivel":{"select":{"name":"Tarea"}},
    "Prioridad":{"select":{"name":"alta"}},"Orden":{"number":1},
    "Agente":{"select":{"name":"claude"}},"Padre":{"relation":[]},
    "Depende de":{"relation":[]}}}],"has_more":false}'
  got=$(env "${entorno[@]}" bash "$HERE/notion.sh" sueltas DEVKIT)
  check "sueltas: Clave, Prioridad, Orden, Agente y Creado de una tarea sin Padre" \
    '{"clave":"DEVKIT-70","prioridad":"alta","orden":1,"agente":"claude","creado":"2026-01-02T00:00:00.000Z"}' \
    "$(jq -c '.[0] | {clave,prioridad,orden,agente,creado}' <<<"$got")"
  check "sueltas: el filtro no anida un \"or\", Padre por is_empty" \
    '{"and":[{"property":"Proyecto","relation":{"contains":"proy-1"}},{"property":"Nivel","select":{"equals":"Tarea"}},{"property":"Estado","select":{"equals":"Lista"}},{"property":"Padre","relation":{"is_empty":true}}]}' \
    "$(grep 'dbtareas' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"

  # epicas-backlog / sueltas-backlog (DEVKIT-122): grupos 3 y 4 de `cola.sh`,
  # sin bandera desde DEVKIT-128, misma forma que `epicas-abiertas` y
  # `sueltas` pero acotadas a Estado Backlog.
  resp POST__databases_dbtareas_query "{\"results\":[$(epica epica-50 50 Backlog)],\"has_more\":false}"
  check "epicas-backlog: las Épicas en Backlog, con id" \
    '[{"id":"epica-50","clave":"DEVKIT-50","estado":"Backlog"}]' \
    "$(env "${entorno[@]}" bash "$HERE/notion.sh" epicas-backlog DEVKIT | jq -c '[.[] | {id, clave, estado}]')"
  check "epicas-backlog: el filtro es Nivel Épica y Estado Backlog" \
    '{"and":[{"property":"Proyecto","relation":{"contains":"proy-1"}},{"property":"Nivel","select":{"equals":"Épica"}},{"property":"Estado","select":{"equals":"Backlog"}}]}' \
    "$(grep 'dbtareas' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"

  resp POST__databases_dbtareas_query '{"results":[{"id":"card-71","created_time":"2026-01-02T00:00:00.000Z",
    "properties":{"ID":{"unique_id":{"number":71}},"Título":{"title":[{"plain_text":"suelta backlog"}]},
    "Estado":{"select":{"name":"Backlog"}},"Nivel":{"select":{"name":"Tarea"}},
    "Prioridad":{"select":{"name":"alta"}},"Orden":{"number":1},
    "Agente":{"select":{"name":"claude"}},"Padre":{"relation":[]},
    "Depende de":{"relation":[]}}}],"has_more":false}'
  got=$(env "${entorno[@]}" bash "$HERE/notion.sh" sueltas-backlog DEVKIT)
  check "sueltas-backlog: Clave, Prioridad, Orden, Agente y Creado de una tarea sin Padre" \
    '{"clave":"DEVKIT-71","prioridad":"alta","orden":1,"agente":"claude","creado":"2026-01-02T00:00:00.000Z"}' \
    "$(jq -c '.[0] | {clave,prioridad,orden,agente,creado}' <<<"$got")"
  check "sueltas-backlog: el filtro es Estado Backlog, Padre por is_empty" \
    '{"and":[{"property":"Proyecto","relation":{"contains":"proy-1"}},{"property":"Nivel","select":{"equals":"Tarea"}},{"property":"Estado","select":{"equals":"Backlog"}},{"property":"Padre","relation":{"is_empty":true}}]}' \
    "$(grep 'dbtareas' "$tmp/llamadas" | tail -1 | cut -d' ' -f3- | jq -c .filter)"

  # El uso calcula su rango buscando la línea de --test en vez de un rango
  # fijo (DEVKIT-80: un rango fijo cortaba la ayuda a media frase cada vez
  # que el bloque crecía, hallazgo H1 de `pr-review` sobre el PR #57, que
  # este mismo PR volvió a activar al documentar H6 y H7).
  check "uso: el rango impreso llega hasta la línea de --test" \
    "#   notion.sh --test                          autoprueba, sin red" \
    "$(bash "$HERE/notion.sh" no-existe 2>&1 >/dev/null | tail -1)"

  return $fail
}

case "${1:-}" in
  card) cmd_card "${2:?Clave}" ;;
  pagina) cmd_pagina "${2:?page_id}" ;;
  set) shift; cmd_set "$@" ;;
  comentar) cmd_comentar "${2:?page_id}" "${3:-}" ;;
  documentacion) cmd_documentacion "${2:?page_id}" "${3:-}" ;;
  crear-doc) cmd_crear_doc "${2:?tarea_id}" "${3:?proyecto_id}" "${4:?titulo}" "${5:?tipo}" "${6:-}" "${7:-}" ;;
  reemplazar-doc) cmd_reemplazar_doc "${2:?page_id}" "${3:-}" "${4:-}" ;;
  hijas) cmd_hijas "${2:?page_id}" ;;
  sueltas) cmd_sueltas "${2:?código}" ;;
  criterios) cmd_criterios "${2:?page_id}" ;;
  contenido) cmd_contenido "${2:?page_id}" ;;
  comentarios) cmd_comentarios "${2:?page_id}" ;;
  bloqueos) cmd_bloqueos "${2:?código}" ;;
  epicas) cmd_epicas "${2:?código}" ;;
  activas) cmd_activas "${2:?código}" ;;
  epicas-abiertas) cmd_epicas_abiertas "${2:?código}" ;;
  epicas-backlog) cmd_epicas_backlog "${2:?código}" ;;
  sueltas-backlog) cmd_sueltas_backlog "${2:?código}" ;;
  --test) run_tests ;;
  *)
    fin=$(grep -n '^#   notion.sh --test' "$0" | head -1 | cut -d: -f1)
    sed -n "9,${fin}p" "$0" >&2
    exit 64
    ;;
esac

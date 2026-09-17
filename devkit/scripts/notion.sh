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
#   notion.sh documentacion <page_id>         entrada de Documentación de la
#                                             card (relación Tarea): {id,url}
#   notion.sh hijas <page_id>                 hijas de una Épica (relación
#                                             Padre), como lista JSON
#   notion.sh criterios <page_id>             texto de la sección "Criterios
#                                             de aceptación" de la página
#   notion.sh bloqueos <código>               por cada card en Lista para
#                                             merge del proyecto, las Claves
#                                             en Lista que dependen de ella
#                                             (columna "bloquea a" de
#                                             `devkit-run --estado`, DEVKIT-63)
#   notion.sh epicas <código>                 por cada Tarea del proyecto
#                                             cuya Épica (Padre) está En
#                                             progreso, la Clave y el título
#                                             de esa Épica (agrupación de
#                                             `devkit-run --estado`, DEVKIT-80)
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
    err "falta el secreto notion_token ($TOKEN_FILE); ver README, sección Notion por token"
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

# rich_text de un comentario: las URL como enlaces, el resto como texto, y
# cada tramo en trozos de 2000 caracteres, el tope de la API por objeto.
RICH_TEXT='
def tramos($t):
  ($t | [match("https?://[^\\s<>()\"]*[^\\s<>()\".,;:]"; "g")]) as $ms
  | (reduce $ms[] as $m ({pos: 0, out: []};
       .out += (if $m.offset > .pos then [{text: {content: $t[.pos:$m.offset]}}] else [] end)
               + [{text: {content: $m.string, link: {url: $m.string}}}]
       | .pos = $m.offset + $m.length)) as $r
  | $r.out + (if ($t | length) > $r.pos then [{text: {content: $t[$r.pos:]}}] else [] end);
[ tramos($texto)[] | . as $s
  | range(0; ($s.text.content | length); 2000) as $i
  | $s | .text.content = $s.text.content[$i:$i + 2000] ]
'

cmd_comentar() {  # cmd_comentar <page_id> <texto>
  local body
  [ -n "${2:-}" ] || { err "comentario vacío"; return 64; }
  body=$(jq -nc --arg p "$1" --arg texto "$2" "{parent: {page_id: \$p}, rich_text: ($RICH_TEXT)}")
  api POST "/comments" "$body" >/dev/null
}

cmd_documentacion() {  # cmd_documentacion <page_id>
  local filas
  filas=$(query_all "$(db_id documentacion)" \
    "$(jq -nc --arg p "$1" '{property: "Tarea", relation: {contains: $p}}')") || return
  [ "$(jq 'length' <<<"$filas")" -gt 0 ] || return 1
  jq -c '.[0] | {id, url}' <<<"$filas"
}

cmd_hijas() {  # cmd_hijas <page_id>
  local filas codigo
  filas=$(query_all "$(db_id tareas)" \
    "$(jq -nc --arg p "$1" '{property: "Padre", relation: {contains: $p}}')") || return
  codigo=$(codigo_de_proyecto "$(jq -r '.[0].properties.Proyecto.relation[0].id // empty' <<<"$filas")")
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
# "(sin Épica)".
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

  # El uso (sed -n '9,30p') debe llegar hasta la línea de --test: si el
  # bloque crece y el rango no se actualiza, un subcomando inválido corta la
  # ayuda a media frase (DEVKIT-80).
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
  documentacion) cmd_documentacion "${2:?page_id}" ;;
  hijas) cmd_hijas "${2:?page_id}" ;;
  criterios) cmd_criterios "${2:?page_id}" ;;
  bloqueos) cmd_bloqueos "${2:?código}" ;;
  epicas) cmd_epicas "${2:?código}" ;;
  --test) run_tests ;;
  *)
    sed -n '9,30p' "$0" >&2
    exit 64
    ;;
esac

#!/usr/bin/env bash
# Escribe o actualiza la entrada de Documentación de tipo "cambio" de una
# card, sin agente (DEVKIT-92). Todo el material ya existe -Objetivo de la
# card, secciones del cuerpo del PR, marcas de modelo, hallazgos corregidos
# de los informes de pr-review-, así que este script solo lo copia y lo
# arma; no redacta nada nuevo. Reemplaza al agente `task-document` para las
# cards de Nivel Tarea: antes corría un `claude -p` completo (17 turnos, 0.61
# USD en DEVKIT-74), dos veces por card (DEVKIT-84) y escalaba a Opus en la
# tercera ronda (DEVKIT-83). Este script no tiene ronda ni modelo: es bash.
#
# La skill `task-document` sigue existiendo para lo que sí necesita criterio:
# la entrada "decisión" (cuando la card cambió una decisión de diseño, marcada
# con "Tipo: decisión" en el cuerpo del PR) y la entrada consolidada de una
# Épica.
#
# Uso:
#   task-document.sh <Clave> [PR]
#
# Sin PR, usa la propiedad `PR` de la card. Idempotente: si la entrada ya
# existe y el PR ya tiene el marcador `<!-- devkit-doc sha=<head> -->` para el
# head vigente, no hace nada y sale con 0. No bloquea la card: un problema acá
# no debe detener el merge, y `task-close.sh` vuelve a intentarlo.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH="${DEVKIT_GH_BIN:-gh}"
LOCK="${DEVKIT_TASK_DOCUMENT_LOCK:-$RUN_DIR/task-document.lock}"

say() { printf 'task-document: %s\n' "$*"; }

# Sección de un texto Markdown entre su encabezado "## ..." y el siguiente
# (o el final). El texto llega por stdin.
seccion() {  # seccion "## Encabezado"
  local enc=$1
  awk -v enc="$enc" '
    $0 == enc { activo=1; next }
    activo && /^## / { exit }
    activo { print }
  '
}

# Quita líneas en blanco al principio y al final, conserva las del medio.
trim() {
  local texto
  texto=$(cat)
  texto=$(printf '%s\n' "$texto" | sed -e '/[^[:space:]]/,$!d')
  texto=$(printf '%s\n' "$texto" | tac | sed -e '/[^[:space:]]/,$!d' | tac)
  printf '%s' "$texto"
}

# Última línea "<verbo> con <modelo>, esfuerzo <esfuerzo>" de un texto
# (DEVKIT-58), mismo patrón que usa task-close.sh: la línea entera, no solo el
# modelo, así se copia tal cual sin volver a armarla.
marca_linea() {  # marca_linea <verbo> <texto>
  printf '%s\n' "$2" | tr -d '\r' | grep -oE "$1 con [^,]+, esfuerzo .+" | tail -1 | sed -E 's/[[:space:].]+$//'
}

# ¿El cuerpo del PR trae la marca "Tipo: decisión" (mismo criterio que
# es_decision en watch.sh)? Esa entrada la escribe el agente task-document,
# que razona el porqué en vez de copiarlo; si este script la crea o la
# reemplaza igual, pisa o duplica el trabajo del agente cuando task-close.sh
# llama siempre, sin mirar la marca (informe del PR 66, H1).
es_decision() {  # es_decision <cuerpo del PR>
  printf '%s\n' "$1" | tr -d '\r' | grep -qx 'Tipo: decisión'
}

# Cada informe de pr-review (marcador, sha corto, veredicto, marca "Revisado
# con ...", en orden cronológico).
REVISIONES='
[ .reviews[] | select(.body // "" | test("<!-- devkit-review sha=[0-9a-f]+ verdict=(OK|CAMBIOS) -->"))
  | (.body | capture("<!-- devkit-review sha=(?<sha>[0-9a-f]+) verdict=(?<verdict>OK|CAMBIOS) -->")) as $m
  | { sha: $m.sha, corto: $m.sha[0:7], verdict: $m.verdict, at: .submittedAt,
      marca: (.body | capture("Revisado con (?<m>[^\n]+)"; "") | .m // "") } ]
| sort_by(.at)
'

# Hallazgos cuyo estado final, a través de las tablas "Hallazgos anteriores"
# de los informes siguientes, es "Corregido". El texto de cada hallazgo es el
# de su bloque `devkit-findings` original (el informe donde nació el id, que
# nunca se repite): nada se redacta de nuevo, solo se cruzan los dos bloques
# que ya publica pr-review.
HALLAZGOS='
( [ .reviews[] | select(.body != null) ] | sort_by(.submittedAt) ) as $revs
| reduce $revs[] as $r
    ({defs: {}, estado: {}};
      . as $acc
      | ( ($r.body | capture("(?s)<!-- devkit-findings -->\\n(?<b>.*?)\\n<!-- /devkit-findings -->").b // "")
          | split("\n") | map(select(. != "")) ) as $lineas
      | (reduce $lineas[] as $l ($acc.defs;
           ($l | split(" | ")) as $c
           | if ($c | length) >= 5 then .[$c[0]] = $c[3] else . end)) as $defs2
      | ( [$r.body | scan("\\| *(H[0-9]+) *\\| *(Corregido|Sin cambios|Reabierto) *\\|")] ) as $filas
      | (reduce $filas[] as $f ($acc.estado; .[$f[0]] = $f[1])) as $estado2
      | {defs: $defs2, estado: $estado2}
    )
| . as $final
| [ $final.estado | to_entries[] | select(.value == "Corregido") | {id: .key, texto: ($final.defs[.key] // "")} ]
| sort_by(.id | ltrimstr("H") | tonumber)
'

# --- Punto de entrada real (no --test) --------------------------------------
principal() {
  local clave=$1 pr_arg=${2:-}
  mkdir -p "$RUN_DIR" 2>/dev/null
  exec 8>"$LOCK"
  flock 8

  local card id nivel pr pr_json head num state body
  card=$("$NOTION" card "$clave") || { say "no pude leer $clave en Notion"; return 1; }
  id=$(jq -r .id <<<"$card")
  nivel=$(jq -r '.nivel // ""' <<<"$card")
  if [ "$nivel" = "Épica" ]; then
    say "$clave es una Épica; la entrada consolidada la escribe el agente task-document"
    return 64
  fi

  pr=${pr_arg:-$(jq -r '.pr // ""' <<<"$card")}
  if [ -z "$pr" ]; then
    "$NOTION" comentar "$id" "task-document: la card no tiene PR registrado y no recibí uno; no puedo escribir la entrada de Documentación." >/dev/null 2>&1
    say "$clave sin PR; comentado en la card"
    return 1
  fi
  if ! pr_json=$("$GH" pr view "$pr" --json number,url,state,headRefOid,headRefName,body,reviews,comments 2>&1); then
    say "gh no pudo leer el PR $pr: $pr_json"
    return 1
  fi
  head=$(jq -r .headRefOid <<<"$pr_json")
  num=$(jq -r .number <<<"$pr_json")
  state=$(jq -r .state <<<"$pr_json")
  body=$(jq -r '.body // ""' <<<"$pr_json" | tr -d '\r')

  if es_decision "$body"; then
    say "$clave marcado Tipo: decisión; la entrada la escribe el agente task-document"
    return 0
  fi

  local ya_marcado doc doc_rc
  ya_marcado=$(jq --arg sha "$head" '[.comments[] | select(.body // "" | test("<!-- devkit-doc sha=" + $sha + " -->"))] | length' <<<"$pr_json")
  doc=$("$NOTION" documentacion "$id" "$clave" 2>/dev/null); doc_rc=$?
  if [ "$doc_rc" -eq 0 ] && [ "$ya_marcado" -gt 0 ]; then
    say "$clave ya documentado en ${head:0:7}; nada que hacer"
    return 0
  fi

  # --- Material, tal cual, de la card y del PR ------------------------------
  local contenido objetivo que_cambia como_probarlo cambios_requeridos
  contenido=$("$NOTION" contenido "$id" 2>/dev/null)
  objetivo=$(printf '%s\n' "$contenido" | seccion "## Objetivo" | trim)
  que_cambia=$(printf '%s\n' "$body" | seccion "## Qué cambia" | trim)
  como_probarlo=$(printf '%s\n' "$body" | seccion "## Cómo probarlo" | trim)
  cambios_requeridos=$(printf '%s\n' "$body" | seccion "## Cambios requeridos" | trim)

  local hallazgos n_hallazgos hallazgos_texto por_que
  hallazgos=$(jq -c "$HALLAZGOS" <<<"$pr_json")
  n_hallazgos=$(jq 'length' <<<"$hallazgos")
  hallazgos_texto=""
  if [ "$n_hallazgos" -gt 0 ]; then
    hallazgos_texto="

Hallazgos corregidos durante la revisión:
$(jq -r '.[] | "- \(.id): \(.texto)"' <<<"$hallazgos")"
  fi
  por_que="${objetivo:-Sin Objetivo legible en la card.}$hallazgos_texto"

  local marca_impl revisiones lineas_revision modelos
  marca_impl=$(marca_linea Implementado "$body")
  [ -n "$marca_impl" ] || marca_impl="Implementado con sin marca"
  revisiones=$(jq -c "$REVISIONES" <<<"$pr_json")
  lineas_revision=$(jq -r '.[] | "- Revisado con \(if .marca == "" then "sin marca" else .marca end) (commit \(.corto), \(.verdict))"' <<<"$revisiones")
  modelos="- $marca_impl"
  [ -z "$lineas_revision" ] || modelos="$modelos
$lineas_revision"
  modelos="$modelos
- Documentado con script task-document.sh"

  local rama card_url pr_url enlaces
  rama=$(jq -r '.rama // ""' <<<"$card")
  card_url=$(jq -r .url <<<"$card")
  pr_url=$(jq -r .url <<<"$pr_json")
  enlaces="- Card: $card_url
- Rama: ${rama:-sin rama}
- PR: $pr_url"

  local cuerpo
  cuerpo="## Qué cambió
${que_cambia:-Sin sección \"Qué cambia\" en el PR.}

## Por qué
$por_que

## Cómo probarlo
${como_probarlo:-Sin sección \"Cómo probarlo\" en el PR.}

## Cambios requeridos
${cambios_requeridos:-Ninguno.}

## Enlaces
$enlaces

## Modelos
$modelos"

  # --- Crea o reemplaza la entrada -------------------------------------------
  local doc_id doc_url resultado
  if [ "$doc_rc" -eq 0 ]; then
    doc_id=$(jq -r .id <<<"$doc")
    if ! resultado=$(printf '%s' "$cuerpo" | "$NOTION" reemplazar-doc "$doc_id" "$rama" "$pr_url" 2>&1); then
      say "no pude actualizar la entrada de Documentación de $clave: $resultado"
      return 1
    fi
  else
    local proyecto titulo
    proyecto=$(jq -r '.proyecto[0] // ""' <<<"$card")
    if [ -z "$proyecto" ]; then
      say "$clave sin Proyecto en Notion; no puedo crear la entrada"
      return 1
    fi
    titulo="$clave: $(jq -r .titulo <<<"$card")"
    if ! resultado=$(printf '%s' "$cuerpo" | "$NOTION" crear-doc "$id" "$proyecto" "$titulo" cambio "$rama" "$pr_url" 2>&1); then
      say "no pude crear la entrada de Documentación de $clave: $resultado"
      return 1
    fi
  fi
  doc_url=$(jq -r .url <<<"$resultado")

  # --- Marcador en el PR, solo si sigue abierto -------------------------------
  if [ "$state" = OPEN ] && [ "$ya_marcado" -eq 0 ]; then
    "$GH" pr comment "$num" --body "<!-- devkit-doc sha=$head -->
Documentación: $doc_url" >/dev/null 2>&1 \
      || say "no pude publicar el marcador devkit-doc en el PR $num"
  fi

  say "$clave documentado: $doc_url"
}

# --- Autoprueba, sin red -----------------------------------------------------
# notion.sh y gh de mentira: el primero responde desde archivos JSON en un
# directorio temporal, el segundo simula `pr view`/`pr comment` con las mismas
# convenciones que usa el resto del devkit (DEVKIT-55).
run_tests() {
  local tmp fail=0
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  check() {
    if [ "$2" = "$3" ]; then
      printf 'ok   %-58s %s\n' "$1" "$(printf '%s' "$3" | head -1 | cut -c1-60)"
    else
      printf 'FAIL %-58s esperado %s, obtenido %s\n' "$1" "$2" "${3:-<vacío>}"
      fail=1
    fi
  }

  mkdir -p "$tmp/notion" "$tmp/gh" "$tmp/run" "$tmp/bin"
  cat >"$tmp/notion.sh" <<'FIN'
#!/usr/bin/env bash
d=$FAKE_NOTION
printf '%s\n' "$*" >>"$d/llamadas"
case "$1" in
  card) cat "$d/card.json" 2>/dev/null || exit 1 ;;
  contenido) cat "$d/contenido.txt" 2>/dev/null ;;
  documentacion) cat "$d/doc.json" 2>/dev/null || exit 1 ;;
  crear-doc) cat >>"$d/cuerpo-creado.txt"; cat "$d/crear-doc-resp.json" ;;
  reemplazar-doc) cat >>"$d/cuerpo-reemplazado.txt"; cat "$d/reemplazar-doc-resp.json" ;;
  comentar) ;;
  *) exit 64 ;;
esac
FIN
  cat >"$tmp/bin/gh" <<'FIN'
#!/usr/bin/env bash
d=$FAKE_GH
case "$1 $2" in
  "pr view") cat "$d/pr.json" ;;
  "pr comment") printf '%s\n' "$*" >>"$d/comentarios" ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$tmp/notion.sh" "$tmp/bin/gh"

  printf '{"id":"card-1","url":"https://notion.so/card-1","clave":"DEVKIT-9","titulo":"Título de prueba","estado":"Revisión automática","nivel":"Tarea","pr":"9","rama":"https://github.com/o/r/tree/feat/DEVKIT-9-x","proyecto":["proy-1"]}' >"$tmp/notion/card.json"
  printf '## Objetivo\nQue esto funcione sin agente.\n## Criterios de aceptación\notro\n' >"$tmp/notion/contenido.txt"
  printf '{"id":"doc-1","url":"https://notion.so/doc-1"}' >"$tmp/notion/reemplazar-doc-resp.json"
  printf '{"id":"doc-nueva","url":"https://notion.so/doc-nueva"}' >"$tmp/notion/crear-doc-resp.json"

  entorno=(FAKE_NOTION="$tmp/notion" FAKE_GH="$tmp/gh"
           DEVKIT_NOTION_BIN="$tmp/notion.sh" DEVKIT_GH_BIN="$tmp/bin/gh"
           DEVKIT_RUN_DIR="$tmp/run")

  # Sin entrada previa: crea. El cuerpo trae Objetivo, secciones del PR y
  # marcas de modelo, sin marcador aún -> comenta el marcador en el PR.
  jq -nc '{state:"OPEN", number:9, url:"https://github.com/o/r/pull/9",
    headRefOid:"a1b2c3d", headRefName:"feat/DEVKIT-9-x", mergeCommit:null,
    body:"## Qué cambia\nAlgo nuevo.\n\n## Cómo probarlo\nbash -n foo.sh\n\n## Cambios requeridos\nNinguno.\n\n## Card\nx\n\nImplementado con opus, esfuerzo high",
    reviews:[{submittedAt:"T01","body":"<!-- devkit-review sha=a1b2c3d verdict=OK -->\nRevisado con fable, esfuerzo high\n## Revisión"}],
    comments:[]}' >"$tmp/gh/pr.json"
  rm -f "$tmp/notion/doc.json"
  salida=$(env "${entorno[@]}" bash "$HERE/task-document.sh" DEVKIT-9)
  check "sin entrada previa: crea y avisa" "task-document: DEVKIT-9 documentado: https://notion.so/doc-nueva" "$salida"
  check "crea con Proyecto, Tarea, Tipo y el resto de argumentos" 1 \
    "$(grep -c '^crear-doc card-1 proy-1 DEVKIT-9: Título de prueba cambio https://github.com/o/r/tree/feat/DEVKIT-9-x https://github.com/o/r/pull/9$' "$tmp/notion/llamadas")"
  check "el cuerpo copia el Objetivo de la card" 1 "$(grep -c 'Que esto funcione sin agente.' "$tmp/notion/cuerpo-creado.txt")"
  check "el cuerpo copia \"Qué cambia\" del PR bajo \"Qué cambió\"" 1 "$(grep -c '^Algo nuevo.$' "$tmp/notion/cuerpo-creado.txt")"
  check "el cuerpo copia \"Cómo probarlo\" del PR" 1 "$(grep -c 'bash -n foo.sh' "$tmp/notion/cuerpo-creado.txt")"
  check "el cuerpo copia la marca Implementado, como viñeta" 1 "$(grep -c '^- Implementado con opus, esfuerzo high$' "$tmp/notion/cuerpo-creado.txt")"
  check "el cuerpo copia la marca Revisado con el commit y el veredicto, como viñeta" 1 \
    "$(grep -c '^- Revisado con fable, esfuerzo high (commit a1b2c3d, OK)$' "$tmp/notion/cuerpo-creado.txt")"
  check "la línea Documentado con dice el script, no un modelo, como viñeta" 1 \
    "$(grep -c '^- Documentado con script task-document.sh$' "$tmp/notion/cuerpo-creado.txt")"
  check "publica el marcador devkit-doc en el PR abierto" 1 \
    "$(grep -c 'devkit-doc sha=a1b2c3d' "$tmp/gh/comentarios")"

  # Con entrada previa (mismo head, ya marcado): idempotente, no llama a nada.
  printf '{"id":"doc-1","url":"https://notion.so/doc-1"}' >"$tmp/notion/doc.json"
  jq '.comments = [{"body":"<!-- devkit-doc sha=a1b2c3d -->\nDocumentación: https://notion.so/doc-1"}]' "$tmp/gh/pr.json" >"$tmp/gh/pr2.json" && mv "$tmp/gh/pr2.json" "$tmp/gh/pr.json"
  : >"$tmp/notion/llamadas"; : >"$tmp/gh/comentarios"
  salida=$(env "${entorno[@]}" bash "$HERE/task-document.sh" DEVKIT-9)
  check "idempotente: mismo head y ya documentado, sale con 0 sin tocar nada" \
    "task-document: DEVKIT-9 ya documentado en a1b2c3d; nada que hacer" "$salida"
  check "idempotente: no crea ni reemplaza" 0 "$(grep -cE '^(crear-doc|reemplazar-doc)' "$tmp/notion/llamadas")"
  check "idempotente: no publica otro marcador" 0 "$(wc -l <"$tmp/gh/comentarios" | tr -d ' ')"

  # Entrada previa pero head nuevo (sin marcador para ese head): reemplaza.
  jq '.headRefOid = "e5f6g7h" | .comments = []' "$tmp/gh/pr.json" >"$tmp/gh/pr2.json" && mv "$tmp/gh/pr2.json" "$tmp/gh/pr.json"
  : >"$tmp/notion/llamadas"; : >"$tmp/gh/comentarios"
  salida=$(env "${entorno[@]}" bash "$HERE/task-document.sh" DEVKIT-9)
  check "head nuevo: reemplaza la entrada existente" "task-document: DEVKIT-9 documentado: https://notion.so/doc-1" "$salida"
  check "head nuevo: llama a reemplazar-doc con el id de la entrada" 1 \
    "$(grep -c '^reemplazar-doc doc-1 https://github.com/o/r/tree/feat/DEVKIT-9-x https://github.com/o/r/pull/9$' "$tmp/notion/llamadas")"

  # Hallazgos corregidos: entran en "Por qué", con su texto original.
  jq -nc '{state:"OPEN", number:9, url:"https://github.com/o/r/pull/9",
    headRefOid:"f1", headRefName:"feat/DEVKIT-9-x", mergeCommit:null,
    body:"## Qué cambia\nAlgo.\n\n## Cómo probarlo\nx\n\n## Cambios requeridos\nNinguno.",
    reviews:[
      {submittedAt:"T01","body":"<!-- devkit-review sha=c1 verdict=CAMBIOS -->\nRevisado con opus, esfuerzo high\n\n<!-- devkit-findings -->\nH1 | alta | foo.sh:1 | rompe algo | arreglar\n<!-- /devkit-findings -->"},
      {submittedAt:"T02","body":"<!-- devkit-review sha=f1 verdict=OK -->\nRevisado con fable, esfuerzo high\n\n### Hallazgos anteriores\n| H1 | Corregido | se ve en el diff |\n"}
    ],
    comments:[]}' >"$tmp/gh/pr.json"
  rm -f "$tmp/notion/doc.json"
  : >"$tmp/notion/llamadas"
  env "${entorno[@]}" bash "$HERE/task-document.sh" DEVKIT-9 >/dev/null
  check "hallazgos corregidos entran en Por qué, con el texto original" 1 \
    "$(grep -c '^- H1: rompe algo$' "$tmp/notion/cuerpo-creado.txt")"

  # Marcado "Tipo: decisión" (informe del PR 66, H1): la entrada la escribe
  # el agente task-document, no este script; ni crea ni reemplaza, aunque no
  # exista entrada previa ni marcador para el head.
  jq -nc '{state:"OPEN", number:9, url:"https://github.com/o/r/pull/9",
    headRefOid:"d1", headRefName:"feat/DEVKIT-9-x", mergeCommit:null,
    body:"## Qué cambia\nAlgo.\n\nTipo: decisión\n\n## Cómo probarlo\nx\n\n## Cambios requeridos\nNinguno.",
    reviews:[], comments:[]}' >"$tmp/gh/pr.json"
  rm -f "$tmp/notion/doc.json"
  : >"$tmp/notion/llamadas"; : >"$tmp/gh/comentarios"
  salida=$(env "${entorno[@]}" bash "$HERE/task-document.sh" DEVKIT-9)
  check "Tipo: decisión: sale con 0 y avisa que la escribe el agente" \
    "task-document: DEVKIT-9 marcado Tipo: decisión; la entrada la escribe el agente task-document" "$salida"
  check "Tipo: decisión: no crea ni reemplaza" 0 "$(grep -cE '^(crear-doc|reemplazar-doc)' "$tmp/notion/llamadas")"
  check "Tipo: decisión: no publica el marcador devkit-doc" 0 "$(wc -l <"$tmp/gh/comentarios" | tr -d ' ')"

  # Sin PR: comenta en la card y sale con 1, sin bloquear la card.
  jq 'del(.pr)' "$tmp/notion/card.json" >"$tmp/notion/card2.json" && mv "$tmp/notion/card2.json" "$tmp/notion/card.json"
  : >"$tmp/notion/llamadas"
  salida=$(env "${entorno[@]}" bash "$HERE/task-document.sh" DEVKIT-9 2>&1); rc=$?
  check "sin PR: sale con 1" 1 "$rc"
  check "sin PR: comenta en la card" 1 "$(grep -c '^comentar card-1' "$tmp/notion/llamadas")"

  # Épica: no la maneja este script, sale con 64.
  printf '{"id":"epica-1","url":"https://notion.so/epica-1","clave":"DEVKIT-1","titulo":"Épica","estado":"En progreso","nivel":"Épica"}' >"$tmp/notion/card.json"
  salida=$(env "${entorno[@]}" bash "$HERE/task-document.sh" DEVKIT-1 2>&1); rc=$?
  check "Épica: no la escribe este script, sale con 64" 64 "$rc"

  return $fail
}

case "${1:-}" in
  --test) run_tests ;;
  "")
    echo "uso: task-document.sh <Clave> [PR]" >&2
    exit 64
    ;;
  *) principal "$1" "${2:-}" ;;
esac

#!/usr/bin/env bash
# La siguiente card del proyecto, por la estrategia fija de la cola
# (DEVKIT-119). Generaliza task-next.sh (DEVKIT-56), que solo mira las
# hermanas de una card dentro de su propia Épica: cola.sh mira el proyecto
# entero, para que el bucle y el humano vean el mismo orden sin abrir Notion.
#
# Uso:
#   cola.sh          la Clave de la siguiente card, o nada
#   cola.sh --lista  las primeras diez en ese orden: Clave, grupo y título
#   cola.sh --test   autoprueba con fixtures, sin red
#
# Orden fijo, dos grupos:
#   1. Hijas de Épicas en `Lista` o `En progreso` (DEVKIT-109: task-begin.sh
#      pasa la Épica a En progreso con su primera hija): las Épicas por
#      `Prioridad` y `Creado`, y dentro de cada una sus hijas por `Orden` y
#      `Prioridad`.
#   2. Tareas sueltas (sin Padre) en `Lista`, por `Prioridad`, `Orden` y
#      `Creado`.
# Una card con algo en `Depende de` que no está `Hecha`, o `Agente` =
# `humano`, no entra en ninguno de los dos grupos.
#
# `cola.sh` (sin argumento) no imprime nada si hay una Tarea `En progreso` o
# `Revisión automática` en el proyecto, o un `task-start` vivo para una card
# en `Lista` (misma detección de `ps` que task-next.sh): con algo en curso,
# "la siguiente" ya está decidida y no hay nada que sugerir. Una Épica En
# progreso no cuenta: solo lo está porque task-begin.sh se lo aplicó junto
# con su primera hija (DEVKIT-109), y es esa hija -una Tarea- la que refleja
# si hay trabajo en curso. `--lista` no aplica este corte: es una foto de la
# cola completa, útil para ver qué sigue aunque algo esté corriendo ahora
# mismo (mismo trato que --tablero frente a --estado).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
PS_BIN="${DEVKIT_PS_BIN:-ps}"

err() { printf 'cola.sh: %s\n' "$*" >&2; }

project_code() {
  [ -f "$WS/.devkit/devkit.toml" ] || return 0
  sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/.devkit/devkit.toml" | head -1
}

PRIO_DEF='def prio: {"alta": 0, "media": 1, "baja": 2}[. // ""] // 3;'

# Ningún `Depende de` de la card sigue sin `Hecha` (mismo criterio que
# task-next.sh). Una llamada a `pagina` por dependencia: en la práctica una
# card trae cero o una, así que no vale la pena una consulta batida aparte.
# 0 = hecha, 1 = no hecha (dependencia legítima sin cerrar), 2 = no se pudo
# leer Notion (DEVKIT-119, H1 de pr-review): un fallo de red no puede
# confundirse con una dependencia pendiente, o `cola.sh` sugiere otra card
# en vez de cortar.
dependencias_hechas() {  # dependencias_hechas <card JSON>
  local item=$1 dep estado
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if ! estado=$("$NOTION" pagina "$dep" 2>&1); then
      err "no pude leer Notion (pagina $dep): $estado"
      return 2
    fi
    estado=$(jq -r '.estado // empty' <<<"$estado")
    [ "$estado" = "Hecha" ] || return 1
  done < <(jq -r '.depende[]? // empty' <<<"$item")
  return 0
}

# Todas las cards elegibles, en el orden fijo de la card: grupo 1 (hijas de
# Épicas en Lista o En progreso) seguido del grupo 2 (sueltas en Lista), cada
# objeto con un campo "grupo" agregado para --lista.
armar_cola() {  # armar_cola <activas JSON>
  local activas=$1 items=()

  local epicas_cards=() clave c
  while IFS= read -r clave; do
    [ -n "$clave" ] || continue
    if ! c=$("$NOTION" card "$clave" 2>&1); then
      err "no pude leer Notion (card $clave): $c"
      return 1
    fi
    epicas_cards+=("$c")
  done < <(jq -r '.[] | select(.nivel == "Épica" and (.estado == "Lista" or .estado == "En progreso")) | .clave' <<<"$activas")

  local epicas_ordenadas='[]'
  if [ "${#epicas_cards[@]}" -gt 0 ]; then
    epicas_ordenadas=$(printf '%s\n' "${epicas_cards[@]}" | jq -s "$PRIO_DEF"'
      sort_by([(.prioridad | prio), (.creado // "")])')
  fi

  local epica_id epica_clave hijas elegibles item rc
  while IFS=$'\t' read -r epica_id epica_clave; do
    [ -n "$epica_id" ] || continue
    if ! hijas=$("$NOTION" hijas "$epica_id" 2>&1); then
      err "no pude leer Notion (hijas $epica_id): $hijas"
      return 1
    fi
    elegibles=$(jq -c "$PRIO_DEF"'
      map(select(.nivel == "Tarea" and .estado == "Lista" and .agente != "humano"))
      | sort_by([(.orden // 1e9), (.prioridad | prio)])' <<<"$hijas")
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      dependencias_hechas "$item"; rc=$?
      case $rc in
        0) items+=("$(jq -c --arg g "$epica_clave" '. + {grupo: $g}' <<<"$item")") ;;
        2) return 1 ;;
      esac
    done < <(jq -c '.[]' <<<"$elegibles")
  done < <(jq -r '.[] | [.id, .clave] | @tsv' <<<"$epicas_ordenadas")

  local sueltas elegibles2
  if ! sueltas=$("$NOTION" sueltas "$(project_code)" 2>&1); then
    err "no pude leer Notion (sueltas): $sueltas"
    return 1
  fi
  elegibles2=$(jq -c "$PRIO_DEF"'
    map(select(.agente != "humano"))
    | sort_by([(.prioridad | prio), (.orden // 1e9), (.creado // "")])' <<<"$sueltas")
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    dependencias_hechas "$item"; rc=$?
    case $rc in
      0) items+=("$(jq -c '. + {grupo: "(sin Épica)"}' <<<"$item")") ;;
      2) return 1 ;;
    esac
  done < <(jq -c '.[]' <<<"$elegibles2")

  if [ "${#items[@]}" -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "${items[@]}" | jq -s -c '.'
  fi
}

# Un task-start vivo para una card en Lista: lanzado, pero esperando
# skill.lock o sin haber cambiado aún el Estado. Idéntico a la comprobación
# de task-next.sh, pero sobre todas las claves en Lista del proyecto, no solo
# las hermanas de una Épica.
task_start_vivo() {  # task_start_vivo <activas JSON>
  local activas=$1 procesos clave
  procesos=$("$PS_BIN" -eo args= 2>/dev/null)
  while IFS= read -r clave; do
    [ -n "$clave" ] || continue
    grep -qE -- "(--sync|--worker|claude -p) /task-start $clave( |$)" <<<"$procesos" && return 0
  done < <(jq -r '.[] | select(.estado == "Lista") | .clave' <<<"$activas")
  return 1
}

modo_siguiente() {
  local codigo activas en_curso cola
  codigo=$(project_code)
  [ -n "$codigo" ] || { err "no encuentro \"project\" en $WS/.devkit/devkit.toml"; exit 1; }
  activas=$("$NOTION" activas "$codigo" 2>&1) || { err "no pude leer Notion: $activas"; exit 1; }
  en_curso=$(jq -r '[.[] | select(.nivel == "Tarea" and (.estado == "En progreso" or .estado == "Revisión automática"))] | length' <<<"$activas")
  [ "$en_curso" -eq 0 ] || exit 0
  task_start_vivo "$activas" && exit 0
  cola=$(armar_cola "$activas") || exit 1
  jq -r '.[0].clave // empty' <<<"$cola"
}

modo_lista() {
  local codigo activas cola
  codigo=$(project_code)
  [ -n "$codigo" ] || { err "no encuentro \"project\" en $WS/.devkit/devkit.toml"; exit 1; }
  activas=$("$NOTION" activas "$codigo" 2>&1) || { err "no pude leer Notion: $activas"; exit 1; }
  cola=$(armar_cola "$activas") || exit 1
  jq -r '.[:10][] | "\(.clave)\t\(.grupo)\t\(.titulo // "")"' <<<"$cola" |
    while IFS=$'\t' read -r clave grupo titulo; do
      # %-14s de printf rellena por bytes, no por caracteres: un grupo con
      # acento (p.ej. "(sin Épica)") queda un espacio corto (DEVKIT-119, H3
      # de pr-review). ${#grupo} sí cuenta caracteres en un locale UTF-8.
      local relleno=$((14 - ${#grupo}))
      [ "$relleno" -ge 1 ] || relleno=1
      printf '%-12s %s%*s%s\n' "$clave" "$grupo" "$relleno" "" "$(printf '%s' "$titulo" | cut -c1-60)"
    done
}

run_tests() {
  local fail=0 tmp
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

  local ws="$tmp/ws"
  mkdir -p "$ws/.devkit"
  printf 'project = "DEVKIT"\n' >"$ws/.devkit/devkit.toml"

  # Fixture principal: una Épica en Lista (DEVKIT-50) con dos hijas -una
  # Lista de prioridad baja (DEVKIT-51) y otra bloqueada por una dependencia
  # sin cerrar (DEVKIT-52, depende de DEVKIT-40, no Hecha)-, y dos sueltas en
  # Lista: DEVKIT-90 (prioridad alta) y DEVKIT-91 (prioridad media, sin
  # bloqueos). También una card con Agente=humano (DEVKIT-92) que no debe
  # aparecer nunca.
  local notion_fake="$tmp/notion-fake"
  cat >"$notion_fake" <<'FIN'
#!/usr/bin/env bash
case "$1 $2" in
  "activas DEVKIT")
    cat "$FAKE_DIR/activas.json" ;;
  "card DEVKIT-50")
    echo '{"id":"epica-50","clave":"DEVKIT-50","prioridad":"alta","creado":"2026-01-01T00:00:00.000Z"}' ;;
  "hijas epica-50")
    echo '[
      {"id":"card-51","clave":"DEVKIT-51","nivel":"Tarea","estado":"Lista","prioridad":"baja","orden":1,"agente":"claude","depende":[],"titulo":"hija libre"},
      {"id":"card-52","clave":"DEVKIT-52","nivel":"Tarea","estado":"Lista","prioridad":"alta","orden":2,"agente":"claude","depende":["card-40"],"titulo":"hija con dependencia"}
    ]' ;;
  "sueltas DEVKIT")
    echo '[
      {"id":"card-90","clave":"DEVKIT-90","estado":"Lista","prioridad":"alta","orden":1,"agente":"claude","depende":[],"titulo":"suelta prioritaria"},
      {"id":"card-91","clave":"DEVKIT-91","estado":"Lista","prioridad":"media","orden":1,"agente":"claude","depende":[],"titulo":"suelta media"},
      {"id":"card-92","clave":"DEVKIT-92","estado":"Lista","prioridad":"alta","orden":1,"agente":"humano","depende":[],"titulo":"solo humano"}
    ]' ;;
  "pagina card-40")
    echo '{"estado":"En progreso"}' ;;
esac
FIN
  chmod +x "$notion_fake"

  cat >"$tmp/activas.json" <<'FIN'
[{"clave":"DEVKIT-50","estado":"Lista","nivel":"Épica"},
 {"clave":"DEVKIT-51","estado":"Lista","nivel":"Tarea"},
 {"clave":"DEVKIT-52","estado":"Lista","nivel":"Tarea"},
 {"clave":"DEVKIT-90","estado":"Lista","nivel":"Tarea"},
 {"clave":"DEVKIT-91","estado":"Lista","nivel":"Tarea"},
 {"clave":"DEVKIT-92","estado":"Lista","nivel":"Tarea"}]
FIN

  local ps_libre="$tmp/ps-libre"
  cat >"$ps_libre" <<'FIN'
#!/usr/bin/env bash
echo "claude -p /task-close DEVKIT-1"
FIN
  chmod +x "$ps_libre"

  local entorno=(FAKE_DIR="$tmp" DEVKIT_NOTION_BIN="$notion_fake" DEVKIT_WS="$ws" DEVKIT_PS_BIN="$ps_libre")

  got=$(env "${entorno[@]}" bash "$HERE/cola.sh")
  check "hija de Épica en Lista antes que suelta de mayor prioridad" "DEVKIT-51" "$got"

  # Depende de sin cerrar (DEVKIT-52 depende de card-40, "En progreso", no
  # Hecha) se salta: no aparece ni en --lista.
  got=$(env "${entorno[@]}" bash "$HERE/cola.sh" --lista)
  check "Depende de sin cerrar se salta, ni siquiera en --lista" no \
    "$(grep -q 'DEVKIT-52' <<<"$got" && echo si || echo no)"
  check "Agente=humano se salta, ni siquiera en --lista" no \
    "$(grep -q 'DEVKIT-92' <<<"$got" && echo si || echo no)"
  check "--lista: orden completo, hijas de la Épica y luego las sueltas por Prioridad" \
    "DEVKIT-51
DEVKIT-90
DEVKIT-91" \
    "$(cut -d' ' -f1 <<<"$got" | tr -s ' ')"
  check "--lista: el grupo de una hija es la Clave de su Épica" si \
    "$(grep 'DEVKIT-51' <<<"$got" | grep -q 'DEVKIT-50' && echo si || echo no)"
  check "--lista: el grupo de una suelta es (sin Épica)" si \
    "$(grep 'DEVKIT-90' <<<"$got" | grep -q '(sin Épica)' && echo si || echo no)"

  # DEVKIT-119, H1 de pr-review: si Notion falla al leer las hijas de la
  # Épica (rate limit, timeout), cola.sh no puede degradarse a "no hay
  # hijas" y sugerir otra card con exit 0: debe cortar sin nada en stdout y
  # con exit distinto de 0, para que quien lo llame note el fallo.
  local notion_falla_hijas="$tmp/notion-falla-hijas"
  cat >"$notion_falla_hijas" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "activas DEVKIT")
    cat "$tmp/activas.json" ;;
  "card DEVKIT-50")
    echo '{"id":"epica-50","clave":"DEVKIT-50","prioridad":"alta","creado":"2026-01-01T00:00:00.000Z"}' ;;
  "hijas epica-50")
    echo "rate limit" >&2
    exit 1 ;;
esac
FIN
  chmod +x "$notion_falla_hijas"
  got=$(env DEVKIT_NOTION_BIN="$notion_falla_hijas" DEVKIT_WS="$ws" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  rc_falla_hijas=$?
  check "Notion falla al leer hijas: sin salida, no sugiere otra card" "" "$got"
  check "Notion falla al leer hijas: exit distinto de 0" si \
    "$([ "$rc_falla_hijas" -ne 0 ] && echo si || echo no)"

  # Nada con una card en curso: DEVKIT-93 En progreso en el proyecto basta
  # para que cola.sh (sin argumento) no sugiera nada, aunque la cola de
  # arriba siga teniendo candidatos libres.
  local activas_en_curso="$tmp/activas-en-curso.json"
  cat >"$activas_en_curso" <<'FIN'
[{"clave":"DEVKIT-93","estado":"En progreso","nivel":"Tarea"},
 {"clave":"DEVKIT-90","estado":"Lista","nivel":"Tarea"}]
FIN
  local notion_en_curso="$tmp/notion-en-curso"
  cat >"$notion_en_curso" <<FIN
#!/usr/bin/env bash
[ "\$1 \$2" = "activas DEVKIT" ] && cat "$activas_en_curso"
FIN
  chmod +x "$notion_en_curso"
  got=$(env DEVKIT_NOTION_BIN="$notion_en_curso" DEVKIT_WS="$ws" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  check "nada con una card En progreso en el proyecto" "" "$got"

  # Un task-start vivo para una card en Lista corta igual, sin necesidad de
  # que nada esté todavía En progreso (misma detección que task-next.sh).
  local ps_ocupado="$tmp/ps-ocupado"
  cat >"$ps_ocupado" <<'FIN'
#!/usr/bin/env bash
echo "claude -p /task-start DEVKIT-51"
FIN
  chmod +x "$ps_ocupado"
  got=$(env "${entorno[@]}" DEVKIT_PS_BIN="$ps_ocupado" bash "$HERE/cola.sh")
  check "nada con un task-start vivo para una card en Lista" "" "$got"

  # --lista sí muestra la cola aunque haya algo en curso: es una foto, no la
  # decisión de arranque (mismo trato que --tablero frente a --estado).
  got=$(env "${entorno[@]}" DEVKIT_PS_BIN="$ps_ocupado" bash "$HERE/cola.sh" --lista)
  check "--lista no aplica el corte de \"algo en curso\"" si \
    "$(grep -q 'DEVKIT-51' <<<"$got" && echo si || echo no)"

  # DEVKIT-126: una Épica En progreso (task-begin.sh la deja así junto con su
  # primera hija, DEVKIT-109) no debe perder sus hijas restantes.
  local activas_epica_progreso="$tmp/activas-epica-progreso.json"
  cat >"$activas_epica_progreso" <<'FIN'
[{"clave":"DEVKIT-118","estado":"En progreso","nivel":"Épica"},
 {"clave":"DEVKIT-121","estado":"Lista","nivel":"Tarea"}]
FIN
  local notion_epica_progreso="$tmp/notion-epica-progreso"
  cat >"$notion_epica_progreso" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "activas DEVKIT")
    cat "$activas_epica_progreso" ;;
  "card DEVKIT-118")
    echo '{"id":"epica-118","clave":"DEVKIT-118","prioridad":"alta","creado":"2026-01-01T00:00:00.000Z"}' ;;
  "hijas epica-118")
    echo '[{"id":"card-121","clave":"DEVKIT-121","nivel":"Tarea","estado":"Lista","prioridad":"media","orden":1,"agente":"claude","depende":[],"titulo":"hija de Épica en progreso"}]' ;;
esac
FIN
  chmod +x "$notion_epica_progreso"
  got=$(env DEVKIT_NOTION_BIN="$notion_epica_progreso" DEVKIT_WS="$ws" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  check "Épica En progreso con una hija libre en Lista: la sugiere" "DEVKIT-121" "$got"

  # Y una Épica En progreso sin ninguna Tarea en curso -aunque ella misma
  # esté En progreso- no bloquea la cola: aquí no tiene hijas elegibles, pero
  # sigue ofreciendo la siguiente card libre (una suelta).
  local activas_epica_sin_hijas="$tmp/activas-epica-sin-hijas.json"
  cat >"$activas_epica_sin_hijas" <<'FIN'
[{"clave":"DEVKIT-118","estado":"En progreso","nivel":"Épica"},
 {"clave":"DEVKIT-90","estado":"Lista","nivel":"Tarea"}]
FIN
  local notion_epica_sin_hijas="$tmp/notion-epica-sin-hijas"
  cat >"$notion_epica_sin_hijas" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "activas DEVKIT")
    cat "$activas_epica_sin_hijas" ;;
  "card DEVKIT-118")
    echo '{"id":"epica-118","clave":"DEVKIT-118","prioridad":"alta","creado":"2026-01-01T00:00:00.000Z"}' ;;
  "hijas epica-118")
    echo '[]' ;;
  "sueltas DEVKIT")
    echo '[{"id":"card-90","clave":"DEVKIT-90","estado":"Lista","prioridad":"alta","orden":1,"agente":"claude","depende":[],"titulo":"suelta prioritaria"}]' ;;
esac
FIN
  chmod +x "$notion_epica_sin_hijas"
  got=$(env DEVKIT_NOTION_BIN="$notion_epica_sin_hijas" DEVKIT_WS="$ws" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  check "Épica En progreso sin ninguna Tarea en curso no bloquea la cola" "DEVKIT-90" "$got"

  return $fail
}

case "${1:-}" in
  --lista) modo_lista ;;
  --test) run_tests ;;
  '') modo_siguiente ;;
  *)
    err "uso: cola.sh [--lista|--test]"
    exit 64
    ;;
esac

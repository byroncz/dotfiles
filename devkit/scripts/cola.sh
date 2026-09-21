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
# Orden fijo, hasta cuatro grupos:
#   1. Hijas de Épicas en `Lista` o `En progreso` (DEVKIT-109: task-begin.sh
#      pasa la Épica a En progreso con su primera hija): las Épicas por
#      `Prioridad` y `Creado`, y dentro de cada una sus hijas por `Orden` y
#      `Prioridad`.
#   2. Tareas sueltas (sin Padre) en `Lista`, por `Prioridad`, `Orden` y
#      `Creado`.
#   3. Con la bandera `cola.backlog` de `.devkit/devkit.toml` en `true`
#      (DEVKIT-122, apagada por defecto): hijas de Épicas en `Backlog`,
#      mismo orden que el grupo 1 pero sobre ese Estado.
#   4. También con `cola.backlog`: tareas sueltas en `Backlog`, mismo orden
#      que el grupo 2.
# Una card con algo en `Depende de` que no está `Hecha`, o `Agente` =
# `humano`, no entra en ninguno de los cuatro grupos. Los grupos 3 y 4 no
# necesitan excluir `Por refinar` aparte: ese Estado nunca es `Backlog`, así
# que el filtro por Estado ya lo deja fuera. Además, a diferencia de los
# grupos 1 y 2 -que solo leen `Lista`, donde esa definición ya se dio por
# buena al moverla ahí-, los grupos 3 y 4 exigen Criterios de aceptación
# definidos (H2 de pr-review, DEVKIT-122): una card de Backlog sin eso no se
# ofrece ni arranca.
#
# Los grupos 3 y 4 tratan `Backlog` como reserva aprobada por el humano
# (AGENTS.md): a diferencia de los grupos 1 y 2, que solo leen, tomar una
# card de ahí es una acción -la pasa a `Lista` con el comentario "tomada por
# la cola" antes de devolver su Clave, porque de lo contrario `task-begin.sh`
# la rechazaría (una card en `Backlog` no se puede arrancar). Si es hija de
# una Épica en `Backlog`, además mueve la propia Épica a `Lista` -si no,
# `task-begin.sh` no la pasa a `En progreso` y sus hermanas arrastradas
# quedan huérfanas de los cuatro grupos (H1 de pr-review, DEVKIT-122)- y le
# aplica la regla de arrastre de `watch.sh` (DEVKIT-121, "hija 3"): el resto
# de las hijas elegibles de esa Épica pasan a `Lista` también, con un
# comentario aparte en la Épica.
# `--lista` sigue siendo una foto pura: muestra los cuatro grupos pero nunca
# muta nada, la mutación solo ocurre al elegir "la" siguiente card.
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

# La bandera `cola.backlog` de devkit.toml (DEVKIT-122), apagada por
# defecto: sin ella, cola.sh no toca el Backlog. `devkit.toml` es una sola
# tabla `[devkit]` de valores de una línea (mismo criterio que `template` o
# `python`, en entrypoint.sh y devkit.sh); la clave lleva un punto porque el
# nombre de la card la escribe así, no porque haya una tabla `[cola]` aparte.
backlog_habilitado() {
  [ -f "$WS/.devkit/devkit.toml" ] || return 1
  local valor
  valor=$(sed -n 's/^cola\.backlog[[:space:]]*=[[:space:]]*\(true\|false\).*/\1/p' "$WS/.devkit/devkit.toml" | head -1)
  [ "$valor" = "true" ]
}

# "a, b, c": mismo helper que `join_coma` de watch.sh (DEVKIT-121), duplicado
# porque cola.sh no se abastece de watch.sh y el helper es de tres líneas.
join_coma() {  # join_coma <elemento>...
  local out="" x
  for x in "$@"; do
    if [ -z "$out" ]; then out="$x"; else out="$out, $x"; fi
  done
  printf '%s' "$out"
}

# Criterios de aceptación definidos (misma regla que `arrastrar_hijas` de
# watch.sh y `task-close.sh`): vacíos o "pendientes de definir" no cuentan.
# La usan los grupos 3 y 4 para no ofrecer una card de Backlog que un humano
# todavía no terminó de definir (H2 de pr-review, DEVKIT-122): a diferencia
# de los grupos 1 y 2, que solo leen `Lista` -donde esa definición ya se dio
# por buena al moverla ahí-, Backlog es la reserva donde puede seguir sin
# terminar.
criterios_definidos() {  # criterios_definidos <page_id>
  local id=$1 criterios
  criterios=$("$NOTION" criterios "$id" 2>&1) || criterios=""
  [ -n "$criterios" ] && ! printf '%s' "$criterios" | grep -qiE 'pendientes? de definir'
}

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

  if backlog_habilitado; then
    local codigo3

    # Grupo 3: hijas de Épicas en Backlog. `activas` (DEVKIT-82) solo trae
    # los cinco Estados del tablero y Backlog no es uno de ellos, así que
    # este grupo no puede salir de "$activas" como el grupo 1: pide su
    # propia lista a `notion.sh epicas-backlog`.
    local epicas_backlog epicas_backlog_ordenadas='[]'
    codigo3=$(project_code)
    if ! epicas_backlog=$("$NOTION" epicas-backlog "$codigo3" 2>&1); then
      err "no pude leer Notion (epicas-backlog): $epicas_backlog"
      return 1
    fi
    if [ "$(jq 'length' <<<"$epicas_backlog")" -gt 0 ]; then
      epicas_backlog_ordenadas=$(jq -c "$PRIO_DEF"'
        sort_by([(.prioridad | prio), (.creado // "")])' <<<"$epicas_backlog")
    fi

    while IFS=$'\t' read -r epica_id epica_clave; do
      [ -n "$epica_id" ] || continue
      if ! hijas=$("$NOTION" hijas "$epica_id" 2>&1); then
        err "no pude leer Notion (hijas $epica_id): $hijas"
        return 1
      fi
      elegibles=$(jq -c "$PRIO_DEF"'
        map(select(.nivel == "Tarea" and .estado == "Backlog" and .agente != "humano"))
        | sort_by([(.orden // 1e9), (.prioridad | prio)])' <<<"$hijas")
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        criterios_definidos "$(jq -r '.id' <<<"$item")" || continue
        dependencias_hechas "$item"; rc=$?
        case $rc in
          0) items+=("$(jq -c --arg g "$epica_clave" --arg eid "$epica_id" \
               '. + {grupo: $g, origen: "backlog", epica_id: $eid}' <<<"$item")") ;;
          2) return 1 ;;
        esac
      done < <(jq -c '.[]' <<<"$elegibles")
    done < <(jq -r '.[] | [.id, .clave] | @tsv' <<<"$epicas_backlog_ordenadas")

    # Grupo 4: tareas sueltas en Backlog, mismo trato que el grupo 2.
    local sueltas_backlog elegibles3
    if ! sueltas_backlog=$("$NOTION" sueltas-backlog "$codigo3" 2>&1); then
      err "no pude leer Notion (sueltas-backlog): $sueltas_backlog"
      return 1
    fi
    elegibles3=$(jq -c "$PRIO_DEF"'
      map(select(.agente != "humano"))
      | sort_by([(.prioridad | prio), (.orden // 1e9), (.creado // "")])' <<<"$sueltas_backlog")
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      criterios_definidos "$(jq -r '.id' <<<"$item")" || continue
      dependencias_hechas "$item"; rc=$?
      case $rc in
        0) items+=("$(jq -c '. + {grupo: "(sin Épica)", origen: "backlog"}' <<<"$item")") ;;
        2) return 1 ;;
      esac
    done < <(jq -c '.[]' <<<"$elegibles3")
  fi

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

# Al elegir como siguiente una card del grupo 3 o 4 (Backlog, DEVKIT-122), la
# pasa a Lista con el comentario "tomada por la cola" -sin eso, task-begin.sh
# la rechaza, una card en Backlog no arranca- y devuelve 1 si Notion no deja
# escribir, para que modo_siguiente corte en vez de sugerir una card que
# nunca cambió de Estado.
# Si es hija de una Épica en Backlog (trae `epica_id`), además mueve la
# propia Épica a Lista antes de devolver la Clave (H1 de pr-review,
# DEVKIT-122): sin eso, `task-begin.sh:213` no la pasa a En progreso -sigue
# en Backlog- y en la siguiente pasada las hermanas que sí llegaron a Lista
# no entran en ninguno de los cuatro grupos (su Épica ni está en Lista/En
# progreso para el grupo 1, ni siguen en Backlog para el grupo 3), y
# `task-close.sh` tampoco puede cerrar la Épica. Un fallo al mover la Épica
# aborta igual que un fallo al mover la card elegida: dejar la card en Lista
# con su Épica en Backlog es el mismo estado a medias.
# Le aplica también la regla de arrastre de `watch.sh` (DEVKIT-121, "hija
# 3"): el resto de las hijas elegibles de esa Épica -ya están en `cola`,
# `armar_cola` las agrupa por Épica- pasan a Lista también, con la misma
# regla de Criterios de aceptación pendientes de definir que usa
# `arrastrar_hijas`, y un solo comentario en la Épica.
tomar_de_backlog() {  # tomar_de_backlog <elegido JSON> <cola JSON>
  local elegido=$1 cola=$2 id clave epica_id hermanos hitem hid hclave
  local movidas=() pendientes=() comentario
  id=$(jq -r '.id' <<<"$elegido")
  clave=$(jq -r '.clave' <<<"$elegido")
  if ! "$NOTION" set "$id" Estado=Lista >/dev/null 2>&1; then
    err "no pude mover $clave (Backlog) a Lista"
    return 1
  fi
  "$NOTION" comentar "$id" "tomada por la cola" >/dev/null 2>&1

  epica_id=$(jq -r '.epica_id // empty' <<<"$elegido")
  [ -n "$epica_id" ] || return 0

  if ! "$NOTION" set "$epica_id" Estado=Lista >/dev/null 2>&1; then
    err "no pude mover la Épica de $clave (Backlog) a Lista"
    return 1
  fi

  hermanos=$(jq -c --arg eid "$epica_id" --arg propia "$clave" \
    '[.[] | select(.epica_id == $eid and .clave != $propia)]' <<<"$cola")
  while IFS= read -r hitem; do
    [ -n "$hitem" ] || continue
    hid=$(jq -r '.id' <<<"$hitem")
    hclave=$(jq -r '.clave' <<<"$hitem")
    if criterios_definidos "$hid"; then
      if "$NOTION" set "$hid" Estado=Lista >/dev/null 2>&1; then
        movidas+=("$hclave")
      else
        err "no pude mover $hclave (hija de la misma Épica) a Lista"
      fi
    else
      pendientes+=("$hclave")
    fi
  done < <(jq -c '.[]' <<<"$hermanos")

  comentario="Épica movida de Backlog a Lista: la tomó $clave."
  [ "${#movidas[@]}" -eq 0 ] || comentario="$comentario Arrastradas de Backlog a Lista: $(join_coma "${movidas[@]}")."
  [ "${#pendientes[@]}" -eq 0 ] || comentario="$comentario Con Criterios de aceptación pendientes de definir, sin mover: $(join_coma "${pendientes[@]}")."
  "$NOTION" comentar "$epica_id" "$comentario" >/dev/null 2>&1
  return 0
}

modo_siguiente() {
  local codigo activas en_curso cola elegido clave origen
  codigo=$(project_code)
  [ -n "$codigo" ] || { err "no encuentro \"project\" en $WS/.devkit/devkit.toml"; exit 1; }
  activas=$("$NOTION" activas "$codigo" 2>&1) || { err "no pude leer Notion: $activas"; exit 1; }
  en_curso=$(jq -r '[.[] | select(.nivel == "Tarea" and (.estado == "En progreso" or .estado == "Revisión automática"))] | length' <<<"$activas")
  [ "$en_curso" -eq 0 ] || exit 0
  task_start_vivo "$activas" && exit 0
  cola=$(armar_cola "$activas") || exit 1
  elegido=$(jq -c '.[0] // empty' <<<"$cola")
  [ -n "$elegido" ] || exit 0
  clave=$(jq -r '.clave' <<<"$elegido")
  origen=$(jq -r '.origen // empty' <<<"$elegido")
  [ "$origen" != "backlog" ] || tomar_de_backlog "$elegido" "$cola" || exit 1
  printf '%s\n' "$clave"
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

  # Bandera cola.backlog (DEVKIT-122): Lista vacía, Backlog con una Épica
  # -DEVKIT-300, con dos hijas elegibles con Criterios definidos (DEVKIT-301
  # orden 1, DEVKIT-302 orden 2) y una con Criterios de aceptación
  # pendientes de definir (DEVKIT-305, que por eso nunca entra a la cola,
  # H2 de pr-review), más una hija Por refinar (DEVKIT-303) que nunca debe
  # aparecer- y una suelta (DEVKIT-310). Toma primero la hija de la Épica, la
  # pasa a Lista con "tomada por la cola" y, por ser hija de una Épica en
  # Backlog, le aplica la hija 3 (DEVKIT-121): arrastra a Lista el resto de
  # hijas elegibles de esa Épica.
  local llamadas_backlog="$tmp/llamadas-backlog"
  local notion_backlog="$tmp/notion-backlog"
  cat >"$notion_backlog" <<FIN
#!/usr/bin/env bash
echo "\$*" >>"$llamadas_backlog"
case "\$1 \$2" in
  "activas DEVKIT")
    echo '[]' ;;
  "epicas-backlog DEVKIT")
    echo '[{"id":"epica-300","clave":"DEVKIT-300","prioridad":"alta","creado":"2026-01-01T00:00:00.000Z"}]' ;;
  "hijas epica-300")
    echo '[
      {"id":"card-301","clave":"DEVKIT-301","nivel":"Tarea","estado":"Backlog","prioridad":"media","orden":1,"agente":"claude","depende":[],"titulo":"hija backlog 1"},
      {"id":"card-302","clave":"DEVKIT-302","nivel":"Tarea","estado":"Backlog","prioridad":"alta","orden":2,"agente":"claude","depende":[],"titulo":"hija backlog 2"},
      {"id":"card-305","clave":"DEVKIT-305","nivel":"Tarea","estado":"Backlog","prioridad":"baja","orden":3,"agente":"claude","depende":[],"titulo":"hija sin criterios"},
      {"id":"card-303","clave":"DEVKIT-303","nivel":"Tarea","estado":"Por refinar","prioridad":"alta","orden":1,"agente":"claude","depende":[],"titulo":"por refinar"}
    ]' ;;
  "sueltas-backlog DEVKIT")
    echo '[{"id":"card-310","clave":"DEVKIT-310","estado":"Backlog","prioridad":"alta","orden":1,"agente":"claude","depende":[],"titulo":"suelta backlog"}]' ;;
  "criterios card-301")
    echo "criterio definido" ;;
  "criterios card-302")
    echo "criterio definido" ;;
  "criterios card-305")
    echo "pendientes de definir" ;;
  "criterios card-310")
    echo "criterio definido" ;;
  "set epica-300")
    echo ok ;;
  "set card-301")
    echo ok ;;
  "set card-302")
    echo ok ;;
  "comentar card-301")
    echo ok ;;
  "comentar epica-300")
    echo ok ;;
esac
FIN
  chmod +x "$notion_backlog"

  local ws_backlog="$tmp/ws-backlog"
  mkdir -p "$ws_backlog/.devkit"
  printf '[devkit]\nproject = "DEVKIT"\ncola.backlog = true\n' >"$ws_backlog/.devkit/devkit.toml"

  got=$(env DEVKIT_NOTION_BIN="$notion_backlog" DEVKIT_WS="$ws_backlog" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  check "cola.backlog: Lista vacía, toma primero la hija de la Épica en Backlog" "DEVKIT-301" "$got"
  check "cola.backlog: mueve la card elegida a Lista" 1 \
    "$(grep -c '^set card-301 Estado=Lista$' "$llamadas_backlog")"
  check "cola.backlog: comenta \"tomada por la cola\" en la card elegida" 1 \
    "$(grep -c '^comentar card-301 tomada por la cola$' "$llamadas_backlog")"
  check "cola.backlog: mueve también la Épica de Backlog a Lista" 1 \
    "$(grep -c '^set epica-300 Estado=Lista$' "$llamadas_backlog")"
  check "cola.backlog: hija 3 arrastra a Lista la otra hija con Criterios definidos" 1 \
    "$(grep -c '^set card-302 Estado=Lista$' "$llamadas_backlog")"
  check "cola.backlog: nunca toca la hija con Criterios pendientes de definir (filtrada antes)" 0 \
    "$(grep -c '^set card-305' "$llamadas_backlog")"
  check "cola.backlog: comenta en la Épica que se movió y qué hijas arrastró" 1 \
    "$(grep -cF 'comentar epica-300 Épica movida de Backlog a Lista: la tomó DEVKIT-301. Arrastradas de Backlog a Lista: DEVKIT-302.' "$llamadas_backlog")"

  got=$(env DEVKIT_NOTION_BIN="$notion_backlog" DEVKIT_WS="$ws_backlog" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh" --lista)
  check "cola.backlog: --lista nunca muestra una card Por refinar" no \
    "$(grep -q 'DEVKIT-303' <<<"$got" && echo si || echo no)"
  check "cola.backlog: --lista nunca muestra una card con Criterios pendientes de definir" no \
    "$(grep -q 'DEVKIT-305' <<<"$got" && echo si || echo no)"
  check "cola.backlog: --lista muestra las hijas elegibles de la Épica y luego la suelta, en ese orden" \
    "DEVKIT-301
DEVKIT-302
DEVKIT-310" \
    "$(cut -d' ' -f1 <<<"$got" | tr -s ' ')"

  # Apagada por defecto (sin "cola.backlog" en devkit.toml, el mismo $ws de
  # las pruebas de arriba): aunque Lista esté vacía, no sugiere nada del
  # Backlog.
  got=$(env DEVKIT_NOTION_BIN="$notion_backlog" DEVKIT_WS="$ws" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  check "cola.backlog apagada por defecto: nada de Backlog aunque Lista esté vacía" "" "$got"

  # H1 de pr-review (DEVKIT-122), segunda pasada: la Épica ya está en Lista
  # -como quedaría tras la pasada de arriba- y trae una hija en Lista
  # (arrastrada). Sin el fix, la Épica se quedaba en Backlog y esta hija no
  # entraba en ningún grupo; con la Épica en Lista, el grupo 1 normal la ve.
  local activas_segunda_pasada="$tmp/activas-segunda-pasada.json"
  cat >"$activas_segunda_pasada" <<'FIN'
[{"clave":"DEVKIT-300","estado":"Lista","nivel":"Épica"},
 {"clave":"DEVKIT-302","estado":"Lista","nivel":"Tarea"}]
FIN
  local notion_segunda_pasada="$tmp/notion-segunda-pasada"
  cat >"$notion_segunda_pasada" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "activas DEVKIT")
    cat "$activas_segunda_pasada" ;;
  "card DEVKIT-300")
    echo '{"id":"epica-300","clave":"DEVKIT-300","prioridad":"alta","creado":"2026-01-01T00:00:00.000Z"}' ;;
  "hijas epica-300")
    echo '[{"id":"card-302","clave":"DEVKIT-302","nivel":"Tarea","estado":"Lista","prioridad":"alta","orden":2,"agente":"claude","depende":[],"titulo":"hija backlog 2"}]' ;;
esac
FIN
  chmod +x "$notion_segunda_pasada"
  got=$(env DEVKIT_NOTION_BIN="$notion_segunda_pasada" DEVKIT_WS="$ws" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  check "segunda pasada: Épica ya en Lista con su hija arrastrada, la cola la sugiere" "DEVKIT-302" "$got"

  # H2 de pr-review (DEVKIT-122): una hija en Orden 1 con Criterios de
  # aceptación pendientes de definir no bloquea el grupo 3 ni se ofrece -se
  # salta, igual que se saltaría del grupo 1 o 2 si estuviera en Lista-; la
  # cola elige la siguiente candidata elegible, DEVKIT-322 en Orden 2.
  local notion_orden_pendiente="$tmp/notion-orden-pendiente"
  cat >"$notion_orden_pendiente" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "activas DEVKIT")
    echo '[]' ;;
  "epicas-backlog DEVKIT")
    echo '[{"id":"epica-320","clave":"DEVKIT-320","prioridad":"alta","creado":"2026-01-01T00:00:00.000Z"}]' ;;
  "hijas epica-320")
    echo '[
      {"id":"card-321","clave":"DEVKIT-321","nivel":"Tarea","estado":"Backlog","prioridad":"alta","orden":1,"agente":"claude","depende":[],"titulo":"orden 1 con criterios pendientes"},
      {"id":"card-322","clave":"DEVKIT-322","nivel":"Tarea","estado":"Backlog","prioridad":"alta","orden":2,"agente":"claude","depende":[],"titulo":"orden 2 con criterios definidos"}
    ]' ;;
  "sueltas-backlog DEVKIT")
    echo '[]' ;;
  "criterios card-321")
    echo "pendientes de definir" ;;
  "criterios card-322")
    echo "criterio definido" ;;
  "set epica-320")
    echo ok ;;
  "set card-322")
    echo ok ;;
  "comentar card-322")
    echo ok ;;
  "comentar epica-320")
    echo ok ;;
esac
FIN
  chmod +x "$notion_orden_pendiente"
  got=$(env DEVKIT_NOTION_BIN="$notion_orden_pendiente" DEVKIT_WS="$ws_backlog" DEVKIT_PS_BIN="$ps_libre" bash "$HERE/cola.sh")
  check "cola.backlog: hija en Orden 1 con Criterios pendientes se salta, elige la de Orden 2" "DEVKIT-322" "$got"

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

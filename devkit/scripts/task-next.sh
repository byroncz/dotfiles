#!/usr/bin/env bash
# Lanza la siguiente hija libre de la Épica de una card (DEVKIT-56). Antes solo
# lo hacía task-close.sh tras el merge, y una Épica se detenía durante las
# horas que tarda el approve humano. Ahora lo llaman dos:
#   - watch.sh, cuando `pr-review` da OK y la card entra en `Lista para merge`;
#   - task-close.sh, cuando la card pasa a `Hecha` tras el merge.
#
# Uso:
#   task-next.sh <Clave>
#
# Hija libre, con las reglas de task-start: `Lista`, nivel Tarea, todo
# `Depende de` en `Hecha`, orden por `Orden` y luego por `Prioridad`. Una
# dependencia fuera de la Épica se consulta aparte. `Depende de` es lo que
# decide si una hija arranca con la anterior en `Lista para merge` o espera a
# que esté `Hecha`: `epic-plan` lo llena cuando dos hijas tocan los mismos
# archivos.
#
# Una sola hija en marcha a la vez. No lanza nada si una hermana está
# `En progreso` o `Revisión automática`, o si ya hay un `task-start` vivo para
# una hermana en `Lista` (lanzado, pero esperando `skill.lock` o sin haber
# cambiado aún el Estado). Así las dos llamadas, al OK y al merge, no arrancan
# dos veces la misma hija ni dos hijas encima de la misma rama de trabajo.
# Sin paralelismo: el que lanza es `devkit-run`, cuyo worker toma `skill.lock`
# y espera su turno detrás de la skill que esté corriendo.
#
# Idempotente: repetirlo con la hija ya lanzada no hace nada.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
DEVKIT_RUN="${DEVKIT_RUN_BIN:-$HERE/devkit-run.sh}"
PS_BIN="${DEVKIT_PS_BIN:-ps}"

say() { printf 'task-next: %s\n' "$*"; }

clave="${1:-}"
if [ -z "$clave" ]; then
  echo "uso: task-next.sh <Clave>" >&2
  exit 64
fi
codigo=${clave%-*}

card=$("$NOTION" card "$clave") || { say "no pude leer $clave en Notion"; exit 1; }
padre=$(jq -r '.padre[0] // ""' <<<"$card")
if [ -z "$padre" ]; then
  say "$clave no tiene Épica; nada que encadenar"
  exit 0
fi
hijas=$("$NOTION" hijas "$padre") || { say "no pude leer las hijas de la Épica"; exit 1; }

# --- ¿Hay una hija en marcha? ------------------------------------------------
en_curso=$(jq -r --arg c "$codigo" \
  '[.[] | select(.estado == "En progreso" or .estado == "Revisión automática") | "\($c)-\(.numero) (\(.estado))"] | join(", ")' <<<"$hijas")
if [ -n "$en_curso" ]; then
  say "no lanzo otra hija: $en_curso sigue en curso"
  exit 0
fi

# El bucle lanza con `devkit-run.sh --sync` y un lanzamiento manual o desde
# task-close con `--worker`; en ambos la línea del proceso trae
# "/task-start <Clave>". Solo cuentan las hermanas en `Lista`: una en otro
# Estado ya se vio arriba.
procesos=$("$PS_BIN" -eo args= 2>/dev/null)
for c in $(jq -r --arg c "$codigo" '.[] | select(.estado == "Lista") | "\($c)-\(.numero)"' <<<"$hijas"); do
  if grep -qE -- "(--sync|--worker|claude -p) /task-start $c( |$)" <<<"$procesos"; then
    say "no lanzo otra hija: task-start $c ya corre o espera el candado"
    exit 0
  fi
done

# --- Siguiente hija libre ----------------------------------------------------
hechas=$(jq -c '[.[] | select(.estado == "Hecha") | .id]' <<<"$hijas")
for dep in $(jq -r --argjson h "$hechas" \
    '[.[] | select(.estado == "Lista") | .depende[]] | unique | map(select(. as $d | $h | index($d) | not)) | .[]' <<<"$hijas"); do
  if [ "$(jq -r --arg d "$dep" '[.[] | select(.id == $d)] | length' <<<"$hijas")" -eq 0 ] \
     && [ "$("$NOTION" pagina "$dep" 2>/dev/null | jq -r .estado)" = "Hecha" ]; then
    hechas=$(jq -c --arg d "$dep" '. + [$d]' <<<"$hechas")
  fi
done
siguiente=$(jq -r --argjson h "$hechas" --arg c "$codigo" '
  def prio: {"alta": 0, "media": 1, "baja": 2}[. // ""] // 3;
  [.[] | select(.estado == "Lista" and .nivel == "Tarea")
       | select(all(.depende[]; . as $d | $h | index($d)))]
  | sort_by([(.orden // 1e9), (.prioridad | prio)])
  | first // empty | "\($c)-\(.numero)"' <<<"$hijas")

if [ -n "$siguiente" ]; then
  if "$DEVKIT_RUN" task-start "$siguiente" >/dev/null 2>&1; then
    say "lanzada la siguiente hija: task-start $siguiente"
  else
    say "no pude lanzar task-start $siguiente"
    exit 1
  fi
elif [ "$(jq '[.[] | select(.estado == "Lista")] | length' <<<"$hijas")" -gt 0 ]; then
  esperan=$(jq -r --arg c "$codigo" '[.[] | select(.estado == "Lista") | "\($c)-\(.numero)"] | join(", ")' <<<"$hijas")
  # Con una hermana en `Lista para merge`, esperar es lo normal: su merge
  # vuelve a llamar a este script. Sin ninguna, la Épica quedó detenida y se
  # avisa en ella.
  if [ "$(jq '[.[] | select(.estado == "Lista para merge")] | length' <<<"$hijas")" -eq 0 ]; then
    "$NOTION" comentar "$padre" "Tras $clave no hay hija libre: $esperan esperan dependencias que no están Hecha."
  fi
  say "sin hija libre; $esperan esperan dependencias"
else
  say "sin hijas en Lista"
fi

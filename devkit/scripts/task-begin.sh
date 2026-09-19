#!/usr/bin/env bash
# Pasos mecánicos de `task-start` en bash (DEVKIT-90): workspace limpio, card
# por Notion, rama y Estado. Antes eran los pasos 1 a 7 de la skill
# (10 a 15 turnos de agente por card, cada uno una llamada a bash o a Notion
# que un script hace en segundos y sin tokens, Épica DEVKIT-86, Contexto 2).
#
# Uso:
#   task-begin.sh <Clave>
#
# Localiza la card con `notion.sh` (por `ID` y `Proyecto`, nunca por la
# fórmula `Clave`: el MCP no la devuelve, ver AGENTS.md) y decide por su
# `Estado`, en ese orden -Notion antes que git, DEVKIT-76: así un
# relanzamiento sobre una card que ya no es tomable responde en este mismo
# turno pase lo que pase en `git status`-:
#   Backlog                                    -> sale con 1, sin tocar git
#                                                  ni Notion
#   Hecha / Lista para merge / Revisión automática
#                                               -> sale con 1, sin tocar git
#                                                  ni Notion
#   Bloqueada                                  -> sale con 1, sin tocar git
#                                                  ni Notion
#   Lista, o En progreso sin Rama               -> comprueba workspace limpio
#                                                  y `devkit-run --otros-agentes`;
#                                                  actualiza `main`, crea la
#                                                  rama (`feat/`, `fix/`,
#                                                  `chore/` según `Tipo`, la
#                                                  Clave en mayúsculas y un
#                                                  slug del título), la sube y
#                                                  deja la card `En progreso`
#                                                  con `Agente=claude` y
#                                                  `Rama`
#   En progreso con Rama (reanudación)          -> comprueba workspace limpio
#                                                  y `devkit-run --otros-agentes`;
#                                                  cambia a esa rama
#
# Motivos por stderr (una línea por mensaje; el último es el motivo que
# devkit-run.sh registra y, si corresponde, pasa a task-block.sh). Sale con 0
# solo si dejó la card lista para trabajar: imprime en stdout, en Markdown
# plano, las propiedades de la card, su contenido (Objetivo, Criterios de
# aceptación, Notas) y todos sus comentarios en orden -los comentarios que
# amplían el alcance cuentan, DEVKIT-41-, para que quien la reciba en el
# prompt no necesite consultar Notion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
NOTION="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
DEVKIT_RUN="${DEVKIT_RUN_BIN:-$HERE/devkit-run.sh}"
SLUGIFY="${DEVKIT_SLUGIFY_BIN:-$HERE/slugify.sh}"

err() { printf 'task-begin: %s\n' "$*" >&2; }

clave="${1:-}"
if [ -z "$clave" ]; then
  echo "uso: task-begin.sh <Clave>" >&2
  exit 64
fi

card=$("$NOTION" card "$clave") || { err "no pude leer $clave en Notion"; exit 1; }
id=$(jq -r .id <<<"$card")
estado=$(jq -r '.estado // ""' <<<"$card")
titulo=$(jq -r '.titulo // ""' <<<"$card")
tipo=$(jq -r '.tipo // ""' <<<"$card")
prioridad=$(jq -r '.prioridad // ""' <<<"$card")
rama_actual=$(jq -r '.rama // ""' <<<"$card")
pr=$(jq -r '.pr // ""' <<<"$card")

case "$estado" in
  Backlog)
    err "$clave está en Backlog; el humano debe moverla a Lista."
    exit 1
    ;;
  Hecha|"Lista para merge"|"Revisión automática")
    err "$clave ya está en $estado (PR ${pr:-sin PR}); no hay nada que hacer."
    exit 1
    ;;
  Bloqueada)
    err "$clave está bloqueada; el humano debe moverla a En progreso antes de relanzar."
    exit 1
    ;;
  Lista)
    reanudacion=0
    ;;
  "En progreso")
    if [ -n "$rama_actual" ]; then reanudacion=1; else reanudacion=0; fi
    ;;
  *)
    err "$clave tiene un Estado que no reconozco: ${estado:-vacío}."
    exit 1
    ;;
esac

# --- Workspace libre: solo hasta aquí importa, Lista o En progreso ----------
# Lista los archivos sucios en el propio mensaje (DEVKIT-99): sin esto, el
# humano tenía que entrar al contenedor y correr `git status` a mano para
# saber qué borrar o commitear antes de relanzar.
sucio=$(git -C "$WS" status --porcelain 2>/dev/null)
if [ -n "$sucio" ]; then
  err "el workspace tiene cambios sin commit; no puedo iniciar $clave sin mezclar trabajo de otra card: $(printf '%s' "$sucio" | tr '\n' ' ')"
  exit 1
fi
# Esta comprobación ya corrió antes de que el agente arrancara: si necesita
# repetirla más adelante en la sesión, su propio `claude -p` puede aparecer
# en el resultado de `--otros-agentes` como `propio: <pid> ...` (DEVKIT-54,
# DEVKIT-63, DEVKIT-77). El agente nunca debe correr su propio `ps`/`pgrep`
# para desconfiar de este resultado, ni interpretar ese `propio:` como un
# agente ajeno.
if ! otros=$("$DEVKIT_RUN" --otros-agentes 2>&1); then
  err "otro agente ocupa el workspace: $(printf '%s' "$otros" | tr '\n' ' ')"
  exit 1
fi

# URL de origin en forma https://github.com/<owner>/<repo> (sin .git), para
# componer la Rama que guarda Notion, igual que hace un humano al copiarla
# desde GitHub.
url_remoto() {
  local url
  url=$(git -C "$WS" remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
  esac
  printf '%s' "${url%.git}"
}

if [ "$reanudacion" = 1 ]; then
  rama=$(printf '%s' "$rama_actual" | sed -E 's#^.*/tree/##')
  if [ -z "$rama" ]; then
    err "la card está En progreso pero su Rama no tiene un nombre reconocible: $rama_actual"
    exit 1
  fi
  git -C "$WS" fetch -q origin "$rama" 2>/dev/null
  if git -C "$WS" show-ref --verify --quiet "refs/heads/$rama"; then
    git -C "$WS" switch -q "$rama" || { err "no pude cambiar a la rama $rama (reanudación)."; exit 1; }
    # La rama local puede haber quedado atrás de origin (otra sesión, u otro
    # intento de esta misma card): sin este pull, la reanudación seguía
    # trabajando sobre un punto de partida viejo (H6 de pr-review en
    # DEVKIT-90). Si diverge de verdad (raro: implicaría un push --force
    # sobre la rama de la card), no es fatal, ya queda sobre una rama válida.
    git -C "$WS" pull -q --ff-only 2>/dev/null || true
  elif git -C "$WS" show-ref --verify --quiet "refs/remotes/origin/$rama"; then
    git -C "$WS" switch -q -c "$rama" --track "origin/$rama" \
      || { err "no pude cambiar a la rama $rama (reanudación)."; exit 1; }
  else
    err "no encuentro la rama $rama (ni local ni en origin) para reanudar $clave."
    exit 1
  fi
else
  if ! git -C "$WS" fetch -q origin 2>/dev/null; then
    err "no pude actualizar main (git fetch)."
    exit 1
  fi
  if ! git -C "$WS" switch -q main 2>/dev/null; then
    err "no pude cambiar a main."
    exit 1
  fi
  if ! git -C "$WS" pull -q --ff-only 2>/dev/null; then
    err "no pude actualizar main (git pull --ff-only)."
    exit 1
  fi
  case "$tipo" in
    feature) prefijo=feat ;;
    bug) prefijo=fix ;;
    chore) prefijo=chore ;;
    *) prefijo=feat ;;
  esac
  slug=$("$SLUGIFY" "$titulo")
  rama="$prefijo/$clave-$slug"
  # Si la rama ya existe (local o en origin), no es un choque de nombres: es
  # un relanzamiento tras un intento anterior que la creó y subió pero no
  # llegó a actualizar Notion (el `set` de más abajo falló a mitad de
  # camino). Antes, `switch -c` fallaba con "¿ya existe?" y la card quedaba
  # trabada -Lista o En progreso sin Rama- hasta que el humano borrara la
  # rama a mano (H6 de pr-review en DEVKIT-90). Ahora la reutiliza.
  if git -C "$WS" show-ref --verify --quiet "refs/heads/$rama"; then
    git -C "$WS" switch -q "$rama" || { err "no pude cambiar a la rama $rama, que ya existía."; exit 1; }
  elif git -C "$WS" fetch -q origin "$rama" 2>/dev/null \
      && git -C "$WS" show-ref --verify --quiet "refs/remotes/origin/$rama"; then
    git -C "$WS" switch -q -c "$rama" --track "origin/$rama" \
      || { err "no pude cambiar a la rama $rama, que ya existía en origin."; exit 1; }
  elif ! git -C "$WS" switch -q -c "$rama" 2>/dev/null; then
    err "no pude crear la rama $rama."
    exit 1
  fi
  if ! git -C "$WS" push -q -u origin "$rama" 2>/dev/null; then
    err "la rama $rama existe, pero no pude subirla (git push)."
    exit 1
  fi
  base_remoto=$(url_remoto) || base_remoto=""
  rama_url="${base_remoto:+$base_remoto/tree/}$rama"
  if ! "$NOTION" set "$id" Estado="En progreso" Agente=claude Rama="$rama_url" >/dev/null; then
    err "la rama $rama quedó creada y subida, pero no pude actualizar la card en Notion (Estado/Agente/Rama)."
    exit 1
  fi
  rama_actual="$rama_url"
fi

# --- Card lista: el volcado que evita que el agente consulte Notion --------
# La card ya quedó En progreso, con la rama creada y subida (o, en una
# reanudación, ya en uso): un fallo de Notion aquí no debe salir con 0 y
# dejar al agente sin Objetivo ni Criterios, o creyendo que "(sin
# comentarios)" significa que no hay ninguno cuando en realidad Notion no
# respondió -el mismo fallo silencioso de DEVKIT-41. El relanzamiento entra
# por la reanudación, así que no se pierde nada.
if ! contenido=$("$NOTION" contenido "$id" 2>/dev/null); then
  err "la card $clave quedó En progreso, pero no pude leer su contenido en Notion (Objetivo/Criterios); relanza para reintentar."
  exit 1
fi
if ! comentarios=$("$NOTION" comentarios "$id" 2>/dev/null); then
  err "la card $clave quedó En progreso, pero no pude leer sus comentarios en Notion; relanza para reintentar."
  exit 1
fi

cat <<EOF
- Clave: $clave
- Título: $titulo
- Tipo: ${tipo:-sin Tipo}
- Prioridad: ${prioridad:-sin Prioridad}
- Estado: En progreso
- Rama: $rama_actual
- PR: ${pr:-sin PR}

$contenido

## Comentarios
${comentarios:-(sin comentarios)}
EOF

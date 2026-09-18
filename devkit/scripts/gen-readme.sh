#!/bin/sh
# ---------------------------------------------------------------------------
#  devkit: arma README.md desde devkit/README.tmpl.md, sustituyendo
#  {{STACK}}, {{COMANDOS}} y {{SKILLS}} por contenido generado. Único modo de
#  tocar el README (AGENTS.md); se corre a mano y se commitea el resultado.
#
#    gen-readme.sh          escribe README.md
#    gen-readme.sh --check  sale con 1 si el README commiteado quedó viejo
#    gen-readme.sh --test   autoprueba, con fixtures propios
#
#  Stack: tabla de herramientas con versión, generada por
#  `gen-stack.sh --tabla` desde devkit/scripts/stack.tsv y los Dockerfile,
#  más la línea de extensiones que reusa de gen-stack.sh. Comandos: agrupado
#  desde devkit/scripts/comandos.txt. Skills: la línea `description` del
#  SKILL.md de cada skill, en el orden del flujo.
# ---------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # devkit/

TMPL="${DEVKIT_GEN_README_TMPL:-$HERE/README.tmpl.md}"
COMANDOS="${DEVKIT_GEN_README_COMANDOS:-$HERE/scripts/comandos.txt}"
SKILLS_DIR="${DEVKIT_GEN_README_SKILLS_DIR:-$HERE/agents/skills}"
GEN_STACK="${DEVKIT_GEN_README_GEN_STACK:-$HERE/scripts/gen-stack.sh}"
README="${DEVKIT_GEN_README_README:-$(pwd)/README.md}"

# Orden del flujo, no alfabético: así se lee de alta de proyecto a cierre.
SKILLS_ORDEN="project-init epic-plan task-create task-start task-submit pr-review task-fix task-document project-status template-update template-propagate"

stack() {
  sh "$GEN_STACK" --tabla
  echo
  echo "Generada por \`gen-readme.sh\` (verificado con \`--check\`), no a mano:"
  echo
  sh "$GEN_STACK"
}

# Agrupa devkit/scripts/comandos.txt (línea `## título` abre grupo, línea
# `comando | descripción` es una fila) en tablas markdown por grupo.
comandos() {  # comandos <comandos.txt>
  awk '
    BEGIN { FS = " \\| "; first = 1 }
    /^## / {
      if (!first) print ""
      first = 0
      titulo = $0
      sub(/^## /, "", titulo)
      print "### " titulo
      print ""
      print "| Comando | Qué hace |"
      print "|---|---|"
      next
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      nombre = $1
      desc = $0
      sub(/^[^|]*\| */, "", desc)
      print "| `" nombre "` | " desc " |"
    }
  ' "$1"
}

# Una fila por skill, en SKILLS_ORDEN, con la línea `description` de su
# SKILL.md tal cual (ya trae qué hace, cuándo usarla y sus argumentos).
skills() {  # skills <skills_dir>
  echo "| Skill | Qué hace |"
  echo "|---|---|"
  for nombre in $SKILLS_ORDEN; do
    archivo="$1/$nombre/SKILL.md"
    [ -f "$archivo" ] || { echo "gen-readme.sh: no existe $archivo" >&2; exit 2; }
    desc="$(sed -n 's/^description: //p' "$archivo" | head -1)"
    printf '| `/%s` | %s |\n' "$nombre" "$desc"
  done
}

# Sustituye, línea por línea, cada placeholder ({{STACK}}, {{COMANDOS}},
# {{SKILLS}}) por el bloque multilínea que le toca. Un placeholder debe ser
# la línea completa (sin texto alrededor).
armar() {
  while IFS= read -r linea || [ -n "$linea" ]; do
    case "$linea" in
      '{{STACK}}') stack ;;
      '{{COMANDOS}}') comandos "$COMANDOS" ;;
      '{{SKILLS}}') skills "$SKILLS_DIR" ;;
      *) printf '%s\n' "$linea" ;;
    esac
  done < "$TMPL"
}

# --- Autoprueba --------------------------------------------------------------
if [ "${1:-}" = "--test" ]; then
  fail=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  check() {  # check <nombre> <esperado> <obtenido>
    if [ "$2" = "$3" ]; then
      printf 'ok   %-45s\n' "$1"
    else
      printf 'FAIL %-45s esperado "%s", obtenido "%s"\n' "$1" "$2" "$3"
      fail=1
    fi
  }

  printf '# t\n{{COMANDOS}}\n' > "$tmp/tmpl.md"
  printf '# comentario\n\n## Grupo uno\nfoo | hace foo\nbar baz | hace bar baz\n## Grupo dos\nqux | hace qux\n' > "$tmp/comandos.txt"
  esperado='# t
### Grupo uno

| Comando | Qué hace |
|---|---|
| `foo` | hace foo |
| `bar baz` | hace bar baz |

### Grupo dos

| Comando | Qué hace |
|---|---|
| `qux` | hace qux |'
  obtenido="$(DEVKIT_GEN_README_TMPL="$tmp/tmpl.md" DEVKIT_GEN_README_COMANDOS="$tmp/comandos.txt" \
    sh "$HERE/scripts/gen-readme.sh" --imprimir)"
  check "comandos agrupados" "$esperado" "$obtenido"

  mkdir -p "$tmp/skills/una-skill" "$tmp/skills/otra-skill"
  printf -- '---\nname: una-skill\ndescription: Hace una cosa.\n---\n' > "$tmp/skills/una-skill/SKILL.md"
  printf -- '---\nname: otra-skill\ndescription: Hace otra cosa.\n---\n' > "$tmp/skills/otra-skill/SKILL.md"
  printf '{{SKILLS}}\n' > "$tmp/tmpl-skills.md"
  esperado='| Skill | Qué hace |
|---|---|
| `/una-skill` | Hace una cosa. |
| `/otra-skill` | Hace otra cosa. |'
  obtenido="$(DEVKIT_GEN_README_TMPL="$tmp/tmpl-skills.md" DEVKIT_GEN_README_SKILLS_DIR="$tmp/skills" \
    DEVKIT_GEN_README_SKILLS_ORDEN="una-skill otra-skill" sh "$HERE/scripts/gen-readme.sh" --imprimir)"
  check "skills desde SKILL.md" "$esperado" "$obtenido"

  printf '"Anthropic.claude-code" = "latest"\n' > "$tmp/extensions.toml"
  printf 'ARG BASE_IMAGE=debian:trixie-slim\nARG UV_VERSION=1.0.0\nARG GH_VERSION=2.0.0\nARG RCLONE_VERSION=3.0.0\nARG BWS_VERSION=4.0.0\nARG STARSHIP_VERSION=5.0.0\nARG OPENVSCODE_VERSION=6.0.0\n' > "$tmp/Dockerfile"
  printf 'FROM alpine:9.9\n' > "$tmp/proxy-Dockerfile"
  printf 'uv | uv | Gestiona Python.\n' > "$tmp/stack.tsv"
  printf '# t\n{{STACK}}\n' > "$tmp/tmpl-stack.md"
  obtenido="$(DEVKIT_GEN_README_TMPL="$tmp/tmpl-stack.md" DEVKIT_GEN_STACK_TOML="$tmp/extensions.toml" \
    DEVKIT_GEN_STACK_DOCKERFILE="$tmp/Dockerfile" DEVKIT_GEN_STACK_TSV="$tmp/stack.tsv" \
    DEVKIT_GEN_STACK_PROXY_DOCKERFILE="$tmp/proxy-Dockerfile" sh "$HERE/scripts/gen-readme.sh" --imprimir)"
  case "$obtenido" in
    *"| uv | Gestiona Python. | 1.0.0 |"*"Anthropic.claude-code latest"*) check "stack trae tabla con versión y extensiones" si si ;;
    *) check "stack trae tabla con versión y extensiones" si no ;;
  esac

  printf '# t\nsin placeholders\n' > "$tmp/tmpl-llano.md"
  printf '# t\nsin placeholders\n' > "$tmp/README.md"
  DEVKIT_GEN_README_TMPL="$tmp/tmpl-llano.md" DEVKIT_GEN_README_README="$tmp/README.md" \
    sh "$HERE/scripts/gen-readme.sh" --check >/dev/null 2>&1
  check "--check con el README al día sale 0" 0 "$?"

  printf 'algo viejo\n' > "$tmp/README.md"
  DEVKIT_GEN_README_TMPL="$tmp/tmpl-llano.md" DEVKIT_GEN_README_README="$tmp/README.md" \
    sh "$HERE/scripts/gen-readme.sh" --check >/dev/null 2>&1
  check "--check con el README viejo sale 1" 1 "$?"

  exit $fail
fi

# SKILLS_ORDEN se puede anular por variable de entorno, solo para la
# autoprueba de arriba: fuera de --test nunca se define, así que se usa la
# constante declarada al inicio del script.
[ -n "${DEVKIT_GEN_README_SKILLS_ORDEN:-}" ] && SKILLS_ORDEN="$DEVKIT_GEN_README_SKILLS_ORDEN"

[ -f "$TMPL" ] || { echo "gen-readme.sh: no existe $TMPL" >&2; exit 2; }

# --imprimir es de uso interno (autoprueba): arma sobre stdout sin comparar
# ni escribir nada.
if [ "${1:-}" = "--imprimir" ]; then
  armar
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  [ -f "$README" ] || { echo "gen-readme.sh: no existe $README" >&2; exit 2; }
  nuevo="$(mktemp)"; trap 'rm -f "$nuevo"' EXIT
  armar > "$nuevo"
  if diff -q "$nuevo" "$README" >/dev/null 2>&1; then
    exit 0
  fi
  echo "gen-readme.sh: $README quedó viejo; corre gen-readme.sh y commitea el resultado" >&2
  exit 1
fi

armar > "$README"

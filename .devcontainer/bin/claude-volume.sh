#!/usr/bin/env bash
# Gestión de los volúmenes Docker persistentes del devcontainer. Los nombres
# reales los define la sección `volumes:` de ../docker-compose.yml:
#   claude-${CLIENTE}                    -> ~/.claude (conversaciones,
#                                           credenciales, settings, plugins,
#                                           .claude.json)
#   git-home                             -> ~/.config/git (config global y
#                                           gitignore GLOBAL del home)
#   bash-history-${CLIENTE}-${PROYECTO}  -> /commandhistory
#   basic-memory-${CLIENTE}              -> ~/basic-memory (knowledge)
#   ide-extensions-${CLIENTE}-${PROYECTO}, nvim-data-*, nvim-state-*
#
# Se ejecuta EN EL HOST (no dentro del container).
#
#   ./bin/claude-volume.sh info                 estado del volumen
#   ./bin/claude-volume.sh create               crea el volumen si no existe
#   ./bin/claude-volume.sh backup [destino]     tarball con timestamp
#   ./bin/claude-volume.sh restore <tarball>    restaura (SOBRESCRIBE)
#
# Por defecto opera sobre claude-${CLIENTE}, leyendo CLIENTE del .env hermano
# (compose lo interpola igual). Para operar sobre otro:
#   CLAUDE_VOLUME=git-home ./bin/claude-volume.sh info
set -euo pipefail

# El .env no está en el entorno del host: hay que leerlo para reconstruir el
# nombre del volumen exactamente como lo hace compose.
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

VOLUME="${CLAUDE_VOLUME:-claude-${CLIENTE:-local}}"
HELPER_IMAGE="${HELPER_IMAGE:-alpine:3.20}"

die() { echo "error: $*" >&2; exit 1; }
command -v docker >/dev/null || die "docker no está en el PATH"

volume_exists() { docker volume inspect "$VOLUME" >/dev/null 2>&1; }

in_volume() { # in_volume <comando sh -c>
  docker run --rm -v "${VOLUME}:/claude" "$HELPER_IMAGE" sh -c "$1"
}

cmd_create() {
  if volume_exists; then
    echo "El volumen '${VOLUME}' ya existe."
  else
    docker volume create "$VOLUME" >/dev/null
    echo "Volumen '${VOLUME}' creado."
  fi
}

cmd_info() {
  volume_exists || die "el volumen '${VOLUME}' no existe (créalo con: $0 create, o levanta el devcontainer)"
  echo "Volumen:   ${VOLUME}"
  echo "Mountpoint: $(docker volume inspect -f '{{.Mountpoint}}' "$VOLUME")"
  echo "Tamaño:     $(in_volume 'du -sh /claude 2>/dev/null | cut -f1')"
  echo
  # El contenido depende de qué volumen se esté inspeccionando.
  in_volume '
    if [ -d /claude/projects ] || [ -f /claude/.claude.json ]; then
      if [ -f /claude/.credentials.json ]; then echo "credenciales:    sí (no hace falta re-login)"; else echo "credenciales:    NO"; fi
      if [ -f /claude/.claude.json ];      then echo ".claude.json:    sí (MCP, trust, cuenta)"; else echo ".claude.json:    NO"; fi
      echo "proyectos:       $(ls /claude/projects 2>/dev/null | wc -l | tr -d " ")"
      echo "transcripciones: $(find /claude/projects -name "*.jsonl" 2>/dev/null | wc -l | tr -d " ")"
      echo "plugins:         $(ls /claude/plugins 2>/dev/null | wc -l | tr -d " ")"
    fi
    if [ -f /claude/ignore ] || [ -f /claude/config ]; then
      if [ -f /claude/config ]; then echo "config global:   sí ($(grep -c "" /claude/config) líneas)"; else echo "config global:   NO"; fi
      if [ -f /claude/ignore ]; then echo "gitignore global:$(grep -cvE "^[[:space:]]*(#|$)" /claude/ignore) reglas"; else echo "gitignore global:NO"; fi
    fi
    ls -A /claude >/dev/null 2>&1 || echo "(volumen vacío)"
  '
}

cmd_backup() {
  volume_exists || die "el volumen '${VOLUME}' no existe"
  local dest="${1:-$PWD}"
  [ -d "$dest" ] || die "el destino '${dest}' no es un directorio"
  local stamp file
  stamp="$(date +%Y%m%d-%H%M%S)"
  file="${VOLUME}-${stamp}.tar.gz"
  docker run --rm \
    -v "${VOLUME}:/claude:ro" \
    -v "$(cd "$dest" && pwd):/backup" \
    "$HELPER_IMAGE" \
    tar czf "/backup/${file}" -C /claude .
  echo "Backup escrito en: ${dest%/}/${file}"
  echo "Contiene credenciales: guárdalo en un sitio seguro."
}

cmd_restore() {
  local tarball="${1:-}"
  [ -n "$tarball" ] || die "uso: $0 restore <tarball>"
  [ -f "$tarball" ] || die "no existe el archivo '${tarball}'"

  cmd_create
  echo "Esto SOBRESCRIBE el contenido del volumen '${VOLUME}' con ${tarball}."
  printf "¿Continuar? [y/N] "
  read -r ans
  case "$ans" in y|Y|yes|s|S|si|SI) ;; *) echo "cancelado"; exit 0 ;; esac

  docker run --rm \
    -v "${VOLUME}:/claude" \
    -v "$(cd "$(dirname "$tarball")" && pwd):/backup:ro" \
    "$HELPER_IMAGE" \
    sh -c "rm -rf /claude/* /claude/.[!.]* 2>/dev/null; tar xzf '/backup/$(basename "$tarball")' -C /claude && chown -R 1000:1000 /claude"
  echo "Restaurado en el volumen '${VOLUME}'."
}

case "${1:-info}" in
  info)    shift || true; cmd_info ;;
  create)  shift || true; cmd_create ;;
  backup)  shift || true; cmd_backup "$@" ;;
  restore) shift || true; cmd_restore "$@" ;;
  -h|--help|help) sed -n '2,16p' "$0" ;;
  *) die "comando desconocido '${1}'. Usa: info | create | backup | restore" ;;
esac

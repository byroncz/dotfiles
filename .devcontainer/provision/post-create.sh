#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  postCreateCommand del template. CWD = workspaceFolder (/workspace).
#    1. Permisos de los volúmenes persistentes
#    2. Estado de Claude Code dentro de su volumen
#    3. git: config global y gitignore GLOBAL dentro de su volumen
#    3d. Basic Memory: registrar el proyecto de conocimiento
#    3e. MCP: generar .mcp.json y ~/.codex/config.toml desde mcp/servers.json
#    4. Resumen de la persistencia en el log de creación
#    5. Extensiones del IDE
#    6. Hook opcional del proyecto: .devcontainer/provision/post-create.local.sh
#  Nunca rompe el arranque: sin `set -e`, termina siempre en 0.
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

# Los scripts hermanos se resuelven desde aquí, no desde el CWD: así mover
# provision/ a otro sitio no vuelve a romper las llamadas.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

USER_NAME="$(id -un)"
HOME_DIR="${HOME:-/home/${USER_NAME}}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME_DIR}/.claude}"
GIT_GLOBAL_CONFIG="${GIT_CONFIG_GLOBAL:-${HOME_DIR}/.config/git/config}"
GIT_CFG_DIR="$(dirname "$GIT_GLOBAL_CONFIG")"
GIT_GLOBAL_IGNORE="${GIT_CFG_DIR}/ignore"

# sudo si está disponible; si no, sin él (los mount points se pre-crean en el
# Dockerfile, así que el volumen ya viene con el owner correcto).
maybe_sudo() { if command -v sudo >/dev/null 2>&1; then sudo "$@"; else "$@"; fi; }

# ── 1. Permisos de los volúmenes ────────────────────────────────────────────
maybe_sudo mkdir -p "$CLAUDE_DIR" "$GIT_CFG_DIR" /commandhistory \
  "${HOME_DIR}/.antigravity-ide-server/extensions" 2>/dev/null
maybe_sudo chown -R "${USER_NAME}:${USER_NAME}" \
  "$CLAUDE_DIR" "$GIT_CFG_DIR" /commandhistory \
  "${HOME_DIR}/.antigravity-ide-server" 2>/dev/null
chmod 700 "$CLAUDE_DIR" 2>/dev/null

# ── 2. ~/.claude.json dentro del volumen ────────────────────────────────────
if [ -f "${HOME_DIR}/.claude.json" ] && [ ! -e "${CLAUDE_DIR}/.claude.json" ]; then
  mv "${HOME_DIR}/.claude.json" "${CLAUDE_DIR}/.claude.json"
  echo "[claude] ~/.claude.json movido dentro del volumen persistente"
fi

# ── 3. dotfiles versionados (git ahora; nvim más adelante) ──────────────────
# El template se copia por proyecto como .devcontainer/ solo, así que una
# carpeta hermana del repo de dotfiles NO viaja con él. Por eso se clona
# dentro del container, en ~/.dotfiles: nunca dentro del repo del cliente,
# que no tiene por qué cargar con la configuración personal de nadie.
DOTFILES_DIR="${HOME_DIR}/.dotfiles"

if [ -f /workspace/git/ignore ]; then
  # El propio workspace ES el repo de dotfiles (este repo). Se usa tal cual:
  # así se puede editar la config y verla aplicada sin clonar ni pushear.
  DOTFILES_DIR=/workspace
  echo "[dotfiles] el workspace es el repo de dotfiles"
elif [ -n "${DOTFILES_REPO:-}" ]; then
  if [ -d "${DOTFILES_DIR}/.git" ]; then
    git -C "$DOTFILES_DIR" pull --ff-only -q 2>/dev/null \
      && echo "[dotfiles] actualizados desde ${DOTFILES_REPO}" \
      || echo "[dotfiles] no pude actualizar, uso la copia local"
  else
    git clone -q --depth 1 "$DOTFILES_REPO" "$DOTFILES_DIR" 2>/dev/null \
      && echo "[dotfiles] clonados en ${DOTFILES_DIR}" \
      || echo "[dotfiles] clone de ${DOTFILES_REPO} falló (¿repo privado sin credenciales?)"
  fi
else
  echo "[dotfiles] DOTFILES_REPO sin definir: se usa la config de git por defecto"
fi

# ── 3b. git ─────────────────────────────────────────────────────────────────
touch "$GIT_GLOBAL_CONFIG" 2>/dev/null

# Identidad que el IDE copia del host: se fusiona una sola vez en el volumen.
# El gitignore ya NO se fusiona: es un archivo versionado del repo y meterle
# contenido del host lo dejaría modificado en cada arranque.
merge_once() {
  local src="$1" dst="$2" label="$3" sum marker
  [ -f "$src" ] || return 0
  sum="$(sha1sum "$src" | cut -c1-12)"
  marker="# ${label}:${sum}"
  if ! grep -qF "$marker" "$dst" 2>/dev/null; then
    { echo; echo "$marker"; cat "$src"; } >> "$dst"
    echo "[git] ${src} fusionado en ${dst}"
  fi
  mv "$src" "${src}.pre-volume"
}
merge_once "${HOME_DIR}/.gitconfig" "$GIT_GLOBAL_CONFIG" "merged-from-gitconfig"

if [ -f "${DOTFILES_DIR}/git/ignore" ]; then
  GIT_GLOBAL_IGNORE="${DOTFILES_DIR}/git/ignore"
  # Lo apunta post-create y no el config versionado porque la ruta del clon
  # solo se conoce aquí (~/.dotfiles o /workspace, según el caso).
  if [ "$(git config --global core.excludesFile 2>/dev/null)" != "$GIT_GLOBAL_IGNORE" ]; then
    git config --global --replace-all core.excludesFile "$GIT_GLOBAL_IGNORE" \
      && echo "[git] core.excludesFile -> ${GIT_GLOBAL_IGNORE}"
  fi
fi

# Preferencias versionadas por include, no por copia: así un cambio en el repo
# se aplica en el siguiente arranque sin fusiones ni duplicados. La identidad
# se queda en el volumen, que es de esta máquina y no se versiona.
if [ -f "${DOTFILES_DIR}/git/config" ]; then
  if ! git config --global --get-all include.path 2>/dev/null \
       | grep -qxF "${DOTFILES_DIR}/git/config"; then
    git config --global --add include.path "${DOTFILES_DIR}/git/config" \
      && echo "[git] include.path -> ${DOTFILES_DIR}/git/config"
  fi
fi

# Marca /workspace como seguro: el bind mount suele traer otro owner que el
# usuario del container y git se niega a operar ("dubious ownership").
git config --global --add safe.directory /workspace 2>/dev/null

# ── 3c. Neovim ──────────────────────────────────────────────────────────────
# Se ENLAZA, no se copia: así editar la config en el repo se ve en el
# siguiente arranque de nvim, sin resincronizar nada ni arriesgar que la
# copia del container y la del repo diverjan.
if [ -f "${DOTFILES_DIR}/nvim/init.lua" ] && command -v nvim >/dev/null 2>&1; then
  mkdir -p "${HOME_DIR}/.config"
  ENLACE="${HOME_DIR}/.config/nvim"
  if [ -L "$ENLACE" ] || [ ! -e "$ENLACE" ]; then
    ln -sfn "${DOTFILES_DIR}/nvim" "$ENLACE"
    echo "[nvim] ~/.config/nvim -> ${DOTFILES_DIR}/nvim"
  else
    # Existe y no es un enlace: alguien puso ahí una config a mano. No se
    # pisa; se avisa.
    echo "[nvim] AVISO: ${ENLACE} existe y no es un enlace; lo dejo como está"
  fi
fi

# ── 3d. Basic Memory ────────────────────────────────────────────────────────
# basic-memory 0.23 no escribe NADA hasta que existe un proyecto registrado:
# sin esto, `write-note` falla con "Project not found" y la nota se pierde.
#
# Dos cosas que solo se ven ejecutándolo:
#
#   1. El proyecto NO se puede llamar "main". Ese es el nombre implícito por
#      defecto, y `project add main` cortocircuita: escribe la entrada en
#      config.json, devuelve "already exists" y NUNCA la inserta en el índice
#      SQLite. El estado queda partido en dos —la config dice que el proyecto
#      existe, la base dice que no hay ninguno— y a partir de ahí ni `add` ni
#      `remove` lo arreglan, porque cada uno consulta una mitad distinta.
#
#   2. La fuente de verdad es `basic-memory tool list-projects`, que pregunta
#      a la API, y NO `basic-memory project list`, que lee config.json. Con el
#      estado partido, `project list` muestra el proyecto y todo parece bien.
#
# La ruta se pasa explícita y no se deja deducir de $HOME, por la misma razón
# que BASIC_MEMORY_HOME está en el compose: si el proyecto apuntara a otro
# sitio, el conocimiento se escribiría fuera del volumen respaldado.
BM_PROYECTO="conocimiento"
if command -v basic-memory >/dev/null 2>&1; then
  BM_HOME="${BASIC_MEMORY_HOME:-${HOME_DIR}/basic-memory}"
  mkdir -p "$BM_HOME"

  # ¿Ya hay un proyecto apuntando a BM_HOME? Se pregunta a la API.
  bm_registrado() {
    basic-memory tool list-projects 2>/dev/null | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(p.get("path") == sys.argv[1] for p in d.get("projects", [])) else 1)
' "$BM_HOME"
  }

  if bm_registrado; then
    echo "[basic-memory] proyecto ya registrado -> ${BM_HOME}"
  else
    basic-memory project add "$BM_PROYECTO" "$BM_HOME" >/dev/null 2>&1
    basic-memory project default "$BM_PROYECTO" >/dev/null 2>&1
    if bm_registrado; then
      echo "[basic-memory] proyecto '${BM_PROYECTO}' -> ${BM_HOME}"
    else
      # No se silencia: sin proyecto, todo lo que escriba un agente se pierde.
      echo "[basic-memory] AVISO: no pude registrar '${BM_PROYECTO}' en ${BM_HOME}."
      echo "[basic-memory]        el índice puede estar inconsistente; se reconstruye con:"
      echo "[basic-memory]        rm -f \"${BASIC_MEMORY_CONFIG_DIR:-${HOME_DIR}/.basic-memory}\"/config.json"
    fi
  fi
fi

# ── 3e. Configuración de MCP, generada desde un origen único ────────────────
# mcp/servers.json es el único sitio donde se declara un servidor MCP. De ahí
# salen .mcp.json (Claude Code) y ~/.codex/config.toml (Codex), con los mismos
# servidores y los mismos comandos porque los genera la misma pasada.
#
# Los dos son ARTEFACTOS y están en el gitignore global (git/ignore): el repo
# donde aterriza .mcp.json es el del cliente, y arrancar el devcontainer no
# puede dejárselo sucio.
if command -v python3 >/dev/null 2>&1; then
  WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}" \
    python3 "${SCRIPT_DIR}/generar-mcp.py" || echo "[mcp] generación incompleta, continuo"
fi

# ── 4. Estado de la persistencia ────────────────────────────────────────────
echo "[claude] CLAUDE_CONFIG_DIR=${CLAUDE_DIR}"
if [ -e "${CLAUDE_DIR}/.credentials.json" ]; then
  echo "[claude] credenciales encontradas -> no hace falta volver a hacer login"
else
  echo "[claude] sin credenciales todavía -> ejecuta 'claude' y haz login una vez"
fi
if [ -d "${CLAUDE_DIR}/projects" ]; then
  echo "[claude] conversaciones persistidas: $(find "${CLAUDE_DIR}/projects" -name '*.jsonl' 2>/dev/null | wc -l)"
fi
echo "[git] config global: ${GIT_GLOBAL_CONFIG} (identidad: $(git config --global user.email 2>/dev/null || echo 'sin configurar'))"
if [ -f "$GIT_GLOBAL_IGNORE" ]; then
  echo "[git] gitignore global: ${GIT_GLOBAL_IGNORE} ($(grep -cvE '^\s*(#|$)' "$GIT_GLOBAL_IGNORE" 2>/dev/null || echo 0) reglas)"
else
  echo "[git] gitignore global: sin configurar (no hay dotfiles disponibles)"
fi

# ── 5. Extensiones del IDE ──────────────────────────────────────────────────
# Sin `chmod +x` sobre .devcontainer/: eso escribe a través del bind mount y
# deja el repo del proyecto con archivos modificados nada más arrancar, lo que
# en un repo de cliente es ruido que alguien acaba commiteando sin querer.
# Además es innecesario: `bash script.sh` no requiere el bit de ejecución.
bash "${SCRIPT_DIR}/install-extensions.sh" || echo "[ext] instalación incompleta, continuo"

# ── 6. Hook del proyecto ────────────────────────────────────────────────────
# Todo lo específico del proyecto (migraciones, seeds, sanity checks) va aquí
# en vez de tocar este archivo; así el template se puede actualizar entero.
if [ -f "${SCRIPT_DIR}/post-create.local.sh" ]; then
  echo "[post-create] ejecutando post-create.local.sh del proyecto"
  bash "${SCRIPT_DIR}/post-create.local.sh" || echo "[post-create] post-create.local.sh falló, continuo"
fi

exit 0

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  postCreateCommand del template. CWD = workspaceFolder (/workspace).
#    1. Permisos de los volúmenes persistentes
#    2. Estado de Claude Code dentro de su volumen
#    3. git: config global y gitignore GLOBAL dentro de su volumen
#    4. Resumen de la persistencia en el log de creación
#    5. Extensiones del IDE
#    6. Hook opcional del proyecto: .devcontainer/post-create.local.sh
#  Nunca rompe el arranque: sin `set -e`, termina siempre en 0.
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

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

# ── 3. git: config global y gitignore GLOBAL ────────────────────────────────
touch "$GIT_GLOBAL_CONFIG" "$GIT_GLOBAL_IGNORE" 2>/dev/null

# Fusiona una sola vez lo que haya quedado fuera del volumen (p. ej. el
# ~/.gitconfig que el IDE copia del host). El marcador evita duplicados.
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
merge_once "${HOME_DIR}/.gitconfig"        "$GIT_GLOBAL_CONFIG" "merged-from-gitconfig"
merge_once "${HOME_DIR}/.gitignore_global" "$GIT_GLOBAL_IGNORE" "merged-from-gitignore-global"

if [ "$(git config --global core.excludesFile 2>/dev/null)" != "$GIT_GLOBAL_IGNORE" ]; then
  git config --global --replace-all core.excludesFile "$GIT_GLOBAL_IGNORE" \
    && echo "[git] core.excludesFile -> ${GIT_GLOBAL_IGNORE}"
fi

# Marca /workspace como seguro: el bind mount suele traer otro owner que el
# usuario del container y git se niega a operar ("dubious ownership").
git config --global --add safe.directory /workspace 2>/dev/null

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
echo "[git] gitignore global: ${GIT_GLOBAL_IGNORE} ($(grep -cvE '^\s*(#|$)' "$GIT_GLOBAL_IGNORE" 2>/dev/null || echo 0) reglas)"

# ── 5. Extensiones del IDE ──────────────────────────────────────────────────
chmod +x .devcontainer/*.sh 2>/dev/null
bash .devcontainer/install-extensions.sh || echo "[ext] instalación incompleta, continuo"

# ── 6. Hook del proyecto ────────────────────────────────────────────────────
# Todo lo específico del proyecto (migraciones, seeds, sanity checks) va aquí
# en vez de tocar este archivo; así el template se puede actualizar entero.
if [ -f .devcontainer/post-create.local.sh ]; then
  echo "[post-create] ejecutando post-create.local.sh del proyecto"
  bash .devcontainer/post-create.local.sh || echo "[post-create] post-create.local.sh falló, continuo"
fi

exit 0

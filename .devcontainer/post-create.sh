#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  postCreateCommand del devcontainer. CWD = workspaceFolder (/workspace).
#  1. Permisos de los volúmenes persistentes
#  2. Migración al volumen de config que hubiera quedado fuera
#  3. git: config global y gitignore GLOBAL dentro del volumen
#  4. Sanity checks del stack (aws, nbformat, boto3)
#  5. Extensiones de Antigravity
#  Nunca falla el arranque: no usa `set -e` y termina siempre en 0.
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

USER_NAME="${USER_NAME:-devuser}"
HOME_DIR="${HOME:-/home/${USER_NAME}}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME_DIR}/.claude}"
GIT_GLOBAL_CONFIG="${GIT_CONFIG_GLOBAL:-${HOME_DIR}/.config/git/config}"
GIT_CFG_DIR="$(dirname "$GIT_GLOBAL_CONFIG")"
GIT_GLOBAL_IGNORE="${GIT_CFG_DIR}/ignore"

# La imagen no instala sudo; si existe se usa, si no se hace sin él (los mount
# points se pre-crean en el Dockerfile, así que el volumen ya viene con el
# owner correcto y basta con el usuario normal).
maybe_sudo() { if command -v sudo >/dev/null 2>&1; then sudo "$@"; else "$@"; fi; }

# ── 1. Permisos de los volúmenes ────────────────────────────────────────────
# Si un mount point no existiera en la imagen, Docker lo habría creado como
# root:root y Claude Code no podría escribir. Idempotente.
maybe_sudo mkdir -p "$CLAUDE_DIR" "$GIT_CFG_DIR" /commandhistory \
  "${HOME_DIR}/.antigravity-ide-server/extensions" 2>/dev/null
maybe_sudo chown -R "${USER_NAME}:${USER_NAME}" \
  "$CLAUDE_DIR" "$GIT_CFG_DIR" /commandhistory \
  "${HOME_DIR}/.antigravity-ide-server" 2>/dev/null
chmod 700 "$CLAUDE_DIR" 2>/dev/null

# ── 2. ~/.claude.json dentro del volumen ────────────────────────────────────
# Con CLAUDE_CONFIG_DIR el archivo vive en $CLAUDE_CONFIG_DIR/.claude.json; si
# viene un container anterior con el archivo en el home, se mueve al volumen.
if [ -f "${HOME_DIR}/.claude.json" ] && [ ! -e "${CLAUDE_DIR}/.claude.json" ]; then
  mv "${HOME_DIR}/.claude.json" "${CLAUDE_DIR}/.claude.json"
  echo "[claude] ~/.claude.json movido dentro del volumen persistente"
fi

# ── 3. git: config global y gitignore GLOBAL ────────────────────────────────
# Se persiste el gitignore del home (aplica a todos los repos del container);
# el .gitignore de cada repositorio viaja en el propio repo.
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

# El valor efectivo de core.excludesFile debe apuntar al archivo del volumen,
# aunque el config fusionado trajera otra ruta.
if [ "$(git config --global core.excludesFile 2>/dev/null)" != "$GIT_GLOBAL_IGNORE" ]; then
  git config --global --replace-all core.excludesFile "$GIT_GLOBAL_IGNORE" \
    && echo "[git] core.excludesFile -> ${GIT_GLOBAL_IGNORE}"
fi

# ── 4. Estado de la persistencia (visible en el log de creación) ────────────
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

# ── 5. Sanity checks del stack del proyecto ─────────────────────────────────
aws --version || echo "[warn] aws CLI no disponible"
python -c "import nbformat; print('nbformat OK')" || echo "[warn] nbformat no disponible"
python -c "import boto3;   print('boto3 OK')"    || echo "[warn] boto3 no disponible"

# ── 6. Extensiones del IDE ──────────────────────────────────────────────────
chmod +x .devcontainer/*.sh 2>/dev/null
bash .devcontainer/install-extensions.sh || echo "[ext] instalación incompleta, continuo"

exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  devkit: arranque del contenedor. Idempotente: se puede ejecutar mil veces.
#
#  Fases, en este orden y por esta razón:
#    1. Secretos       -> todo lo demás los necesita.
#    2. Identidad git  -> antes de clonar.
#    3. Template       -> las skills y AGENTS.md salen de aquí.
#    4. Workspace      -> clonar el proyecto si no existe.
#    5. Python         -> lo que declare .python-version.
#    6. Sandbox        -> restaurar desde Dropbox ANTES de sincronizar hacia
#                         Dropbox. Un sync desde un directorio vacío borraría
#                         el respaldo. El marcador .restored lo impide.
#    7. Claude         -> settings y plugins por proyecto.
#    8. Bucles         -> sync del sandbox y vigilancia de PRs mergeados.
#
#  Variables (vienen de devkit.env vía compose):
#    DEVKIT_PROJECT        nombre corto del proyecto (ej. devkit)
#    DEVKIT_PROJECT_CODE   código de Notion (ej. DEVKIT)
#    DEVKIT_REPO           URL del repo del proyecto (https://github.com/...)
#    DEVKIT_REPO_REF       rama a clonar (opcional; por defecto la principal)
#    DEVKIT_VERSION        etiqueta del template (ej. 0.1.0). "dev" = usar
#                          el workspace como template (solo para DEVKIT).
#    GIT_USER_NAME / GIT_USER_EMAIL
#    DEVKIT_SANDBOX_REMOTE ruta en Dropbox (ej. dropbox:devkit/sandbox.local)
# ---------------------------------------------------------------------------
set -euo pipefail

log()  { printf '\033[1;34m[devkit]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[devkit] aviso:\033[0m %s\n' "$*" >&2; }

RUN_DIR=/run/devkit
ENV_FILE="$RUN_DIR/env"
TEMPLATE_DIR=/opt/devkit/template
TEMPLATE_REPO="${DEVKIT_TEMPLATE_REPO:-https://github.com/byroncz/dotfiles.git}"
WS=/workspace
mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
: > "$ENV_FILE"; chmod 600 "$ENV_FILE"

# --- 1. Secretos -------------------------------------------------------------
# El secreto cero llega como archivo (secrets: de compose). Sin él, el
# contenedor arranca en "modo sin secretos": sirve para probar la imagen.
if [ -s /run/secrets/bws_token ]; then
  export BWS_ACCESS_TOKEN
  BWS_ACCESS_TOKEN="$(tr -d '[:space:]' < /run/secrets/bws_token)"
  log "leyendo secretos de Bitwarden"
  if secrets_json="$(bws secret list -o json 2>"$RUN_DIR/bws.err")"; then
    # Cada secreto se guarda como archivo $RUN_DIR/<clave> (600). Los que son
    # variables de entorno se exportan además en $ENV_FILE.
    printf '%s' "$secrets_json" | jq -r '.[] | "\(.key)\t\(.value|@base64)"' \
    | while IFS=$'\t' read -r key b64; do
        printf '%s' "$b64" | base64 -d > "$RUN_DIR/$key"; chmod 600 "$RUN_DIR/$key"
      done
    for pair in "claude_oauth_token:CLAUDE_CODE_OAUTH_TOKEN" "github_token:GH_TOKEN"; do
      key="${pair%%:*}"; var="${pair##*:}"
      # Tokens de una línea: se eliminan espacios y saltos pegados por error.
      [ -r "$RUN_DIR/$key" ] && printf 'export %s=%q\n' "$var" "$(tr -d '[:space:]' < "$RUN_DIR/$key")" >> "$ENV_FILE"
    done
    # rclone.conf viaja en base64 en una sola línea (ver scripts/dropbox-setup.sh).
    if [ -r "$RUN_DIR/rclone_conf_b64" ]; then
      mkdir -p "$HOME/.config/rclone"
      tr -d '[:space:]' < "$RUN_DIR/rclone_conf_b64" | base64 -d > "$HOME/.config/rclone/rclone.conf"
      chmod 600 "$HOME/.config/rclone/rclone.conf"
    fi
  else
    warn "bws falló: $(cat "$RUN_DIR/bws.err")"
  fi
else
  warn "token de Bitwarden ausente o vacío: modo sin secretos"
fi
# shellcheck disable=SC1090
. "$ENV_FILE"

# --- 2. Identidad git ----------------------------------------------------------
git config --global user.name  "${GIT_USER_NAME:-devkit}"
git config --global user.email "${GIT_USER_EMAIL:-devkit@localhost}"
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global core.excludesFile "$HOME/.config/git/ignore"
mkdir -p "$HOME/.config/git"
printf '%s\n' '*.local' '*.local.*' '.DS_Store' '.env' '.env.*' '!.env.example' '.ipynb_checkpoints/' '__pycache__/' '.venv/' > "$HOME/.config/git/ignore"
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 && log "gh autenticado como $(gh api user -q .login 2>/dev/null || echo '?')"
fi

# --- 3. Template ---------------------------------------------------------------
if [ "${DEVKIT_VERSION:-dev}" = "dev" ]; then
  # El proyecto DEVKIT: el workspace es el propio template.
  ln -sfn "$WS/devkit" "$TEMPLATE_DIR"
  log "template en modo dev -> $WS/devkit"
elif [ ! -d "$TEMPLATE_DIR/.git" ]; then
  log "clonando template v${DEVKIT_VERSION}"
  rm -rf "$TEMPLATE_DIR.tmp"
  git clone --quiet --depth 1 --branch "v${DEVKIT_VERSION}" "$TEMPLATE_REPO" "$TEMPLATE_DIR.tmp"
  rm -rf "$TEMPLATE_DIR"; mv "$TEMPLATE_DIR.tmp/devkit" "$TEMPLATE_DIR"; rm -rf "$TEMPLATE_DIR.tmp"
fi

# --- 4. Workspace --------------------------------------------------------------
if [ ! -d "$WS/.git" ]; then
  if [ -n "${DEVKIT_REPO:-}" ]; then
    log "clonando $DEVKIT_REPO${DEVKIT_REPO_REF:+ (rama $DEVKIT_REPO_REF)}"
    # Se clona en un temporal del usuario y se copia: /workspace puede no
    # estar vacío (sandbox.local) y git rehúsa clonar sobre un directorio con
    # contenido.
    clone_tmp="$(mktemp -d)"
    if git clone --quiet ${DEVKIT_REPO_REF:+--branch "$DEVKIT_REPO_REF"} "$DEVKIT_REPO" "$clone_tmp/repo"; then
      cp -a "$clone_tmp/repo/." "$WS/"
    else
      warn "clon falló; workspace vacío"
    fi
    rm -rf "$clone_tmp"
  else
    warn "sin DEVKIT_REPO y sin repo en $WS: workspace vacío"
  fi
fi
cd "$WS"

# Enlaces del template hacia el workspace (solo si el template existe).
if [ -d "$TEMPLATE_DIR/agents" ]; then
  mkdir -p "$WS/.claude"
  ln -sfn "$TEMPLATE_DIR/agents/skills" "$WS/.claude/skills"
  [ -f "$WS/AGENTS.md" ] || sed "s/{{PROJECT}}/${DEVKIT_PROJECT:-proyecto}/g; s/{{CODE}}/${DEVKIT_PROJECT_CODE:-PROJ}/g" "$TEMPLATE_DIR/agents/AGENTS.template.md" > "$WS/AGENTS.md"
  [ -f "$WS/CLAUDE.md" ] || printf '@AGENTS.md\n' > "$WS/CLAUDE.md"
fi

# --- 5. Python -----------------------------------------------------------------
if [ -f "$WS/.python-version" ]; then
  log "python $(cat "$WS/.python-version") vía uv"
  uv python install --quiet || warn "uv python install falló (¿sin red?)"
fi

# --- 6. Sandbox ----------------------------------------------------------------
SANDBOX="$WS/sandbox.local"
mkdir -p "$SANDBOX"
if [ -n "${DEVKIT_SANDBOX_REMOTE:-}" ] && [ -r "$HOME/.config/rclone/rclone.conf" ]; then
  if [ ! -f "$SANDBOX/.restored" ]; then
    log "restaurando sandbox desde $DEVKIT_SANDBOX_REMOTE"
    if rclone mkdir "$DEVKIT_SANDBOX_REMOTE" && rclone copy --quiet "$DEVKIT_SANDBOX_REMOTE" "$SANDBOX"; then
      date -u +%FT%TZ > "$SANDBOX/.restored"
    else
      warn "restauración falló; NO se iniciará el sync para proteger el respaldo"
    fi
  fi
  if [ -f "$SANDBOX/.restored" ]; then
    nohup /opt/devkit/scripts/sync-sandbox.sh "$SANDBOX" "$DEVKIT_SANDBOX_REMOTE" >"$RUN_DIR/sync.log" 2>&1 &
    log "sync del sandbox activo (cada 60 s)"
  fi
else
  warn "sandbox sin respaldo: falta DEVKIT_SANDBOX_REMOTE o el secreto rclone_conf_b64"
fi

# --- 7. Claude -----------------------------------------------------------------
if [ -d "$TEMPLATE_DIR/agents" ]; then
  [ -f "$HOME/.claude/settings.json" ] || cp "$TEMPLATE_DIR/agents/settings.json" "$HOME/.claude/settings.json"
fi
# Reenvío del retorno OAuth: Docker entrega en la IP del contenedor (54546) y
# Claude Code escucha en 127.0.0.1:54545. socat une ambos extremos.
nohup socat TCP-LISTEN:54546,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:54545 >/dev/null 2>&1 &
# Plugin oficial de Notion, por proyecto (queda en el volumen ~/.claude).
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if claude plugin list 2>/dev/null | grep -q '^notion@'; then
    log "plugin de Notion ya instalado"
  else
    claude plugin marketplace update claude-plugins-official >"$RUN_DIR/plugin.log" 2>&1 || true
    claude plugin install notion@claude-plugins-official >>"$RUN_DIR/plugin.log" 2>&1 \
      && log "plugin de Notion instalado" \
      || warn "no se pudo instalar el plugin de Notion: $(tail -1 "$RUN_DIR/plugin.log")"
  fi
fi

# --- 8. Bucles -----------------------------------------------------------------
if [ -n "${GH_TOKEN:-}" ] && [ -x /opt/devkit/scripts/watch-merged.sh ]; then
  nohup /opt/devkit/scripts/watch-merged.sh >"$RUN_DIR/watch-merged.log" 2>&1 &
  log "vigilancia de PRs mergeados activa (cada 5 min)"
fi

log "listo. Proyecto: ${DEVKIT_PROJECT:-?}  Template: ${DEVKIT_VERSION:-dev}"
# Marcador que espera el comando devkit del host antes de abrir la sesión.
date -u +%FT%TZ > "$RUN_DIR/ready"
exec "$@"

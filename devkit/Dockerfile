# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
#  devkit: imagen de trabajo.
#
#  Principios (docs/ARCHITECTURE.md):
#    - Base sin lenguaje. Python lo instala uv al primer arranque.
#    - Todo binario se elige por arquitectura (arm64 en Apple Silicon, amd64
#      en el resto). Las versiones van fijadas en ARG y se suben a propósito.
#    - Usuario sin sudo. Lo que el contenedor necesita viene de esta imagen.
#    - Nada de secretos aquí. Entran al arrancar (entrypoint.sh).
# ---------------------------------------------------------------------------
ARG BASE_IMAGE=debian:trixie-slim
ARG UV_VERSION=0.12.7

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ${BASE_IMAGE}

ARG NVIM_VERSION=0.12.5
ARG GH_VERSION=2.100.0
ARG RCLONE_VERSION=1.75.1
ARG BWS_VERSION=2.1.0
ARG STARSHIP_VERSION=1.24.2
ARG TOOLS_PYTHON=3.14
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG EXTRA_APT=""

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# --- Paquetes de sistema ---------------------------------------------------
# ncurses-base trae la base terminfo (evita el fallo de borrado en el REPL de
# python-build-standalone). ripgrep y fd-find los usa Neovim para buscar.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg unzip zip jq less procps \
      ncurses-base ncurses-term tmux zsh ripgrep fd-find openssh-client \
      ${EXTRA_APT} \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# --- Binarios por arquitectura --------------------------------------------
# uname -m devuelve x86_64 o aarch64. Cada proyecto nombra sus assets a su
# manera; el case traduce.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  nvim_arch=x86_64; gh_arch=amd64; rc_arch=amd64; triple=x86_64-unknown-linux-gnu; st_triple=x86_64-unknown-linux-musl ;; \
      aarch64) nvim_arch=arm64;  gh_arch=arm64; rc_arch=arm64; triple=aarch64-unknown-linux-gnu; st_triple=aarch64-unknown-linux-musl ;; \
      *) echo "arquitectura no soportada: $arch" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; cd "$tmp"; \
    \
    # Neovim
    curl -fsSLo nvim.tar.gz "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-${nvim_arch}.tar.gz"; \
    tar -xzf nvim.tar.gz; mv "nvim-linux-${nvim_arch}" /opt/nvim; \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim; \
    \
    # GitHub CLI
    curl -fsSLo gh.tar.gz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz"; \
    tar -xzf gh.tar.gz; install -m 0755 "gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh; \
    \
    # rclone
    curl -fsSLo rclone.zip "https://github.com/rclone/rclone/releases/download/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-${rc_arch}.zip"; \
    unzip -q rclone.zip; install -m 0755 "rclone-v${RCLONE_VERSION}-linux-${rc_arch}/rclone" /usr/local/bin/rclone; \
    \
    # Bitwarden Secrets Manager CLI
    curl -fsSLo bws.zip "https://github.com/bitwarden/sdk-sm/releases/download/bws-v${BWS_VERSION}/bws-${triple}-${BWS_VERSION}.zip"; \
    unzip -q bws.zip; install -m 0755 bws /usr/local/bin/bws; \
    \
    # starship
    curl -fsSLo starship.tar.gz "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-${st_triple}.tar.gz"; \
    tar -xzf starship.tar.gz; install -m 0755 starship /usr/local/bin/starship; \
    \
    cd /; rm -rf "$tmp"; \
    nvim --version | head -1; gh --version | head -1; rclone version | head -1; \
    bws --version; starship --version | head -1

# uv y uvx desde la imagen oficial de Astral.
COPY --from=uv /uv /uvx /usr/local/bin/

# --- Plugins de zsh (en la imagen, no en el home) --------------------------
RUN git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions /opt/zsh/zsh-autosuggestions \
 && git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting /opt/zsh/zsh-syntax-highlighting

# --- Usuario sin sudo -------------------------------------------------------
RUN groupadd --gid "$USER_GID" "$USERNAME" \
 && useradd --uid "$USER_UID" --gid "$USER_GID" -m --shell /usr/bin/zsh "$USERNAME"

# Puntos de montaje pre-creados con el owner correcto. Docker los crearía
# como root si no existieran en la imagen.
RUN mkdir -p "/home/$USERNAME/.claude" /commandhistory /workspace /opt/devkit /run/devkit \
 && touch /commandhistory/.zsh_history \
 && chown -R "$USER_UID:$USER_GID" "/home/$USERNAME" /commandhistory /workspace /opt/devkit /run/devkit \
 && chmod 700 "/home/$USERNAME/.claude" /run/devkit

USER $USERNAME
ENV HOME="/home/${USERNAME}" \
    PATH="/home/${USERNAME}/.local/bin:${PATH}" \
    CLAUDE_CONFIG_DIR="/home/${USERNAME}/.claude" \
    DISABLE_AUTOUPDATER=1 \
    UV_PYTHON_INSTALL_DIR="/home/${USERNAME}/.local/share/uv/python" \
    UV_TOOL_DIR="/home/${USERNAME}/.local/share/uv/tools" \
    UV_TOOL_BIN_DIR="/home/${USERNAME}/.local/bin" \
    HISTFILE=/commandhistory/.zsh_history
WORKDIR /workspace

# --- Claude Code CLI (binario nativo, sin Node) ---------------------------
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

# --- Herramientas de Python para el editor ---------------------------------
# Un Python fijo solo para las herramientas. El de cada proyecto lo decide su
# .python-version al arrancar.
RUN uv python install "${TOOLS_PYTHON}" \
 && uv tool install --python "${TOOLS_PYTHON}" ruff \
 && uv tool install --python "${TOOLS_PYTHON}" basedpyright \
 && ruff --version && basedpyright --version

# --- Configuración de shell y editor ---------------------------------------
COPY --chown=${USER_UID}:${USER_GID} zsh/zshrc      /home/${USERNAME}/.zshrc
COPY --chown=${USER_UID}:${USER_GID} zsh/starship.toml /home/${USERNAME}/.config/starship.toml
COPY --chown=${USER_UID}:${USER_GID} tmux/tmux.conf /home/${USERNAME}/.tmux.conf
COPY --chown=${USER_UID}:${USER_GID} nvim/          /home/${USERNAME}/.config/nvim/

# Plugins de Neovim instalados en la imagen. Versiones fijadas por
# nvim/nvim-pack-lock.json (lockfile de vim.pack, Neovim 0.12).
RUN nvim --headless +qa && ls "$HOME/.local/share/nvim/site/pack/core/opt"

COPY --chown=${USER_UID}:${USER_GID} entrypoint.sh /opt/devkit/entrypoint.sh
COPY --chown=${USER_UID}:${USER_GID} scripts/      /opt/devkit/scripts/

ENTRYPOINT ["/opt/devkit/entrypoint.sh"]
CMD ["sleep", "infinity"]

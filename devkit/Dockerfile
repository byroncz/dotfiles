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

ARG GH_VERSION=2.100.0
ARG RCLONE_VERSION=1.75.1
ARG BWS_VERSION=2.1.0
ARG STARSHIP_VERSION=1.24.2
ARG OPENVSCODE_VERSION=1.109.5
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
# python-build-standalone). ripgrep y fd-find van en la lista de permisos de
# los agentes.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg unzip zip jq less procps \
      ncurses-base ncurses-term zsh ripgrep fd-find openssh-client socat \
      ${EXTRA_APT} \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# --- Binarios por arquitectura --------------------------------------------
# uname -m devuelve x86_64 o aarch64. Cada proyecto nombra sus assets a su
# manera; el case traduce.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  gh_arch=amd64; rc_arch=amd64; triple=x86_64-unknown-linux-gnu; st_triple=x86_64-unknown-linux-musl; ovs_arch=x64 ;; \
      aarch64) gh_arch=arm64; rc_arch=arm64; triple=aarch64-unknown-linux-gnu; st_triple=aarch64-unknown-linux-musl; ovs_arch=arm64 ;; \
      *) echo "arquitectura no soportada: $arch" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; cd "$tmp"; \
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
    # openvscode-server (editor VS Code en el navegador, ver DEVKIT-38)
    curl -fsSLo ovs.tar.gz "https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${OPENVSCODE_VERSION}/openvscode-server-v${OPENVSCODE_VERSION}-linux-${ovs_arch}.tar.gz"; \
    tar -xzf ovs.tar.gz; mv "openvscode-server-v${OPENVSCODE_VERSION}-linux-${ovs_arch}" /opt/openvscode-server; \
    ln -s /opt/openvscode-server/bin/openvscode-server /usr/local/bin/openvscode-server; \
    \
    cd /; rm -rf "$tmp"; \
    gh --version | head -1; rclone version | head -1; \
    bws --version; starship --version | head -1; openvscode-server --version

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

# --- Extensiones del editor, desde Open VSX ---------------------------------
# Versionadas en el template (devkit/vscode/extensions.toml), resueltas al
# construir por devkit.sh (resolve_extensions) y pasadas aquí ya fijas, como
# "ns.ext=versión" separadas por espacio: nunca "latest" a esta altura, y
# nunca una extensión a mano en el contenedor. Por cada una se prueba primero
# el paquete de su plataforma (Open VSX no publica todas así) y, si no existe,
# el universal. Dominios `open-vsx.org` y `openvsx.eclipsecontent.org`
# (redirección de descarga) van en `domains` de .devkit/devkit.toml.
# --retry reintenta un 5xx de Open VSX (un 404 del paquete de plataforma no
# es un error transitorio, así que cae al universal sin reintentar).
# --retry-all-errors va solo en el paquete universal: ahí un corte de
# conexión a mitad de descarga sí debe reintentarse porque no hay más
# alternativas (DEVKIT-73: un 503 intermitente de Open VSX tumbó un build a
# medias); en el paquete de plataforma dejaría al 404 esperado
# reintentando en vano antes de caer al universal.
# ARG EXTENSIONS se declara aquí, no arriba con los demás: Docker mete todo
# ARG en el entorno de cada RUN posterior a su declaración, así que si
# viviera arriba, cada versión nueva de una extensión invalidaría la caché
# desde el primer RUN (apt, gh, rclone, zsh, claude...), no solo esta capa.
ARG EXTENSIONS=""
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  ovx_platform=linux-x64 ;; \
      aarch64) ovx_platform=linux-arm64 ;; \
      *) echo "arquitectura no soportada: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    for entry in ${EXTENSIONS}; do \
      id="${entry%%=*}"; version="${entry#*=}"; \
      ns="${id%%.*}"; ext="${id#*.}"; \
      curl --retry 5 --retry-delay 3 -fsSLo /tmp/ext.vsix \
        "https://open-vsx.org/api/${ns}/${ext}/${ovx_platform}/${version}/file/${ns}.${ext}-${version}@${ovx_platform}.vsix" \
      || curl --retry 5 --retry-delay 3 --retry-all-errors -fsSLo /tmp/ext.vsix \
        "https://open-vsx.org/api/${ns}/${ext}/${version}/file/${ns}.${ext}-${version}.vsix"; \
      openvscode-server --install-extension /tmp/ext.vsix \
        --server-data-dir "$HOME/.openvscode-server/data" \
        --extensions-dir "$HOME/.openvscode-server/extensions"; \
      rm -f /tmp/ext.vsix; \
    done; \
    openvscode-server --list-extensions --show-versions \
      --extensions-dir "$HOME/.openvscode-server/extensions"

# --- Herramientas de Python para el editor ---------------------------------
# Un Python fijo solo para las herramientas. El de cada proyecto lo decide su
# .devkit/devkit.toml (clave `python`) al arrancar.
RUN uv python install "${TOOLS_PYTHON}" \
 && uv tool install --python "${TOOLS_PYTHON}" ruff \
 && uv tool install --python "${TOOLS_PYTHON}" basedpyright \
 && ruff --version && basedpyright --version

# --- Configuración de shell y editor ---------------------------------------
COPY --chown=${USER_UID}:${USER_GID} zsh/zshrc      /home/${USERNAME}/.zshrc
COPY --chown=${USER_UID}:${USER_GID} zsh/starship.toml /home/${USERNAME}/.config/starship.toml
COPY --chown=${USER_UID}:${USER_GID} vscode/settings.json /home/${USERNAME}/.openvscode-server/data/User/settings.json

COPY --chown=${USER_UID}:${USER_GID} entrypoint.sh /opt/devkit/entrypoint.sh
COPY --chown=${USER_UID}:${USER_GID} scripts/      /opt/devkit/scripts/

# Copia de referencia de lo que solo entra por imagen. `entrypoint.sh` la
# compara en modo dev con el devkit/ del workspace para avisar cuándo hace
# falta un `devkit recreate` (DEVKIT-30): a diferencia de entrypoint.sh y
# scripts/, que el arranque lee del workspace, estos archivos se congelan en la
# imagen. Son los mismos del contexto de build y de los COPY de arriba, no otra
# fuente. Va al final para no invalidar las capas anteriores.
COPY --chown=${USER_UID}:${USER_GID} Dockerfile /opt/devkit/image/Dockerfile
COPY --chown=${USER_UID}:${USER_GID} zsh/       /opt/devkit/image/zsh/
COPY --chown=${USER_UID}:${USER_GID} proxy/     /opt/devkit/image/proxy/
COPY --chown=${USER_UID}:${USER_GID} vscode/    /opt/devkit/image/vscode/

ENTRYPOINT ["/opt/devkit/entrypoint.sh"]
CMD ["sleep", "infinity"]

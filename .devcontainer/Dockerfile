# ─────────────────────────────────────────────────────────────────────────
#  Template de devcontainer. Todo lo específico de un proyecto se pasa por
#  build args desde devcontainer.json; este archivo no se toca.
#
#  Base por defecto: debian:bookworm-slim (~27 MB comprimido). El CLI de
#  Claude Code se instala como binario nativo, así que NO hace falta Node.
#
#  Ejemplos de override en devcontainer.json -> build.args:
#    "BASE_IMAGE": "python:3.11-slim", "PIP_PACKAGES": "boto3 pandas"
#    "EXTRA_APT": "postgresql-client", "INSTALL_AWSCLI": "true"
# ─────────────────────────────────────────────────────────────────────────
ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
ARG EXTRA_APT=""
ARG INSTALL_AWSCLI=false
ARG PIP_PACKAGES=""

ENV DEBIAN_FRONTEND=noninteractive

# Herramientas mínimas para que el container sea usable y para que funcionen
# el CLI de Claude Code, git y el instalador de extensiones.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git unzip zip jq less procps sudo \
      bash-completion locales ${EXTRA_APT} \
 && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# AWS CLI v2 (opcional)
RUN if [ "$INSTALL_AWSCLI" = "true" ]; then \
      ARCH=$(uname -m) \
      && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
      && unzip -q /tmp/awscliv2.zip -d /tmp \
      && /tmp/aws/install \
      && rm -rf /tmp/awscliv2.zip /tmp/aws ; \
    fi

# Paquetes de Python (opcional; requiere una BASE_IMAGE con pip)
RUN if [ -n "$PIP_PACKAGES" ]; then pip install --no-cache-dir $PIP_PACKAGES ; fi

# Hook de build del proyecto: extras/build.sh. El template lo trae vacío; un
# proyecto lo sobrescribe para instalar lo que los args no cubren (Node,
# Terraform, un repo apt propio...). Ver extras/build.sh.
COPY extras/ /tmp/extras/
RUN if [ -f /tmp/extras/build.sh ]; then bash /tmp/extras/build.sh ; fi \
 && rm -rf /tmp/extras

# ─────────────────────────────────────────────────────────────────────────
#  Usuario no-root. Se crea solo si la base no lo trae ya (node, python y
#  debian-slim no lo traen; devcontainers/base sí).
# ─────────────────────────────────────────────────────────────────────────
RUN if ! getent group "$USER_GID" >/dev/null; then groupadd --gid "$USER_GID" "$USERNAME"; fi \
 && if ! id -u "$USERNAME" >/dev/null 2>&1; then \
      useradd --uid "$USER_UID" --gid "$USER_GID" -m --shell /bin/bash "$USERNAME"; \
    fi \
 && echo "$USERNAME ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME" \
 && chmod 0440 "/etc/sudoers.d/$USERNAME"

# ─────────────────────────────────────────────────────────────────────────
#  Puntos de montaje de los volúmenes persistentes (Problemas 7b, 11 y 12).
#  Docker crea el directorio de un mount point como root:root si no existe
#  en la imagen; pre-creándolo aquí con el owner correcto, el volumen
#  nombrado hereda contenido y ownership la primera vez que se monta.
# ─────────────────────────────────────────────────────────────────────────
RUN mkdir -p "/home/$USERNAME/.claude" \
      "/home/$USERNAME/.config/git" \
      "/home/$USERNAME/.local/bin" \
      "/home/$USERNAME/.antigravity-ide-server/extensions" \
      "/home/$USERNAME/basic-memory" \
      "/home/$USERNAME/.basic-memory" \
      /commandhistory \
 && touch /commandhistory/.bash_history \
 && chown -R "$USER_UID:$USER_GID" "/home/$USERNAME" /commandhistory \
 && chmod 700 "/home/$USERNAME/.claude"

# Semilla de la config global de git dentro de su volumen:
#   ~/.config/git/ignore -> gitignore GLOBAL (el del home, no el de cada repo)
#   ~/.config/git/config -> config global
RUN printf '%s\n' \
      '# gitignore global del usuario (~/.config/git/ignore).' \
      '# Aplica a TODOS los repos del container y persiste en su volumen.' \
      '# Para reglas de un repo concreto usa el .gitignore de ese repo.' \
      '' \
      '.DS_Store' \
      '*.swp' \
      '.env' \
      '.env.*' \
      '!.env.example' \
      '.ipynb_checkpoints/' \
      '.claude/settings.local.json' \
      > "/home/$USERNAME/.config/git/ignore" \
 && printf '%s\n' \
      '[core]' \
      "  excludesFile = /home/$USERNAME/.config/git/ignore" \
      > "/home/$USERNAME/.config/git/config" \
 && chown -R "$USER_UID:$USER_GID" "/home/$USERNAME/.config"

USER $USERNAME
ENV HOME="/home/${USERNAME}"
WORKDIR /workspace

# Claude Code CLI: binario nativo, sin Node.js. Se instala en ~/.local/bin,
# que NO es un volumen; ~/.claude sí lo es (ver devcontainer.json).
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# Estado de Claude Code y config global de git dentro de sus volúmenes,
# también para escritura (Problemas 11 y 12).
ENV CLAUDE_CONFIG_DIR="/home/${USERNAME}/.claude"
ENV GIT_CONFIG_GLOBAL="/home/${USERNAME}/.config/git/config"

# Terminal mejorada (prompt con rama de git, venv y exit code; historial
# grande; completado; aliases). ASCII-safe, sin Nerd Fonts (Problema 10).
COPY --chown=${USER_UID}:${USER_GID} bash-enhancements.sh "/home/${USERNAME}/.bash_enhancements.sh"
RUN printf '\n# devcontainer bash enhancements\n[ -f "$HOME/.bash_enhancements.sh" ] && . "$HOME/.bash_enhancements.sh"\n' \
      >> "/home/${USERNAME}/.bashrc"

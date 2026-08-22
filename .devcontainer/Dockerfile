# devcontainer up --workspace-folder /Users/byroncampo/dev/gt/capta_homologacion --remove-existing-container

FROM python:3.11-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    procps \
    unzip \
    git \
    jq \
    less \
    groff \
    bash-completion \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Python packages for Jupyter notebook management
RUN pip install --no-cache-dir \
    boto3 \
    nbformat \
    nbconvert \
    jupyterlab \
    ipykernel \
    pandas \
    pyarrow

# Non-root user (VS Code convention)
ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m --shell /bin/bash $USERNAME \
    && mkdir -p /home/$USERNAME/.claude /home/$USERNAME/.local/bin \
       /home/$USERNAME/.config/git \
       /home/$USERNAME/.antigravity-ide-server/extensions \
       /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USER_UID:$USER_GID /home/$USERNAME /commandhistory \
    && chmod 700 /home/$USERNAME/.claude

# Puntos de montaje de los volúmenes persistentes (Problemas 7b, 11 y 12).
# Docker crea el directorio de un mount point como root:root si no existe en la
# imagen; pre-creándolo aquí con el owner correcto, el volumen nombrado hereda
# contenido y ownership la primera vez que se monta.
#
# Semilla de la config global de git dentro del volumen:
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
      > /home/$USERNAME/.config/git/ignore \
    && printf '%s\n' \
      '[core]' \
      "  excludesFile = /home/$USERNAME/.config/git/ignore" \
      > /home/$USERNAME/.config/git/config \
    && chown -R $USER_UID:$USER_GID /home/$USERNAME/.config

USER $USERNAME
ENV HOME=/home/devuser
WORKDIR /workspace

# Claude Code CLI (native binary — no Node.js required).
# Installs to ~/.local/bin; ~/.claude is a persisted named volume (see devcontainer.json)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/devuser/.local/bin:${PATH}"

# Todo el estado de Claude Code (transcripciones, credenciales, settings,
# plugins y .claude.json) dentro del volumen montado en ~/.claude, y el config
# global de git dentro del suyo — también para escritura (Problemas 11 y 12).
ENV CLAUDE_CONFIG_DIR="/home/devuser/.claude"
ENV GIT_CONFIG_GLOBAL="/home/devuser/.config/git/config"

# Enhanced bash terminal (informative prompt, history, completion) — ASCII-safe,
# no oh-my-zsh/starship. Sourced from ~/.bashrc so every interactive shell gets it.
COPY --chown=devuser:devuser bash-enhancements.sh /home/devuser/.bash_enhancements.sh
RUN printf '\n# devcontainer bash enhancements\n[ -f "$HOME/.bash_enhancements.sh" ] && . "$HOME/.bash_enhancements.sh"\n' \
    >> /home/devuser/.bashrc

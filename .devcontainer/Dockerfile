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
       /home/$USERNAME/.antigravity-ide-server/extensions \
    && chown -R $USER_UID:$USER_GID /home/$USERNAME

USER $USERNAME
ENV HOME=/home/devuser
WORKDIR /workspace

# Claude Code CLI (native binary — no Node.js required).
# Installs to ~/.local/bin; ~/.claude is a persisted named volume (see devcontainer.json)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/devuser/.local/bin:${PATH}"

# Enhanced bash terminal (informative prompt, history, completion) — ASCII-safe,
# no oh-my-zsh/starship. Sourced from ~/.bashrc so every interactive shell gets it.
COPY --chown=devuser:devuser bash-enhancements.sh /home/devuser/.bash_enhancements.sh
RUN printf '\n# devcontainer bash enhancements\n[ -f "$HOME/.bash_enhancements.sh" ] && . "$HOME/.bash_enhancements.sh"\n' \
    >> /home/devuser/.bashrc

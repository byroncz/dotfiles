# ─────────────────────────────────────────────────────────────────────────
#  Template de devcontainer. Todo lo específico de un proyecto se pasa por
#  build args desde devcontainer.json; este archivo no se toca.
#
#  Base por defecto: debian:trixie-slim. El CLI de Claude Code se instala
#  como binario nativo, así que NO hace falta Node.
#
#  Trixie y no bookworm por la glibc: bookworm trae 2.36 y muchos binarios
#  precompilados de hoy piden 2.39 o más. El caso concreto que lo forzó fue
#  el `tree-sitter` que instala Mason, que en bookworm falla con
#  "version GLIBC_2.39 not found" y deja Neovim sin parsers. Trixie da 2.41.
#
#  Ejemplos de override en devcontainer.json -> build.args:
#    "BASE_IMAGE": "python:3.11-slim", "PIP_PACKAGES": "boto3 pandas"
#    "EXTRA_APT": "postgresql-client", "INSTALL_AWSCLI": "true"
# ─────────────────────────────────────────────────────────────────────────
ARG BASE_IMAGE=debian:trixie-slim
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
#
# python3-minimal (11 MB) no es opcional: provision/install-extensions.sh lo
# usa para parsear la API de Open VSX y para escribir extensions.json. Sin él
# NINGUNA extensión se instala. La variante -minimal basta: solo hace falta
# `json`, que sí trae.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git unzip zip jq less procps sudo \
      python3-minimal bash-completion locales ${EXTRA_APT} \
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

# ─────────────────────────────────────────────────────────────────────────
#  Neovim + herramientas de edición (opcional, pero por defecto sí).
#
#  Del tarball oficial, NO de apt: Debian trae Neovim 0.7.2 (bookworm), muy
#  por debajo del mínimo que pide LazyVim. El tarball son 11 MB y da 0.12.x.
#  Tarball y no AppImage: el AppImage necesita FUSE dentro del container.
#
#  Cuesta unos 300 MB, casi todos de build-essential, que hace falta para
#  compilar telescope-fzf-native y algunos parsers de treesitter. Un
#  proyecto que no quiera nada de esto pone INSTALL_NVIM=false y se queda
#  con la base mínima.
# ─────────────────────────────────────────────────────────────────────────
ARG INSTALL_NVIM=true
ARG NVIM_VERSION=v0.12.4
RUN if [ "$INSTALL_NVIM" = "true" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends \
           ripgrep fd-find tmux build-essential \
      && rm -rf /var/lib/apt/lists/* \
      && case "$(uname -m)" in \
           aarch64) NVARCH=arm64 ;; \
           x86_64)  NVARCH=x86_64 ;; \
           *) echo "arquitectura $(uname -m) sin binario oficial de Neovim" >&2; exit 1 ;; \
         esac \
      && curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${NVARCH}.tar.gz" \
           -o /tmp/nvim.tar.gz \
      && tar xzf /tmp/nvim.tar.gz -C /opt \
      && mv "/opt/nvim-linux-${NVARCH}" /opt/nvim \
      && ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim \
      && rm /tmp/nvim.tar.gz \
      # En Debian el binario se llama fdfind; telescope y LazyVim buscan `fd`.
      && ln -s "$(command -v fdfind)" /usr/local/bin/fd ; \
    fi

# ─────────────────────────────────────────────────────────────────────────
#  uv — gestor de paquetes y de intérpretes de Python (Astral).
#
#  SUSTITUYE a PIP_PACKAGES, que sigue existiendo solo por compatibilidad:
#  PIP_PACKAGES exige una BASE_IMAGE con pip (python:3.11-slim y similares),
#  mientras que uv se trae su propio intérprete y funciona sobre la base
#  mínima de 27 MB. Ver README, "Python con uv".
#
#  Se instala en /usr/local/bin para que lo vean todos los usuarios, y NO en
#  ~/.local/bin, que no es un volumen y se perdería en cada rebuild igual.
#
#  UV_CACHE_DIR apunta a un volumen (ver docker-compose.yml). La caché de uv
#  es reconstruible por definición, así que ese volumen NO se respalda: se
#  vuelve a llenar descargando. Lo que evita es pagar la descarga otra vez
#  en cada rebuild, que es todo lo que se le pide.
# ─────────────────────────────────────────────────────────────────────────
ARG INSTALL_UV=true
RUN if [ "$INSTALL_UV" = "true" ]; then \
      curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_UNMANAGED_INSTALL=/usr/local/bin sh \
      && uv --version ; \
    fi

# ─────────────────────────────────────────────────────────────────────────
#  Basic Memory — base de conocimiento local (markdown + grafo) y servidor
#  MCP. Se instala con `uv tool`, no con pip: así trae su propio Python y no
#  obliga a cambiar la BASE_IMAGE.
#
#  Las tres rutas van a /opt y el lanzador a /usr/local/bin porque esto se
#  instala como root, antes de que exista el usuario. El CONOCIMIENTO no vive
#  aquí: vive en ~/basic-memory, que sí es un volumen y sí se respalda.
#
#  El intérprete va FIJO y no al gusto de uv. Sin `--python`, uv coge el más
#  nuevo que encuentra y la instalación revienta compilando `pybars3` (una
#  dependencia de basic-memory) con "NameError: name 'os' is not defined":
#  su setup.py es antiguo y no sobrevive al setuptools de Python 3.13+.
#  Fijarlo aquí hace además que el build sea reproducible en el tiempo, en
#  vez de romperse solo el día que Astral publique un Python nuevo.
# ─────────────────────────────────────────────────────────────────────────
ARG INSTALL_BASIC_MEMORY=true
ARG BASIC_MEMORY_PYTHON=3.12
RUN export UV_TOOL_DIR=/opt/uv/tools \
           UV_TOOL_BIN_DIR=/usr/local/bin \
           UV_PYTHON_INSTALL_DIR=/opt/uv/python; \
    if [ "$INSTALL_BASIC_MEMORY" = "true" ]; then \
      if ! command -v uv >/dev/null 2>&1; then \
        echo "INSTALL_BASIC_MEMORY=true requiere INSTALL_UV=true" >&2; exit 1; \
      fi \
      && uv tool install --quiet --python "$BASIC_MEMORY_PYTHON" basic-memory \
      && basic-memory --version ; \
    fi

# ─────────────────────────────────────────────────────────────────────────
#  Herramientas de agente que se distribuyen por npm:
#
#    openspec (@fission-ai/openspec)  desarrollo dirigido por especificación
#    backlog.md                       gestión de tareas en markdown, en el repo
#    @notionhq/notion-mcp-server      servidor MCP oficial de Notion
#
#  Node NO está en la base y solo se instala si alguna de las tres se pide:
#  son ~120 MB que un proyecto que no las use no tiene por qué pagar.
#
#  Ojo: sus ARTEFACTOS (openspec/, backlog/) van en el repo del CLIENTE, no
#  en este template. Aquí solo se instala el binario. Ver README.
# ─────────────────────────────────────────────────────────────────────────
ARG INSTALL_OPENSPEC=true
ARG INSTALL_BACKLOG=true
ARG INSTALL_NOTION_MCP=true
ARG NODE_MAJOR=22
RUN set -eu; \
    PKGS=""; \
    if [ "$INSTALL_OPENSPEC"   = "true" ]; then PKGS="$PKGS @fission-ai/openspec"; fi; \
    if [ "$INSTALL_BACKLOG"    = "true" ]; then PKGS="$PKGS backlog.md"; fi; \
    if [ "$INSTALL_NOTION_MCP" = "true" ]; then PKGS="$PKGS @notionhq/notion-mcp-server"; fi; \
    if [ -n "$PKGS" ]; then \
      if ! command -v node >/dev/null 2>&1; then \
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
        && apt-get install -y --no-install-recommends nodejs \
        && rm -rf /var/lib/apt/lists/*; \
      fi; \
      npm install -g --no-fund --no-audit $PKGS; \
      npm cache clean --force; \
    fi

# Paquetes de Python (opcional; requiere una BASE_IMAGE con pip)
RUN if [ -n "$PIP_PACKAGES" ]; then pip install --no-cache-dir $PIP_PACKAGES ; fi

# Hook de build del proyecto: image/extras/build.sh. El template lo trae vacío;
# un proyecto lo sobrescribe para instalar lo que los args no cubren (Node,
# Terraform, un repo apt propio...). Ver image/extras/build.sh.
#
# Las rutas de COPY son relativas al build CONTEXT (.devcontainer/), no a este
# fichero: por eso llevan el prefijo de carpeta aunque el Dockerfile viva en
# image/.
COPY image/extras/ /tmp/extras/
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
      "/home/$USERNAME/.local/share/nvim" \
      "/home/$USERNAME/.local/state/nvim" \
      "/home/$USERNAME/.cache/uv" \
      /commandhistory \
 && touch /commandhistory/.bash_history \
 && chown -R "$USER_UID:$USER_GID" "/home/$USERNAME" /commandhistory \
 && chmod 700 "/home/$USERNAME/.claude"

# El gitignore global y las preferencias de git NO se hornean aquí: viven
# versionados en el repo de dotfiles (carpeta git/) y post-create.sh los
# clona en ~/.dotfiles. Hornearlos obligaba a editar este Dockerfile y
# reconstruir la imagen para añadir una regla, y lo que se editara dentro
# del container acababa en un volumen sin historia que nadie versionaba.
#
# En ~/.config/git (volumen) solo queda lo que es de ESTA máquina: la
# identidad (user.name, user.email) y el include hacia el config versionado.

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

# Caché de uv dentro de su volumen. Sin esto uv la pondría en ~/.cache/uv
# igualmente, pero explícito es mejor: si algo cambia $HOME (un `sudo -i`,
# un cron) la caché se partiría en dos sin que nadie lo note.
ENV UV_CACHE_DIR="/home/${USERNAME}/.cache/uv"

# Los intérpretes que uv descarga (`uv venv --python 3.12`) van DENTRO del
# volumen de caché. Por defecto aterrizan en ~/.local/share/uv/python, que no
# es un volumen: se perdían enteros en cada rebuild y había que volver a
# bajar un CPython de 60 MB. Van con la caché y no en un volumen propio
# porque son exactamente igual de reconstruibles: se rebajan y ya.
ENV UV_PYTHON_INSTALL_DIR="/home/${USERNAME}/.cache/uv/python"

# Terminal mejorada (prompt con rama de git, venv y exit code; historial
# grande; completado; aliases). ASCII-safe, sin Nerd Fonts (Problema 10).
COPY --chown=${USER_UID}:${USER_GID} provision/bash-enhancements.sh "/home/${USERNAME}/.bash_enhancements.sh"
RUN printf '\n# devcontainer bash enhancements\n[ -f "$HOME/.bash_enhancements.sh" ] && . "$HOME/.bash_enhancements.sh"\n' \
      >> "/home/${USERNAME}/.bashrc"

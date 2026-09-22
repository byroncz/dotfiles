# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
#  devkit: imagen de trabajo.
#
#  Principios (entrada de Documentación "Arquitectura del devkit", Notion):
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
# los agentes. tzdata trae la base de zonas horarias que usa TZ (DEVKIT-64,
# la zona del Mac que pasa compose.yaml); sin ella, TZ con una zona con
# nombre (no un offset fijo) no cambia nada y el contenedor se queda en UTC.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg unzip zip jq less procps \
      ncurses-base ncurses-term zsh ripgrep fd-find openssh-client socat \
      tzdata \
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
# vscode/settings.json ya no se copia a data/User/settings.json: openvscode-
# server no lee esa ruta como ajustes de usuario del navegador, así que
# nunca quedaba vigente (DEVKIT-116). Se copia más abajo junto a la
# extensión devkit.cheatsheet, que es quien los aplica de verdad.

COPY --chown=${USER_UID}:${USER_GID} entrypoint.sh /opt/devkit/entrypoint.sh
COPY --chown=${USER_UID}:${USER_GID} scripts/      /opt/devkit/scripts/

# Chuleta de comandos del editor (DEVKIT-96): extensión local, sin empaquetar
# ni Open VSX (devkit/vscode/cheatsheet/, con su cheatsheet.html y los SVG
# cheatsheet-{light,dark}.svg generados por gen-cheatsheet.sh), copiada tal
# cual a la carpeta de extensiones. openvscode-server la carga igual que una
# .vsix desempaquetada. A diferencia de README.md (que solo se regenera en la
# card de release, AGENTS.md), este HTML y estos SVG los sirve la imagen en
# vivo: el build corta si alguno quedó viejo respecto a comandos.txt.
COPY --chown=${USER_UID}:${USER_GID} vscode/cheatsheet/ /home/${USERNAME}/.openvscode-server/extensions/devkit.cheatsheet-0.1.0/
# settings.json copiado junto a la extensión (DEVKIT-116): es la única forma
# de dejar vigentes los ajustes del editor, porque openvscode-server no lee
# ningún archivo de settings del lado del navegador. La extensión lo lee al
# activarse y aplica cada clave por la API de configuración; settings.json
# sigue siendo la única fuente, no se duplica en el código de la extensión.
COPY --chown=${USER_UID}:${USER_GID} vscode/settings.json /home/${USERNAME}/.openvscode-server/extensions/devkit.cheatsheet-0.1.0/settings.json
# gen-cheatsheet.sh calcula SALIDA/SALIDA_SVG_CLARO/SALIDA_SVG_OSCURO por
# defecto como <devkit>/vscode/cheatsheet/cheatsheet.{html,-light.svg,-dark.svg},
# rutas que en la imagen no existen (solo entrypoint.sh y scripts/ viven bajo
# /opt/devkit): --check tiene que comparar contra los archivos recién
# copiados a la carpeta de extensiones, así que se lo indica con las
# variables que el script ya prevé.
RUN DEVKIT_GEN_CHEATSHEET_SALIDA="$HOME/.openvscode-server/extensions/devkit.cheatsheet-0.1.0/cheatsheet.html" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_CLARO="$HOME/.openvscode-server/extensions/devkit.cheatsheet-0.1.0/cheatsheet-light.svg" \
    DEVKIT_GEN_CHEATSHEET_SALIDA_SVG_OSCURO="$HOME/.openvscode-server/extensions/devkit.cheatsheet-0.1.0/cheatsheet-dark.svg" \
    bash /opt/devkit/scripts/gen-cheatsheet.sh --check
# Desde VS Code 1.80, extensions.json (ya escrito por el --install-extension
# de más arriba) es el manifiesto autoritativo de qué extensiones carga
# openvscode-server: una carpeta copiada a mano después no aparece ahí y
# queda en disco pero invisible para el editor. Se borra para forzar un
# reescaneo del directorio completo; el grep corta el build si el reescaneo
# no deja la extensión listada.
RUN rm -f "$HOME/.openvscode-server/extensions/extensions.json" \
 && openvscode-server --list-extensions --extensions-dir "$HOME/.openvscode-server/extensions" \
    | grep -qx devkit.cheatsheet

# Marca de agua del editor vacío (DEVKIT-143): el editor sin pestañas pinta
# un div.letterpress con el logo de openvscode-server como fondo; no hay API
# de extensiones para cambiarlo (ver Notas de la card), así que se
# reemplazan los cuatro SVG de tema (el claro para light/hcLight, el oscuro
# para dark/hcDark -H1 de la revisión: un solo SVG con @media
# prefers-color-scheme sigue al sistema operativo o al navegador, no al tema
# de VS Code) y se amplían las dos reglas de workbench.css que limitan su
# tamaño a un ícono pequeño. La sustitución es de cadena literal exacta -no
# una regex de sed- para que un cambio de bundling en la próxima versión de
# openvscode-server corte el build en vez de quedar aplicado a medias en
# silencio.
# set -eu, no -x: con -x, bash traza también el valor expandido de
# "contenido=$(cat "$CSS")" -workbench.css minificado pesa ~900 KB en una
# sola línea- e infla el log del build sin decir nada útil.
# USER root ... USER $USERNAME: /opt/openvscode-server se extrajo como root
# (línea 80, antes del USER $USERNAME de más arriba) y no se le hizo chown,
# a diferencia de /opt/devkit; escribir ahí como $USERNAME corta el build con
# permiso denegado (H2 de la revisión).
USER root
# SHELL a bash solo para este RUN: contenido="${contenido//$VIEJO/$NUEVO}" es
# sustitución de patrones de bash, que dash (el /bin/sh de Debian) no
# implementa y corta el build con "Bad substitution" (DEVKIT-145).
SHELL ["/bin/bash", "-c"]
RUN set -eu; \
    SVG_CLARO="$HOME/.openvscode-server/extensions/devkit.cheatsheet-0.1.0/cheatsheet-light.svg"; \
    SVG_OSCURO="$HOME/.openvscode-server/extensions/devkit.cheatsheet-0.1.0/cheatsheet-dark.svg"; \
    MEDIA="/opt/openvscode-server/out/media"; \
    cp "$SVG_CLARO" "$MEDIA/letterpress-light.svg"; \
    cp "$SVG_CLARO" "$MEDIA/letterpress-hcLight.svg"; \
    cp "$SVG_OSCURO" "$MEDIA/letterpress-dark.svg"; \
    cp "$SVG_OSCURO" "$MEDIA/letterpress-hcDark.svg"; \
    ancho="$(grep -oE 'width="[0-9]+' "$SVG_CLARO" | head -1 | grep -oE '[0-9]+')"; \
    alto="$(grep -oE 'height="[0-9]+' "$SVG_CLARO" | head -1 | grep -oE '[0-9]+')"; \
    [ -n "$ancho" ] && [ -n "$alto" ] || { echo "cheatsheet-light.svg sin width/height en la etiqueta raíz" >&2; exit 1; }; \
    CSS="/opt/openvscode-server/out/vs/code/browser/workbench/workbench.css"; \
    VIEJO_WATERMARK='.editor-group-watermark{display:flex;height:100%;max-width:272px;margin:auto;flex-direction:column;align-items:center;justify-content:center}'; \
    NUEVO_WATERMARK='.editor-group-watermark{display:flex;height:100%;max-width:1000px;margin:auto;flex-direction:column;align-items:center;justify-content:center}'; \
    VIEJO_LETTERPRESS='.editor-group-watermark .letterpress{width:100%;max-height:100%;aspect-ratio:1/1;background-image:url(../../../../media/letterpress-light.svg);background-size:contain;background-position-x:center;background-repeat:no-repeat;max-width:256px}'; \
    NUEVO_LETTERPRESS=".editor-group-watermark .letterpress{width:100%;max-height:100%;aspect-ratio:${ancho}/${alto};background-image:url(../../../../media/letterpress-light.svg);background-size:contain;background-position-x:center;background-repeat:no-repeat;max-width:100%}"; \
    contenido="$(cat "$CSS")"; \
    case "$contenido" in \
      *"$VIEJO_WATERMARK"*) ;; \
      *) echo "workbench.css: no se encontró la regla .editor-group-watermark (max-width:272px); openvscode-server cambió el CSS, revisa DEVKIT-143" >&2; exit 1 ;; \
    esac; \
    case "$contenido" in \
      *"$VIEJO_LETTERPRESS"*) ;; \
      *) echo "workbench.css: no se encontró la regla .letterpress (aspect-ratio:1/1); openvscode-server cambió el CSS, revisa DEVKIT-143" >&2; exit 1 ;; \
    esac; \
    contenido="${contenido//$VIEJO_WATERMARK/$NUEVO_WATERMARK}"; \
    contenido="${contenido//$VIEJO_LETTERPRESS/$NUEVO_LETTERPRESS}"; \
    printf '%s' "$contenido" > "$CSS"
SHELL ["/bin/sh", "-c"]
USER $USERNAME

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

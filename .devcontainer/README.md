# Template de devcontainer

Base mínima (`debian:trixie-slim`, **30 MB** comprimido) con Claude Code
persistente entre rebuilds, terminal usable y extensiones de Antigravity
instaladas automáticamente. **No está atado a ningún runtime**: Python, Node,
Go o lo que haga falta se añade por proyecto sin tocar los archivos del
template.

El diagnóstico completo del entorno está en [`docs/DIAGNOSTICO.md`](docs/DIAGNOSTICO.md).
La configuración de una sola vez del respaldo cifrado está en
[`docs/CONFIGURACION-MANUAL.md`](docs/CONFIGURACION-MANUAL.md).

## Estructura

El folder está ordenado por **fase del pipeline**: mirando la carpeta se sabe
dónde y cuándo se ejecuta cada cosa.

| Carpeta | Se ejecuta | Contiene |
|---|---|---|
| *(raíz)* | Host, al levantar | `devcontainer.json`, `docker-compose.yml`, `.env` — los tres ficheros que las herramientas exigen en una ruta fija |
| [`image/`](image/) | En el **build** de Docker | `Dockerfile` y el hook `extras/build.sh` |
| [`provision/`](provision/) | **Dentro** del dev container | `post-create.sh`, `install-extensions.sh`, `bash-enhancements.sh` |
| [`backup/`](backup/) | Sidecars rclone + host | `watch.sh`, `filtros.txt`, `rclone-setup.sh` |
| [`bin/`](bin/) | Host, a mano | `claude-volume.sh` |
| [`mcp/`](mcp/) | Leído en **provision** | `servers.json`, el origen único de los servidores MCP |
| [`docs/`](docs/) | — | Diagnóstico y configuración manual |

Lo que suele cambiar por proyecto **no está en ninguno de esos scripts**, sino
en `.env` (ver `.env.example`) y en `docker-compose.yml`.

> Las rutas de `COPY` del `Dockerfile` son relativas al **build context**
> (`.devcontainer/`), no al fichero: por eso llevan prefijo (`image/extras/`,
> `provision/bash-enhancements.sh`). El `.dockerignore` es una allow-list — si
> añades un `COPY`, decláralo también ahí.

## Uso

```bash
cp -r ruta/a/dotfiles/.devcontainer mi-proyecto/.devcontainer
cd mi-proyecto
devcontainer up --workspace-folder . --remove-existing-container
```

`--remove-existing-container` destruye el container, **no** los volúmenes: la
sesión de Claude Code sigue ahí y no hay que volver a hacer login.

## Adaptarlo a cada proyecto

Tres niveles, de menos a más invasivo. **Ninguno requiere editar el
`Dockerfile`**, así que el template se puede actualizar entero copiándolo otra
vez encima.

### 1. Build args en `.env`

Los args ya no viven en `devcontainer.json`: `docker-compose.yml` los toma del
`.env` hermano, que **no se versiona**. Copia `.env.example` y edítalo.

```bash
# .devcontainer/.env
BASE_IMAGE=python:3.11-slim          # cualquier imagen Debian/Ubuntu
USERNAME=vscode
EXTRA_APT=postgresql-client libpq-dev
PIP_PACKAGES=boto3 pandas nbformat
INSTALL_AWSCLI=true
```

| Arg | Para qué | Por defecto |
|---|---|---|
| `BASE_IMAGE` | Imagen base. Cualquiera basada en Debian/Ubuntu con `apt-get` | `debian:trixie-slim` |
| `USERNAME` | Usuario no-root; se crea solo si la base no lo trae | `vscode` |
| `EXTRA_APT` | Paquetes apt adicionales, separados por espacios | `""` |
| `PIP_PACKAGES` | Paquetes pip (requiere una base con `pip`) | `""` |
| `INSTALL_AWSCLI` | Instala AWS CLI v2 | `false` |

Bases habituales y su tamaño comprimido: `debian:trixie-slim` 30 MB ·
`python:3.11-slim` 43 MB · `node:22-slim` 76 MB · `ubuntu:24.04` 28 MB.

### 2. Hooks del proyecto

Tres archivos opcionales. Si no existen, no pasa nada; si existen, el template
los ejecuta. Cada uno vive en la carpeta de su fase:

| Archivo | Cuándo | Para qué |
|---|---|---|
| `image/extras/build.sh` | En el **build**, como root | Lo que los args no cubren: Node sin cambiar de base, Terraform, un repo apt propio, compilar algo |
| `provision/post-create.local.sh` | Tras crear el container, como usuario | Migraciones, seeds, `npm install`, sanity checks del stack |
| `provision/extensions.local.sh` | Al instalar extensiones | Lista de extensiones del proyecto; usa `install_vsix <publisher> <name> [versión]` |

Ejemplo de `image/extras/build.sh` para tener Node sin dejar `debian:trixie-slim`:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y --no-install-recommends nodejs
rm -rf /var/lib/apt/lists/*
```

### 3. Cambiar la base entera

`BASE_IMAGE` acepta cualquier imagen con `apt-get` (Debian/Ubuntu y derivadas:
`python:*-slim`, `node:*-slim`, `golang:*-bookworm`, `eclipse-temurin:*-jdk-jammy`).
Con bases Alpine o RedHat el template no funciona tal cual — habría que
cambiar el gestor de paquetes en `image/Dockerfile`.

Si la base ya trae un usuario con UID 1000 (por ejemplo `node`), el template lo
detecta y no intenta crearlo; pon ese nombre en `USERNAME` y en `remoteUser`.

### Ejemplo completo: proyecto Python + AWS + Jupyter

```bash
# .devcontainer/.env
BASE_IMAGE=python:3.11-slim
INSTALL_AWSCLI=true
PIP_PACKAGES=boto3 nbformat nbconvert jupyterlab ipykernel pandas pyarrow
```

```bash
# .devcontainer/provision/extensions.local.sh
install_vsix ms-python  python
install_vsix ms-toolsai jupyter
install_vsix ms-toolsai vscode-jupyter-cell-tags
install_vsix amazonwebservices aws-toolkit-vscode
```

```bash
# .devcontainer/provision/post-create.local.sh
aws --version
python -c "import nbformat, boto3; print('stack OK')"
```

## Qué persiste y dónde

| Volumen | Montado en | Contenido |
|---|---|---|
| `claude-<cliente>` | `~/.claude` | Transcripciones (`projects/*.jsonl`), `.credentials.json`, `settings.json`, `history.jsonl`, `plugins/`, `.claude.json` |
| `git-home` | `~/.config/git` | **gitignore global** (`ignore`) y config global de git (`config`) |
| `bash-history-<cliente>-<proyecto>` | `/commandhistory` | Historial de bash |
| `ide-extensions-<cliente>-<proyecto>` | `~/.antigravity-ide-server/extensions` | Extensiones de Open VSX |
| `basic-memory-<cliente>` | `~/basic-memory` | Knowledge acumulado sobre el cliente |
| `basic-memory-index-<cliente>` | `~/.basic-memory` | Índice SQLite y `config.json` de Basic Memory |
| `nvim-data-…` / `nvim-state-…` | `~/.local/{share,state}/nvim` | Plugins y estado de lazy.nvim |
| `uv-cache-<cliente>` | `~/.cache/uv` | Caché de uv e intérpretes de Python descargados |

`claude-<cliente>` va por **cliente**, no por proyecto ni global: los
transcripts de un cliente no deben acabar en el respaldo cifrado de otro. El
precio es un `/login` por cliente, no uno por proyecto. `git-home` sí es global.
Los nombres exactos los fija la sección `volumes:` de `docker-compose.yml`.

Tres detalles hacen que la persistencia funcione de verdad:

1. **`CLAUDE_CONFIG_DIR`**. Por defecto Claude Code escribe `~/.claude.json`
   **fuera** de `~/.claude`, así que un volumen montado solo en `~/.claude`
   perdería en cada rebuild el login OAuth, los MCP servers de usuario y el
   `trust` por proyecto. Verificado con Claude Code 2.1.240.
2. **`GIT_CONFIG_GLOBAL`**. El gitignore que se persiste es el **del home**
   (`~/.config/git/ignore`), el que aplica a todos los repos del container — no
   el `.gitignore` de cada repositorio, que viaja en el propio repo. Git
   prefiere `~/.gitconfig` sobre `~/.config/git/config`, así que sin esta
   variable el archivo efectivo queda fuera del volumen. Verificado con git 2.43.
3. **Los mount points se pre-crean en `image/Dockerfile`** con el owner del
   usuario. Docker crea el directorio de un montaje como `root:root` si no
   existe en la imagen; creándolo antes, el volumen nombrado hereda el
   ownership correcto la primera vez que se monta.

`provision/post-create.sh` fusiona además una sola vez cualquier `~/.claude.json`,
`~/.gitconfig` o `~/.gitignore_global` que quede fuera del volumen (por ejemplo
el que el IDE copia del host) y deja el original como `.pre-volume`.

## Ecosistema de agentes

Cinco herramientas, cada una tras su build arg, todas a `true` por defecto.
Un proyecto que no las quiera las apaga en `.env` y no paga ni un byte.

| Build arg | Instala | Cuesta |
|---|---|---|
| `INSTALL_UV` | `uv` (Astral) | ~35 MB |
| `INSTALL_BASIC_MEMORY` | `basic-memory` + servidor MCP | ~150 MB (trae su propio Python) |
| `INSTALL_OPENSPEC` | `openspec` (`@fission-ai/openspec`) | Node 22, ~120 MB, compartidos |
| `INSTALL_BACKLOG` | `backlog` (`backlog.md`) | — |
| `INSTALL_NOTION_MCP` | `@notionhq/notion-mcp-server` | — |

Las tres últimas vienen por npm y arrastran Node, que **solo se instala si
alguna de las tres está a `true`**. Apagadas las tres, no hay Node en la imagen.

### Python con uv, no con `PIP_PACKAGES`

**`uv` sustituye a `PIP_PACKAGES`**, que se mantiene solo por compatibilidad y
no debería usarse en proyectos nuevos.

El motivo no es la velocidad: es que `PIP_PACKAGES` **exige una `BASE_IMAGE`
con pip**. Instalar un paquete de Python obligaba a cambiar la imagen base
entera a `python:3.11-slim`, lo que a su vez fija la versión de Python para
todo el container. `uv` se trae su propio intérprete, así que funciona sobre la
base mínima de 27 MB y cada proyecto elige su versión de Python sin tocar nada
más:

```bash
uv venv --python 3.12          # se descarga el intérprete si no está
uv pip install pandas boto3
uv run script.py               # sin activar el venv
```

Dos rutas van a un volumen, las dos declaradas explícitas en el compose:

- `UV_CACHE_DIR` → `~/.cache/uv`, las ruedas y fuentes descargadas.
- `UV_PYTHON_INSTALL_DIR` → `~/.cache/uv/python`, los **intérpretes**. Por
  defecto aterrizarían en `~/.local/share/uv/python`, que no es un volumen: se
  perdía un CPython de 60 MB en cada rebuild.

Ese volumen (`uv-cache-<cliente>`) **no se respalda**: es reconstruible por
definición, se vuelve a llenar descargando. Va por cliente y no por proyecto
porque uv sí está pensado para que varios procesos compartan caché.

### Basic Memory

Conocimiento en markdown, local, fuera de `~/.claude` a propósito: es del
proyecto, no del agente, y Codex u OpenCode deben poder leer el mismo
directorio. Se declara como servidor MCP en [`mcp/servers.json`](mcp/servers.json).

`provision/post-create.sh` registra el proyecto en el primer arranque. Dos
cosas que conviene saber antes de tocarlo:

- El proyecto **no puede llamarse `main`**. Ese es el nombre implícito por
  defecto y `project add main` cortocircuita: escribe `config.json`, devuelve
  «already exists» y nunca inserta en el índice SQLite. El estado queda partido
  —la config dice que existe, la base dice que no hay ninguno— y ni `add` ni
  `remove` lo arreglan, porque cada uno consulta una mitad distinta. El
  template usa `conocimiento`.
- La fuente de verdad es `basic-memory tool list-projects` (pregunta a la API),
  **no** `basic-memory project list` (lee `config.json`). Con el estado partido,
  el segundo muestra el proyecto y todo parece correcto.

El índice se reconstruye con `basic-memory reindex`; `basic-memory sync` ya no
existe en 0.23. `basic-memory status` y `basic-memory doctor` dicen si el
índice y los archivos coinciden.

### OpenSpec y Backlog.md

> **Sus artefactos van en el repo del CLIENTE, no en este template.**

`openspec init` crea `openspec/` y `backlog init` crea `backlog/` **en el
directorio donde los ejecutes**. Ejecutados en `/workspace` de un proyecto,
esas carpetas son del proyecto: se versionan en su repo, y las revisa y
commitea quien trabaja ahí. Este template solo instala los binarios; no trae
ni debe traer un `openspec/` o un `backlog/` propio.

### Notion

El servidor MCP oficial queda **instalado pero sin configurar**: sin token, sin
workspace y sin permisos. Está declarado en `mcp/servers.json` con
`"enabled": false`, así que no se genera en ninguna config de MCP hasta que
alguien lo active a conciencia. El token, cuando llegue, va **fuera del repo**,
como el resto de los secretos.

## Neovim

Neovim 0.12 con [LazyVim](https://www.lazyvim.org/), más ripgrep, fd, tmux y
build-essential. Se instala con `INSTALL_NVIM=true` (por defecto); un proyecto
que no lo quiera lo pone a `false` y se ahorra unos 300 MB.

**Del tarball oficial, no de apt.** Debian bookworm empaqueta Neovim 0.7.2,
años por debajo del mínimo de LazyVim. El tarball son 11 MB. Se usa tarball y
no AppImage porque el AppImage necesita FUSE dentro del container.

**La base es `debian:trixie-slim`, no bookworm.** Por la glibc: bookworm trae
2.36 y bastantes binarios precompilados actuales piden 2.39 o más. El caso que
lo forzó fue el `tree-sitter` que instala Mason, que en bookworm muere con
`version GLIBC_2.39 not found` y deja Neovim sin parsers. Trixie da 2.41.

### La config se enlaza, no se hornea

`nvim/` vive en este repo y `provision/post-create.sh` enlaza `~/.config/nvim` ahí.

No se hornea en la imagen porque entonces cambiar un atajo obligaría a
reconstruirla. No se copia porque la copia del container y la del repo
divergen en cuanto editas una de las dos. Enlazada, editas el repo y lo ves en
el siguiente arranque de `nvim`.

Cuando el workspace **es** este repo, se enlaza directamente a `/workspace/nvim`.
En cualquier otro proyecto, `provision/post-create.sh` clona `DOTFILES_REPO` en
`~/.dotfiles` y enlaza ahí — **nunca dentro del repo del cliente**, que no
tiene por qué cargar con la configuración de editor de nadie.

### Plugins

Van a los volúmenes `nvim-data-<cliente>-<proyecto>` y `nvim-state-...`, así
que un rebuild no los vuelve a descargar. **No se respaldan a rclone**: se
reconstruyen enteros desde este repo con `nvim --headless "+Lazy! sync" +qa`.

Son por proyecto y no globales porque puedes tener varios devcontainers
abiertos a la vez, y lazy.nvim no espera que dos procesos escriban su estado.

### Iconos

`NERD_FONT=false` por defecto: los iconos de LazyVim son de Nerd Font y, sin
la fuente instalada **y configurada en la terminal**, se ven cuadraditos. La
funcionalidad —LSP, diagnósticos, búsqueda— es idéntica; esto es solo
estético. Ponlo a `true` cuando tu terminal la tenga.

### Portapapeles

Dentro de un container no hay X ni `pbcopy`, así que `nvim/lua/config/options.lua`
configura OSC 52: un código de escape que interpreta la propia terminal. Copiar
funciona; pegar usa el registro interno de Neovim, porque muchas terminales
desactivan la lectura por OSC 52 por seguridad. Requiere Kitty, WezTerm,
Ghostty o Alacritty.


## Backup y restauración

`bin/claude-volume.sh` se ejecuta **en el host**:

```bash
./bin/claude-volume.sh info                 # credenciales, nº de transcripciones, tamaño
./bin/claude-volume.sh backup ~/backups     # tarball con timestamp
./bin/claude-volume.sh restore ~/backups/claude-<cliente>-20260822-193000.tar.gz
CLAUDE_VOLUME=git-home ./bin/claude-volume.sh info
```

El tarball de `claude-<cliente>` incluye `.credentials.json`: trátalo como un
secreto. `docker volume prune` se lleva por delante cualquier volumen que no
esté en uso por un container existente — haz `backup` antes de limpiar.

## Decisiones de diseño

- **Base slim en vez de `devcontainers/base`** (27 MB frente a 336 MB): el
  único coste es crear el usuario e instalar cuatro paquetes, que el template
  ya hace.
- **CLI de Claude Code nativo en vez de npm**: evita arrastrar Node (~76 MB de
  base + toolchain) en proyectos que no lo usan. Quien necesite Node lo añade
  con `BASE_IMAGE` o `image/extras/build.sh`.
- **`/workspace` fijo con bind explícito** en vez de
  `/workspaces/${localWorkspaceFolderBasename}`: evita que el `postCreateCommand`
  falle cuando el directorio local tiene espacios o mayúsculas (Problema 9b).
- **Nombres de volumen sin `${devcontainerId}`**: ese ID cambia al editar
  `devcontainer.json` y con él se dejaría de montar el volumen anterior.

## Archivos

| Archivo | Para qué |
|---|---|
| `devcontainer.json` | Solo apunta al compose: servicio, `workspaceFolder`, `remoteUser`, `postCreateCommand` |
| `docker-compose.yml` | Servicio `dev`, volúmenes, env vars de persistencia y los 4 sidecars de respaldo |
| `.env` / `.env.example` | Lo que cambia por proyecto: `CLIENTE`, `PROYECTO`, build args, `COMPOSE_PROFILES` |
| `.dockerignore` | Allow-list del build context: solo entra lo que el `Dockerfile` COPYa |
| **`image/`** | |
| `image/Dockerfile` | Base parametrizable, usuario, mount points, CLI de Claude, terminal |
| `image/extras/build.sh` | Hook de build del proyecto (vacío en el template) |
| **`provision/`** | |
| `provision/post-create.sh` | Permisos, migraciones al volumen, `core.excludesFile`, nvim, extensiones, hook del proyecto |
| `provision/install-extensions.sh` | Extensiones desde Open VSX (Problemas 3-7) |
| `provision/generar-mcp.py` | Genera `.mcp.json` y `~/.codex/config.toml` desde `mcp/servers.json` |
| `provision/bash-enhancements.sh` | Prompt informativo, historial, aliases, completado (Problema 10) |
| **`mcp/`** | |
| `mcp/servers.json` | **Origen único** de los servidores MCP. Se edita aquí; los de cada agente se generan |
| **`backup/`** | |
| `backup/watch.sh` | Entrypoint compartido de los 4 sidecars: `inotifywait` + debounce + `rclone sync` versionado |
| `backup/filtros.txt` | Filtros rclone del sidecar `sync-workspace` |
| `backup/rclone-setup.sh` | `config` / `check` / `ls` / `restore-test` de rclone, desde el host y sin instalarlo |
| **`bin/`** | |
| `bin/claude-volume.sh` | `info` / `create` / `backup` / `restore` de los volúmenes, desde el host |
| **`docs/`** | |
| `docs/DIAGNOSTICO.md` | Guía de diagnóstico del entorno completo (Problemas 1-12) |
| `docs/CONFIGURACION-MANUAL.md` | Los pasos de una sola vez del respaldo cifrado (Dropbox, crypt, OAuth) |

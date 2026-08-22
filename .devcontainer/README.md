# Template de devcontainer

Base mínima (`debian:bookworm-slim`, **27 MB** comprimido) con Claude Code
persistente entre rebuilds, terminal usable y extensiones de Antigravity
instaladas automáticamente. **No está atado a ningún runtime**: Python, Node,
Go o lo que haga falta se añade por proyecto sin tocar los archivos del
template.

El diagnóstico completo del entorno está en [`AGENTS.md`](AGENTS.md).

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

### 1. Build args en `devcontainer.json`

```jsonc
"build": {
  "dockerfile": "Dockerfile",
  "context": ".",
  "args": {
    "BASE_IMAGE": "python:3.11-slim",     // cualquier imagen Debian/Ubuntu
    "USERNAME": "vscode",
    "EXTRA_APT": "postgresql-client libpq-dev",
    "PIP_PACKAGES": "boto3 pandas nbformat",
    "INSTALL_AWSCLI": "true"
  }
}
```

| Arg | Para qué | Por defecto |
|---|---|---|
| `BASE_IMAGE` | Imagen base. Cualquiera basada en Debian/Ubuntu con `apt-get` | `debian:bookworm-slim` |
| `USERNAME` | Usuario no-root; se crea solo si la base no lo trae | `vscode` |
| `EXTRA_APT` | Paquetes apt adicionales, separados por espacios | `""` |
| `PIP_PACKAGES` | Paquetes pip (requiere una base con `pip`) | `""` |
| `INSTALL_AWSCLI` | Instala AWS CLI v2 | `false` |

Bases habituales y su tamaño comprimido: `debian:bookworm-slim` 27 MB ·
`python:3.11-slim` 43 MB · `node:22-slim` 76 MB · `ubuntu:24.04` 28 MB.

### 2. Hooks del proyecto

Tres archivos opcionales dentro de `.devcontainer/`. Si no existen, no pasa
nada; si existen, el template los ejecuta:

| Archivo | Cuándo | Para qué |
|---|---|---|
| `extras/build.sh` | En el **build**, como root | Lo que los args no cubren: Node sin cambiar de base, Terraform, un repo apt propio, compilar algo |
| `post-create.local.sh` | Tras crear el container, como usuario | Migraciones, seeds, `npm install`, sanity checks del stack |
| `extensions.local.sh` | Al instalar extensiones | Lista de extensiones del proyecto; usa `install_vsix <publisher> <name> [versión]` |

Ejemplo de `extras/build.sh` para tener Node sin dejar `debian:bookworm-slim`:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y --no-install-recommends nodejs
rm -rf /var/lib/apt/lists/*
```

### 3. Cambiar la base entera

`BASE_IMAGE` acepta cualquier imagen con `apt-get` (Debian/Ubuntu y derivadas:
`python:*-slim`, `node:*-slim`, `golang:*-bookworm`, `eclipse-temurin:*-jdk-jammy`).
Con bases Alpine o RedHat el template no funciona tal cual — habría que
cambiar el gestor de paquetes en el `Dockerfile`.

Si la base ya trae un usuario con UID 1000 (por ejemplo `node`), el template lo
detecta y no intenta crearlo; pon ese nombre en `USERNAME` y en `remoteUser`.

### Ejemplo completo: proyecto Python + AWS + Jupyter

```jsonc
// devcontainer.json
"build": {
  "dockerfile": "Dockerfile",
  "context": ".",
  "args": {
    "BASE_IMAGE": "python:3.11-slim",
    "INSTALL_AWSCLI": "true",
    "PIP_PACKAGES": "boto3 nbformat nbconvert jupyterlab ipykernel pandas pyarrow"
  }
}
```

```bash
# .devcontainer/extensions.local.sh
install_vsix ms-python  python
install_vsix ms-toolsai jupyter
install_vsix ms-toolsai vscode-jupyter-cell-tags
install_vsix amazonwebservices aws-toolkit-vscode
```

```bash
# .devcontainer/post-create.local.sh
aws --version
python -c "import nbformat, boto3; print('stack OK')"
```

## Qué persiste y dónde

| Volumen | Montado en | Contenido |
|---|---|---|
| `claude-home` | `~/.claude` | Transcripciones (`projects/*.jsonl`), `.credentials.json`, `settings.json`, `history.jsonl`, `plugins/`, `.claude.json` |
| `git-home` | `~/.config/git` | **gitignore global** (`ignore`) y config global de git (`config`) |
| `<proyecto>-bash-history` | `/commandhistory` | Historial de bash |
| `<proyecto>-ide-extensions` | `~/.antigravity-ide-server/extensions` | Extensiones de Open VSX |

`claude-home` y `git-home` **no llevan el nombre del proyecto**: son
compartidos por todos los devcontainers de la máquina, así que el login de
Claude Code y el gitignore global se hacen una sola vez. Para aislarlos por
proyecto, anteponer `${localWorkspaceFolderBasename}-` en `mounts`.

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
3. **Los mount points se pre-crean en el `Dockerfile`** con el owner del
   usuario. Docker crea el directorio de un montaje como `root:root` si no
   existe en la imagen; creándolo antes, el volumen nombrado hereda el
   ownership correcto la primera vez que se monta.

`post-create.sh` fusiona además una sola vez cualquier `~/.claude.json`,
`~/.gitconfig` o `~/.gitignore_global` que quede fuera del volumen (por ejemplo
el que el IDE copia del host) y deja el original como `.pre-volume`.

## Backup y restauración

`claude-volume.sh` se ejecuta **en el host**:

```bash
./claude-volume.sh info                     # credenciales, nº de transcripciones, tamaño
./claude-volume.sh backup ~/backups         # tarball con timestamp
./claude-volume.sh restore ~/backups/claude-home-20260822-193000.tar.gz
CLAUDE_VOLUME=git-home ./claude-volume.sh info
```

El tarball de `claude-home` incluye `.credentials.json`: trátalo como un
secreto. `docker volume prune` se lleva por delante cualquier volumen que no
esté en uso por un container existente — haz `backup` antes de limpiar.

## Decisiones de diseño

- **Base slim en vez de `devcontainers/base`** (27 MB frente a 336 MB): el
  único coste es crear el usuario e instalar cuatro paquetes, que el template
  ya hace.
- **CLI de Claude Code nativo en vez de npm**: evita arrastrar Node (~76 MB de
  base + toolchain) en proyectos que no lo usan. Quien necesite Node lo añade
  con `BASE_IMAGE` o `extras/build.sh`.
- **`/workspace` fijo con bind explícito** en vez de
  `/workspaces/${localWorkspaceFolderBasename}`: evita que el `postCreateCommand`
  falle cuando el directorio local tiene espacios o mayúsculas (Problema 9b).
- **Nombres de volumen sin `${devcontainerId}`**: ese ID cambia al editar
  `devcontainer.json` y con él se dejaría de montar el volumen anterior.

## Archivos

| Archivo | Para qué |
|---|---|
| `devcontainer.json` | Volúmenes, build args, `CLAUDE_CONFIG_DIR`, `GIT_CONFIG_GLOBAL` |
| `Dockerfile` | Base parametrizable, usuario, mount points, CLI de Claude, terminal |
| `post-create.sh` | Permisos, migraciones al volumen, `core.excludesFile`, extensiones, hook del proyecto |
| `install-extensions.sh` | Extensiones desde Open VSX (Problemas 3-7) |
| `bash-enhancements.sh` | Prompt informativo, historial, aliases, completado (Problema 10) |
| `claude-volume.sh` | `info` / `create` / `backup` / `restore` de los volúmenes, desde el host |
| `extras/build.sh` | Hook de build del proyecto (vacío en el template) |
| `AGENTS.md` | Guía de diagnóstico del entorno completo |

# .devcontainer — devcontainer del proyecto con estado persistente

Devcontainer de `gt-algorithia-capta-homologacion` (Python 3.11 + AWS CLI v2 +
Jupyter/pandas, usuario `devuser` en `/workspace`) **con el estado del home
persistido en volúmenes Docker**: al rehacer el container no se pierden las
conversaciones ni las credenciales de Claude Code, ni la configuración global
de git, ni el historial de bash.

El diagnóstico completo del entorno (Antigravity IDE, extensiones, permisos de
montaje, terminal, persistencia) está en [`AGENTS.md`](AGENTS.md).

## Uso

```bash
devcontainer up --workspace-folder /ruta/al/proyecto --remove-existing-container
```

`--remove-existing-container` destruye el container, **no** los volúmenes: al
volver a levantarlo la sesión de Claude Code sigue ahí y no hay que hacer login
de nuevo.

## Qué persiste y dónde

| Volumen | Montado en | Contenido |
|---|---|---|
| `capta-claude-config` | `/home/devuser/.claude` | Transcripciones (`projects/*.jsonl`), `.credentials.json`, `settings.json`, `history.jsonl`, `plugins/`, `.claude.json` |
| `capta-git-config` | `/home/devuser/.config/git` | **gitignore global** (`ignore`) y config global de git (`config`) |
| `capta-bash-history` | `/commandhistory` | Historial de bash |
| `capta-ide-extensions` | `/home/devuser/.antigravity-ide-server/extensions` | Extensiones instaladas desde Open VSX |

Tres detalles hacen que esto funcione de verdad:

1. **`CLAUDE_CONFIG_DIR=/home/devuser/.claude`**. Por defecto Claude Code
   escribe `~/.claude.json` **fuera** de `~/.claude`, así que un volumen montado
   solo en `~/.claude` perdería en cada rebuild el login OAuth, los MCP servers
   de usuario y el `trust` por proyecto. Con esta variable el archivo pasa a
   `$CLAUDE_CONFIG_DIR/.claude.json`, dentro del volumen. Verificado con Claude
   Code 2.1.240.

2. **`GIT_CONFIG_GLOBAL=/home/devuser/.config/git/config`**. El gitignore que se
   persiste es el **del home** (`~/.config/git/ignore`), el que aplica a todos
   los repos del container — no el `.gitignore` de cada repositorio, que viaja
   en el propio repo. Sin esta variable, `git config --global ...` crea
   `~/.gitconfig` fuera del volumen y ese archivo tiene prioridad sobre
   `~/.config/git/config`. Verificado con git 2.43.

3. **Los mount points se pre-crean en el `Dockerfile`** con el owner de
   `devuser`. Docker crea el directorio de un montaje como `root:root` si no
   existe en la imagen; creándolo antes, el volumen nombrado hereda el
   ownership correcto la primera vez que se monta. `post-create.sh` repite el
   `chown` como red de seguridad y es idempotente.

`post-create.sh` además fusiona una sola vez cualquier `~/.claude.json`,
`~/.gitconfig` o `~/.gitignore_global` que quede fuera del volumen (por ejemplo
el que el IDE copia del host) y deja el original como `.pre-volume`.

## Backup y restauración

`claude-volume.sh` se ejecuta **en el host**:

```bash
./claude-volume.sh info                     # estado: credenciales, nº de transcripciones, tamaño
./claude-volume.sh backup ~/backups         # tarball con timestamp
./claude-volume.sh restore ~/backups/capta-claude-config-20260822-193000.tar.gz

# el mismo script sirve para los otros volúmenes
CLAUDE_VOLUME=capta-git-config ./claude-volume.sh info
CLAUDE_VOLUME=capta-git-config ./claude-volume.sh backup ~/backups
```

El tarball de `capta-claude-config` incluye `.credentials.json`: trátalo como un
secreto.

Borrar el volumen sí destruye los datos (`docker volume rm capta-claude-config`),
y `docker volume prune` se lleva por delante cualquier volumen que no esté en uso
por un container existente. Haz un `backup` antes de limpiar volúmenes.

## Archivos

| Archivo | Para qué |
|---|---|
| `devcontainer.json` | Volúmenes, `CLAUDE_CONFIG_DIR`, `GIT_CONFIG_GLOBAL`, nombre de container, extensiones y settings del IDE |
| `Dockerfile` | Python 3.11 + AWS CLI + Jupyter, `devuser`, Claude Code CLI nativo, pre-creación de mount points y semilla del gitignore global |
| `post-create.sh` | Permisos de los volúmenes, migraciones al volumen, `core.excludesFile`, sanity checks del stack y extensiones |
| `install-extensions.sh` | Instalación de extensiones desde Open VSX (Problemas 3-7 de `AGENTS.md`) |
| `bash-enhancements.sh` | Prompt informativo, historial grande, aliases y completado (Problema 10) |
| `claude-volume.sh` | `info` / `create` / `backup` / `restore` de los volúmenes, desde el host |
| `AGENTS.md` | Guía de diagnóstico y solución de todo el entorno |

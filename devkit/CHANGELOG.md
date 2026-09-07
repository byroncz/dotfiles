# Changelog del template devkit

Una entrada por etiqueta, la más reciente arriba. Semantic Versioning adaptado
(ver `docs/ARCHITECTURE.md`, sección 4.7): PATCH y MINOR son reemplazo directo;
MAJOR exige tocar `devkit.env` o los volúmenes, y la sección "Cambios
requeridos" dice exactamente qué.

`template-update` lee este archivo para explicar al humano qué cambia entre la
versión que usa un proyecto y la destino.

## 0.1.0 - 2026-09-06

Mínimo viable. Un proyecto se instancia en el Mac con Docker y `curl`, trabaja
dentro de un contenedor sin salida directa a internet, gestiona sus tareas en
Notion y cierra cada card con un PR aprobado por un humano y mergeado por
GitHub.

### Imagen y arranque

- Imagen `debian:trixie-slim` sin lenguaje preinstalado. Python lo instala
  `uv` al primer arranque según `.python-version`. Binarios de Neovim, `gh`,
  `rclone`, `bws` y `starship` elegidos por arquitectura, con versiones
  fijadas en el `Dockerfile`. Usuario `dev` sin `sudo`.
- Compose con dos contenedores por proyecto: `dev`, en una red interna sin
  salida, y `proxy` (tinyproxy) como única salida, filtrada por la lista
  blanca de `proxy/allowlist.base` más `DEVKIT_ALLOW_DOMAINS` de `devkit.env`.
  `net-denied.sh` muestra los destinos bloqueados; `devkit net-open` abre la
  red en una sesión para depurar.
- `entrypoint.sh` idempotente, en ocho fases: secretos desde Bitwarden Secrets
  Manager a un `tmpfs`, identidad git, clon del template en la etiqueta
  declarada, clon del proyecto, Python, restauración del sandbox, Claude y
  bucles. Con `DEVKIT_VERSION=dev` el workspace es el propio template y el
  arranque del workspace manda sobre el de la imagen.
- Persistencia en dos volúmenes por proyecto: `claude-<proyecto>` para
  `~/.claude` y `history-<proyecto>` para el historial de shell. Todo lo demás
  se regenera en cada arranque.
- `sandbox.local/` fuera de git y respaldado en Dropbox con `rclone` en una
  sola dirección. El arranque restaura antes de sincronizar y un marcador
  `.restored` impide que un sandbox vacío borre el respaldo.
- Neovim con `kickstart.nvim` y `claudecode.nvim` en un hueco de agente; zsh
  con `starship`; tmux invisible al entrar. `new-project.sh` deja en
  `~/.devkit/<proyecto>/` el template, `compose.yaml`, `.env` y `devkit.env`,
  e instala el comando `devkit` (`up`, `attach`, `stop`, `down`, `recreate`,
  `rebuild`, `logs`, `net-open`, `ls`).

### Notion y las diez skills

- Tres bases de datos bajo "Ingeniería": Proyectos, Tareas y Documentación.
  Sus identificadores y las opciones de cada select viven en
  `agents/notion.json`, enlazado al workspace como `.claude/devkit-notion.json`.
- Plugin oficial de Notion para Claude Code, instalado al arrancar y
  autorizado una vez por proyecto. El retorno OAuth entra por el puerto
  `54545` publicado en `127.0.0.1` del Mac a través del proxy, con `socat` en
  cada salto.
- `AGENTS.template.md` se instancia como `AGENTS.md` del proyecto y
  `CLAUDE.md` lo importa: una sola fuente de instrucciones para Claude Code y
  Codex, con la guía de redacción incluida.
- `agents/settings.json` gobierna los permisos de Claude Code y se
  sobrescribe en cada arranque: niega force push, push a `main`, merges
  inmediatos y lectura de secretos; permite el flujo rutinario de git, `gh` y
  el MCP de Notion, también en modo headless.
- Diez skills en formato Agent Skills, enlazadas en `.claude/skills/`:
  `project-init`, `epic-plan`, `task-create`, `task-start`, `task-review`,
  `task-close`, `task-block`, `session-start`, `template-update` y
  `template-propagate`. Cada una es una transición de la máquina de estados
  Backlog, Lista, En progreso, En revisión, Hecha, Bloqueada. Las cards se
  localizan por `ID` y `Proyecto`, nunca por la fórmula `Clave`.

### Bucles

- `scripts/sync-sandbox.sh`: cada 60 segundos sube `sandbox.local` a Dropbox
  solo si hubo cambios, con `--backup-dir` por fecha para conservar borrados.
- `scripts/watch-merged.sh`: cada cinco minutos busca PRs mergeados cuyo
  título empieza por una Clave del proyecto y lanza `task-close` headless para
  cada uno, una sola vez por contenedor. Ignora la Clave reservada `<CÓDIGO>-0`.

### Protección de `main` y auto-merge

- Configurado en GitHub, fuera del template: PR obligatorio, una aprobación,
  aprobación invalidada por push posterior, sin force push, sin borrado,
  aplicable también al propietario. Auto-merge activo y borrado automático de
  ramas.
- Los agentes trabajan con una cuenta máquina separada. `task-review` arma el
  auto-merge con `gh pr merge --auto`; el merge lo ejecuta GitHub con squash
  tras el approve humano. Un commit por card en `main`.

### Cambios requeridos

Ninguno: es la primera versión. La configuración manual de una sola vez
(Bitwarden, cuenta máquina de GitHub, app de Dropbox, `claude setup-token`,
árbol "Ingeniería" en Notion) está en `docs/ARCHITECTURE.md`, sección 10.3.

### Fuera de esta versión

Codex en el hueco de agente, worktrees para varias cards en paralelo, imagen
preconstruida por etiqueta, cierre por GitHub Actions, firma de commits.
Registrado como DEVKIT-6: `DEVKIT_VERSION` no existe aún como archivo del
repo del proyecto aunque tres skills lo asumen.

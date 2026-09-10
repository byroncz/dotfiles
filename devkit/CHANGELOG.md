# Changelog del template devkit

Una entrada por etiqueta, la más reciente arriba. Semantic Versioning adaptado
(ver `docs/ARCHITECTURE.md`, sección 4.7): PATCH y MINOR son reemplazo directo;
MAJOR exige tocar `devkit.env` o los volúmenes, y la sección "Cambios
requeridos" dice exactamente qué.

`template-update` lee este archivo para explicar al humano qué cambia entre la
versión que usa un proyecto y la destino.

## Sin publicar

### El cierre de cards deja marcador en el PR (DEVKIT-24)

- `task-close` publica al terminar `<!-- devkit-closed sha=<merge commit> -->`
  en el PR, con una línea de texto: el enlace a la entrada de Documentación.
  Es el cuarto marcador de la familia (`devkit-review`, `devkit-fix`,
  `devkit-block`). Si la card ya estaba `Hecha`, el skill igual lo publica
  cuando falta: así un repo que viene de una versión anterior se pone al día
  solo. En esa ruta puede no haber entrada de Documentación; entonces el
  marcador va solo, porque el enlace es cortesía y el sha es el dato que lee
  `watch.sh`. El paso de limpieza local pasa a ser el 7 y el de Épica el 8.
- `watch.sh` omite los PRs mergeados que ya llevan el marcador, además de los
  registrados en `launched`, y lo deja escrito en el log
  (`ya cerrado en <sha>`). Antes, `/run/devkit/launched` era el único freno:
  vive en tmpfs y nace vacío en cada `devkit recreate`, así que el bucle
  relanzaba `task-close` sobre cada PR mergeado en las últimas 48 h aunque su
  card estuviera cerrada. El 2026-09-08 fueron siete ejecuciones inútiles,
  unos 3 USD y veinte minutos de espera.
- `watch.sh --decide-merged` es la entrada de prueba para esa decisión: recibe
  el JSON de `gh pr view <N> --json comments` e imprime `cerrar -` o
  `cerrada <sha>`. `watch-test.sh` suma ocho casos para la rama de cierre.
  Los dos lados exigen el mismo patrón con sha hexadecimal, así que un
  marcador malformado no da el PR por cerrado: `task-close` lo republica.
- Cambios requeridos: los PRs ya mergeados y cerrados de un repo existente no
  llevan marcador. Para que el próximo `recreate` no los reprocese, se les
  pone una vez con el comando del README (sección "Cierre de PRs").

### Las ejecuciones headless no terminan preguntando (DEVKIT-17)

- `task-start` gana una sección "Modo headless": tras comentar el plan
  implementa la card hasta cumplir los criterios y ejecuta `task-review`; si
  falta algo, `task-block`. Antes, invocada desde `task-close` con `claude -p`,
  creaba la rama y preguntaba si seguía: nadie respondía y la card quedaba en
  `En progreso` sin proceso.
- `task-close`, paso 7: la siguiente hija se trabaja completa en la misma
  ejecución, no solo se arranca.
- `AGENTS.template.md` generaliza la regla: en `claude -p`, una pregunta al
  humano equivale a `task-block`.
- `watch.sh` registra al terminar cada `claude -p` una línea `estado:` con la
  rama, sus commits sobre `main` y su PR, para que un corte se vea en el log
  sin abrir Notion.

### `slugify.sh`: script de prueba punta a punta (DEVKIT-25)

- `devkit/scripts/slugify.sh` convierte un texto libre en un slug de
  minúsculas separado por guiones, el formato que usan las ramas de las
  cards. `--test` corre su tabla de autoprueba.

### La sesión interactiva no toca código fuera del flujo de cards (DEVKIT-15)

- `AGENTS.template.md` suma la regla: sin una card en `En progreso` sobre la
  rama actual, la sesión no edita archivos de código. Puede crear cards,
  comentar, revisar con `pr-review` y escribir Documentación. Excepción:
  autorización expresa del humano en la conversación. El porqué está en
  `docs/ARCHITECTURE.md`, sección 6.2.

### `devkit.toml` como única fuente del entorno (DEVKIT-6)

- `devkit.toml`, plano y en la raíz del repo, reemplaza a `DEVKIT_VERSION`,
  `.python-version` y el placeholder `{{CODE}}` de `AGENTS.md` como fuente de
  la versión del template, el código de Notion, la versión de Python, los
  paquetes apt y los dominios extra del proxy.
- `entrypoint.sh` lo crea con placeholders si el repo no lo tiene, exporta
  `UV_PYTHON` desde su clave `python` y avisa si el repo pide un `template`
  distinto al de la imagen. `devkit.sh` gana `devkit update <proyecto>` y
  sincroniza `apt`/`domains` hacia el `.env` del Mac antes de `recreate` o
  `rebuild`.

### Revisor independiente de PRs (DEVKIT-12)

- Skill `pr-review <número de PR>`: comprueba cada criterio de aceptación
  de la card ejecutando algo, lee el diff de forma adversarial y publica el
  informe en el PR con el marcador
  `<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->`. Con `OK` mueve
  la card a `Lista para merge` y pide review al dueño del repo; con
  `CAMBIOS` deja un bloque `devkit-findings` con una línea por hallazgo para
  `task-fix`.
- `settings.json` permite `gh pr review --comment`, `gh pr edit` y
  `git worktree`; la negación de `gh pr review` se reduce a `--approve`. La
  compuerta real contra aprobar sigue siendo GitHub (ver
  `docs/ARCHITECTURE.md`, 12b).
- `devkit.toml` admite la clave opcional `reviewer`: usuario de GitHub al
  que `pr-review` pide el review. Sin ella, vale el dueño del repo si es un
  usuario y no una organización.

### Corrector de PRs (DEVKIT-13)

- Skill `task-fix <Clave> [texto]`: lee el bloque `devkit-findings` del
  último informe de `pr-review` con veredicto `CAMBIOS`, o el comentario del
  humano sobre una card en `Lista para merge`, y atiende cada hallazgo con
  un commit en la rama de la card. Responde en el PR con el bloque
  `devkit-fixes` (`id | atendido o descartado | commit o motivo`) y deja la
  card en `Revisión automática`. Trabaja en un `git worktree` aparte cuando
  la sesión interactiva está en otra rama. Sin permisos nuevos en
  `settings.json`: `gh pr comment`, `git worktree` y el push a ramas
  `feat/`, `fix/` y `chore/` ya estaban permitidos.

### Bucle de revisión automática (DEVKIT-14)

- `scripts/watch-merged.sh` pasa a ser `scripts/watch.sh` y orquesta el ciclo
  completo. Cada cinco minutos, por cada PR cuyo título empieza por una Clave
  del proyecto: head sin marcador `devkit-review` → `pr-review`; último
  marcador `CAMBIOS` para el head sin respuesta `devkit-fix` → `task-fix`;
  último marcador `OK` y comentario humano posterior → `task-fix` con ese
  texto; PR mergeado → `task-close`, como antes.
- Guardia: tras tres informes `CAMBIOS` sin `OK` para el mismo PR, publica
  el marcador `<!-- devkit-block sha=<head> -->` en el PR, lanza `task-block`
  y no toca ese PR hasta que el humano mueva la card a `Revisión automática`
  y comente en el PR. El conteo se lee de los marcadores del PR, no de un
  archivo del contenedor; el bloqueo lo reinicia. La respuesta `devkit-fix`
  del corrector a ese comentario levanta el bloqueo y el head nuevo vuelve
  a revisarse.
- `scripts/watch-test.sh` prueba la tabla de decisión con PRs sintéticos
  (vacío, `CAMBIOS` con y sin respuesta, comentario humano, tres ciclos,
  bloqueo y reanudación) y sale con 1 si un caso falla.
- Cada skill headless deja su log en `/run/devkit/<skill>-<N>.log` con el
  costo y los tokens de la ejecución en la última línea (`claude -p
  --output-format json`). Variables: `DEVKIT_WATCH_INTERVAL` (300 s) y
  `DEVKIT_WATCH_MAX_CYCLES` (3). `bash watch.sh --decide < pr.json` imprime
  la decisión para un PR sin esperar al bucle.

### Cambios requeridos

Proyectos en `0.1.0`: al actualizar, dentro del contenedor,

- el bucle nuevo llega con la imagen: `devkit update` (o `devkit rebuild`)
  tras subir `template`;

- crear `devkit.toml` en la raíz del repo con `template` y `project` (el
  código de Notion que antes estaba en `AGENTS.md`); commit y push;
- borrar `.python-version` si existe, y declarar esa versión en `devkit.toml`
  (clave `python`);
- en `~/.devkit/<proyecto>/devkit.env`, en el Mac, borrar
  `DEVKIT_PROJECT_CODE`, `DEVKIT_EXTRA_APT` y `DEVKIT_ALLOW_DOMAINS` si están
  presentes: ya no los lee nada. Si el proyecto usaba paquetes apt o dominios
  extra, declararlos en `devkit.toml` (`apt`, `domains`) y correr
  `devkit rebuild`.

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

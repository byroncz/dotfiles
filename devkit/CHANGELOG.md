# Changelog del template devkit

Una entrada por etiqueta, la más reciente arriba. Semantic Versioning adaptado
(ver `docs/ARCHITECTURE.md`, sección 4.7): PATCH y MINOR son reemplazo directo;
MAJOR exige tocar `devkit.env` o los volúmenes, y la sección "Cambios
requeridos" dice exactamente qué.

`template-update` lee este archivo para explicar al humano qué cambia entre la
versión que usa un proyecto y la destino.

## Sin publicar

### Neovim se ve bien en cualquier terminal, sin Nerd Font (DEVKIT-31)

- El explorador, el menú de `<espacio>` y el autocompletado dibujaban cuadros
  con un signo de interrogación: pedían glifos de Nerd Font y Terminal.app
  pinta con la fuente del Mac, que no los tiene. `vim.g.have_nerd_font = false`
  no bastaba, porque cada plugin trae su propia tabla de iconos.
- `devkit/nvim/init.lua` fija en texto los iconos de `snacks.picker`,
  `which-key`, `blink.cmp`, `fidget`, `gitsigns`, los diagnósticos y
  `listchars`: `+` y `-` para carpetas, `M`/`A`/`?` para git, `E`/`W`/`I`/`H`
  para diagnósticos, el nombre del tipo en el autocompletado. Se mantiene el
  dibujo de cajas de bordes y árbol, que Menlo sí trae.
- Dos pruebas nuevas en `devkit/nvim/tests/`, con su `README.md`. No se añadió
  ningún plugin y `nvim-pack-lock.json` no cambia.
- El cambio entra por el `Dockerfile`: se activa al reconstruir la imagen.

### En modo dev la imagen se construye desde el workspace (DEVKIT-30)

- El contexto de build es `~/.devkit/<proyecto>/template/`, una copia del
  template que solo `new-project.sh` y `devkit update` refrescaban. En modo dev
  no hay etiqueta que bajar, así que nadie la tocaba: `devkit recreate`
  reconstruía con el template del día de la instalación. DEVKIT-21 y DEVKIT-23
  se mergearon, el humano recreó y ninguna quedó activa, porque la imagen se
  armó con el `nvim/init.lua` viejo. Verificado el 2026-09-11.
- Ahora `devkit up`, `recreate` y `rebuild` rearman ese contexto con
  `docker cp devkit-<proyecto>:/workspace/devkit/. template/` antes de
  construir, y lo dicen en una línea. Montar el workspace como contexto no era
  opción: `/workspace` vive dentro del contenedor y no hay bind mount desde el
  Mac, así que no existe ruta del host que Compose pueda usar.
- Si el contenedor no responde (primer `up`, contenedor destruido), se avisa y
  se construye con la copia que haya, sin fallar: sin contenedor no hay
  workspace del que copiar, y abortar dejaría al humano sin poder levantar
  nada.
- Fuera de modo dev el comportamiento no cambia: el contexto sigue siendo la
  copia de la etiqueta, que es lo que hace reproducible una versión.
- `devkit update` en modo dev ya no responde "ya en dev", que sonaba a que no
  faltaba nada: manda a `devkit recreate <proyecto>`, que es quien lleva
  `devkit/` a la imagen.
- El arranque avisa de la deriva. El `Dockerfile` deja en `/opt/devkit/image`
  la copia de lo que solo entra por imagen (`Dockerfile`, `nvim/`, `tmux/`,
  `zsh/`, `proxy/`) y `entrypoint.sh` la compara con el workspace en modo dev:
  `hay cambios que requieren devkit recreate: <qué>`. Lo que el arranque relee
  del workspace (`entrypoint.sh`, `scripts/`, `agents/`) no cuenta, para que el
  aviso no sea ruido en cada sesión.
- `scripts/image-drift.sh` es esa comparación, con la lista de rutas de imagen
  como única fuente y autoprueba en `--test`. `host/devkit-test.sh` prueba el
  comando `devkit` del Mac contra un doble de `docker`, sin Docker ni
  contenedores: 27 casos que cubren modo dev, versión etiquetada, contenedor
  caído y los avisos.
- `recreate` avisa además cuando el `compose.yaml` del proyecto o el comando
  `~/.devkit/bin/devkit` difieren del template. Esos dos son del Mac y los
  instala `new-project.sh`; reemplazarlos desde el propio script no es seguro,
  así que se avisa y se reinstalan con `new-project.sh <proyecto> --ref <rama>`.
- Reemplazo directo: nada que tocar en `devkit.env` ni en los volúmenes. El
  aviso del arranque solo aparece tras el primer `devkit recreate` con esta
  versión, que es cuando `/opt/devkit/image` existe.

### El bucle relanza la skill que murió por cuota agotada (DEVKIT-27)

- Un `claude -p` que agota la cuota de la suscripción muere con código distinto
  de cero y deja la card `En progreso` sin nadie trabajándola. El agente no
  puede arreglarlo: sin cuota no habla con el modelo y ninguna skill corre,
  `task-block` incluida. Ahora reacciona `watch.sh`, que es bash y sobrevive.
- `run_skill` reconoce el fallo por el código de salida más el aviso del límite
  en el log de la skill, saca de ahí la hora de reinicio y deja dos líneas en
  `watch.log`: `cuota agotada: <skill> en pausa hasta <hora UTC>` y
  `cuota reanudada: relanzando <skill>`. Relanza con el mismo prompt y los
  mismos flags; las skills ya eran reanudables.
- La hora sale del `Claude AI usage limit reached|<epoch>` que publica Claude
  Code, o de la hora del texto para el humano ("resets 3pm
  (America/Los_Angeles)", "resets Feb 3 at 10am"). Si no hay ninguna, espera lo
  que diga `DEVKIT_WATCH_QUOTA_WAIT` (30 min) y lo dice en el log.
- La espera corre en segundo plano: el bucle sigue atendiendo otros PRs. Un
  solo relanzamiento en curso por skill y PR, y como mucho
  `DEVKIT_WATCH_QUOTA_RETRIES` (3) intentos. La entrada de `launched` se
  reescribe como `cuota:<clave>` mientras dura la pausa, para que el bucle no
  lance una segunda copia, y vuelve a su forma justo antes del relanzamiento.
- `run_skill` toma un candado: un solo `claude -p` a la vez sobre el workspace.
  Sin él, un relanzamiento que despierta mientras el bucle atiende otro PR
  pondría dos agentes a cambiar de rama en el mismo repo.
- No se toca Notion ni se comenta en el PR. `Bloqueada` significa "necesita al
  humano" y aquí solo falta tiempo; y una card puede morir antes de tener PR,
  así que el PR no sirve de canal para todas. Decisión del humano del
  2026-09-11; el aviso llegará cuando exista un canal que no dependa del PR.
- Variables nuevas: `DEVKIT_WATCH_QUOTA_RETRIES`, `DEVKIT_WATCH_QUOTA_WAIT`,
  `DEVKIT_WATCH_QUOTA_MIN_WAIT` y `DEVKIT_WATCH_QUOTA_MAX_WAIT`. Reemplazo
  directo: nada que tocar en `devkit.env` ni en los volúmenes.
- `watch-test.sh` prueba todo esto sin gastar cuota, con los hooks nuevos
  `--quota-hit`, `--quota-reset` y `--run-skill` de `watch.sh`: avisos de
  límite de mentira y un doble de `claude` que muere por cuota la primera vez.

### Dos skills se renombran para que el nombre diga lo que hacen (DEVKIT-10)

- Cambio de nombre, sin cambio de comportamiento. Mapa viejo → nuevo:
  `session-start` → `project-status`, `task-review` → `task-submit`. Los pasos
  de cada skill son los mismos.
- `session-start` no era solo del inicio de sesión: reconcilia Notion con
  GitHub y resume el estado del proyecto, y sirve en cualquier momento.
  `project-status` lo dice.
- `task-review` no revisa nada: verifica, sube la rama, abre el PR y pasa la
  card a `Revisión automática`. Es el autor entregando. El nombre hacía creer
  que el autor se revisaba a sí mismo, confusión observada el 2026-09-11 con
  DEVKIT-26. Quien revisa sigue siendo `pr-review`, en otro proceso, sin la
  conversación del autor. `task-submit` separa entregar de revisar.
- Invocarlas por el nombre viejo ya no funciona: `/project-status` y
  `/task-submit` son los nombres nuevos en Claude Code y en `claude -p`.
  Ninguna skill, script ni documento vigente conserva el nombre viejo; las
  entradas de 0.1.0 de este changelog se dejan como están porque son historia.
- Regla nueva en `devkit/agents/skills/README.md` y en `AGENTS.template.md`:
  una skill se edita por su ruta real `devkit/agents/skills/<skill>/SKILL.md`,
  nunca por `.claude/skills/`, que es un enlace al template. Claude Code no
  escribe bajo `.claude/` sin confirmación del humano, y en headless nadie la
  da: la ejecución se detiene a medias, como pasó en la primera de DEVKIT-26.

### El bucle despierta al instante cuando una skill deja trabajo nuevo (DEVKIT-26)

- `watch.sh` ya no duerme el intervalo de un tirón: lo hace en tramos de cinco
  segundos y sale antes si existe `/run/devkit/poke`, que borra al despertar,
  antes de consultar GitHub, para no perder un aviso llegado durante la
  consulta.
- `task-submit` (tras abrir el PR) y `task-fix` (tras responder en el PR) crean
  ese archivo con `touch /run/devkit/poke` como último paso, sin redirecciones
  ni `|| true` para que la regla exacta de `settings.json` lo cubra. Si no se
  puede crear, no se reintenta: el bucle llega igual en el siguiente intervalo.
- El ciclo revisar → corregir → revisar encadena en segundos. Antes cada salto
  costaba hasta cinco minutos muertos; medido el 2026-09-10 en el PR 15, unos
  veinte minutos por card sin nadie trabajando.
- El aviso no decide nada ni salta la guarda de `launched`: la decisión sigue
  saliendo de los marcadores del PR, así que `--decide` responde lo mismo que
  antes y `watch-test.sh` no cambia. El revisor sigue siendo independiente del
  autor.
- `settings.json` permite `Bash(touch /run/devkit/poke)`, sin abrir el resto de
  `/run/devkit`, que sigue en `deny` para lectura.
- Nueva línea del log, `consultando GitHub`, que marca el inicio de cada vuelta
  y hace visible el efecto del aviso.

### Explorador de archivos en Neovim y qué esperar del diff del agente (DEVKIT-23)

- `<espacio>e` abre el árbol del workspace en un panel a la izquierda, con el
  estado de git por archivo. Es `snacks.explorer`, que ya venía dentro de
  `snacks.nvim` porque `claudecode.nvim` lo usa de proveedor de terminal: no
  entra ningún plugin y `nvim-pack-lock.json` no cambia.
- El árbol se actualiza solo cuando el agente crea, borra o renombra archivos.
  No hace falta cerrar y abrir el panel: el explorador levanta un
  `vim.uv.fs_event` por cada directorio abierto y otro sobre `.git`, así que
  también repinta la marca de git en cuanto cambia el índice.
- Un clic abre el archivo bajo el ratón; expandir y plegar carpetas se queda en
  el doble clic. Un clic que alternara la carpeta la volvería a cerrar con el
  segundo clic de un doble clic, que es justo lo que hace quien viene de Finder.
- `.git` queda excluido del árbol aunque se enciendan los archivos ocultos con
  `H`.
- `snacks.explorer` reemplaza a `netrw`: `:Ex` y abrir un directorio caen ahora
  en el mismo panel.
- Nuevo en el README: "Neovim en cinco atajos", la guía mínima para moverse por
  el proyecto (explorador, buscar archivo, buscar texto, cambiar de panel, salir
  del panel de Claude).
- `docs/ARCHITECTURE.md` 4.4 explica, medido, cuándo una edición de Claude llega
  como diff para aceptar con `<espacio>aa` y cuándo aparece ya escrita en disco.
  Resumen: solo hay diff si abriste Claude desde Neovim con `<espacio>ac` y lo
  dejaste en modo manual. Desde el shell, con `accept edits on`, o en el ciclo
  automático (`claude -p`, que ni se conecta a Neovim), la edición va directa al
  disco. Forzar el diff siempre no es posible: `claudecode.nvim` solo atiende el
  `openDiff` que pide el CLI, y sus `diff_opts` deciden cómo se ve, no si
  aparece.

### Neovim relee los archivos que cambian en disco (DEVKIT-21)

- `devkit/nvim/init.lua` ejecuta `checktime` en `CursorHold`, `CursorHoldI`,
  `FocusGained`, `BufEnter` y `TermLeave`, saltándose solo la línea de
  comandos. `autoread` ya venía activo, pero Neovim solo compara la marca de
  tiempo del archivo cuando algo dispara la comprobación, y dentro de tmux en
  Terminal.app casi ningún evento de foco llega: mientras el agente editaba,
  el buffer seguía mostrando la versión vieja hasta que el humano escribía
  `:e`.
- No se filtra por `buftype`. Sería tentador saltarse los buffers sin archivo
  detrás (el terminal de Claude, los paneles de los plugins), pero `checktime`
  sin argumentos revisa todos los buffers: filtrar por el buffer con el foco
  apagaría la recarga justo en el caso que motiva la card, mirar el panel de
  `claudecode.nvim` mientras el agente edita el archivo abierto al lado.
- Un timer de `vim.uv` repite la comprobación cada segundo. `CursorHold`
  dispara una sola vez tras cada pulsación, no cada `updatetime`, así que por
  sí solo deja fuera el caso más común: mirar el panel del agente sin tocar el
  teclado. Medido con el archivo abierto y en reposo, sin el timer el buffer
  no se actualiza nunca; con él, en menos de dos segundos.
- `updatetime` pasa de 250 a 1000 ms. Deja de ser solo el retardo de gitsigns
  y del resaltado del LSP: ahora es también cada cuánto se consulta el disco.
  Un segundo se percibe igual de inmediato y evita cuatro `stat()` por segundo
  sobre un volumen montado desde el Mac, donde esa llamada cuesta bastante más
  que en disco local.
- Los cambios que Claude propone por la integración (`openDiff`) no cambian:
  siguen llegando como diff para aceptar con `espacio a a`. Esto cubre las
  ediciones que el agente escribe directo en disco.

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
  implementa la card hasta cumplir los criterios y ejecuta `task-submit`; si
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

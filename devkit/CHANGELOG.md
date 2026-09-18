# Changelog del template devkit

Una entrada por etiqueta, la más reciente arriba. Semantic Versioning adaptado
(ver `docs/ARCHITECTURE.md`, sección 4.7): PATCH y MINOR son reemplazo directo;
MAJOR exige tocar `devkit.env` o los volúmenes, y la sección "Cambios
requeridos" dice exactamente qué.

`template-update` lee este archivo para explicar al humano qué cambia entre la
versión que usa un proyecto y la destino.

## Sin publicar

- `docs/ARCHITECTURE.md`: el riesgo residual de credenciales del humano en
  memoria del extension host queda también en la tabla de la sección 12, no
  solo declarado en 8.2 (DEVKIT-74).

### devkit-run --estado agrupa por Épica de origen cuando hay más de una En progreso (DEVKIT-80)

- `notion.sh epicas <código>`: por cada Épica `En progreso` del proyecto, una
  entrada de sí misma, y por cada Tarea que no está `Hecha` con esa Épica
  como `Padre`, su Clave y título. Una sola consulta, con las dos ramas de
  `Estado` repitiendo el filtro de Proyecto para no anidar tres niveles: la
  API de Notion solo acepta dos.
- `devkit-run --estado` agrupa la tabla con un encabezado `Épica <Clave>:
  <Título>` por cada Épica `En progreso` representada entre las filas (en el
  orden en que aparecen), y un bloque final `(sin Épica)` para las filas sin
  Padre activo, sin Clave resuelta, o cuya card ya está `Hecha` aunque su
  Épica siga activa. Con una sola Épica, o ninguna, la tabla sigue plana.
  Caché de 30 s (`DEVKIT_EPICAS_CACHE`/`DEVKIT_EPICAS_TTL`), refrescada en
  segundo plano igual que `bloqueos`: nunca bloquea la lectura de
  `--estado`.
- Motivo: la Ampliación 1 de DEVKIT-63 pedía esta agrupación y quedó
  "pendiente" en este changelog, sección "Sin publicar", sin card que lo
  registrara (hallazgo H2 de `pr-review` sobre el PR #53).

### ps -ww en todo lanzamiento, lanzamiento duplicado rechazado y confirmar_arranque elige al descendiente correcto (DEVKIT-79)

- Todo `ps` que lee argumentos en `devkit-run.sh` y `watch.sh` pide ancho
  ilimitado con `-ww`: sin ella, una terminal integrada (la del editor)
  exporta `COLUMNS`/`LINES` y `ps` corta cada línea a ese ancho aunque la
  salida vaya a una tubería, dejando la ruta del log fuera de la línea.
- `devkit-run <skill> <Clave>` no lanza si ya hay un worker o un `claude -p`
  de ese mismo prompt vivo o esperando el candado: imprime
  `ya hay un lanzamiento de "<prompt>" en curso (pid <n>, log <ruta>);
  síguelo con devkit-run --estado` y sale con 68. `devkit-run --forzar
  <skill> <Clave>` salta la comprobación.
- `confirmar_arranque` identifica el `claude -p` del worker recién lanzado
  por descendencia (hijo, nieto, ...) de su PID, no por el primer proceso
  del sistema cuyo prompt coincida: con dos lanzamientos vivos del mismo
  prompt, ese primero podía ser el de un lanzamiento anterior.
- Motivo: el 2026-09-17, tres lanzamientos distintos mostraron `--estado`
  "no arrancó" con el agente en realidad vivo. La causa era `ps` recortando
  la línea a `COLUMNS` (60-100 en la terminal integrada del editor) antes de
  llegar a la ruta del log; el humano relanzó la card sin saber que la
  anterior seguía corriendo, y la reanudación quedó esperando el candado
  detrás de la primera.

### task-start no confunde su propio claude -p con otro agente, y la barrera de pregunta abierta detecta preguntas con opciones (DEVKIT-77)

- `devkit-run --otros-agentes` imprime, antes de la lista de ajenos, una
  línea `propio: <pid> claude -p "<prompt>"` cuando corre dentro de un
  agente: el proceso que un `ps` propio ve con `PPID` 1 (el `nohup` de quien
  lo lanzó), no un segundo agente. La skill `task-start` ya no corre su
  propio `ps`/`pgrep` para desconfiar de `--otros-agentes` ni interpreta ese
  proceso como ajeno.
- `pregunta_abierta` (la barrera de `devkit-run.sh` que fuerza un
  `task-block.sh` cuando el `result` es una pregunta sin contestar) ya no
  solo mira si el texto entero termina en "?" (DEVKIT-50): también reconoce,
  en el último párrafo, una línea que empieza por "¿", "Opciones:" seguida
  de líneas numeradas, y las frases fijas "¿Cómo quieres que siga"/"¿Qué
  prefieres".
- Un `task-start` que "terminó" sin pregunta abierta ni bloqueo, pero dejó su
  card `En progreso` sin PR, deja `ALARMA: terminó sin entregar ni bloquear`
  en `watch.log` y `devkit-run --estado` lo muestra como `error`, no como
  `terminó`.
- `devkit-run --pregunta-abierta <resultado>` expone la misma
  `pregunta_abierta` de arriba como subcomando puro, igual que `--resumen`/
  `--rol`. `watch.sh` lo usa en el camino `--sync` (el que lanza `pr-review`,
  `task-fix` y `task-document`), que se había quedado con el `grep` viejo de
  DEVKIT-50: solo `--worker` veía las formas nuevas.
- Motivo: el 2026-09-17, un `task-start DEVKIT-63` lanzado por `task-close`
  encontró su propio `claude -p` en `ps` (PPID 1, efecto del `nohup` de su
  lanzador), desconfió del resultado ya correcto de `--otros-agentes` y
  terminó preguntando "¿Cómo quieres que siga? Opciones: 1. [...] 2. [...]
  3. [...] antes de decidir.", que no termina en "?": la barrera de
  DEVKIT-50 no lo vio, la card quedó `En progreso` con una rama vacía y sin
  plan comentado, y el humano lo descubrió por `--estado` mostrando
  `terminó`.

### Hora local del Mac en todo el contenedor (DEVKIT-64)

- `devkit/host/devkit.sh` detecta la zona horaria del Mac con `readlink
  /etc/localtime` (macOS la enlaza a `/var/db/timezone/zoneinfo/<Zona>`), la
  escribe como `DEVKIT_TZ` en `~/.devkit/<proyecto>/.env` en `up`,
  `recreate`, `rebuild` y `update`, y `devkit/compose.yaml` la pasa al
  contenedor `dev` como `TZ` (`${DEVKIT_TZ:-UTC}`). Sin zona detectable: UTC
  y un aviso en la consola del Mac; el comando no se detiene por esto.
- `devkit/Dockerfile` instala `tzdata`, la base de zonas que `TZ` necesita
  para resolver un nombre como `America/Bogota` (un offset fijo no la
  necesita, pero un nombre sí).
- `watch.sh`, `devkit-run.sh`, `task-close.sh`, `task-block.sh`,
  `sync-sandbox.sh`, `entrypoint.sh` y `pr-guard.sh` dejan de escribir marcas
  legibles con `date -u +%FT%TZ` y escriben `date +%FT%T%:z`: la hora del Mac,
  con desplazamiento. Ninguna línea nueva de `watch.log` termina en `Z`. Las
  comparaciones por hora (`launched`, ventana de PRs mergeados, hora de
  reinicio de cuota) siguen en epoch (`date +%s`, `date -d "<marca>" +%s`),
  que interpreta igual una marca vieja en `Z` y una nueva con desplazamiento.
  `dropbox-setup.sh` queda igual: su `expiry` lo parsea `rclone` como token
  OAuth, no es una marca que lea un humano.
- `docs/ARCHITECTURE.md` (4.8 y 6.3) y el README dicen qué queda en hora
  local y qué sigue en UTC (`mergedAt`, `submittedAt` y `createdAt` de
  GitHub; `Creado` y `Cierre` de Notion).
- Cambios requeridos: `devkit recreate` (el `Dockerfile` con `tzdata` entra
  por imagen) y reinstalar el comando del Mac y `compose.yaml`
  (`new-project.sh <proyecto> --ref <rama>` o copiar
  `template/host/devkit.sh` y `template/compose.yaml`), para que `devkit up`
  vuelva a escribir `DEVKIT_TZ`.

### Prompt de una línea, y `task-close.sh` deja de callar al limpiar (DEVKIT-63)

- `devkit/zsh/starship.toml` deja el preset de símbolos de texto plano por un
  único módulo `custom` que corre `devkit/scripts/prompt-status.sh`:
  `<proyecto>:<template> <rama> ±<cambios> ↑<commits> agentes:<a> !<alarmas>
  >`, con "arrancando" mientras no existe `/run/devkit/ready`. Rama corta
  (`feat/DEVKIT-57`, sin el slug) con color por prefijo. Sin red; medido bajo
  50 ms por módulo con `starship timings` (ver `docs/ARCHITECTURE.md` 4.4
  para el porqué de cada decisión: `when = "true"`, `shell` sin `-c`
  explícito, `style = ""`).
- `devkit-run --agentes`: el mismo conteo que las filas `en curso` de
  `--estado`, en una sola pasada del log con bash puro en vez del fork por
  fila de `estado_filas` (baja de ~90 ms a menos de 20 ms). `--estado` deja
  además un marcador de qué tanto de `watch.log` ya se mostró, para que el
  segmento `!<k>` del prompt cuente solo las `ALARMA:` nuevas.
- `task-close.sh` diagnosticado: la "Limpieza local" tomaba el mismo
  `skill.lock` que un `task-start` corriendo la siguiente hija, y con el
  candado ocupado `flock -n` fallaba sin dejar rastro; así quedó el
  workspace en una rama ya mergeada tras DEVKIT-58. Ahora ese caso, el árbol
  sucio y un `git switch`/`pull` fallido dejan `task-close.sh <Clave> no
  limpia el workspace: <motivo>` en `watch.log`. `devkit-run` también avisa
  cuando el workspace queda detrás de `origin/main` al lanzar, antes de
  resolver el modelo: hace `git fetch origin main` primero, porque sin ese
  fetch la comparación usaba la referencia local vieja de `origin/main` y no
  veía un avance reciente del remoto (hallazgo de `pr-review`, PR #53).
- Ampliación de la card: `devkit-run --estado` suma "bloquea a: <Claves>" a
  la fila de una card en `Lista para merge`, con las cards en `Lista` que la
  tienen en `Depende de` (`notion.sh bloqueos`, una consulta por refresco,
  cacheada 30 s). Agrupar la tabla por Épica de origen cuando hay más de una
  Épica `En progreso` sale en DEVKIT-80, más arriba en esta misma sección.
- `±n` cuenta ahora con `git status --porcelain --untracked-files=all`: antes
  un directorio nuevo sin seguimiento con varios archivos salía como una sola
  línea y `±n` los subcontaba (hallazgo de `pr-review`, PR #53).
- Cambios requeridos: `devkit recreate` (el `starship.toml` nuevo entra por
  imagen).

### `devkit-run --estado` muestra la cuota del plan en vivo (DEVKIT-62)

- Compuerta antes de programar: con la CLI instalada (`claude --version`
  2.1.274), `claude -p "/usage" --output-format json` sí trae, en el campo
  `result`, el mismo texto que `/usage` en una sesión interactiva —
  porcentaje de sesión y de semana—, como comando local que no gasta turnos
  ni cuota (`duration_api_ms=0`). No hay campo numérico estructurado.
- `devkit-run --estado` (y `--estado --seguir`) agrega un bloque `Consumo`
  con el porcentaje de sesión y de semana, la hora en que reinician y la hora
  de la lectura: cifra oficial, no una estimación desde `watch.log`. Se lee
  aislado (directorio vacío, sin MCP), con `--no-session-persistence` (no
  deja sesión propia en `~/.claude/projects/`) y con timeout
  (`DEVKIT_CUOTA_TIMEOUT`, 20 s); si la CLI no responde o cambia ese texto,
  el bloque lo dice en vez de romper el resto de `--estado`.
- La lectura tarda ~1.3 s, y `--estado` nunca la espera en línea: la cachea en
  `$RUN_DIR/cuota.cache` con su hora y la refresca en segundo plano cuando
  vence `DEVKIT_CUOTA_TTL` (60 s) o no hay ninguna todavía (revisión de
  pr-review: la primera versión sí esperaba, y `--estado` pasaba de 0.2 s a
  1.4–2.2 s con un `watch.log` de mil líneas).
- El refresco en segundo plano cierra su entrada y salida
  (`</dev/null >/dev/null 2>&1`): la primera versión las heredaba del
  llamador, así que leer `--estado` por un pipe o `$(...)` seguía atado a la
  lectura, hasta `DEVKIT_CUOTA_TIMEOUT` (revisión de pr-review, segundo
  ciclo).
- Cambios requeridos: ninguno, `devkit recreate` alcanza.

### `resolve_extensions` comprueba el motor del editor antes de construir (DEVKIT-73)

- Cada extensión de `devkit/vscode/extensions.toml` (fija o `"latest"`) se
  comprueba contra `engines.vscode` en Open VSX frente a `ARG
  OPENVSCODE_VERSION` del `Dockerfile` (única fuente, `resolve_extensions` la
  lee de ahí). Antes de esta card, una versión incompatible tumbaba el build
  a mitad del `Dockerfile`, con el error de `openvscode-server
  --install-extension`, no antes: así falló DEVKIT-68 la primera vez, con
  `GitHub.vscode-pull-request-github` resolviendo 0.166.0 (exige
  `^1.137.0`) contra un editor 1.109.5.
- Si `latest` no calza, se recorre `allVersions` de Open VSX (de la más nueva
  a la más vieja) y se usa la primera versión compatible, con aviso. Si una
  versión fija no calza, el comando se detiene con el rango exigido y una
  sugerencia de cuál sí calza. Un rango de `engines.vscode` que no sea
  `^X.Y.Z` o `>=X.Y.Z` se acepta con aviso, no se rechaza.
- `curl` hacia Open VSX (en `devkit.sh` y en las descargas de `.vsix` del
  `Dockerfile`) reintenta un 5xx (`--retry 5 --retry-delay 3`) antes de
  rendirse: un segundo `devkit recreate` de DEVKIT-68 se topó con Open VSX
  devolviendo 503 intermitentes toda una tarde y el build murió a medias.
  Un 404 del paquete por plataforma (esperado, no todas las extensiones lo
  publican) sigue cayendo al universal sin reintentar.
- Medición del 2026-09-17: la última release estable de
  `gitpod-io/openvscode-server` es la 1.109.5, la misma que ya trae la
  imagen; no existe todavía una que satisfaga `^1.137.0` (lo que exige el
  `latest` de `GitHub.vscode-pull-request-github`). DEVKIT-75 (Backlog) sube
  el editor en el `Dockerfile` cuando eso cambie.
- Cambios requeridos: ninguno, `devkit recreate` alcanza.

### Extensión GitHub Pull Requests en el editor, con compuerta de login (DEVKIT-68)

- `devkit/vscode/extensions.toml` suma `"GitHub.vscode-pull-request-github" =
  "0.128.0"`: deja revisar, comentar y aprobar PRs desde el editor sin
  cambiar de pestaña. Versión fija, sin `"latest"`: la 0.166.0 que resuelve
  Open VSX hoy exige VS Code `^1.137.0` y la imagen trae openvscode-server
  1.109.5; 0.128.0 es la más nueva compatible con `^1.109.0`. Subir el
  editor para usar una versión más nueva queda para otra card.
- Compuerta verificada por el humano el 2026-09-17: el login por el
  proveedor de autenticación de GitHub de VS Code cierra al primer intento
  contra `127.0.0.1:3000`; el token no queda en claro en el disco del
  contenedor, pero sí en la memoria del extension host mientras la sesión
  está abierta, legible por cualquier otro proceso `dev` del contenedor:
  riesgo residual aceptado, no corregido en esta card. `github.com` y
  `api.github.com` ya estaban en la lista blanca, sin dominios nuevos.
  Detalle de amenaza y mitigación en `docs/ARCHITECTURE.md` 8.2.
- Cambios requeridos: ninguno, `devkit recreate` alcanza.

### Extensiones del editor versionadas en `extensions.toml` y resueltas contra Open VSX (DEVKIT-67)

- `devkit/vscode/extensions.toml` reemplaza el `ARG CLAUDE_CODE_EXT_VERSION`
  del `Dockerfile`: una línea por extensión, versión fija o `"latest"`. Nace
  con `"Anthropic.claude-code" = "latest"`.
- `devkit.sh` suma `resolve_extensions`, enganchada en `up`, `recreate`,
  `rebuild` y `update`: resuelve cada `"latest"` en el Mac contra la API de
  Open VSX, guarda la resolución en `~/.devkit/<proyecto>/extensions.lock` y
  la pasa al build como `DEVKIT_EXTENSIONS` (mismo mecanismo que
  `DEVKIT_EXTRA_APT`, vía `.env` y `compose.yaml`). Sin red se usa la última
  resolución guardada con aviso; sin red y sin resolución previa, el comando
  se detiene en vez de construir a ciegas.
- `Dockerfile`: un solo `RUN` instala todas las extensiones del `ARG
  EXTENSIONS` (ya con versiones exactas, nunca `"latest"`), con el paquete de
  la plataforma si Open VSX lo publica así y el universal si no.
- `devkit/scripts/gen-stack.sh` genera la línea de extensiones de la sección
  Stack del README desde `extensions.toml` y la verifica con `--check`; la
  entrada de Notion "Stack y comandos del devkit" la refleja a mano en el
  mismo PR.
- `devkit/host/devkit-test.sh` suma un doble de `curl` y cubre los cuatro
  casos: `latest` resuelto y guardado, versión fija sin consulta, sin red con
  resolución previa (aviso y build) y sin red sin resolución (se detiene).
- Cambios requeridos: `compose.yaml` del proyecto cambia (build arg
  `EXTENSIONS` nuevo); reinstala con `new-project.sh <proyecto> --ref <rama>`
  para probarlo antes de una etiqueta, o `--version <x>` después de
  publicarla.

### `pr-review` corre en Opus; `epic-plan` conserva el primer modelo de frontera (DEVKIT-72)

- `roles.toml`: `revision.model_index = 2`. Con `frontera = ["fable", "opus",
  "sonnet"]`, la revisión pasa de `fable` a `opus`: la mitad de costo por
  token de entrada/salida (USD 5/25 frente a 10/50 por millón) y sin ciclos
  de corrección de sobra como implementador (PR 39 a 43: 1, 1, 0, 0 y 0
  ciclos, evidencia de DEVKIT-54). Si `opus` no responde, la sonda de
  `frontera` cae a `sonnet`, no a `fable`.
- `devkit-run.sh`: `model_effort_of` admite `<skill>.model_index` como
  anulación por skill sobre `model_index` del rol, igual que ya admitía
  `<skill>.effort`. `epic-plan.model_index = 1` en `roles.toml` usa esa
  anulación para quedarse en el primer modelo de frontera: un mal desglose
  de Épica se paga en todas sus hijas.
- `revision.rondas` sigue sin existir: el revisor no escala (DEVKIT-61), y
  esta card cambia qué modelo revisa, no esa regla.
- Cambios requeridos: ninguno, `devkit recreate` alcanza.

### Entorno limpio y comprobación de Notion en el `claude -p` hijo (DEVKIT-65)

- `run_claude` (en `devkit-run.sh`) arma el entorno de cada `claude -p` con
  `env -i` y una lista blanca (`ENV_HEREDABLE`) en vez de heredar el
  entorno tal cual: identidad de Notion/GitHub, red de salida, hora local,
  `DISABLE_AUTOUPDATER` y `MCP_OAUTH_CALLBACK_PORT`. Un `task-start`
  lanzado por `epic-plan` -que a su vez corre dentro de otro `claude -p`-
  dejaba de leer la card porque la CLI hija montaba el conector de Notion
  con otro nombre; la causa exacta queda como hipótesis, no confirmada.
  `DEVKIT_ENV_LIMPIO=0` vuelve al entorno heredado completo.
- `watch.sh` pasa `DEVKIT_LANZADOR=watch` a `--sync`, y `run_claude` la
  repone en el entorno del hijo pese a `env -i`, para que `task-fix` sepa
  si lo lanzó el bucle y no firme `manual=1` de más.
- Antes de lanzar de verdad, `run_claude` prueba con `claude mcp list` que
  Notion está conectada en ese mismo entorno; si no, dejar `ALARMA: sin
  Notion conectado` en `watch.log` y no lanza. `DEVKIT_NOTION_CHECK=0`
  apaga la sonda.
- Si el `claude -p` termina sin acceso a Notion pese a la sonda, la card
  queda bloqueada sin intervención: `devkit-run` deja `ALARMA: terminó sin
  acceso a Notion` en `watch.log` y llama a `task-block.sh` con ese motivo.
  El único disparador del bloqueo es una herramienta de Notion en
  `permission_denials` del evento `result`. El texto del `result` que lo
  dice en una misma oración solo deja `ALARMA: el resultado describe falta
  de acceso a Notion` en `watch.log`, sin bloquear.
- `--allowedTools` trae los dos nombres conocidos del conector de Notion
  (`mcp__plugin_Notion_notion` y `mcp__claude_ai_Notion`), y
  `devkit/agents/settings.json` los autoriza también para la sesión
  interactiva.
- Cambios requeridos: ninguno, `devkit recreate` alcanza.

### Ajustes rápidos del editor y del shell (DEVKIT-66)

- Alias `c` para `clear` en `zshrc`.
- `"chat.disableAIFeatures": true` en los ajustes del editor, con la
  intención de apagar el chat integrado de VS Code. En esta build de
  openvscode-server (1.109.5) el comando `Chat: Open Chat` sigue en la
  paleta: limitación conocida, sin arreglo aquí (ver DEVKIT-71). La
  extensión Claude Code no cambia.
- `devkit awake <proyecto>` en el Mac: `caffeinate -i docker wait
  devkit-<proyecto>` evita el reposo por inactividad mientras el contenedor
  vive. No evita el reposo al cerrar la tapa. Cubierto en
  `devkit/host/devkit-test.sh` con un doble de `caffeinate`.
- Cambios requeridos: `devkit recreate <proyecto>` para el alias y el ajuste
  del editor; reinstalar el comando `devkit` con `new-project.sh` para tener
  `awake`.

### Escalera de modelos por ronda: la implementación escala y el revisor no (DEVKIT-61)

- `roles.toml` admite `implementacion.rondas`, una lista de
  `<alias>:<esfuerzo>` cuya posición es la ronda. El template trae
  `["sonnet:high", "sonnet:high", "opus:high"]`.
- Ronda: 1 para `task-start` y `task-submit`; para `task-fix` y
  `task-document`, 1 más los comentarios `<!-- devkit-fix` del PR de la card.
  Pasada la lista, repite el último. `devkit-run` la lee del PR (URL en
  Notion o `gh pr list --head <rama>`) y, si no puede, usa la 1 y lo dice en
  `watch.log`.
- El alias de la ronda pasa por la sonda de `frontera`; si no responde,
  manda `model_index`. `--modelo`, `--esfuerzo` y `DEVKIT_MODELO_FORZADO`
  siguen por encima. `revision.rondas` se ignora con aviso: `pr-review` y
  `epic-plan` no cambian.
- La línea de resumen de `watch.log` lleva `ronda=<n>` después de
  `esfuerzo=` (`ronda=-` en revisión). `devkit-run --rol` imprime un cuarto
  campo, la ronda, y `--resumen` acepta un quinto argumento.
- Por qué es un experimento: en la implementación, un error se ve (el PR
  vuelve con `CAMBIOS`) y cuesta como mucho un ciclo más; en la revisión, un
  OK falso no lo detecta nadie. La evidencia en contra de empezar barato
  existe (DEVKIT-51 en Sonnet necesitó tres ciclos, entrada de DEVKIT-54), así
  que la escalera se mide en las hijas de DEVKIT-43 con las marcas de
  DEVKIT-58 antes de fijar el valor por defecto.
- Cambios requeridos: ninguno. Para volver al modelo fijo por rol, quita
  `implementacion.rondas` en `.devkit/roles.toml` o en el template. Un
  `watch.sh` anterior, vivo hasta el próximo `devkit recreate`, sigue
  lanzando, pero su resumen sale con `ronda=-` y sin el aviso de presupuesto
  de turnos (lee `--rol` con tres campos). `devkit recreate` lo corrige.

### Modelo y esfuerzo visibles en el PR, la revisión, la Documentación y el cierre (DEVKIT-58)

- `devkit-run` exporta `DEVKIT_MODEL` y `DEVKIT_EFFORT` al `claude -p` que
  lanza, con el modelo y el esfuerzo que usó de verdad.
- `task-submit` escribe en el cuerpo del PR `Implementado con <modelo>,
  esfuerzo <x>`; `pr-review`, `Revisado con ...` debajo del marcador de cada
  informe; `task-document`, una sección "Modelos" con esas marcas y
  `Documentado con ...`.
- `task-close.sh` copia al comentario de cierre la marca del PR y la del
  último informe, o "sin marca" si faltan.
- Cambios requeridos: ninguno. Los PRs abiertos antes de este cambio cierran
  con "sin marca".

### `devkit-run --estado`: qué hace cada agente, sin lanzar otro agente (DEVKIT-57)

- `devkit-run --estado` muestra los últimos lanzamientos: skill, card, quién
  lanzó (`humano`, `bucle`, `epic-plan`, `task-close`), hace cuánto y estado
  (`en curso`, `terminó`, `error`, `bloqueada` con el motivo, `no arrancó`).
  `--estado --seguir` la refresca cada 3 s.
- Todo lanzamiento escribe antes en `watch.log` la línea
  `<id> lanzando (origen=<quién>): "<prompt>" log=<log>`, y cuenta como
  `en curso` desde ella. El resumen de `devkit-run` pasa a
  `devkit-run "<prompt>" terminado [<id>]: ...`. `task-block.sh` deja
  `task-block.sh <Clave> Bloqueada desde <estado>: <motivo>`.
- `devkit-run <skill> <Clave>` espera `/run/devkit/ready` (sale con 69 si el
  arranque no termina en 120 s) y confirma a los 5 s que el worker vive; si
  murió sin terminar, imprime el log y sale con 70.
- Quinta alarma de `watch.sh`: un `task-fix` que responde "nada que corregir"
  o "informe desactualizado" con `CAMBIOS` vigente sobre el mismo head se
  registra como `ALARMA:`, se relanza una vez con el siguiente modelo de
  `frontera` (`devkit-run --siguiente-modelo`) y, si repite, bloquea la card.
- `watch.sh --agentes-vivos` también ve lo que lanza el bucle (`--sync`).
- Cambios requeridos: ninguno. El `watch.sh` que ya corre sigue sin las
  líneas `lanzando` hasta el próximo `devkit recreate`: sus lanzamientos no
  salen en `--estado` hasta entonces.

### La siguiente hija arranca al OK y la guarda de tres ciclos no bloquea por un head superado (DEVKIT-56)

- Script nuevo `devkit/scripts/task-next.sh <Clave>`: lanza con `devkit-run
  task-start` la siguiente hija libre de la Épica (`Lista`, `Depende de` en
  `Hecha`, por `Orden` y `Prioridad`). `watch.sh` lo llama en cuanto el
  último informe del head es `OK`, una vez por head, y `task-close.sh` al
  merge. No lanza si una hermana está `En progreso` o `Revisión automática`,
  ni si ya hay un `task-start` vivo para una hermana. `watch.log` registra
  `task-next-<N> terminado: bash, <Clave> en Lista para merge :: ...`.
- `epic-plan` llena `Depende de` con una regla: si dos hijas tocan los
  mismos archivos, dependen y la segunda espera a `Hecha`; si no, arranca con
  la anterior en `Lista para merge`.
- La guarda de tres ciclos de `watch.sh` cuenta `CAMBIOS` respondidos y solo
  decide `bloquear` si el último informe es `CAMBIOS` sobre el head vigente.
  Antes bloqueaba tras el tercer fix sin revisar su head; ahora ese head se
  revisa y bloquea si vuelve a recibir `CAMBIOS`.
- `task-fix` firma `<!-- devkit-fix ... manual=1 -->` cuando no lo lanzó el
  bucle (`DEVKIT_LANZADOR` distinto de `watch`), y ese marcador reinicia el
  conteo. `pr-review` acepta la marca al buscar la respuesta del corrector.
- Cambios requeridos: ninguno. El `watch.sh` que ya corre sigue con la regla
  anterior hasta el próximo `devkit recreate`.

### Notion por token: `task-close` y `task-block` en bash, `task-document` nueva (DEVKIT-55)

- Secreto nuevo `notion_token` en Bitwarden: conexión interna de Notion,
  tipo Access Token, con acceso a la página "Ingeniería". `entrypoint.sh` lo
  deja como archivo `/run/devkit/notion_token` (600) y no lo exporta como
  variable; avisa si falta. `pr-guard.sh` bloquea leer esa ruta igual que la
  del token del editor.
- `devkit/scripts/notion.sh` habla con la API de Notion desde bash: `card
  <Clave>` (por `ID` y `Proyecto`), `set <page_id> Prop=valor...`, `comentar`,
  `documentacion` (entrada por la relación `Tarea`), más `pagina`, `hijas` y
  `criterios` para el cierre de Épica. El token viaja por descriptor, nunca
  por argumento. Autoprueba con `notion.sh --test`.
- `task-close` y `task-block` dejan de ser skills y pasan a
  `devkit/scripts/task-close.sh` y `task-block.sh`. Hacen lo mismo que antes
  (`Hecha`, `Cierre`, comentario con enlace, marcador `devkit-closed`, cierre
  de la Épica con la regla de DEVKIT-44, siguiente hija con `devkit-run`;
  `Bloqueada` con comentario y `wip` si hay cambios) sin lanzar modelo.
  `devkit-run task-close|task-block ...` los llama en primer plano.
- `watch.sh` cierra los PRs mergeados en un bucle aparte cada 30 s
  (`DEVKIT_WATCH_MERGED_INTERVAL`), no cada 5 min detrás de la skill en curso.
  La línea `task-close-<n> terminado: bash, cerrado Ns después del merge` en
  `watch.log` da la medida.
- La entrada de Documentación la escribe la skill nueva `task-document`
  cuando `pr-review` da OK: `watch.sh` decide `documentar` si el último
  informe OK del head no tiene marcador `<!-- devkit-doc sha=<head> -->`. Si
  la card vuelve atrás y un head nuevo recibe OK, corre otra vez y actualiza
  la misma entrada. `task-close.sh` la lanza si al cerrar no existe y no
  hay ya un `task-document` corriendo para esa Clave.
- El rol `contabilidad` desaparece de `roles.toml` y de `devkit-run.sh`.
- `devkit-run` exporta `DEVKIT_SCRIPTS_DIR` y `DEVKIT_RUN_DIR` al `claude -p`
  que lanza, y `entrypoint.sh` exporta `DEVKIT_SCRIPTS_DIR` antes de arrancar
  `watch.sh`. Sin eso, una skill que invocaba
  `${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/devkit-run.sh` caía a la copia
  de la imagen, vieja en modo dev, y lanzaba con modelo vacío. Ahora un
  modelo vacío no se lanza: `devkit-run` sale con 65 y deja `ALARMA: modelo
  vacío` en `watch.log`.
- Cambios requeridos: crear en Notion la conexión interna, darle acceso a la
  página "Ingeniería" y guardar su token en Bitwarden con la clave
  `notion_token`; luego `devkit recreate`. Sin el secreto, `task-close.sh` y
  `task-block.sh` fallan con un mensaje claro y el bucle deja `ALARMA:`.
  Hasta el `recreate`, el `watch.sh` que ya corre sigue pidiendo
  `/task-close` y `/task-block` como skills; `devkit-run --sync` los atiende
  con los scripts, así que el cierre funciona igual, pero con el tick viejo de
  5 min: el bucle de 30 s llega con el `recreate`.

### Modelos por frontera: `roles.toml` declara una lista ordenada (DEVKIT-54)

- `devkit/agents/roles.toml` cambia de fijar un modelo por nombre en cada rol
  a declarar una lista `frontera` ordenada de alias (hoy `fable, opus,
  sonnet`) y un `model_index` por rol: la posición desde la que
  `devkit-run.sh` busca el primero disponible. El `Tipo` de la card ya no
  elige modelo (sigue eligiendo prefijo de rama y sección del CHANGELOG).
- Reparto por papel en el flujo: `epic-plan` y `pr-review` usan el primer
  modelo de la lista; `task-start`, `task-fix`, `task-submit` y
  `task-document` (nace en la hija siguiente de esta Épica), el segundo;
  `task-close` y `task-block`, el tercero. Esfuerzo `high` en todos salvo
  `epic-plan`, que sube a `max`.
- La disponibilidad de cada modelo se comprueba una sola vez por arranque,
  con el resultado cacheado en `/run/devkit/frontera/<alias>` (tmpfs: se
  repite en cada `devkit recreate`). Un `no` caduca a los 600 s
  (`DEVKIT_MODEL_RETRY`): la sonda no distingue un modelo inexistente de una
  cuota agotada, y la cuota vuelve. Si el modelo que le toca a un rol no
  responde, `devkit-run` cae al siguiente de la lista y lo escribe en
  `watch.log`: `sonda de modelo: <alias> no responde en Ns` si fue timeout,
  `falló (rc=N): <stderr>` si la CLI dio error. El stderr queda en
  `/run/devkit/frontera/<alias>.err`.
- La sonda corre aislada: directorio vacío, `--strict-mcp-config` con una
  configuración MCP vacía y sin herramientas. Sin aislarla hereda el contexto
  de `/workspace` y deja de ser mínima: medido con `fable`, 41 s y USD 0.95
  para responder "ok", por encima del timeout de 30 s, de modo que el primer
  modelo de la lista quedaba marcado como caído en cada arranque. Aislada
  tarda 2 s.
- `devkit-run --otros-agentes` lista los procesos `claude -p` ajenos al
  lanzamiento en curso y sale 0 si el workspace está libre. Es lo que deben
  usar las skills en vez de un `pgrep -f <Clave>`: la Clave viaja en los
  argumentos del lanzador, así que un `pgrep` devuelve los cuatro procesos
  propios (el `--worker`, su subshell, su vigilante y el `claude -p` propio)
  como si fueran de otro agente. `task-start/SKILL.md` lo deja escrito.
- `epic-plan/SKILL.md` y `task-close/SKILL.md` lanzan la siguiente/primera
  hija por la ruta explícita del script
  (`"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/devkit-run.sh"`), no por el
  alias `devkit-run`: el alias solo existe en `zshrc` y el Bash no
  interactivo de `claude -p` no lo carga, así que las dos skills se quedaban
  sin arrancar la hija siguiente. `task-fix/SKILL.md` trae ahora el `jq`
  explícito sobre `reviews` para hallar el marcador `devkit-review`, y aclara
  que el ejemplo sobre `comments` sirve solo para el marcador `devkit-fix`.
- Cambios requeridos: ninguno. `--modelo`/`--esfuerzo` de `devkit-run` siguen
  anulando la resolución en un lanzamiento puntual, y `.devkit/roles.toml`
  sigue anulando la tabla completa por proyecto con el mismo formato nuevo.

### Raíz limpia: `devkit.toml` se muda a `.devkit/` (DEVKIT-53)

- `devkit.toml` deja la raíz del proyecto y pasa a `.devkit/devkit.toml`,
  versionado igual que antes. `AGENTS.md`, `CLAUDE.md` y `.claude/` se quedan
  en la raíz porque las herramientas (Codex, Claude Code) obligan a tenerlos
  ahí; todo lo demás que el devkit necesita en un proyecto vive en `.devkit/`.
- `entrypoint.sh` crea y lee `devkit.toml` en la ruta nueva, y avisa si
  `CLAUDE.md` existe sin la línea `@AGENTS.md`.
- `devkit.sh` (host), `devkit-test.sh`, `watch.sh` y las skills
  `project-init`, `task-create`, `pr-review`, `template-update` y
  `template-propagate` apuntan a `.devkit/devkit.toml`.
- Opcionalmente, `.devkit/roles.toml` anula la tabla de roles del template
  (`devkit/agents/roles.toml`) en este proyecto solo. Si existe, `devkit-run.sh`
  lo resuelve primero en el orden de búsqueda de roles.
- Cambios requeridos: el arranque mueve `devkit.toml` de la raíz a `.devkit/`
  la primera vez que un proyecto sube a esta versión; `template-update` lo
  repite si hiciera falta. El movimiento se queda sin commit hasta que la card
  de actualización lo incluya. **En el Mac**: reinstala el comando con
  `new-project.sh <proyecto> --version <X.Y.Z>` para que lea la ruta nueva; sin
  esto, `devkit update` falla cuando `~/.devkit/bin/devkit` intenta abrir el
  archivo viejo.

### El token del editor deja de filtrarse por logs y terminal (DEVKIT-51)

- `/run/devkit/vscode.log` nace en `600` (antes `644`) y el arranque de
  `openvscode-server` filtra con `grep --line-buffered -v 'tkn='` la línea
  que trae el token, para que un `tail`/`cat` normal no lo muestre.
- `devkit code` deja de imprimir la URL con el token cuando `open` la abre
  bien en el Mac; solo la imprime si `open` falla o no está.
- `pr-guard.sh` pasa de lista negra a lista blanca para
  `/run/devkit/vscode-token`: bloquea cualquier segmento que mencione la
  ruta, incluidas la redirección (`< vscode-token`), la sustitución de
  comando y los intérpretes, salvo que solo compruebe que el archivo existe
  (`test`, `[` o `[[` con `-e`, `-f`, `-r` o `-s`). `ls` y `stat` salieron
  de la lista blanca: su salida (listado, `%n`) reinyecta la ruta o el
  nombre del archivo a un segundo comando en el mismo pipe (ej. `ls
  /run/devkit/vscode-token | xargs cat`), que esta inspección de texto por
  segmento no veía.
- Runbook "El editor no abre" actualizado con el procedimiento de rotación
  del token y qué no pegar nunca en un chat ni en una card.
- Cambios requeridos: quien tenga el comando `devkit code` instalado en el
  Mac desde antes de esta card lo reinstala con
  `new-project.sh <proyecto> --ref <rama>` para tomar el cambio; `devkit
  recreate` alcanza para el resto (imagen).

### `devkit-run` en task-close y epic-plan; alarmas y anulación manual (DEVKIT-50)

- `task-close` y `epic-plan` lanzan la siguiente/primera hija con
  `devkit-run task-start <Clave>` como proceso aparte y terminan, en vez de
  trabajarla en su propia ejecución: antes corría con el rol de contabilidad
  de `task-close` (Haiku, esfuerzo bajo) en vez del que le toca por su propio
  `Tipo` (DEVKIT-45 nunca se aplicaba a la hija siguiente).
- Alias `devkit-run` en `zshrc`, hacia `$DEVKIT_SCRIPTS_DIR/devkit-run.sh`:
  antes solo funcionaba con la ruta completa, pese a que el README lo
  documentaba como comando. `DEVKIT_SCRIPTS_DIR` lo exporta el arranque
  (mismo `SCRIPTS_DIR` que usa `watch.sh`), así que en modo dev el alias
  corre el script del workspace, no la copia vieja de la imagen.
- Sin `DEVKIT_ROLES_FILE`, `devkit-run.sh` resuelve `roles.toml` contra un
  hermano `../agents` que no existe cuando corre desde `/opt/devkit/scripts`
  (el Dockerfile solo copia `scripts/`): cae ahora al `agents/` de
  `TEMPLATE_DIR`, que sí existe siempre. `--modelo`/`--esfuerzo` sin valor ya
  no cuelgan el proceso: salen con el mensaje de uso y rc 64.
- `epic-plan` entra al rol `revision` (modelo fuerte, esfuerzo alto) en
  `devkit-run.sh`: un mal desglose de Épica cuesta más que cualquier card.
- `devkit-run` acepta `--modelo <alias>` y `--esfuerzo <low|medium|high>`
  para anular el rol resuelto en un lanzamiento puntual, sin tocar
  `roles.toml`; el modo interno homónimo que usaba `watch.sh` se renombró a
  `--rol`.
- Un lanzamiento por `devkit-run` pasa por las mismas alarmas de DEVKIT-46
  que `run_skill` de `watch.sh` (error, skill lenta, pregunta abierta) y,
  ante una pregunta abierta con la card en curso, relanza `task-block` una
  vez con un motivo forzado, en vez de dejarla colgada (DEVKIT-44, DEVKIT-48).
- `watch.sh --agentes-vivos` imprime "sin agentes vivos" y sale con código 0
  cuando no hay ninguno, en vez de salir sin texto.

### Inventario por capa del peso de la imagen (DEVKIT-48)

- Inventario completo en `docs/ARCHITECTURE.md`, sección 4.2b: tabla de
  `docker history` capa por capa con su origen en el `Dockerfile`, desglose
  por herramienta y las tres duplicaciones que la tabla de capas escondía.
  Medido el 2026-09-15 sobre `devkit:dev` (`9884ae5f1355`, arm64).
- **Esta card no toca el `Dockerfile`.** Mide y decide; no retira nada. El
  criterio de aceptación exige `docker image ls` antes y después de cualquier
  cambio, y el rebuild solo corre en el Mac, no en el workspace en modo dev.
  Cifra registrada: 2,54 GB antes, sin cambio después. Cada retiro aprobado
  queda como card propia, con su medición.
- Las dos cifras del peso no son la misma y conviene no confundirlas otra
  vez: `docker image ls` reporta 2,54 GB y la suma de capas de `docker
  history`, 1,90 GB. Los ~640 MB de diferencia no son capas perdidas. Docker
  Desktop usa el almacén de imágenes de containerd (`docker info` devuelve
  `overlayfs [["driver-type","io.containerd.snapshotter.v1"]]`), que cuenta el
  blob comprimido además del contenido desempaquetado. El inventario real por
  capa es el de `docker history`.
- `docker history` se detiene en la capa, y las dos capas más pesadas (710 MB
  y 381 MB) agrupan varias herramientas en un solo `RUN`. El desglose se
  obtuvo midiendo con `du` dentro de un contenedor de esa misma imagen. Las
  unidades cuadran: `du -h` reporta MiB y `docker history --human`, MB
  decimales; convertidas, cada capa coincide con la suma de sus herramientas
  (capa 9: 711,5 MB medidos contra 710 MB; capa 3: 383 MB contra 381 MB).

**Sale, con cifra y justificación:**

- **Caché de `uv`, 308 MB (12,1 % de la imagen).** `~/.cache/uv/archive-v0`
  guarda una copia desempaquetada de todo lo que `uv` instaló, y no está
  enlazada con hardlink a `~/.local/share/uv`: `find -printf '%n'` da 1 enlace
  en ambos lados y un `du` conjunto suma 677 MiB en vez de compartir bloques.
  Son dos copias completas y solo una se usa en runtime. Se retira con `uv
  cache clean` en el mismo `RUN` de `uv python install`; en un `RUN` posterior
  la capa anterior ya fijó los bytes y no se recupera nada. Costo funcional:
  ninguno, la caché solo acelera reinstalaciones, que en una imagen no
  ocurren.
- **Binario de Claude Code duplicado, 224 MB (8,8 %).** El mismo archivo de
  223 862 184 bytes, SHA-256 `7bf9f33a…`, está en `~/.local/share/claude/`
  y dentro de la extensión del editor, en `…/resources/native-binary/claude`.
  Inodos distintos y un enlace cada uno: dos copias reales. Sale una, con
  reserva: hay que probar que la extensión funciona con un symlink a la otra,
  y que `CLAUDE_CODE_EXT_VERSION` y la versión que baja `claude.ai/install.sh`
  no se separen, porque hoy nada las ata entre sí. Necesita rebuild y prueba,
  por eso va en card propia y no aquí.

Juntos, 532 MB: 20,9 % de los 2,54 GB, sin perder una sola herramienta.

**Se queda, con cifra y justificación:**

- `openvscode-server`, 243 MB. Único editor desde DEVKIT-40; sin él no hay
  `devkit code`.
- `basedpyright`, 284 MB, de los cuales 207 MB son un runtime de Node propio.
  Es lo más pesado después del editor, pero está en la lista de permisos de
  los agentes para type-checking y no hay alternativa que no traiga su propio
  runtime. Dentro del paquete sí hay 95 MB de grasa real: 66 MB de cabeceras
  C para compilar addons nativos y 29 MB de sourcemaps. No se tocan: borrar
  por dentro un paquete que `uv tool install` puede rehacer en cualquier
  reinstalación es frágil. Queda anotado con su cifra.
- `rclone`, 78,6 MB. Respaldo de `sandbox.local/` en Dropbox.
- `git`, 50,8 MB, el paquete apt más grande, y `gh`, 39,8 MB. Núcleo del
  flujo de cards y PRs.
- CPython 3.14 de herramientas, 96,5 MB, más `uv` y `uvx`, 46,8 MB. Decisión
  de arquitectura 4.2.
- `ruff` 23 MB, `bws` 11,5 MB, `starship` 10,1 MB, `ripgrep` 4,9 MB,
  `fd-find` 3,1 MB y plugins de zsh 2,43 MB. Todos con función declarada en
  DEVKIT-40 y ninguno pasa de 23 MB: la cifra no justifica el trabajo.
- `perl`, 52,2 MB entre `libperl5.40` y `perl-modules-5.40`. No se instala a
  propósito: entra como dependencia de `git`. No sale sin romper `git`.

### Documentación corregida: CHANGELOG, poke, permisos del token y devkit-net-denied (DEVKIT-47)

- La entrada `1.0.0` de este CHANGELOG decía que el peso de la imagen antes
  de retirar Neovim y tmux no se pudo recuperar. Sí estaba, en un comentario
  de la card DEVKIT-40 que el corrector no citó (DEVKIT-41, deuda técnica):
  2,72 GB (`b33709ccd140`) antes, 2,54 GB (`bb48fe816d53`) después, 180 MB
  menos. Corregido con la fuente.
- README: la frase sobre los 5 s entre el `touch` de `/run/devkit/poke` y la
  línea `consultando GitHub` solo valía si el bucle estaba durmiendo; en el
  ciclo automático normal, con el bucle despierto atendiendo otro PR, la
  línea sale al terminar esa vuelta, no a los 5 s. Acotada en el README y en
  la entrada "Stack y comandos del devkit" de Notion.
- README y `docs/ARCHITECTURE.md` (8.1 y 12b) documentan los alcances
  exactos que necesita el token de GitHub de la cuenta máquina: `repo` y
  `read:org`, este último porque `gh pr edit --add-reviewer` (lo usa
  `pr-review` para pedir el review al humano) lo exige incluso sin
  organización. Faltaba y `gh pr edit --add-reviewer` falló con 403 en el
  PR 30; el humano añadió el alcance a mano el 2026-09-15.
- `devkit-net-denied` leía el log completo del proxy sin ventana de tiempo,
  así que un rechazo de días atrás aparecía junto a uno de ahora mismo y
  producía un bloqueo falso (DEVKIT-38, con `open-vsx.org` ya resuelto).
  Ahora acota a los últimos `DEVKIT_NET_DENIED_WINDOW` minutos (15 por
  defecto) y confirma con `curl`, a través del proxy, cuál de esos dominios
  sigue bloqueado de verdad antes de sugerir añadirlo a `domains`.
- La línea `estado:` de `work_state` en `watch.sh` ya era una observación de
  git y GitHub ("rama X, N commits sobre main, PR..."), no una orden ni una
  afirmación sobre el Estado real de la card en Notion: ya la había corregido
  DEVKIT-17. Sin cambios; se deja constancia de que el criterio de esta card
  ya estaba cubierto.

### Monitoreo mínimo sin modelo en watch.sh (DEVKIT-46)

- Cuatro alarmas en bash dentro de `watch.sh`, sin gastar tokens, como líneas
  `ALARMA: ...` en `watch.log`: una skill que termina con error; una skill
  que lleva más de `DEVKIT_WATCH_SKILL_TIMEOUT` segundos corriendo (1200 por
  defecto); un `result` que termina en pregunta en vez de resolver en un
  estado observable; y la rama en la que quedó el workspace, sin PR y sin
  ningún `claude -p` vivo hace más de `DEVKIT_WATCH_ORPHAN_AGE` segundos
  (1800 por defecto).
- `watch.sh --agentes-vivos` lista los `devkit-run.sh --worker` en curso con
  su PID, Clave y paso (skill).
- Variables nuevas: `DEVKIT_WATCH_SKILL_TIMEOUT`, `DEVKIT_WATCH_SKILL_POLL` y
  `DEVKIT_WATCH_ORPHAN_AGE`.

### Lanzador `devkit-run` con modelo, esfuerzo y costo por rol (DEVKIT-45)

- `devkit/scripts/devkit-run.sh`, único punto de lanzamiento de una skill:
  `devkit-run <skill> <Clave> [texto extra...]` la corre en segundo plano con
  `nohup` desde `/workspace`, sin el `nohup claude -p ... &` a mano que exigía
  hasta ahora (absorbe DEVKIT-18). Log en `/run/devkit/<skill>-<n>.log`, con
  el mismo candado que `run_skill` para no pisarle la rama al bucle
  (DEVKIT-27).
- `devkit/agents/roles.toml`, la tabla rol -> modelo/esfuerzo/presupuesto de
  turnos: `contabilidad` (`task-close`, `task-block`) con el modelo más
  barato; `implementación`, por `Tipo` de card (derivado del prefijo de la
  rama, porque el bucle no consulta Notion desde bash); `revisión`
  (`pr-review`), siempre el modelo fuerte. `max_turns` es un presupuesto, no
  un límite: la CLI instalada (2.1.270) no tiene `--max-turns`.
- `watch.sh` usa `devkit-run.sh` en `run_skill`, y agrega una línea con el
  costo total del ciclo (todas las rondas de revisión y corrección de un PR,
  no solo el cierre) al terminar `task-close`.
- **Corrección de rumbo sobre el criterio original:** el criterio de
  aceptación pedía "permisos `dontAsk` con la lista blanca completa de
  `settings.json`... y un registro de denegaciones para ampliar la lista
  cuando algo legítimo falle". Se probó con `claude -p` real (modos
  `acceptEdits` y `dontAsk`, con y sin `--permission-prompts none`): un
  comando fuera de la lista `allow` corre igual en modo headless; esa lista
  no restringe nada ahí, solo evita el diálogo de confirmación en una sesión
  interactiva. `docs/ARCHITECTURE.md` (8.2) ya documentaba esto: la compuerta
  real es la lista `deny` más el hook `pr-guard.sh`. Por eso `devkit-run`
  sigue en `--permission-mode acceptEdits` (no cambia a `dontAsk`, que no
  aporta nada distinto) y el registro de denegaciones se implementó donde sí
  hay denegaciones reales: `pr-guard.sh` ahora anota cada comando que bloquea
  en `/run/devkit/denials.log`.

### Skills headless corregidas: comentarios, cierre sin preguntas, fuente citada y clase agotada (DEVKIT-44)

- `task-start` lee los comentarios de la card antes de publicar el plan y
  cita cada ampliación encontrada; ignorar un comentario dejó el CHANGELOG
  de `1.0.0` con un dato falso (DEVKIT-41).
- `task-fix`, cuando un hallazgo pide retirar un dato que vive en un
  comentario de la card (el revisor no puede leerlos), ya no lo retira: cita
  la fuente en el commit.
- `pr-review` agota en el mismo ciclo la clase de un hallazgo con variantes
  (por ejemplo, una sintaxis con varios flags), en vez de encontrar una
  variante por ciclo; esto costó 7 revisiones en el PR 27 (DEVKIT-20).
- `task-close` no cierra una Épica a `Hecha` cuando terminan sus hijas salvo
  que esté `En progreso` y tenga Criterios de aceptación; cerrar sin este
  chequeo dejó DEVKIT-19 en `Hecha` sin ejecutar su contenido.

### Retirar `.devcontainer/`, el enfoque anterior basado en la CLI de devcontainers (DEVKIT-29)

- `.devcontainer/` quedaba como "referencia histórica hasta que exista la
  0.1.0"; la 0.1.0 existe desde 2026-09-06 y ningún script del repo
  (`new-project.sh`, `devkit/`, `README.md`) lo nombraba. El enfoque vivo es
  Docker Compose puro, documentado en `docs/ARCHITECTURE.md`.
- La cabecera de `docs/ARCHITECTURE.md` decía "diseño aprobado, pendiente de
  construcción"; pasa a "en producción desde la versión `0.1.0`".
- No había nada que rescatar de `.devcontainer/README.md` o
  `.devcontainer/AGENTS.md`: los volúmenes, `CLAUDE_CONFIG_DIR` y el
  pre-creado de puntos de montaje ya estaban en `docs/ARCHITECTURE.md`
  (sección 4.3).
- El PR lista, para que las borre el humano, las ramas remotas del enfoque
  anterior: `claude/devcontainer-ecosystem-setup-7q3sod`,
  `claude/devcontainer-persistencia-volumenes`, `claude/devcontainer-template`
  y la huérfana `chore/DEVKIT-16-prueba-punta-a-punta`.
  `claude/devcontainer-notion-docker-0tmny4` es la sesión web activa del
  humano: no se toca.

### `template-update` pone al día `AGENTS.md` con cada bump de versión (DEVKIT-28)

- Hasta ahora `entrypoint.sh` solo escribía `AGENTS.md` la primera vez
  (`[ -f "$WS/AGENTS.md" ] || ...`) y `template-update` no lo tocaba: un
  cambio en `AGENTS.template.md` nunca llegaba a un proyecto ya creado. El
  caso de origen fue el renombre de skills de DEVKIT-10: un proyecto en
  0.1.0 se queda con `session-start`/`task-review` en su `AGENTS.md` aunque
  suba de versión.
- `AGENTS.template.md` declara un marcador nuevo, `## Reglas del proyecto`,
  con una línea que explica el reparto: todo lo de arriba es del template,
  todo lo de abajo es del proyecto y se conserva.
- `devkit/scripts/agents-sync.sh` (con autoprueba, `--test`) hace la fusión
  mecánica: si el `AGENTS.md` del proyecto tiene el marcador, arma un
  archivo nuevo con la plantilla destino arriba y la sección del proyecto
  intacta abajo. Es texto plano, sin criterio de por medio: por eso puede
  aplicarse solo, a diferencia de una fusión que tuviera que interpretar
  contenido libre.
- Si el `AGENTS.md` no tiene el marcador (proyectos de antes de esta
  convención), el script no toca nada y avisa con el código de salida `2`;
  `template-update` pega el diff en el cuerpo del PR y deja la fusión al
  humano. Aplicar una plantilla nueva a un archivo sin ese límite claro
  podría borrar contenido del proyecto sin que nadie lo note antes del
  merge, así que ahí no hay automatismo.
- `template-update`, paso nuevo entre cambiar `devkit.toml` y `task-submit`:
  descarga `AGENTS.template.md` y `agents-sync.sh` de la versión destino
  (no los del template local, que pueden ir atrás si la imagen no se ha
  reconstruido), renderiza `{{PROJECT}}` y corre la fusión.
- `template-propagate` corre la misma fusión antes de su commit, con los
  archivos locales de este repo en vez de descargarlos: ya está parado en la
  última etiqueta. Sin este paso, los PRs que abre habrían subido `template`
  sin poner `AGENTS.md` al día, la misma laguna que originó esta card.
- Sin acción manual para quien arrastre los nombres viejos de skill del
  renombre de DEVKIT-10 (`session-start`, `task-review`): `template-update`
  los corrige solo al actualizar a esta versión, la primera que trae
  `agents-sync.sh`.
- Cambios requeridos para quien venga de 0.1.0: ver la sección de la
  versión 1.0.0.

### `pr-review` vuelve a juzgar el mismo head cuando `task-fix` responde sin push (DEVKIT-22)

- Antes, si `task-fix` respondía a un informe `CAMBIOS` descartando todos los
  hallazgos (o solo comentando) sin empujar commits, `watch.sh` decidía
  `nada` y `pr-review` terminaba con "ya revisado en \<sha\>": nadie volvía a
  mirar el PR y la card se quedaba en `Revisión automática` hasta que el
  humano interviniera.
- `watch.sh --decide` separa ahora "sin respuesta" (`fix`, sin cambios) de
  "respuesta sin push" (`revisar` de nuevo), y la clave de deduplicación del
  bucle incluye la referencia además del head para no perder el segundo
  aviso. `pr-review` comprueba si hay un `devkit-fix` posterior a su
  informe con el mismo `sha`; si lo hay, revisa igual con un diff vacío en
  vez de terminar con "ya revisado".

### Hook que reduce evasiones al aprobar o mergear un PR desde la sesión (DEVKIT-20)

- `devkit/scripts/pr-guard.sh`, declarado como hook `PreToolUse` de `Bash` en
  `devkit/agents/settings.json`, inspecciona el texto completo del comando
  (no solo su prefijo, como el `deny` de `settings.json`) y bloquea `gh pr
  review --approve`/`-a`, `gh pr merge` sin `--auto` o con `--admin`, `gh
  api` de escritura sobre reviews, merge o `refs/heads/main`, `gh alias set`
  y `git push` a `main` en cualquiera de sus formas (refspecs cortos,
  `--force*`, comillas, expansiones de shell). Es una inspección de texto,
  no una sandbox: reduce evasiones accidentales o perezosas, no las
  garantiza. La compuerta real sigue siendo GitHub (ruleset de `main` con
  aprobación humana obligatoria y la cuenta máquina sin permiso de aprobar).

## 1.0.0 - 2026-09-14

### Neovim y tmux fuera de la imagen; openvscode-server como único editor (DEVKIT-40)

- Con el servidor VS Code ya permanente (DEVKIT-39), Neovim y tmux salen por
  completo: `devkit/nvim/` (init, plugins, lockfile, pruebas de DEVKIT-31),
  `NVIM_VERSION` y `/opt/nvim` del `Dockerfile`, el paquete `tmux` y
  `devkit/tmux/tmux.conf`. `git grep -i -E "nvim|neovim|tmux"` queda limpio
  fuera de este changelog.
- El único papel de tmux era sostener la sesión de terminal si se cerraba
  Terminal.app; la terminal integrada de VS Code Server ya lo cubre, con un
  período de gracia de reconexión de tres horas, y ni `watch.sh` ni las
  skills dependían de él. `devkit attach` se retira; `devkit shell
  <proyecto>` (`docker exec -it devkit-<proyecto> zsh`) es su reemplazo para
  una shell suelta, sin esa persistencia. `up`, `recreate` y `rebuild` dejan
  de encadenar una sesión al final.
- Inventario de la imagen, con justificación por herramienta: se quedan zsh,
  starship y sus plugins (terminal del editor y de los agentes), Claude
  Code y el plugin de Notion, gh y git, uv, ruff y basedpyright (este último
  en la lista de permisos de los agentes para type-checking), ripgrep y fd
  (también en esa lista), bws, rclone, socat y openvscode-server. Todo lo
  que solo existía para Neovim o tmux, fuera.
- `image-drift.sh` deja de vigilar `nvim/` y `tmux/`; `devkit-test.sh` y
  `image-drift.sh --test` actualizan sus casos. README, `docs/ARCHITECTURE.md`
  (sección 4.4) y la entrada "Stack y comandos del devkit" de Notion, al día.
- `devkit.toml` de la raíz (este repo es a la vez template y proyecto) suma
  `domains = ["open-vsx.org", "openvsx.eclipsecontent.org"]`, con nota de que
  solo hacen falta para instalar extensiones desde dentro del editor.
- Medidas de `devkit rebuild devkit` en el Mac: build de 126,9 s, imagen final
  `devkit:dev` en 2,54 GB (`bb48fe816d53`) y `devkit-proxy:dev` en 16,7 MB;
  memoria en reposo del contenedor recién levantado (`docker stats
  --no-stream`), 235 MiB de 7,8 GiB asignados (2,9 %). Peso de la imagen
  antes de esta card (con Neovim y tmux): 2,72 GB (`b33709ccd140`), medido
  con `docker image ls` en la card (DEVKIT-40, comentario de las 17:20)
  justo antes del rebuild que produjo la imagen final `bb48fe816d53`.
  Diferencia: 180 MB menos, 6,6 %. La reducción se sostiene en lo que salió
  del `Dockerfile` y del repo, no solo en la resta de bytes: el paquete
  `tmux`, el binario de Neovim en `/opt/nvim` y unas 830 líneas de
  configuración y pruebas en `devkit/nvim/`.
- Cambios requeridos: quien use `devkit attach` pasa a `devkit shell`. Nadie
  pierde el editor: Neovim ya no estaba documentado como camino recomendado
  desde DEVKIT-39.

### Editor VS Code en el navegador, con `devkit code` (DEVKIT-39)

- `openvscode-server` (1.109.5) entra a la imagen como alternativa a Neovim,
  con la extensión Claude Code (2.1.270) instalada desde Open VSX durante el
  build, no a mano en el contenedor. Veredicto y medición completa en la
  exploración DEVKIT-38: 354 MB de RAM adicionales, ~458 MB de imagen.
- Arranca en `entrypoint.sh`, como usuario `dev`, escuchando solo en
  `127.0.0.1:3000` del contenedor. Gateado por
  `--connection-token-file /run/devkit/vscode-token`: el secreto llega de
  Bitwarden (clave `vscode-token`) igual que el resto, y si el archivo no
  existe el editor no arranca, sin inventar un token.
- Publicado por el mismo patrón `socat` de dos saltos que el retorno OAuth:
  Mac `127.0.0.1:3000` → proxy:3001 → `dev:3001` → `127.0.0.1:3000` dentro
  de `dev`, donde escucha el servidor.
- `devkit code <proyecto>` arma la URL con el token y la abre en el
  navegador del Mac; sin proyecto, explica el uso y sale con código
  distinto de cero (la validación genérica que ya tenían el resto de los
  subcomandos).
- Dominios `open-vsx.org` y `openvsx.eclipsecontent.org` (la CDN a la que
  redirige la descarga) van en `domains` de `devkit.toml`, por proyecto: solo
  quien usa el editor los necesita, así que no entran a la lista base del
  proxy.
- `devkit/vscode/` (los ajustes del editor) se suma a lo que solo entra por
  imagen: `image-drift.sh` lo compara igual que `nvim/`, `tmux/`, `zsh/` y
  `proxy/`.
- Amenazas y mitigaciones del puerto y del token en
  `docs/ARCHITECTURE.md`, sección 8.
- Cambios requeridos: ninguno para quien no lo use. Para adoptar el editor en
  un proyecto: crear el secreto `vscode-token` en Bitwarden, declarar los dos
  dominios de Open VSX en `devkit.toml` y correr `devkit recreate`.

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

Salto MAJOR desde `0.1.0`: el punto de `devkit.env` de abajo no es reemplazo
directo (regla de `docs/ARCHITECTURE.md`, 4.7). Proyectos en `0.1.0`, al
actualizar:

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
  `devkit rebuild`;
- PRs ya mergeados y cerrados que no llevan el marcador `devkit-closed`: se
  les pone una vez con el comando de la sección "Cierre de PRs" del README,
  para que el próximo `recreate` no los reprocese;
- quien usaba `devkit attach` pasa a `devkit shell <proyecto>`
  (`docker exec -it devkit-<proyecto> zsh`): sin la persistencia de sesión
  que daba tmux, cubierta ahora por la terminal integrada de
  `openvscode-server`, con tres horas de gracia de reconexión;
- para adoptar el editor: crear el secreto `vscode-token` en Bitwarden,
  declarar `open-vsx.org` y `openvsx.eclipsecontent.org` en `domains` de
  `devkit.toml` y correr `devkit recreate`. `devkit code <proyecto>`, en el
  Mac, abre el editor en el navegador contra `127.0.0.1:3000` del
  contenedor (publicado por el proxy con el mismo patrón `socat` de dos
  saltos que el retorno OAuth) y con el token de conexión ya en la URL: sin
  el secreto, el editor no arranca. Nadie pierde el editor si no lo adopta:
  Neovim ya no estaba documentado como camino recomendado desde DEVKIT-39.

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

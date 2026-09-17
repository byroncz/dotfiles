# Arquitectura del entorno de desarrollo `devkit`

Estado: en producción desde la versión `0.1.0` del template. Fecha: 2026-09-06.

Está escrito para alguien que llega hoy al proyecto. Cada sección explica qué
se decidió, por qué, y qué consecuencia tiene. Las alternativas descartadas se
mencionan solo cuando ayudan a entender la decisión.

## 1. Propósito

Un entorno de desarrollo en contenedor que:

- Depende del host solo para correr Docker. Ni Node, ni git, ni Python, ni
  Dropbox instalados en el Mac.
- Se reconstruye sin perder nada que importe.
- Trae un editor integrado con Claude Code y preparado para Codex.
- Usa Notion como centro de gestión: un kanban por proyecto donde los agentes
  toman tareas, abren ramas y PRs, y documentan al cerrar.
- Vive como template versionado en este repo y se instancia por proyecto.

### Criterio de "listo"

Una Épica en el proyecto `DEVKIT` pasa de Backlog a Hecha con sus hijas, sus
PRs, auto-merge y entradas de Documentación, y la única intervención manual es
aprobar PRs. Un rebuild del contenedor no pierde nada. Un proyecto nuevo se
instancia en menos de quince minutos con Docker y Terminal.app en el Mac.

## 2. Principios

1. **Host mínimo.** El Mac aporta Docker con Compose, un shell, `curl` y un
   archivo con un token. Nada más.
2. **El contenedor es la frontera de seguridad.** Cada credencial tiene el
   alcance mínimo y se pregunta "qué es lo peor que un agente puede hacer con
   esto".
3. **Todo es reconstruible salvo dos volúmenes.** El código vive en git, el
   sandbox en Dropbox, el estado de Claude y el historial de shell en
   volúmenes. Lo demás se regenera al arrancar.
4. **Versiones fijadas.** Cada proyecto declara qué versión del template usa.
   Nada se propaga sin pasar por un PR.
5. **Una compuerta humana: el approve del PR.** De ahí en adelante ejecutan
   máquinas.
6. **Un solo texto de instrucciones para todos los agentes.** `AGENTS.md` es
   la fuente; `CLAUDE.md` lo importa.
7. **Estilo de redacción único** para todo texto que produzcan los agentes.
   Ver sección 11.

## 3. Vista general

```
Mac (host)                         Contenedor de trabajo               Servicios
--------------------------------   ---------------------------------   ---------------
Docker Desktop / OrbStack          debian:trixie-slim, usuario sin     GitHub
Terminal.app                       sudo                                Notion
~/.devkit/bws-token  (600)   --->  entrypoint: secretos, clon, sync    Dropbox (/Apps/devkit)
~/.devkit/<proy>/compose.yaml      zsh -> Claude, VS Code en navegador  Bitwarden Secrets Manager
~/.devkit/<proy>/devkit.env        /workspace  (capa del contenedor)   Anthropic
                                   /workspace/sandbox.local -> rclone  PyPI
                                   ~/.claude   (volumen)
                                   /commandhistory (volumen)
                                   |
                                   v
                                   Proxy de salida (contenedor auxiliar, lista blanca)
```

El contenedor de trabajo está en una red interna sin salida a internet. Solo
el proxy sale, y solo hacia los dominios de la lista blanca.

## 4. Decisiones por tema

### 4.1 Persistencia y respaldo del código

- El código vive en la capa de escritura del contenedor, no en un bind mount
  ni en un volumen. `docker compose stop` y `start` lo conservan; `down` o un
  rebuild lo destruyen.
- La fuente de verdad del código es el remoto de git. Antes de cualquier
  rebuild: commit y push.
- `sandbox.local/` es un directorio ignorado por git y respaldado en Dropbox
  con `rclone`, en una sola dirección, cada minuto, solo si hubo cambios, con
  `--backup-dir` para conservar borrados.
- Cualquier otro directorio `*.local` no va a git ni a Dropbox y muere en el
  rebuild.
- No hay daemon de Dropbox ni Docker dentro del contenedor.

Por qué: Dropbox corrompe repos de git al no tener bloqueo, su cliente Linux
exige ext4, y Docker-in-Docker requiere `--privileged`. Git es distribuido por
diseño: cada push es una copia completa.

Guardia obligatoria: el arranque restaura `sandbox.local` desde Dropbox
**antes** de iniciar el bucle de subida. Un `sync` desde un directorio vacío
borraría Dropbox. Un archivo marcador impide ese orden.

### 4.2 Imagen base, Python y `uv`

- Base `debian:trixie-slim`. Sin lenguaje preinstalado.
- `uv` copiado como binario desde la imagen oficial de Astral.
- La versión de Python la declara cada proyecto en `.devkit/devkit.toml` (clave
  `python`), fijando la serie menor, por ejemplo `3.14`. `uv python install`
  la instala al primer arranque. Subir de serie es un commit consciente.
- Paquetes apt adicionales por parámetro de build, vacío por defecto.

Por qué: separa la evolución del template de la del lenguaje. `uv` usa
`python-build-standalone`, mantenido por Astral; sus limitaciones documentadas
no aplican a Debian con glibc.

### 4.2b Peso de la imagen, por capa

Inventario medido el 2026-09-15 sobre `devkit:dev` (`9884ae5f1355`, arm64),
en el Mac con `docker history` (DEVKIT-48). Sirve para no discutir el peso
de la imagen de memoria: cada retiro se decide con una cifra al lado.

**Dos cifras que no son la misma.** `docker image ls` dice 2,54 GB; la suma
de las capas de `docker history` da 1,90 GB. Los ~640 MB de diferencia no son
capas perdidas: Docker Desktop usa el almacén de imágenes de containerd
(`docker info --format '{{.Driver}} {{json .DriverStatus}}'` devuelve
`overlayfs [["driver-type","io.containerd.snapshotter.v1"]]`), que contabiliza
el blob comprimido *además* del contenido desempaquetado. El inventario real
por capa es el de `docker history`; los 2,54 GB son lo que ocupa en el disco
del Mac.

| # | Capa (`CREATED BY`) | Tamaño | Origen en `devkit/Dockerfile` |
|---|---|---|---|
| 1 | `# debian.sh --arch 'arm64' … 'trixie'` | 108 MB | `FROM debian:trixie-slim` |
| 2 | `RUN apt-get install …` | 194 MB | Paquetes de sistema |
| 3 | `RUN set -eux; arch=…` | 381 MB | gh, rclone, bws, starship, openvscode-server |
| 4 | `COPY /uv /uvx /usr/local/bin/` | 46,8 MB | `uv` y `uvx` desde la imagen de Astral |
| 5 | `RUN git clone … /opt/zsh/…` | 2,43 MB | Plugins de zsh |
| 6 | `RUN groupadd && useradd` | 53,2 kB | Usuario sin sudo |
| 7 | `RUN curl claude.ai/install.sh \| bash` | 224 MB | Claude Code CLI |
| 8 | `RUN … --install-extension …vsix` | 236 MB | Extensión Claude Code para el editor |
| 9 | `RUN uv python install … uv tool install …` | 710 MB | CPython, ruff, basedpyright |
| 10 | 9 × `COPY` de config y scripts | 143 kB | zshrc, starship, settings, entrypoint, scripts |
| 0 | `RUN mkdir -p ... && chown -R ... && chmod 700 ...` | 0 B | Puntos de montaje pre-creados (Dockerfile:98-101) |
| — | `ARG`, `ENV`, `USER`, `WORKDIR`, `ENTRYPOINT`, `CMD` | 0 B | Metadatos, no ocupan capa |
| | **Suma** | **1,90 GB** | |

**Desglose por herramienta.** `docker history` se detiene en la capa, y las
capas 3 y 9 agrupan varias herramientas en un solo `RUN`. Para abrirlas se
mide dentro de un contenedor de esa misma imagen con `du`. Cuidado con las
unidades: `du -h` reporta MiB y `docker history --human`, MB decimales; abajo
todo va convertido a MB para que cuadre con la tabla de arriba.

| Herramienta | Tamaño | Capa |
|---|---|---|
| Caché de `uv` (`~/.cache/uv`) | 308 MB | 9 |
| `basedpyright` | 284 MB | 9 |
| `openvscode-server` | 243 MB | 3 |
| Extensión Claude Code | 237 MB | 8 |
| Claude Code CLI | 224 MB | 7 |
| CPython 3.14 de herramientas | 96,5 MB | 9 |
| `rclone` | 78,6 MB | 3 |
| `git` (paquete apt más grande) | 50,8 MB | 2 |
| `gh` | 39,8 MB | 3 |
| `ruff` | 23 MB | 9 |
| `bws` | 11,5 MB | 3 |
| `starship` | 10,1 MB | 3 |

**Lo que el desglose encontró y `docker history` escondía:**

- **La caché de `uv` viaja en la imagen: 308 MB.** `uv` deja en
  `~/.cache/uv/archive-v0` una copia desempaquetada de lo que instala, y esa
  copia **no** está enlazada con hardlink a `~/.local/share/uv`: `find -printf
  '%n'` da 1 enlace en ambos lados y un `du` conjunto de las dos rutas suma
  677 MiB en vez de compartir bloques. Son dos copias completas y solo una se
  usa en runtime. Se recupera con `uv cache clean` **dentro del mismo `RUN`**
  que instala; en un `RUN` posterior la capa anterior ya fijó los bytes y no
  se recupera nada.
- **El binario de Claude Code va dos veces: 224 MB.** El mismo archivo de
  223 862 184 bytes, SHA-256 `7bf9f33a…`, está en `~/.local/share/claude/`
  (capa 7) y dentro de la extensión, en `…/resources/native-binary/claude`
  (capa 8). Inodos distintos y un enlace cada uno: dos copias reales, no una
  compartida.
- **`basedpyright` trae su propio Node: 207 MB de sus 284 MB.** De ahí,
  66 MB son cabeceras C para compilar addons nativos y 29 MB son sourcemaps
  (`pyright.js.map`, `pyright-langserver.js.map`), inútiles en un
  type-checker que solo se ejecuta.

Decisiones tomadas con estas cifras, y por qué de cada una, en la entrada de
DEVKIT-48 de `devkit/CHANGELOG.md`. Regla: solo sale lo que tenga cifra y
justificación; el resto se queda documentado con su cifra, para que la
siguiente discusión empiece donde terminó esta.

### 4.3 Volúmenes

Solo dos, ambos por proyecto:

| Volumen | Montado en | Contenido |
|---|---|---|
| `claude-<proyecto>` | `~/.claude` | Login, transcripciones, memoria, plugins, `settings.json` |
| `history-<proyecto>` | `/commandhistory` | Historial de shell |

Todo lo demás vive en la imagen o se regenera al arrancar: intérpretes de
Python, caché de `uv`, configuración de git, tokens.

`CLAUDE_CONFIG_DIR` apunta al volumen para que `~/.claude.json` no quede fuera.
Los puntos de montaje se pre-crean en la imagen con el usuario correcto.

Costo aceptado: cada rebuild vuelve a descargar Python y los paquetes.

### 4.4 Terminal, shell y editor

| Capa | Decisión |
|---|---|
| Terminal en el Mac | Terminal.app, macOS 26. Corre solo el comando `devkit`: el trabajo real pasa por el editor en el navegador o por `devkit shell` |
| Shell | zsh con `starship` en preset de símbolos de texto plano, `zsh-autosuggestions`, `zsh-syntax-highlighting` |
| Editor | openvscode-server (VS Code en el navegador), único editor del devkit desde DEVKIT-40. Extensiones versionadas en `devkit/vscode/extensions.toml` (nace con `Anthropic.claude-code`), resueltas contra Open VSX al construir y comprobadas contra `engines.vscode` frente a este mismo editor antes de instalarlas (sección 9.2) e instaladas por el `Dockerfile` con `ruff` y `basedpyright` desde `uv tool`. `devkit code <proyecto>` abre la URL con el token ya puesto; amenazas y mitigaciones en la sección 8.2. `chat.disableAIFeatures` en los ajustes desde DEVKIT-66, con la intención de apagar el chat integrado de VS Code porque el agente del devkit es Claude Code y dos paneles de chat compiten por la atención y por memoria del proceso de extensiones sin aportar nada. En esta build de openvscode-server (1.109.5) el ajuste no oculta el comando `Chat: Open Chat` de la paleta: limitación conocida, sin arreglo. Claude Code es una extensión aparte y no depende de él. `extensions.autoUpdate` y `extensions.autoCheckUpdates` en `false`: una actualización en caliente muere en cada `recreate` (el directorio de extensiones no está en un volumen) y rompería la reproducibilidad de la imagen, que es la que fija la versión exacta que corre |

Contexto portable entre agentes: `AGENTS.md` como fuente, skills en formato
Agent Skills, un servidor MCP de Notion cuya configuración se genera por
agente al arrancar.

Hasta DEVKIT-40 un multiplexor de terminal mantenía viva la sesión del humano
si cerraba Terminal.app. Se retiró: la terminal integrada del editor cubre el
mismo papel, con un periodo de gracia de reconexión de tres horas
(`reconnection-grace-time` en su log de arranque), y ni el bucle en segundo
plano ni las skills dependían de él. `devkit shell` sigue disponible para una
shell suelta, sin esa persistencia.

### 4.5 Notion

- Plugin oficial de Notion para Claude Code, instalado por script al primer
  arranque de cada proyecto.
- Autenticación OAuth. El puerto de retorno `54545` se publica en
  `127.0.0.1` del Mac para que la redirección del navegador llegue al
  contenedor. Una vez por proyecto; el token queda en `claude-<proyecto>`.
- Conexión interna de Notion para bash (DEVKIT-55): token tipo Access Token
  con acceso a la página "Ingeniería", secreto `notion_token` en Bitwarden.
  Lo usan `notion.sh`, `task-close.sh` y `task-block.sh`, para que cerrar o
  bloquear una card no cueste un agente: el plugin solo vive dentro de Claude
  Code. La API no cobra por llamada; su límite es de peticiones por minuto y
  sobra para este uso. Las skills que escriben contenido largo
  (`task-document`, `epic-plan`) siguen con el plugin.
- Plan Notion Business en cuenta personal. Idioma: español latino neutro.

Modelo de datos: tres bases de datos globales con relaciones, y vistas
filtradas por proyecto. Ver sección 7.

### 4.6 Flujo de trabajo

Ver sección 6. Resumen: Épicas y Tareas en dos niveles; el humano aprueba la
Épica y cada PR; los agentes planifican, ejecutan hijas en secuencia, abren
PRs con auto-merge y documentan al cerrar.

### 4.7 Branches y versionado

- Repo `dotfiles`: solo `main` protegida y ramas `<tipo>/DEVKIT-<n>-slug`
  (`feat/`, `fix/` o `chore/` según el Tipo de la card) que vuelven a `main`
  con squash.
- Sin branches de instancia. La instancia es el repo del proyecto.
- Etiquetas `vX.Y.Z` con Semantic Versioning adaptado: PATCH y MINOR son
  reemplazo directo; MAJOR exige tocar `devkit.env` o volúmenes y el changelog
  dice qué.
- `dotfiles` es el proyecto `DEVKIT` en Notion y se gestiona con el mismo
  flujo. Es la prueba de concepto del sistema.

### 4.8 Instanciación e independencia del host

- Sin `devcontainer.json` ni CLI de devcontainers: Docker Compose puro.
- Binarios elegidos por `uname -m`; base multi-arquitectura. Hoy solo Mac
  Apple Silicon.
- `new-project.sh` se descarga con `curl` y ejecuta todo lo demás dentro de
  contenedores.

### 4.9 Seguridad

Ver sección 8.

### 4.10 Mínimo viable

Ver sección 10.

## 5. Componentes

### 5.1 Repo `dotfiles`

```
devkit/
  Dockerfile
  compose.yaml            # contenedor de trabajo + proxy de salida
  entrypoint.sh
  proxy/                  # configuración del proxy y lista blanca base
  zsh/  starship.toml
  agents/
    AGENTS.template.md    # incluye la guía de redacción
    settings.json         # permisos de Claude Code
    skills/               # ver 5.3
  scripts/
    sync-sandbox.sh       # rclone cada minuto
    watch.sh              # revisión, corrección y cierre de PRs cada cinco minutos
    watch-test.sh         # casos de la tabla de decisión de watch.sh
    net-denied.sh         # destinos bloqueados por el proxy
    agents-sync.sh        # funde AGENTS.md con la plantilla nueva; la usa template-update
  VERSION                 # la lee new-project.sh para elegir la etiqueta
  CHANGELOG.md            # una entrada por etiqueta; la lee template-update
new-project.sh
docs/ARCHITECTURE.md
```

### 5.2 Repo de un proyecto

```
.devkit/
  devkit.toml              # única fuente: template, project, python, apt, domains
  roles.toml               # opcional: anula la tabla de roles del template para este proyecto
AGENTS.md                  # instrucciones del proyecto; Codex lo lee directo, sin importación
CLAUDE.md                  # una línea: @AGENTS.md
.claude/skills -> enlace al template clonado en el contenedor
sandbox.local/             # ignorado por git, respaldado en Dropbox
```

La raíz queda libre de archivos del entorno salvo los que las herramientas
obligan a tener ahí: `AGENTS.md` porque Codex lo lee sin mecanismo de
importación, `CLAUDE.md` porque Claude Code no permite reubicarlo, y
`.claude/` porque tampoco admite moverse (DEVKIT-53). Todo lo demás que el
devkit necesita vive en `.devkit/`, versionado junto con el resto del repo.

`devkit.toml` es plano: una sola tabla `[devkit]`, valores string o lista de
strings en una línea. Se lee con expresiones regulares, no con un parser de
TOML, porque lo leen scripts POSIX (`entrypoint.sh`, `devkit.sh`) sin esa
dependencia.

```toml
[devkit]
template = "0.1.0"           # versión del template (obligatorio)
project  = "DATA"            # código del proyecto en Notion (obligatorio)
python   = "3.13"            # opcional; el arranque exporta UV_PYTHON
apt      = ["libpq-dev"]     # opcional; paquetes de sistema extra
domains  = ["api.ejemplo.com"]  # opcional; dominios extra para el proxy
reviewer = "usuario"         # opcional; usuario de GitHub que aprueba los PRs
```

Regla de reparto entre el repo y el Mac: al repo va lo que cualquiera
necesita para reconstruir el proyecto igual (versión del template, código de
Notion, versión de Python, paquetes apt, dominios, usuario que aprueba los
PRs); al Mac va solo lo personal e irreproducible. `reviewer` lo usa
`pr-review` para pedir el review; si falta, vale el dueño del repo cuando es
un usuario y no una organización. En `~/.devkit/<proyecto>/`:

- `devkit.env`: URL del repo, identidad git, remoto de Dropbox. Lo edita el
  humano una vez.
- `.env`: variables de interpolación de Compose (`DEVKIT_PROJECT`,
  `DEVKIT_VERSION`, y `DEVKIT_EXTRA_APT`/`DEVKIT_ALLOW_DOMAINS` copiados de
  `devkit.toml`). Es una copia derivada: `devkit.sh` la reescribe leyendo
  `.devkit/devkit.toml` del contenedor antes de `recreate`, `rebuild` o
  `update`; no se edita a mano.

Se descartó un archivo por parámetro (desorden) y `pyproject.toml` (ataría el
template a Python). Antes de `devkit.toml`, `DEVKIT_VERSION` y
`.python-version` vivían como archivos sueltos y el código de Notion se
insertaba con un placeholder en `AGENTS.md`: tres fuentes de verdad para
datos que un proyecto declara una sola vez (DEVKIT-6).

### 5.3 Skills

| Skill | Transición | Qué hace |
|---|---|---|
| `project-init` | Alta de proyecto | Fila en Proyectos, vistas filtradas, verificación |
| `epic-plan` | Épica en Lista | Descompone en hijas con orden y dependencias, las deja en Lista, publica el desglose como comentario |
| `task-create` | Nace en Backlog | Crea la card desde la plantilla |
| `task-start` | Lista → En progreso | Asigna agente, crea rama desde `main`, escribe URL de rama, comenta el plan |
| `task-submit` | En progreso → Revisión automática | Push, PR enlazando la card, auto-merge armado, URL de PR, comentario |
| `pr-review` | Revisión automática → Lista para merge, o se queda | Revisor independiente del autor: comprueba cada criterio ejecutando, lee el diff de forma adversarial, publica el informe en el PR con el marcador `devkit-review` y el bloque `devkit-findings`; con `OK` pide review al humano |
| `task-fix` | Revisión automática o Lista para merge → Revisión automática | Corrector del ciclo: lee el bloque `devkit-findings` del último informe `CAMBIOS` (o el comentario del humano como hallazgo único), un commit por hallazgo en la rama de la card, push, respuesta en el PR con el bloque `devkit-fixes` (`id | atendido o descartado | commit o motivo`) |
| `task-document` | Lista para merge, sin cambio de Estado | Escribe o actualiza la entrada de Documentación de la card (la encuentra por la relación `Tarea`) y deja el marcador `devkit-doc` del head en el PR; también la entrada consolidada de una Épica cerrada |
| `project-status` | En cualquier momento | Reconcilia cards con PRs mergeados, reporta cards huérfanas o inactivas |
| `template-update` | Mantenimiento | Sube `template` en `.devkit/devkit.toml`, funde `AGENTS.md` con la plantilla destino y actualiza Notion |
| `template-propagate` | Desde `DEVKIT` | Abre un PR de actualización en cada proyecto registrado |

Cerrar, bloquear y encadenar la siguiente hija no son skills sino scripts
bash (DEVKIT-55, DEVKIT-56), porque no toman ninguna decisión que necesite un
modelo:

| Script | Transición | Qué hace |
|---|---|---|
| `task-close.sh` | Lista para merge → Hecha | Verifica merge, `Hecha` y `Cierre`, comentario con enlace a la entrada de Documentación y las marcas de modelo del PR y del último informe (o lanza `task-document` si falta), marcador `devkit-closed` en el PR, cierra la Épica con la regla de DEVKIT-44 o llama a `task-next.sh` |
| `task-next.sh` | Siguiente hija: Lista → (task-start) | Elige la hija libre por `Depende de`, `Orden` y `Prioridad`, y la lanza con `devkit-run` si ninguna hermana está en curso. Lo llaman `watch.sh` al `OK` y `task-close.sh` al merge |
| `task-block.sh` | Cualquiera → Bloqueada | Comenta el estado anterior y qué necesita del humano; guarda `wip` si hay cambios sin commit |

`watch.sh` lanza cada skill de la tabla a través de `devkit-run.sh`, que
resuelve modelo y esfuerzo por el papel de la skill en el flujo (revisión o
implementación), no por el `Tipo` de la card: `roles.toml`
declara una lista `frontera` ordenada de modelos y cada rol el índice desde
el que empieza a buscar el primero disponible, con caída al siguiente si no
responde (DEVKIT-54). La sonda que decide si un modelo responde corre aislada
—directorio vacío, sin MCP y sin herramientas—; si no, hereda el contexto de
`/workspace` y deja de ser una sonda, al punto de pasarse del timeout y marcar
como caído al modelo que sí estaba disponible. Detalle completo en el README,
sección "Modelo, esfuerzo y costo por rol".

Desde DEVKIT-61, el rol de implementación puede además escalar por ronda:
`implementacion.rondas = ["sonnet:high", "sonnet:high", "opus:high"]` da
modelo y esfuerzo por posición. La ronda es 1 para `task-start` y
`task-submit`, y para `task-fix` y `task-document` es 1 más el número de
comentarios `devkit-fix` del PR de la card; pasada la lista, repite el último
elemento. `devkit-run` la lee del PR (URL en Notion o, si falta, `gh pr list
--head <rama>`), usa la ronda 1 si no puede leerlo y lo escribe en
`watch.log`, y anota `ronda=<n>` en la línea de resumen. El alias de la ronda
pasa por la misma sonda; si no responde, manda `model_index`. `--modelo`,
`--esfuerzo` y `DEVKIT_MODELO_FORZADO` siguen por encima.

La decisión es asimétrica a propósito. La implementación escala porque su
error es visible: un PR flojo vuelve con `CAMBIOS` y la ronda siguiente lo
corrige con un modelo más fuerte, así que el costo de empezar barato es, como
mucho, un ciclo más. La revisión no escala (`revision.rondas` se ignora con
aviso) porque su error es invisible: un revisor débil da un OK falso y nada en
el flujo lo detecta antes del humano. Es un experimento y no una regla:
DEVKIT-51 en Sonnet necesitó tres ciclos (evidencia de DEVKIT-54), y la
escalera se mide en las hijas de DEVKIT-43, pequeñas, comparando ciclos y
costo por card con las marcas de DEVKIT-58 antes de fijar el valor por
defecto. Se desactiva quitando `rondas`; detalle en el README, sección
"Escalera de modelos por ronda".

Una skill que necesite saber si otro agente ya ocupa el workspace pregunta con
`devkit-run --otros-agentes`, nunca con un `pgrep` sobre la Clave: la Clave
viaja en los argumentos del propio lanzador, así que un `pgrep` devuelve los
cuatro procesos del lanzamiento en curso como si fueran ajenos (DEVKIT-54).

Una skill invoca otro script por ruta,
`"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/<script>"`, y por eso
`devkit-run` exporta `DEVKIT_SCRIPTS_DIR` (su propio directorio) y
`DEVKIT_RUN_DIR` al `claude -p` que lanza (y, desde DEVKIT-58,
`DEVKIT_MODEL` y `DEVKIT_EFFORT`: ver 6.3), y `entrypoint.sh` exporta la
variable antes de arrancar `watch.sh` (DEVKIT-55). Sin eso, la variable solo
existía en `/run/devkit/env`, que carga la shell del humano; el respaldo
`/opt/devkit/scripts` es la copia de la imagen, que en modo dev queda atrás
del workspace, y el `task-start` que lanzó `task-close` el 2026-09-16 usó una
copia sin `frontera`, resolvió un modelo vacío y murió en el primer turno.
`devkit-run` tampoco lanza ya con un modelo vacío: sale con 65 y deja una
`ALARMA` en `watch.log`.

Qué hace cada agente se responde sin lanzar otro agente, con
`devkit-run --estado` (DEVKIT-57). La fuente es `watch.log`, no la lista de
procesos: todo lanzamiento, de `devkit-run` o de `run_skill` en `watch.sh`,
escribe antes una línea `<id> lanzando (origen=<quién>): "<prompt>"
log=<log>`, y su resumen final lleva el mismo `<id>`. Mirar solo procesos
falla en la ventana entre pedir un lanzamiento y que exista su `claude -p`
(candado, sonda de modelos, `nohup`): el 2026-09-16, `--agentes-vivos` dijo
"sin agentes vivos" dos segundos después de "lanzando pr-review". Con la
línea como origen, un lanzamiento está `en curso` desde que se pide, y uno
que nunca llegó a correr se ve como `no arrancó` en vez de desaparecer. El
cruce con `ps` y con los logs distingue el resto: `terminó`, `error` y
`bloqueada`, que toma el motivo de la línea que deja `task-block.sh`. Quién
lanzó lo declara el que llama con `DEVKIT_ORIGEN` (`bucle`, `task-close`);
si no, se deduce del primer `claude -p /<skill>` entre los procesos padre, y
sin ninguno es `humano`. La variable no pasa al `claude -p`: describe este
lanzamiento, no los que la skill haga después.

`devkit-run` en segundo plano ya no vuelve a ciegas. Espera el marcador
`/run/devkit/ready` del arranque, y tras el `nohup` espera hasta 5 s a su
worker: si muere sin resumen `terminado`, imprime el log y sale con error.
El caso de origen fue un `task-start` lanzado desde el editor recién abierto
que imprimió su PID y nunca corrió; el humano lo descubrió al ir a mirar.

`watch.sh` suma una quinta alarma: un `task-fix` que responde "nada que
corregir" o "informe desactualizado" con el último informe `CAMBIOS` sobre
el mismo head. El bucle no puede avanzar solo: no hay `devkit-fix` que
dispare otra revisión y `launched` impide relanzar el mismo fix. Se relanza
una vez con el siguiente modelo de `frontera`, porque la causa conocida es
el modelo (un task-fix en Haiku, DEVKIT-54), y si responde igual se bloquea
la card. Relanzar sin límite gastaría cuota en un ciclo que un humano
resuelve en un minuto.

## 6. Flujo de trabajo

### 6.1 Jerarquía

Dos niveles en la misma base de datos, con subelementos nativos de Notion:
Épica y Tarea. No hay tercer nivel.

### 6.2 Máquina de estados

Estados: Backlog, Lista, En progreso, Revisión automática, Lista para merge,
Hecha, Bloqueada. Entre `Revisión automática` y `Lista para merge` corre el
ciclo de revisor y corrector de DEVKIT-9: `watch.sh` lo orquesta leyendo los
marcadores del PR cada cinco minutos, o en segundos cuando la skill anterior
lo despierta con `/run/devkit/poke`, y el humano solo ve PRs que ya pasaron la
revisión.

| Paso | Quién | Qué pasa |
|---|---|---|
| La Épica nace en Backlog | Humano o agente | Objetivo y criterios de aceptación fijan el alcance máximo |
| Backlog → Lista en la Épica | Humano | Única aprobación de planificación |
| `epic-plan` | Agente | Hijas en Lista con orden y dependencias; desglose publicado como comentario |
| `task-start` en la primera hija libre | Agente | Rama `<tipo>/<CLAVE>-slug` desde `main` |
| `task-submit` | Agente | PR a `main` con auto-merge armado; card en `Revisión automática` |
| `watch.sh`: head sin informe | Máquina | Lanza `pr-review` headless. `OK`: card a `Lista para merge` y review pedido al humano. `CAMBIOS`: bloque `devkit-findings` en el PR |
| `watch.sh`: `CAMBIOS` para el head, sin respuesta | Máquina | Lanza `task-fix` headless: un commit por hallazgo, push, bloque `devkit-fixes`. El head nuevo vuelve a la fila anterior |
| `watch.sh`: `CAMBIOS` para el head, respuesta `devkit-fix` sin push (DEVKIT-22) | Máquina | Lanza `pr-review` de nuevo sobre el mismo head: juzga la respuesta con diff vacío. `OK` u otro `CAMBIOS`, igual que la fila anterior |
| Comentario en un PR en `Lista para merge` | Humano | `watch.sh` lanza `task-fix` con ese texto; la card vuelve a `Revisión automática` |
| `watch.sh`: `OK` para el head, sin marcador `devkit-doc` de ese head | Máquina | Lanza `task-document` headless: escribe o actualiza la entrada de Documentación antes del approve. Si un head nuevo recibe otro `OK`, corre de nuevo sobre la misma entrada |
| `watch.sh`: `OK` para el head | Máquina | Tras documentar, corre `task-next.sh`, que lanza `task-start` de la siguiente hija libre mientras el PR espera el approve (DEVKIT-56) |
| Tres ciclos respondidos sin `OK` y otro `CAMBIOS` sobre el head vigente | Máquina | `watch.sh` publica el marcador `devkit-block` en el PR y corre `task-block.sh`. No toca el PR hasta que el humano mueva la card a `Revisión automática` y comente |
| `watch.sh`: una skill muere por cuota agotada | Máquina | Anota la pausa en `watch.log` y relanza la misma skill al reiniciarse la ventana. La card no cambia de Estado: solo falta tiempo |
| Approve del PR | Humano | GitHub mergea con squash: un commit por card en `main` |
| `watch.sh`: PR mergeado sin marcador `devkit-closed` | Máquina | Bucle aparte, cada 30 s: corre `task-close.sh`, que cierra la hija en bash, deja el marcador `devkit-closed` en el PR y llama a `task-next.sh` para las hijas que esperaban este merge. `watch.log` registra los segundos desde el merge |
| Todas las hijas en Hecha | Automático | `task-close.sh` pasa la Épica a Hecha (regla de DEVKIT-44) y `task-document` escribe la entrada consolidada |

El bucle no guarda estado propio: decide con lo que hay en el PR. Cada
informe del revisor lleva `<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->`,
cada respuesta del corrector `<!-- devkit-fix sha=<head nuevo> review=<sha> -->`,
cada entrada de Documentación escrita `<!-- devkit-doc sha=<head> -->`,
cada bloqueo `<!-- devkit-block sha=<head> -->` y cada cierre
`<!-- devkit-closed sha=<merge commit> -->`. Los marcadores se reconocen
por su texto, no por su autor, para que valgan aunque el informe lo haya
publicado el humano desde otra sesión. Un comentario humano es cualquier
comentario o review sin marcador, de una cuenta distinta a la máquina y
posterior al último marcador; los approve no cuentan porque los consume el
auto-merge. La guardia cuenta ciclos, es decir, informes `CAMBIOS` que el
corrector ya respondió con su `devkit-fix`, posteriores al último `OK`, al
último bloqueo o al último `devkit-fix` con `manual=1`, lo que sea más
reciente: un rebuild no pierde nada y el humano reinicia el conteo con solo
retomar. Bloquea con tres ciclos solo si el último informe es `CAMBIOS` sobre
el head vigente (ver "Guarda de tres ciclos" más abajo). `/run/devkit/launched` (tmpfs) solo evita
relanzar la misma skill para la misma entrada dentro de una vida del
contenedor; como cada skill es idempotente, perderlo no daña la corrección de
lo que hay en Notion.

Un mismo head puede recibir más de un informe cuando `task-fix` responde a un
`CAMBIOS` sin empujar commits, por ejemplo si descarta todos los hallazgos
(DEVKIT-22). `pr-review` reconoce ese caso por un `devkit-fix` con `review=`
igual al `sha` de su marcador anterior y posterior a él, y vuelve a juzgar el
mismo head con esa respuesta a la vista en vez de terminar con "ya revisado".
La clave que `watch.sh` usa para no relanzar dos veces el mismo aviso incluye
la referencia (el `sha` del marcador o el propio head, según el caso), no
solo el head: si usara solo el head, la segunda llamada a `pr-review` se
perdería porque ya estaba marcada como lanzada desde la primera.

Sí daña la factura, y por eso el cierre también dejó de depender de él
(DEVKIT-24). `launched` nace vacío en cada `devkit recreate`, y la ventana de
48 h de la consulta de PRs mergeados vuelve a ofrecer todos los que ya se
cerraron: el 2026-09-08, el primer arranque del bucle nuevo reprocesó siete
PRs con card en `Hecha` antes de llegar al único pendiente, unos 3 USD y veinte
minutos de espera. La corrección es la misma idea que el resto del ciclo:
`task-close.sh` publica `<!-- devkit-closed sha=<merge commit> -->` en el PR al
terminar, y `watch.sh` omite los PRs mergeados que ya lo llevan. Se descartó
persistir `launched` en disco: guardaría en el contenedor un estado que ya
existe en GitHub, y no serviría en otra máquina ni tras un `devkit rebuild`.

La otra forma de perder trabajo no era una decisión equivocada sino una muerte
súbita: un `claude -p` que agota la cuota de la suscripción termina con código
distinto de cero y deja la card `En progreso` sin nadie trabajándola
(DEVKIT-27). El agente no puede arreglarlo, porque sin cuota ya no habla con el
modelo y ninguna skill corre; y Claude Code no ofrece
comando ni endpoint para consultar la cuota desde un script, ni hook para este
fallo. Lo único legible es el aviso del límite en el log de la skill, así que
quien reacciona es `watch.sh`, que es bash y sobrevive: `run_skill` reconoce el
aviso, lee la hora de reinicio (el `Claude AI usage limit reached|<epoch>` que
publica Claude Code, o la hora del texto para el humano, o una espera fija si
no hay ninguna), escribe `cuota agotada: <skill> en pausa hasta <hora UTC>` y
`cuota reanudada: relanzando <skill>`, y relanza la misma skill con el mismo
prompt y los mismos flags. La espera corre en segundo plano para que el bucle
siga atendiendo otros PRs, con un tope de intentos. La entrada de `launched` se
reescribe como `cuota:<clave>` mientras dura la pausa: sigue contando como
lanzada, así que el bucle no arranca una segunda copia, y vuelve a su forma
justo antes del relanzamiento, así que tampoco lo impide. Como el relanzamiento
puede despertar mientras el bucle atiende otro PR, `run_skill` toma un candado:
un solo `claude -p` a la vez sobre el workspace.

Se dejó fuera a propósito todo aviso: no se mueve la card a `Bloqueada` ni se
comenta en el PR. `Bloqueada` significa "necesita al humano", y aquí solo hace
falta tiempo; usarla obligaría al humano a devolver la card a mano. Y el PR no
sirve de canal porque una card puede morir antes de tener PR, y el mecanismo
debe valer igual para todas. Desde DEVKIT-55 ese segundo camino a Notion
existe (`notion.sh`, con su propio token), pero la razón de fondo no cambió:
una pausa por cuota no necesita al humano.

**Documentar al aprobar y cerrar en bash (DEVKIT-55).** La entrada de
Documentación se escribía al cerrar, cuando ya nadie la leía para revisar, y
el cierre corría en un agente entero solo porque el contenedor no hablaba con
Notion desde bash: entre el approve y la siguiente hija pasaban hasta cinco
minutos de tick más los minutos de un `claude -p` de 10 a 15 turnos, más la
espera del candado. Ahora `task-document` corre tras el `OK` del revisor
(`watch.sh` decide `documentar` cuando el último informe `OK` del head no
tiene su `devkit-doc`), así que la entrada existe antes del approve y se
reescribe si la revisión vuelve a abrir la card. El cierre es `task-close.sh`,
en un bucle propio de `watch.sh` cada 30 s: el bucle principal queda
bloqueado mientras corre una skill, y un merge en ese rato esperaba a que
terminara. `task-close.sh` no toma `skill.lock`, porque solo toca Notion y
GitHub; su limpieza de git sí lo intenta sin esperar y, si el workspace está
ocupado, la omite. Se descartó mantener el cierre en un agente con un modelo
más barato: seguía pagando el arranque de Claude Code y el candado, y no hay
ninguna decisión de alcance que tomar al cerrar.

**Encadenar la siguiente hija al OK, no al merge (DEVKIT-56).** Tras
DEVKIT-55 el cierre tardaba segundos, pero la Épica seguía detenida las horas
que tarda el approve humano: la siguiente hija solo arrancaba al merge. Ahora
`watch.sh` llama a `task-next.sh` en cuanto el último informe del head es
`OK`, y `task-close.sh` lo vuelve a llamar al merge. Qué hija puede arrancar
lo decide `Depende de`, que `epic-plan` llena con una regla mecánica: si dos
hijas tocan los mismos archivos, dependen. Una hija que depende espera a
`Hecha`, porque partir de un `main` sin el código de la otra la llevaría a un
conflicto de merge o a reescribir lo mismo; una que no depende arranca con la
anterior en `Lista para merge`.

No hay paralelismo ni worktrees, y no hacen falta: el papel lo cumple
`skill.lock`. Un solo `claude -p` trabaja el workspace a la vez; quien llega
segundo espera en fila. `task-start` parte de `main` actualizado y
`task-fix` hace checkout de la rama de su card, así que ninguno depende de la
rama en la que dejó el workspace el anterior. El costo aceptado: si el humano
comenta en el PR de A mientras B implementa, el `task-fix` de A espera a que
B termine. Para que la fila no crezca sin control, `task-next.sh` lanza una
sola hija a la vez: no lanza si una hermana está `En progreso` o `Revisión
automática`, ni si ya hay un `task-start` vivo para una hermana en `Lista`
(lanzado al OK, esperando el candado, cuando llega el merge). Se descartó
lanzar todas las hijas libres de golpe: varias ramas abiertas a la vez
multiplican los rebases y dejan al humano con varios PRs que aprobar sin
orden.

**Guarda de tres ciclos (DEVKIT-56).** Hasta DEVKIT-55 el bucle bloqueaba en
cuanto contaba tres `CAMBIOS` con respuesta, aunque el último fix hubiera
empujado un head que nadie había revisado. En el PR 38 (2026-09-16 06:23) el
humano relanzó `task-fix` a mano con Opus, ese fix subió un head nuevo y el
bucle bloqueó la card sin revisarlo; la única salida era reanudar, que cuesta
otro `task-fix` antes de la revisión. Ahora un ciclo es un `CAMBIOS`
respondido, y `bloquear` exige además que el último informe sea `CAMBIOS`
sobre el head vigente: un informe sobre un head superado no dice nada del
código actual. Un `task-fix` que no lanzó el bucle firma su `devkit-fix` con
`manual=1` y el conteo vuelve a cero, igual que con un `OK` o un bloqueo:
que el humano intervenga es una decisión explícita de darle otra vuelta. La
marca sale de `DEVKIT_LANZADOR=watch`, que `run_skill` pasa solo a lo que
lanza el bucle; `devkit-run` la borra al lanzar en segundo plano, para que
un `claude -p` del bucle que lanza otra skill no la herede. Se descartó leer
la marca `anulación manual` de `watch.log`: vive en tmpfs, se pierde en un
rebuild y la decisión del bucle sale solo de los marcadores del PR.

`/run/devkit/poke` es el otro archivo del bucle en tmpfs, y tampoco guarda
estado (DEVKIT-26): `task-submit` y `task-fix` lo tocan al terminar, `watch.sh`
duerme en tramos de cinco segundos en vez de un `sleep` seguido y despierta en
cuanto aparece, y lo borra antes de consultar GitHub para no perder un aviso
llegado durante la consulta. Solo adelanta el reloj entre dos vueltas: no salta
la guarda de `launched` y la decisión sigue saliendo de los marcadores del PR,
así que el revisor sigue naciendo en un proceso sin memoria del autor y el
autor sigue sin decidir cuándo lo revisan. Por eso se descartó que
`task-submit` invocara `pr-review` como skill: compartiría su conversación y
rompería esa independencia. Perder el aviso no rompe nada, solo devuelve la
espera al intervalo completo, y por eso las skills lo tocan sin comprobar el
resultado ni reintentar. El comando que prescriben es `touch /run/devkit/poke`
a secas, sin redirecciones ni `|| true`, porque la regla de `allow` en
`settings.json` es de coincidencia exacta: cualquier añadido la dejaría fuera y
el humano tendría que aprobar el aviso en cada corrida interactiva.

Reglas:

- El humano puede vetar en cualquier momento moviendo una hija a Backlog o
  Bloqueada. La revisión del desglose es asíncrona.
- Si el agente descubre una necesidad dentro del alcance, crea una hija nueva
  y lo comenta. Si excede los criterios de aceptación, crea una Épica en
  Backlog.
- Cada hija sale de `main` y vuelve a `main`. No hay rama por Épica.
- Una card activa por sesión en el mínimo viable.
- Sin una card en `En progreso` sobre la rama actual, la sesión interactiva
  no edita código: revisa, crea cards, comenta y documenta. La regla vive en
  `AGENTS.md` (sección "Cómo se trabaja aquí"). Razón: con el ciclo de
  revisor y corrector andando, un cambio hecho a mano desde la sesión web se
  salta la revisión independiente y no deja rastro en Notion. La excepción es
  una autorización expresa del humano en la conversación.

### 6.3 Trazabilidad

La Clave de la card aparece en la rama, en el ámbito de cada commit con
Conventional Commits, en el título del PR y en la entrada de Documentación.

```
Rama:    feat/DATA-42-carga-incremental
Commit:  feat(DATA-42): agregar carga incremental por fecha
PR:      DATA-42 Carga incremental por fecha
```

Cada artefacto dice además con qué modelo y esfuerzo se produjo (DEVKIT-58):
el cuerpo del PR (`Implementado con <modelo>, esfuerzo <x>`, de
`task-submit`), cada informe `devkit-review` (`Revisado con ...`, debajo del
marcador), la entrada de Documentación (sección "Modelos", con las anteriores
y `Documentado con ...`) y el comentario de cierre de la card, donde
`task-close.sh` copia la de implementación y la del último informe. Los
valores salen de `DEVKIT_MODEL` y `DEVKIT_EFFORT`, que `devkit-run` exporta al
`claude -p` con lo que lanzó de verdad; `roles.toml` no sirve de fuente
porque dice qué se pretendía lanzar, no qué corrió tras la caída en
`frontera` o una anulación manual. `watch.log` ya tenía el dato, pero vive en
tmpfs y se pierde en cada `devkit recreate`: la marca en el PR y en Notion es
la que queda para decidir si un modelo más barato alcanza para un papel del
flujo. `task-close.sh` es bash y no tiene marca propia: copia las ajenas y
dice "sin marca" cuando faltan, en vez de deducirlas.

`devkit-run --estado` suma un bloque `Consumo` (DEVKIT-62) con el porcentaje
de cuota del plan en vivo, sesión y semana, y la hora de la lectura. Antes de
programarlo, la card comprobó con la CLI instalada si existía una fuente
oficial legible por script: sí existe, `claude -p "/usage" --output-format
json` devuelve en el campo `result` el mismo texto que `/usage` en una sesión
interactiva, como comando local que no gasta turnos ni cuota
(`duration_api_ms=0`). No hay un campo numérico estructurado, así que
`--estado` lo extrae de ese texto con una expresión regular, aislado (sin
MCP, directorio vacío) y con `--no-session-persistence` para no dejar una
sesión propia en `~/.claude/projects/`, igual que la sonda de modelo de 5.3.
Es una cifra oficial, no una estimación desde `watch.log`: si la CLI no
responde o cambia ese texto, el bloque lo dice en vez de calcular algo
distinto.

Esa lectura tarda ~1.3 s, y la revisión de DEVKIT-62 midió que llamarla en
línea rompía el criterio de que `--estado` responda bajo un segundo. Por eso
`--estado` nunca la espera: lee `$RUN_DIR/cuota.cache` (última lectura, con su
hora) y, si venció `DEVKIT_CUOTA_TTL` (60 s) o no hay ninguna todavía,
dispara un refresco en segundo plano (candado en `$RUN_DIR/cuota.lock`, para
no correr dos a la vez) y sigue sin esperarlo. La primera vez que corre, sin
caché, el bloque dice que va a refrescar en vez de mostrar una cifra. El
refresco corre con su entrada y salida cerradas (`</dev/null >/dev/null
2>&1`): sin eso hereda las del llamador, y leer `--estado` por un pipe o
`$(...)` quedaba atado igual al refresco, el mismo problema que el TTL
resolvía para la línea de comandos (H3 de pr-review en DEVKIT-62).

## 7. Modelo de datos en Notion

Tres bases de datos bajo un árbol "Ingeniería".

**Proyectos**: nombre, código corto como `DATA`, repo en GitHub, versión del
template, estado, fecha de creación.

**Tareas**: título, ID único de Notion, Clave como fórmula que concatena el
código del proyecto relacionado con el número del ID, estado, proyecto como
relación, padre e hijas como subelementos, orden, depende de, agente con
valores claude, codex o humano, tipo con valores feature, bug o chore,
prioridad, rama como URL, PR como URL, fecha de cierre. Plantilla de card con
tres secciones: objetivo, criterios de aceptación, notas. Los comentarios de
avance van en los comentarios nativos de la card.

**Documentación**: título, proyecto y tarea como relaciones, rama y PR como
URL, tipo con valores cambio, decisión o runbook, fecha. Cuerpo con secciones
fijas: qué cambió, por qué, cómo probarlo, cambios requeridos, enlaces.

Los huecos en los IDs no significan cards perdidas. Una card perdida se detecta
por estado y tiempo con una vista filtrada y con `project-status`.

## 8. Seguridad

### 8.1 Credenciales

| Credencial | Dónde vive | Alcance mínimo | Cómo entra |
|---|---|---|---|
| Token de Bitwarden, secreto cero | `~/.devkit/bws-token` en el Mac, 600 | Lectura del proyecto `devcontainers` | Archivo con `secrets:` de Compose |
| Token de Claude | Bitwarden | Suscripción Max. `claude setup-token`, doce meses | `CLAUDE_CODE_OAUTH_TOKEN` al arrancar |
| Token de GitHub de la cuenta máquina | Bitwarden | Alcances `repo` (contenido y PRs en escritura) y `read:org` (`gh pr edit --add-reviewer`, que usa `pr-review` para pedir el review al humano, lo exige incluso fuera de una organización); caduca en un año | `GH_TOKEN` y `gh auth setup-git` |
| Token de Dropbox | Bitwarden | App propia con acceso "App folder": solo `/Apps/devkit` | `rclone.conf` generado al arrancar |
| Notion | Volumen `claude-<proyecto>` | Páginas autorizadas en OAuth: el árbol "Ingeniería" | Plugin oficial, puerto en `127.0.0.1` |
| Token de Notion para bash (`notion_token`) | Bitwarden | Conexión interna, tipo Access Token, con acceso solo a la página "Ingeniería" | Archivo `/run/devkit/notion_token`; `notion.sh` lo pasa a `curl` por descriptor, nunca por argumento ni variable de entorno. `pr-guard.sh` bloquea leer la ruta |
| Token del editor VS Code, por proyecto | Bitwarden | Solo abre el editor; el panel hereda los mismos permisos del contenedor, no es un shell aparte | Archivo `/run/devkit/vscode-token`, `--connection-token-file` |

Los secretos obtenidos de Bitwarden se escriben en un directorio `tmpfs` con
permisos 600. Nunca en la imagen ni en un volumen. El secreto cero entra como
archivo, no como variable de entorno, porque las variables se heredan por cada
proceso y aparecen en `docker inspect`.

### 8.2 Controles técnicos

- Regla de protección de `main` en cada repo: PR obligatorio, una aprobación,
  aprobación invalidada por push posterior, sin force push, sin borrado.
  Aplica también al propietario.
- Cuenta máquina de GitHub separada: distingue lo que hizo el humano de lo
  que hicieron los agentes. No es administradora.
- Sin `sudo` en la imagen.
- `settings.json` de Claude Code: comandos denegados como force push, push a
  `main` y lectura del directorio de secretos; comandos rutinarios permitidos.
  El bucle headless lanza cada skill con una lista fija de herramientas
  (`--allowedTools`); las negaciones de `settings.json` siguen aplicando,
  porque una negación gana a cualquier permiso.
- Hook `PreToolUse` (`devkit/scripts/pr-guard.sh`) para `Bash`: las reglas
  `deny` de `settings.json` son prefijos exactos, así que un comando
  reordenado o compuesto las evade (`gh pr review 42 --approve`, `git -C
  <dir> push origin main`, `gh api` crudo sobre `/pulls/*/reviews` o
  `/pulls/*/merge`, `gh api graphql`, `gh alias set`). El hook recibe el
  comando completo por `stdin` y lo busca en cualquier posición: sale con
  código 2 y un mensaje si encuentra aprobar un PR, mergearlo sin `--auto` o
  con `--admin`, empujar a `main` o una mutación de GraphQL que apruebe o
  mergee. Las reglas `deny` siguen igual, como segunda barrera si el hook
  falla. Es una inspección de texto sobre el comando tal como Claude lo
  escribió, no una sandbox que evalúe qué ejecuta bash: una variable
  (`git push origin $RAMA`), un alias de `gh` o una API nueva que el hook no
  conozca lo evaden. Por eso reduce las evasiones accidentales o perezosas,
  no las garantiza; la compuerta que sí sostiene la regla es la de abajo, el
  ruleset de GitHub y la cuenta máquina sin permiso de aprobar.
- Proxy de salida con lista blanca. Lista base en el template; dominios del
  proyecto en `devkit.env`; interruptor de red abierta por sesión para
  depurar; `net-denied.sh` muestra los destinos bloqueados.
- Editor VS Code (`openvscode-server`) publicado solo en `127.0.0.1` del Mac,
  nunca en una interfaz pública, y gateado por un token de conexión: sin él
  la URL no abre (`403`). El token nunca se escribe en una card, un
  comentario ni un log; solo `devkit code <proyecto>` lo lee, en el Mac, y lo
  arma en la URL. Si el archivo `/run/devkit/vscode-token` no existe al
  arrancar, el servidor simplemente no arranca: no se inventa un token.
  Dentro del panel, las mismas reglas `deny` de `settings.json` siguen
  aplicando (un `git push origin main` desde su terminal integrada lo
  rechaza igual que desde cualquier shell del contenedor), y una extensión de
  terceros instalada ahí corre con los mismos permisos del contenedor, sin
  escalar privilegios: no hay `sudo` en la imagen.
- Extensión `GitHub.vscode-pull-request-github` en el editor (DEVKIT-68):
  deja al humano revisar, comentar y aprobar PRs desde `127.0.0.1:3000` sin
  cambiar de pestaña. Amenaza: si su token de GitHub quedara legible en el
  disco del contenedor, un `claude -p` de ese mismo contenedor podría
  aprobar PRs con la identidad del humano y saltarse la compuerta humana.
  Verificado el 2026-09-17: en disco, `grep -rIl -e 'gh[opsu]_' -e
  'github-authentication' ~/.openvscode-server/` no encuentra el token en
  claro (solo coincide con el nombre del proveedor en código de extensión y
  en `remoteexthost.log`); no existe ningún `*.vscdb` ni archivo
  `*secret*`/`*token*` bajo ese directorio. Login por el proveedor de
  autenticación de GitHub de VS Code, no por el `gh` de la imagen;
  `github.com` y `api.github.com` ya estaban en la lista blanca del proxy,
  sin dominios nuevos.
  En memoria la mitigación es parcial: mientras el humano tiene sesión
  abierta, el extension host (`bootstrap-fork --type=extensionHost`, mismo
  usuario `dev`) sostiene el token para llamar a la API de GitHub, y
  `/proc/<pid>/mem` es legible por cualquier otro proceso `dev` del mismo
  contenedor (`ptrace_scope` en 0). Un `claude -p` headless corriendo ahí
  podría, en teoría, leer ese token y aprobar PRs con la identidad del
  humano. Riesgo residual aceptado, no una card de seguimiento: es el mismo
  problema de fondo que cualquier credencial del contenedor (por ejemplo el
  token de `gh` en el entorno de cualquier proceso), porque el contenedor no
  aísla procesos entre sí; resolverlo exigiría sandboxing por agente, fuera
  del alcance de esta card.

Riesgo residual aceptado: el túnel por DNS. Ningún enfoque casero lo cierra.

Riesgo residual aceptado: sin aislamiento de procesos entre agentes del
mismo contenedor, cualquier credencial que un proceso sostenga en memoria
(el token de la extensión GitHub Pull Requests, el de `gh`, el de Notion) es
legible por otro proceso del mismo usuario. Corregirlo exige sandboxing por
agente; no hay card abierta para eso todavía.

### 8.3 Caducidad

Los tokens de Claude y GitHub duran doce meses como máximo. El arranque falla
con mensaje claro si alguno es inválido. Bitwarden guarda la fecha de
vencimiento en la nota de cada secreto.

## 9. Versionado y propagación

- El proyecto declara la versión que quiere en `.devkit/devkit.toml` (clave
  `template`), dentro del repo. `.env` en el Mac guarda la versión de imagen
  con la que Compose arrancó hoy (`DEVKIT_VERSION`): son dos cosas distintas
  a propósito, porque `.env` tiene que existir antes de que el repo se
  clone.
- Al arrancar, el contenedor clona `dotfiles` en la etiqueta de `.env` dentro
  de sí mismo y crea enlaces simbólicos hacia el workspace. Se reconstruye en
  cada arranque y nunca se edita.
- El bootstrap descarga el tarball de esa etiqueta para construir la imagen.
- Al arrancar, `entrypoint.sh` compara `template` de `.devkit/devkit.toml` contra
  `DEVKIT_VERSION` de `.env` y avisa si difieren: el repo pide una versión
  que la imagen todavía no tiene.
- `devkit update <proyecto>`, desde el Mac, lee `template` del contenedor
  (`docker exec ... cat /workspace/.devkit/devkit.toml`), descarga esa versión,
  actualiza `.env` y reconstruye. Así `.env` se pone al día con lo que el
  repo ya declaraba.
- `template-propagate`, desde `DEVKIT`, abre un PR en cada proyecto
  registrado en Notion que cambia `template` en su `.devkit/devkit.toml`. El
  humano aprueba, el auto-merge hace el resto; `devkit update` en cada
  proyecto aplica el cambio en el Mac.
- Para `DEVKIT`, el clon de `dotfiles` es su workspace: ahí los cambios se
  prueban en vivo antes de etiquetar, con `template = "dev"` en su propio
  `.devkit/devkit.toml`.
- `template-update` y `template-propagate` también funden `AGENTS.md` con la
  plantilla destino, con `devkit/scripts/agents-sync.sh` (DEVKIT-28).
  `AGENTS.template.md` declara
  el marcador `## Reglas del proyecto`: todo lo de arriba es del template,
  todo lo de abajo es del proyecto. Con el marcador presente, la fusión es
  mecánica (reemplazar texto por encima de una línea fija) y se aplica sola,
  sin que ningún agente tenga que interpretar contenido libre para decidir
  qué conservar. Sin el marcador —proyectos de antes de esta convención, o
  que lo hayan borrado— no hay límite confiable entre lo que es del template
  y lo que escribió el proyecto: aplicar la plantilla ahí podría borrar
  contenido sin que nadie lo note antes del merge, así que el script no
  toca el archivo y deja el diff en el PR para que lo funda un humano.

Descartado: bind mount del clon local con enlaces simbólicos. Rompe el host
mínimo, elimina las versiones y no tiene radio de impacto controlado.

### 9.1 Modo dev: dos canales, no uno

En modo dev el workspace es el template, pero llega al contenedor por dos
caminos con latencias distintas, y confundirlos costó dos cards dadas por
hechas (DEVKIT-21 y DEVKIT-23, verificado el 2026-09-11):

| Canal | Qué viaja | Cuándo se activa |
|---|---|---|
| Lectura en vivo | `entrypoint.sh` (re-exec), `scripts/` (`SCRIPTS_DIR`), `agents/` (enlaces simbólicos) | Al recrear el contenedor, o al instante en el caso de `agents/` |
| Imagen | `Dockerfile`, `zsh/`, `proxy/`, `vscode/` | Solo al reconstruir la imagen |

El contexto de build de Compose es `~/.devkit/<proyecto>/template/`, una copia
que `new-project.sh` baja una vez y que `devkit update` reemplaza por la
etiqueta destino. En modo dev no hay etiqueta, así que nadie la refrescaba: la
imagen se reconstruía con el template del día de la instalación aunque el
workspace ya tuviera el cambio mergeado, y el arranque avisaba de todo menos de
eso.

Decisión: en modo dev, `devkit up`, `recreate` y `rebuild` rearman el contexto
con `docker cp devkit-<proyecto>:/workspace/devkit/. template/` antes de
construir. La alternativa era montar el workspace como contexto de build, y no
es posible: `/workspace` vive dentro del contenedor, no hay bind mount desde el
Mac (decisión 4.1, el código no vive en el host), así que no existe una ruta
del Mac que Compose pueda usar de contexto. `docker cp` es la única vía, y
tiene el efecto correcto: copia lo que hay en el contenedor, que es la rama
mergeada del propio repo. Si el contenedor no responde, se avisa y se
construye con la copia existente: sin contenedor no hay workspace del que
copiar, y fallar dejaría al humano sin poder levantar nada.

Para que la asimetría deje de engañar, `entrypoint.sh` compara en cada arranque
el `devkit/` del workspace con `/opt/devkit/image`, la copia de lo que entró
por imagen, y avisa: `hay cambios que requieren devkit recreate: <qué>`. La
lista de qué es "solo por imagen" y la comparación viven en
`scripts/image-drift.sh`, con autoprueba (`--test`), para que no se dupliquen
entre el `Dockerfile` y el arranque.

Fuera de modo dev nada de esto corre: el contexto sigue siendo la copia de la
etiqueta, que es lo que hace reproducible una versión.

### 9.2 Versionado de extensiones del editor

Hasta DEVKIT-67 la única extensión (Claude Code) iba fija en un `ARG` del
`Dockerfile`; actualizarla era editarlo a mano. `devkit/vscode/extensions.toml`
la reemplaza como fuente: una línea por extensión, con versión fija o
`"latest"`.

- `devkit up`, `recreate`, `rebuild` y `update` (`resolve_extensions` en
  `devkit.sh`) resuelven cada `latest` en el Mac contra
  `https://open-vsx.org/api/<ns>/<ext>/latest` (campo `version`) antes de
  construir, después de que el contexto de build ya tiene la versión correcta
  de `extensions.toml` (tras `sync_dev_template` en modo dev, o tras bajar la
  etiqueta destino en `update`). Una versión fija no vuelve a resolverse.
- La resolución queda en `~/.devkit/<proyecto>/extensions.lock` (una entrada
  `ns.ext=versión` por línea) y se pasa a Compose como `DEVKIT_EXTENSIONS`, el
  mismo mecanismo que `DEVKIT_EXTRA_APT`: el `Dockerfile` la recibe como
  `ARG EXTENSIONS` con versiones exactas, nunca `"latest"`, así que dos builds
  con la misma resolución cachean la capa de extensiones y una resolución
  distinta la invalida, como cualquier otro `ARG`. Ese `ARG` se declara justo
  antes de su `RUN`, no arriba con los demás: Docker mete todo `ARG` en el
  entorno de cada `RUN` posterior a su declaración, y declararlo arriba
  invalidaría la caché desde el primer `RUN` (apt, gh, rclone, zsh, claude...)
  con cada versión nueva. Con la declaración movida, solo se rehacen esta capa
  y las que la siguen (el `RUN uv python install` de 4.2), no la imagen
  entera.
- Sin red en el Mac, se usa la última resolución guardada en `extensions.lock`
  y se avisa; sin red y sin resolución previa, el comando se detiene con un
  mensaje claro en vez de construir a ciegas o con una versión implícita. Un
  5xx de Open VSX se reintenta (`curl --retry 5 --retry-delay 3`, que ya
  trata un 5xx como error transitorio sin necesitar `-f`) antes de rendirse;
  agotados los reintentos se distingue igual de "sin red", porque si llegó a
  responder con un código sí hay red hasta Open VSX (H8, DEVKIT-67).
- El `Dockerfile` prueba primero el paquete de la plataforma del build
  (`linux-x64` o `linux-arm64`, que Open VSX no publica para todas las
  extensiones) y si no existe instala el universal, en un solo paso para
  todas las extensiones del argumento. Solo el `curl` del paquete universal
  suma `--retry-all-errors` a `--retry 5 --retry-delay 3 -f`: ahí un corte de
  conexión a mitad de descarga debe reintentarse porque no hay más
  alternativas (DEVKIT-73: un 503 intermitente de Open VSX tumbó un build a
  medias). El `curl` del paquete de plataforma se queda solo con `--retry 5
  --retry-delay 3 -f`, así que un 404 (esperado, no lo publican todas) cae al
  universal sin reintentar y un 5xx sí reintenta antes de rendirse; con
  `--retry-all-errors` ahí también, el 404 esperado se habría reintentado en
  vano.
- La lista de extensiones y versiones del README y de la entrada "Stack y
  comandos del devkit" en Notion sale de `extensions.toml` con
  `devkit/scripts/gen-stack.sh`, que también verifica el README (`--check`):
  un `"latest"` se lista tal cual, sin resolver, porque esa resolución solo
  existe en el Mac de quien construye, no en el repo.
- DEVKIT-73: cada extensión (fija o `latest`) se comprueba además contra
  `engines.vscode` en Open VSX frente a `ARG OPENVSCODE_VERSION` del
  `Dockerfile`, la única fuente de la versión del editor (`resolve_extensions`
  la lee de ahí, no la duplica). Antes de esta card, una versión que exigía un
  VS Code más nuevo del que trae la imagen tumbaba el build a mitad del
  `Dockerfile`, con el error de `openvscode-server --install-extension`, no
  antes de empezar. `engines.vscode` en Open VSX solo usa dos formatos:
  `^X.Y.Z` (semver de npm: admite desde X.Y.Z hasta antes de (X+1).0.0) y
  `>=X.Y.Z`; cualquier otro se acepta con aviso, no se rechaza. Si `latest` no
  calza, se recorre `allVersions` de la respuesta de `/latest` (solo
  versiones estables `X.Y.Z`, de la más nueva a la más vieja) consultando
  `/api/<ns>/<ext>/<versión>` hasta encontrar la primera compatible, con un
  aviso de cuál se usó en su lugar; si ninguna calza, se detiene. Si una
  versión fija no calza, se detiene con el rango exigido y una sugerencia de
  cuál sí calza, sin construir a ciegas. Sin red para este chequeo, una
  versión fija se instala sin comprobar, igual que antes de esta card.

## 10. Mínimo viable

### 10.1 Dentro

Imagen, Compose con proxy, arranque completo, editor integrado con Claude Code
(ver 4.4), `AGENTS.md` y `settings.json`, las diez skills, las tres bases de
datos de Notion, `new-project.sh`.

### 10.2 Fuera, en orden de probable llegada

Codex en el hueco de agente, worktrees para varias cards en paralelo, imagen
preconstruida por etiqueta en el registro de GitHub, cierre por GitHub Actions,
firma de commits, `mise` para otros lenguajes, Copier si el template necesita
variables internas, pruebas en amd64, Claude Squad como orquestador.

### 10.3 Configuración manual, una sola vez

- Bitwarden: organización gratuita, Secrets Manager, proyecto `devcontainers`,
  una cuenta máquina, token guardado en `~/.devkit/bws-token`.
- GitHub: cuenta máquina, token de permisos finos, regla de protección de
  `main` y auto-merge activado en cada repo, borrado automático de ramas.
- Dropbox: app con acceso "App folder", autorización de `rclone` una vez.
- Claude: `claude setup-token`.
- Notion: árbol "Ingeniería" con las tres bases de datos y la plantilla de
  card; autorización del plugin por proyecto.

### 10.4 Orden de construcción

1. **Cinco pruebas de riesgo**, una hora cada una como máximo:
   - OAuth de Notion a través del puerto publicado.
   - Integración del editor con Claude Code, con `CLAUDE_CONFIG_DIR` en volumen.
   - `rclone` con la app de Dropbox sin navegador.
   - `claude -p` headless con el token de Max y el MCP de Notion.
   - Todas las herramientas hablando a través del proxy.
2. Imagen, Compose y arranque sin Notion.
3. Notion y skills.
4. Bucles y compuertas; prueba completa sobre `DEVKIT`.
5. Etiqueta `0.1.0` e instanciación del primer proyecto personal.

### 10.5 Arranque inicial

La versión `0.1.0` se construye en una rama de `dotfiles` con Claude Code en
la web, sin instalar nada en el Mac. Tras el PR y la etiqueta, en el Mac:

```sh
mkdir -p ~/.devkit && chmod 700 ~/.devkit
# pegar el token de Bitwarden en ~/.devkit/bws-token y chmod 600
curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/new-project.sh | sh -s -- devkit
```

El script descarga el tarball de la etiqueta, construye la imagen, crea los
volúmenes y levanta el contenedor. Dentro, `dotfiles` ya es el workspace. En
el Mac no queda ningún clon.

### 10.6 Publicación de 0.1.0

Etiqueta `v0.1.0` publicada el 2026-09-06 sobre `e74b770`, el commit de `main`
que fija `devkit/VERSION` en `0.1.0` (DEVKIT-3). Es una etiqueta anotada,
creada y empujada directo al remoto sin PR: una etiqueta no es contenido
revisable y el ruleset de `main` no la cubre. Lo que sí pasa por PR es esta
sección (DEVKIT-4).

Comprobaciones hechas desde el contenedor del proyecto `DEVKIT`. Las tres
consultan lo mismo que `new-project.sh` cuando corre sin `--version`:

```sh
# 1. La etiqueta existe y apunta al commit correcto.
gh api repos/byroncz/dotfiles/git/refs/tags/v0.1.0 --jq '.object.sha'
# 256cada… (objeto de etiqueta anotada); resuelve al commit con:
gh api repos/byroncz/dotfiles/git/tags/256cada162d9e8e92fd33587ce60a94b69372aff --jq '.object.sha'
# e74b770b97a644595f3df63a0e64f8612d03ee2b

# 2. La versión por defecto que lee new-project.sh (línea 34).
curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/devkit/VERSION
# 0.1.0

# 3. El tarball que arma new-project.sh (línea 35) existe y responde.
curl -fsSLI https://github.com/byroncz/dotfiles/archive/refs/tags/v0.1.0.tar.gz
# HTTP 200, Content-Disposition: attachment; filename=dotfiles-0.1.0.tar.gz
```

Claude Code pide aprobación humana para `curl` y en modo autónomo no hay
quien la dé, así que 2 y 3 se verificaron con `gh api`, que llega a los
mismos datos por el mismo proxy: `gh api -H "Accept: application/vnd.github.raw"
"repos/byroncz/dotfiles/contents/devkit/VERSION?ref=main"` devolvió `0.1.0`
y `gh api --silent -i https://github.com/byroncz/dotfiles/archive/refs/tags/v0.1.0.tar.gz`
devolvió `HTTP/2.0 200 OK` con `filename=dotfiles-0.1.0.tar.gz`. Ese nombre
importa: `new-project.sh` busca `devkit/` a profundidad 2 dentro del tarball
(`dotfiles-0.1.0/devkit`), y ahí está.

Queda pendiente, como acción manual en el Mac, instanciar el primer proyecto
personal con el comando de 10.5.

## 11. Guía de redacción para agentes

Aplica sin excepción a descripciones, comentarios, respuestas, PRs y entradas
de Documentación. Se incluye en `AGENTS.md` y toda skill que escriba texto la
referencia.

- Español latino neutro.
- Conciso, simple, autoexplicativo y pedagógico. Escrito para un ingeniero de
  datos de primer año que llega hoy al proyecto.
- Respeta los tecnicismos y las definiciones.
- Posición crítica, técnica y con evidencia contrastada cuando se toma una
  decisión.
- Profundidad proporcional al artefacto:

| Texto | Longitud | Contenido |
|---|---|---|
| Comentario de avance en una card | Dos a cuatro líneas | Qué se hizo y qué sigue |
| Descripción de PR | Secciones fijas y cortas | Qué cambia, cómo probarlo, enlace a la card |
| Entrada de Documentación | Completa | El porqué de cada decisión, con evidencia |

La justificación de una decisión se escribe una vez, en la entrada de
Documentación, y los demás textos enlazan a ella.

## 12. Costos y riesgos aceptados

| Riesgo | Mitigación |
|---|---|
| Trabajo no committeado fuera de `sandbox.local` se pierde con `down` o rebuild | Commit y push antes de cualquier rebuild; los agentes lo hacen por diseño |
| Un `sync` prematuro borraría Dropbox | Restaurar antes de sincronizar; archivo marcador; `--backup-dir` |
| Un `task-fix` de una card en `Lista para merge` espera a que la hija siguiente termine su turno de `claude -p` | Aceptado (DEVKIT-56): `skill.lock` pone en fila; la alternativa, worktrees en paralelo, multiplica conflictos |
| Rebuild descarga Python y paquetes | Imagen preconstruida por etiqueta, fuera del mínimo viable |
| Exfiltración por túnel DNS | Riesgo residual; ningún enfoque casero lo cierra |
| Tokens que caducan | Fallo claro al arrancar; fechas en Bitwarden |
| Credenciales del humano (por ejemplo el token de GitHub de la extensión Pull Requests) en memoria del extension host, legibles entre procesos del mismo contenedor | Aceptado; exigiría sandboxing por agente (ver sección 8.2) |

## 12b. Desviaciones verificadas en la construcción (2026-09-06)

Lo que la práctica cambió respecto al diseño, con su causa:

| Punto del diseño | Realidad | Decisión |
|---|---|---|
| Token de GitHub de permisos finos | GitHub no permite tokens finos a colaboradores de repos ajenos | Token clásico con alcance `repo` en la cuenta máquina; el alcance real lo limita la lista de colaboraciones. Mejora futura: organización de GitHub |
| Token de GitHub con solo `repo` | `gh pr edit --add-reviewer` (lo usa `pr-review` para pedir el review al humano al veredicto `OK`) falló en el PR 30 con 403: GitHub exige `read:org` para resolver revisores por nombre de usuario, incluso sobre un repo personal sin organización | Se sumó el alcance `read:org` al token de la cuenta máquina en Bitwarden (humano, 2026-09-15). Documentado en 8.1 para que `new-project.sh` o el arranque puedan comprobarlo con `gh auth status` a futuro |
| Repo `dotfiles` privado | El bootstrap y el clon inicial necesitan acceso anónimo | Repo público. Es un template sin secretos |
| `rclone` autorizado con navegador | El retorno a localhost no llega al contenedor | `scripts/dropbox-setup.sh`: flujo de código manual de Dropbox y `rclone.conf` en base64 en Bitwarden (`rclone_conf_b64`) |
| Retorno OAuth de MCP por puerto publicado en `dev` | Claude Code escucha solo en 127.0.0.1, y Docker no publica puertos de un contenedor que solo está en una red interna | El puerto lo publica el proxy, que sí toca la red de salida: Mac 127.0.0.1:54545 → proxy:54546 → dev:54546 → 127.0.0.1:54545. Un `socat` en cada contenedor |
| Notion solo vía plugin | El login de Claude Code expone además los conectores de claude.ai | Ambos caminos funcionan; el plugin se instala al arrancar y su MCP se autoriza una vez por proyecto |
| Sesión interactiva con el token de Bitwarden | El asistente de primer arranque exige un login propio | Login OAuth una vez por proyecto; queda en el volumen `claude-<proyecto>`. El token de Bitwarden sirve para el modo headless |
| Las skills buscan cards por la fórmula `Clave` | El MCP de Notion devuelve las fórmulas y rollups como referencias opacas, no como texto | Las skills filtran por `ID` (número) y `Proyecto`, y construyen la Clave como `<Código>-<ID>`. `Clave` queda como columna legible para el humano |
| `settings.json` niega todo `gh pr merge` | `task-submit` necesita `gh pr merge --auto` para activar el auto-merge | Se permite solo `--auto`; se niegan `--admin` y los merges inmediatos. La barrera real es el ruleset de `main`: GitHub no mergea sin approve humano |
| `settings.json` niega `gh pr review` entero | `pr-review` necesita `gh pr review --comment` para publicar su informe (DEVKIT-12) | Se permite `--comment` y se niega solo `--approve`/`-a`. Las reglas de `settings.json` son prefijos: no ven `gh pr review <N> --approve` ni una review publicada con `gh api`, así que solas no pueden impedir aprobar. El hook `pr-guard.sh` (DEVKIT-20, 8.2) reduce ese hueco inspeccionando el comando completo, no solo el prefijo, pero sigue siendo texto: no ve una variable de shell, un alias de `gh` ni una API que no conozca. La compuerta real sigue siendo GitHub: la cuenta máquina no puede aprobar sus propios PRs y el ruleset de `main` exige una aprobación humana; el hook solo achica la ventana de un PR abierto por el humano, que la cuenta máquina sí podría aprobar si nadie se lo impidiera |
| `DEVKIT_VERSION`, `.python-version` y `{{CODE}}` en `AGENTS.md` como fuentes sueltas | Tres archivos/placeholders para configuración que un proyecto declara una sola vez; tres skills asumían un `DEVKIT_VERSION` que ni siquiera existía como archivo (DEVKIT-2) | `devkit.toml` único en la raíz del repo, plano y leído con expresiones regulares. Regla de reparto: al repo lo que hace falta para reconstruir el proyecto igual (`template`, `project`, `python`, `apt`, `domains`); al Mac solo lo personal e irreproducible (`devkit.env`: repo, identidad git, remoto de Dropbox). Se descartó un archivo por parámetro (desorden) y `pyproject.toml` (ataría el template a Python). `new-project.sh` no puede crear `devkit.toml` porque nunca toca el repo del proyecto: lo crea `entrypoint.sh` con placeholders en el primer arranque (DEVKIT-6) |
| `devkit.toml` en la raíz del repo del proyecto | Cuando el proyecto tiene sus propios `CLAUDE.md`, `AGENTS.md` y `README.md`, se mezclan con los del entorno y el mantenimiento se complica | `devkit.toml` se muda a `.devkit/devkit.toml`, versionado. `AGENTS.md`, `CLAUDE.md` y `.claude/` se quedan en la raíz porque las herramientas (Codex, Claude Code) obligan a tenerlos ahí; todo lo demás del devkit vive en `.devkit/`. `template-update` migra el archivo viejo una sola vez (DEVKIT-53) |

## 13. Referencias

- Docker: volúmenes y almacenamiento. https://docs.docker.com/engine/storage/volumes/
- Petazzoni, J. "Using Docker-in-Docker for your CI or testing environment? Think twice." 2015.
- Chacon, S. y Straub, B. *Pro Git*, capítulo 1 y flujos de branches. https://git-scm.com/book/en/v2
- Dropbox: soporte exclusivo de ext4 en Linux, 2018. https://www.bleepingcomputer.com/news/security/dropbox-will-only-support-the-ext4-file-system-in-linux-in-november/
- rclone: Dropbox y límites de tasa. https://rclone.org/dropbox/
- Bitwarden Secrets Manager: planes y CLI. https://bitwarden.com/help/secrets-manager-plans/ y https://bitwarden.com/help/secrets-manager-cli/
- HashiCorp: fin de vida de HCP Vault Secrets. https://support.hashicorp.com/hc/en-us/articles/41802449287955-HCP-Vault-Secrets-End-Of-Life
- Astral: `uv`, versiones de Python y uso en Docker. https://docs.astral.sh/uv/concepts/python-versions/ y https://docs.astral.sh/uv/guides/integration/docker/
- python-build-standalone: quirks. https://github.com/astral-sh/python-build-standalone/blob/main/docs/quirks.rst
- Agent Skills, estándar abierto. https://agentskills.io
- Notion: ID único, subelementos, plantillas por API. https://www.notion.com/help/unique-id y https://developers.notion.com/guides/data-apis/creating-pages-from-templates
- Claude Code: autenticación, worktrees, OAuth en entornos remotos. https://code.claude.com/docs/en/authentication y https://code.claude.com/docs/en/worktrees y https://github.com/anthropics/claude-code/issues/69326
- GitHub: auto-merge, cuentas máquina. https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/automatically-merging-a-pull-request
- DORA: trunk-based development. https://dora.dev/capabilities/trunk-based-development/
- Conventional Commits. https://www.conventionalcommits.org/
- Semantic Versioning. https://semver.org/
- The Twelve-Factor App: dependencias; build, release, run. https://12factor.net
- Google SRE Workbook: canarying releases. https://sre.google/workbook/canarying-releases/
- OWASP Top 10 for LLM Applications: prompt injection. https://genai.owasp.org/llmrisk/llm01-prompt-injection/
- Anthropic: cortafuegos del devcontainer de referencia. https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
- Cockburn, A. Walking Skeleton. https://wiki.c2.com/?WalkingSkeleton

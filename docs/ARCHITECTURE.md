# Arquitectura del entorno de desarrollo `devkit`

Estado: diseño aprobado, pendiente de construcción. Fecha: 2026-09-06.
Este documento reemplaza al enfoque descrito en `.devcontainer/README.md` y
`.devcontainer/AGENTS.md`, que quedan como referencia histórica hasta que
exista la versión `0.1.0` del template.

Está escrito para alguien que llega hoy al proyecto. Cada sección explica qué
se decidió, por qué, y qué consecuencia tiene. Las alternativas descartadas se
mencionan solo cuando ayudan a entender la decisión.

## 1. Propósito

Un entorno de desarrollo en contenedor que:

- Depende del host solo para correr Docker. Ni Node, ni git, ni Python, ni
  Dropbox instalados en el Mac.
- Se reconstruye sin perder nada que importe.
- Trae Neovim integrado con Claude Code y preparado para Codex.
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
~/.devkit/<proy>/compose.yaml      tmux -> zsh -> Neovim -> Claude     Bitwarden Secrets Manager
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
- La versión de Python la declara cada proyecto en `devkit.toml` (clave
  `python`), fijando la serie menor, por ejemplo `3.14`. `uv python install`
  la instala al primer arranque. Subir de serie es un commit consciente.
- Paquetes apt adicionales por parámetro de build, vacío por defecto.

Por qué: separa la evolución del template de la del lenguaje. `uv` usa
`python-build-standalone`, mantenido por Astral; sus limitaciones documentadas
no aplican a Debian con glibc.

### 4.3 Volúmenes

Solo dos, ambos por proyecto:

| Volumen | Montado en | Contenido |
|---|---|---|
| `claude-<proyecto>` | `~/.claude` | Login, transcripciones, memoria, plugins, `settings.json` |
| `history-<proyecto>` | `/commandhistory` | Historial de shell |

Todo lo demás vive en la imagen o se regenera al arrancar: intérpretes de
Python, caché de `uv`, plugins de Neovim, configuración de git, tokens.

`CLAUDE_CONFIG_DIR` apunta al volumen para que `~/.claude.json` no quede fuera.
Los puntos de montaje se pre-crean en la imagen con el usuario correcto.

Costo aceptado: cada rebuild vuelve a descargar Python y los paquetes.

### 4.4 Neovim, terminal, shell y tmux

| Capa | Decisión |
|---|---|
| Terminal en el Mac | Terminal.app, macOS 26. Color de 24 bits. Sin OSC 52: copiar del contenedor al Mac requiere apagar "Permitir informe del ratón" en el menú Ver, seleccionar y Cmd-C. Se asigna un atajo de teclado a ese menú |
| Editor | Neovim con `kickstart.nvim`, ratón activo, `ruff` y `basedpyright` instalados con `uv tool` |
| Explorador de archivos | `snacks.explorer`, en `<espacio>e`. `snacks.nvim` ya entraba como proveedor de terminal de `claudecode.nvim`, así que no se añade ningún plugin |
| Integración con agentes | `coder/claudecode.nvim` en un "hueco de agente": un módulo Lua por agente con los mismos atajos. Codex se enchufa después |
| Shell | zsh con `starship` en preset de símbolos de texto plano, `zsh-autosuggestions`, `zsh-syntax-highlighting` |
| Multiplexor | tmux, invisible: el arranque entra directo; `Ctrl-b d` desconecta sin cerrar. Los splits los hace Neovim |

Contexto portable entre agentes: `AGENTS.md` como fuente, skills en formato
Agent Skills, un servidor MCP de Notion cuya configuración se genera por
agente al arrancar.

#### Cuándo el agente propone un diff y cuándo escribe al disco

Una edición de Claude llega al editor por dos caminos distintos, y confundirlos
es la causa habitual de "no veo lo que hizo el agente". El que manda no es
Neovim: es el CLI de Claude Code, según con quién esté hablando y en qué modo de
permisos esté.

| Cómo corre Claude | Qué pasa con una edición |
|---|---|
| `claude` desde el shell del contenedor, sin pasar por Neovim | Escribe directo al disco. Si el archivo está abierto, el buffer se relee solo y `gitsigns` marca las líneas en el margen |
| `claude` abierto con `<espacio>ac` desde Neovim, en modo manual (el de partida) | Llama a `openDiff` por el websocket: se abre un diff vertical y **el archivo en disco no cambia** hasta que aceptas con `<espacio>aa` (o `:w` en el diff). `<espacio>ad` lo descarta |
| Igual, pero con `accept edits on` (shift-tab), o con la herramienta ya permitida | Escribe directo al disco, sin diff |
| Ciclo automático: `watch.sh` lanza `claude -p` | Nunca usa el diff. En modo `-p` el CLI no se conecta a Neovim ni aunque tenga las variables de la integración |

Medido con un Neovim headless que registra las invocaciones del websocket y los
autocomandos `ClaudeCodeDiffOpened` y `ClaudeCodeDiffClosed`: en modo manual
llegó `openDiff` y el archivo siguió intacto hasta ejecutar
`ClaudeCodeDiffAccept`, que lo cerró con el motivo `diff tab closed after save`
y escribió el cambio; con `accept edits on` no llegó ninguna invocación y el
archivo cambió solo en disco; con `claude -p` el servidor ni siquiera registró
una conexión.

Forzar el diff para toda edición no es posible, y no por falta de configuración
nuestra: `claudecode.nvim` solo implementa el lado servidor: atiende `openDiff`
cuando el CLI lo pide. Sus `diff_opts` deciden cómo se ve el diff (vertical,
pestaña propia, foco), nunca si aparece. La única palanca real es el modo de
permisos de la sesión, que el propio CLI muestra en su barra inferior: en manual
verás el diff, en `accept edits on` no. La regla práctica: si quieres revisar
antes de que toque el disco, abre Claude desde Neovim y déjalo en manual; si lo
que quieres es velocidad, cualquiera de los otros caminos escribe directo y
`<espacio>e` más el margen de `gitsigns` te dicen qué cambió.

### 4.5 Notion

- Plugin oficial de Notion para Claude Code, instalado por script al primer
  arranque de cada proyecto.
- Autenticación OAuth. El puerto de retorno `54545` se publica en
  `127.0.0.1` del Mac para que la redirección del navegador llegue al
  contenedor. Una vez por proyecto; el token queda en `claude-<proyecto>`.
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
  nvim/                   # kickstart + hueco de agente
  zsh/  tmux/  starship.toml
  agents/
    AGENTS.template.md    # incluye la guía de redacción
    settings.json         # permisos de Claude Code
    skills/               # ver 5.3
  scripts/
    sync-sandbox.sh       # rclone cada minuto
    watch.sh              # revisión, corrección y cierre de PRs cada cinco minutos
    watch-test.sh         # casos de la tabla de decisión de watch.sh
    net-denied.sh         # destinos bloqueados por el proxy
  VERSION                 # la lee new-project.sh para elegir la etiqueta
  CHANGELOG.md            # una entrada por etiqueta; la lee template-update
new-project.sh
docs/ARCHITECTURE.md
```

### 5.2 Repo de un proyecto

```
devkit.toml               # única fuente: template, project, python, apt, domains
AGENTS.md                 # instrucciones del proyecto; importa la guía del template
CLAUDE.md                 # una línea: @AGENTS.md
.claude/skills -> enlace al template clonado en el contenedor
sandbox.local/            # ignorado por git, respaldado en Dropbox
```

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
  `devkit.toml` del contenedor antes de `recreate`, `rebuild` o `update`; no
  se edita a mano.

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
| `task-review` | En progreso → Revisión automática | Push, PR enlazando la card, auto-merge armado, URL de PR, comentario |
| `pr-review` | Revisión automática → Lista para merge, o se queda | Revisor independiente del autor: comprueba cada criterio ejecutando, lee el diff de forma adversarial, publica el informe en el PR con el marcador `devkit-review` y el bloque `devkit-findings`; con `OK` pide review al humano |
| `task-fix` | Revisión automática o Lista para merge → Revisión automática | Corrector del ciclo: lee el bloque `devkit-findings` del último informe `CAMBIOS` (o el comentario del humano como hallazgo único), un commit por hallazgo en la rama de la card, push, respuesta en el PR con el bloque `devkit-fixes` (`id | atendido o descartado | commit o motivo`) |
| `task-close` | Lista para merge → Hecha | Verifica merge, fecha de cierre, entrada de Documentación, marcador `devkit-closed` en el PR, arranca la siguiente hija |
| `task-block` | Cualquiera → Bloqueada | Comenta qué necesita del humano |
| `session-start` | Inicio de sesión | Reconcilia cards con PRs mergeados, reporta cards huérfanas o inactivas |
| `template-update` | Mantenimiento | Sube `template` en `devkit.toml` y actualiza Notion |
| `template-propagate` | Desde `DEVKIT` | Abre un PR de actualización en cada proyecto registrado |

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
| `task-review` | Agente | PR a `main` con auto-merge armado; card en `Revisión automática` |
| `watch.sh`: head sin informe | Máquina | Lanza `pr-review` headless. `OK`: card a `Lista para merge` y review pedido al humano. `CAMBIOS`: bloque `devkit-findings` en el PR |
| `watch.sh`: `CAMBIOS` para el head, sin respuesta | Máquina | Lanza `task-fix` headless: un commit por hallazgo, push, bloque `devkit-fixes`. El head nuevo vuelve a la fila anterior |
| Comentario en un PR en `Lista para merge` | Humano | `watch.sh` lanza `task-fix` con ese texto; la card vuelve a `Revisión automática` |
| Tres informes `CAMBIOS` sin `OK` | Máquina | `watch.sh` publica el marcador `devkit-block` en el PR y lanza `task-block`. No toca el PR hasta que el humano mueva la card a `Revisión automática` y comente |
| Approve del PR | Humano | GitHub mergea con squash: un commit por card en `main` |
| `watch.sh`: PR mergeado sin marcador `devkit-closed` | Máquina | Lanza `task-close` headless; cierra la hija, documenta, deja el marcador `devkit-closed` en el PR y arranca la siguiente |
| Todas las hijas en Hecha | Automático | La Épica pasa a Hecha con una entrada de Documentación consolidada |

El bucle no guarda estado propio: decide con lo que hay en el PR. Cada
informe del revisor lleva `<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->`,
cada respuesta del corrector `<!-- devkit-fix sha=<head nuevo> review=<sha> -->`,
cada bloqueo `<!-- devkit-block sha=<head> -->` y cada cierre
`<!-- devkit-closed sha=<merge commit> -->`. Los marcadores se reconocen
por su texto, no por su autor, para que valgan aunque el informe lo haya
publicado el humano desde otra sesión. Un comentario humano es cualquier
comentario o review sin marcador, de una cuenta distinta a la máquina y
posterior al último marcador; los approve no cuentan porque los consume el
auto-merge. La guardia cuenta los `CAMBIOS` posteriores al último `OK` o al
último bloqueo, lo que sea más reciente: un rebuild no pierde nada y el humano
reinicia el conteo con solo retomar. `/run/devkit/launched` (tmpfs) solo evita
relanzar la misma skill para la misma entrada dentro de una vida del
contenedor; como cada skill es idempotente, perderlo no daña la corrección de
lo que hay en Notion.

Sí daña la factura, y por eso el cierre también dejó de depender de él
(DEVKIT-24). `launched` nace vacío en cada `devkit recreate`, y la ventana de
48 h de la consulta de PRs mergeados vuelve a ofrecer todos los que ya se
cerraron: el 2026-09-08, el primer arranque del bucle nuevo reprocesó siete
PRs con card en `Hecha` antes de llegar al único pendiente, unos 3 USD y veinte
minutos de espera. La corrección es la misma idea que el resto del ciclo:
`task-close` publica `<!-- devkit-closed sha=<merge commit> -->` en el PR al
terminar, y `watch.sh` omite los PRs mergeados que ya lo llevan. Se descartó
persistir `launched` en disco: guardaría en el contenedor un estado que ya
existe en GitHub, y no serviría en otra máquina ni tras un `devkit rebuild`.

`/run/devkit/poke` es el otro archivo del bucle en tmpfs, y tampoco guarda
estado (DEVKIT-26): `task-review` y `task-fix` lo tocan al terminar, `watch.sh`
duerme en tramos de cinco segundos en vez de un `sleep` seguido y despierta en
cuanto aparece, y lo borra antes de consultar GitHub para no perder un aviso
llegado durante la consulta. Solo adelanta el reloj entre dos vueltas: no salta
la guarda de `launched` y la decisión sigue saliendo de los marcadores del PR,
así que el revisor sigue naciendo en un proceso sin memoria del autor y el
autor sigue sin decidir cuándo lo revisan. Por eso se descartó que
`task-review` invocara `pr-review` como skill: compartiría su conversación y
rompería esa independencia. Perder el aviso no rompe nada, solo devuelve la
espera al intervalo completo, y por eso las skills lo tocan con `|| true`.

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
por estado y tiempo con una vista filtrada y con `session-start`.

## 8. Seguridad

### 8.1 Credenciales

| Credencial | Dónde vive | Alcance mínimo | Cómo entra |
|---|---|---|---|
| Token de Bitwarden, secreto cero | `~/.devkit/bws-token` en el Mac, 600 | Lectura del proyecto `devcontainers` | Archivo con `secrets:` de Compose |
| Token de Claude | Bitwarden | Suscripción Max. `claude setup-token`, doce meses | `CLAUDE_CODE_OAUTH_TOKEN` al arrancar |
| Token de GitHub de la cuenta máquina | Bitwarden | Permisos finos: solo los repos listados; contenido y PRs en escritura; caduca en un año | `GH_TOKEN` y `gh auth setup-git` |
| Token de Dropbox | Bitwarden | App propia con acceso "App folder": solo `/Apps/devkit` | `rclone.conf` generado al arrancar |
| Notion | Volumen `claude-<proyecto>` | Páginas autorizadas en OAuth: el árbol "Ingeniería" | Plugin oficial, puerto en `127.0.0.1` |

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
- Proxy de salida con lista blanca. Lista base en el template; dominios del
  proyecto en `devkit.env`; interruptor de red abierta por sesión para
  depurar; `net-denied.sh` muestra los destinos bloqueados.

Riesgo residual aceptado: el túnel por DNS. Ningún enfoque casero lo cierra.

### 8.3 Caducidad

Los tokens de Claude y GitHub duran doce meses como máximo. El arranque falla
con mensaje claro si alguno es inválido. Bitwarden guarda la fecha de
vencimiento en la nota de cada secreto.

## 9. Versionado y propagación

- El proyecto declara la versión que quiere en `devkit.toml` (clave
  `template`), dentro del repo. `.env` en el Mac guarda la versión de imagen
  con la que Compose arrancó hoy (`DEVKIT_VERSION`): son dos cosas distintas
  a propósito, porque `.env` tiene que existir antes de que el repo se
  clone.
- Al arrancar, el contenedor clona `dotfiles` en la etiqueta de `.env` dentro
  de sí mismo y crea enlaces simbólicos hacia el workspace. Se reconstruye en
  cada arranque y nunca se edita.
- El bootstrap descarga el tarball de esa etiqueta para construir la imagen.
- Al arrancar, `entrypoint.sh` compara `template` de `devkit.toml` contra
  `DEVKIT_VERSION` de `.env` y avisa si difieren: el repo pide una versión
  que la imagen todavía no tiene.
- `devkit update <proyecto>`, desde el Mac, lee `template` del contenedor
  (`docker exec ... cat /workspace/devkit.toml`), descarga esa versión,
  actualiza `.env` y reconstruye. Así `.env` se pone al día con lo que el
  repo ya declaraba.
- `template-propagate`, desde `DEVKIT`, abre un PR en cada proyecto
  registrado en Notion que cambia `template` en su `devkit.toml`. El humano
  aprueba, el auto-merge hace el resto; `devkit update` en cada proyecto
  aplica el cambio en el Mac.
- Para `DEVKIT`, el clon de `dotfiles` es su workspace: ahí los cambios se
  prueban en vivo antes de etiquetar, con `template = "dev"` en su propio
  `devkit.toml`.

Descartado: bind mount del clon local con enlaces simbólicos. Rompe el host
mínimo, elimina las versiones y no tiene radio de impacto controlado.

## 10. Mínimo viable

### 10.1 Dentro

Imagen, Compose con proxy, arranque completo, Neovim con `claudecode.nvim`,
`AGENTS.md` y `settings.json`, las diez skills, las tres bases de datos de
Notion, `new-project.sh`.

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
   - `claudecode.nvim` con `CLAUDE_CONFIG_DIR` en volumen.
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
volúmenes, levanta el contenedor y entra a tmux. Dentro, `dotfiles` ya es el
workspace. En el Mac no queda ningún clon.

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
| Latencia de hasta cinco minutos entre approve y arranque de la siguiente hija | Comando manual para arrancar sin esperar el bucle |
| Rebuild descarga Python y paquetes | Imagen preconstruida por etiqueta, fuera del mínimo viable |
| Copiar del contenedor al Mac requiere un gesto extra en Terminal.app | Atajo de teclado al menú "Permitir informe del ratón" |
| Exfiltración por túnel DNS | Riesgo residual; ningún enfoque casero lo cierra |
| Tokens que caducan | Fallo claro al arrancar; fechas en Bitwarden |

## 12b. Desviaciones verificadas en la construcción (2026-09-06)

Lo que la práctica cambió respecto al diseño, con su causa:

| Punto del diseño | Realidad | Decisión |
|---|---|---|
| Token de GitHub de permisos finos | GitHub no permite tokens finos a colaboradores de repos ajenos | Token clásico con alcance `repo` en la cuenta máquina; el alcance real lo limita la lista de colaboraciones. Mejora futura: organización de GitHub |
| Repo `dotfiles` privado | El bootstrap y el clon inicial necesitan acceso anónimo | Repo público. Es un template sin secretos |
| `rclone` autorizado con navegador | El retorno a localhost no llega al contenedor | `scripts/dropbox-setup.sh`: flujo de código manual de Dropbox y `rclone.conf` en base64 en Bitwarden (`rclone_conf_b64`) |
| Retorno OAuth de MCP por puerto publicado en `dev` | Claude Code escucha solo en 127.0.0.1, y Docker no publica puertos de un contenedor que solo está en una red interna | El puerto lo publica el proxy, que sí toca la red de salida: Mac 127.0.0.1:54545 → proxy:54546 → dev:54546 → 127.0.0.1:54545. Un `socat` en cada contenedor |
| Notion solo vía plugin | El login de Claude Code expone además los conectores de claude.ai | Ambos caminos funcionan; el plugin se instala al arrancar y su MCP se autoriza una vez por proyecto |
| Sesión interactiva con el token de Bitwarden | El asistente de primer arranque exige un login propio | Login OAuth una vez por proyecto; queda en el volumen `claude-<proyecto>`. El token de Bitwarden sirve para el modo headless |
| Copiar direcciones largas desde tmux | Terminal.app inserta saltos de línea al copiar texto envuelto | En el Mac: `pbpaste \| tr -d ' \n' \| pbcopy` antes de pegar en Safari |
| Ratón en Neovim y en Claude Code | Ambos capturan el ratón; la selección nativa exige apagar "Permitir informe del ratón" | Documentado en 4.4; se recomienda un atajo de teclado al menú |
| Las skills buscan cards por la fórmula `Clave` | El MCP de Notion devuelve las fórmulas y rollups como referencias opacas, no como texto | Las skills filtran por `ID` (número) y `Proyecto`, y construyen la Clave como `<Código>-<ID>`. `Clave` queda como columna legible para el humano |
| `settings.json` niega todo `gh pr merge` | `task-review` necesita `gh pr merge --auto` para activar el auto-merge | Se permite solo `--auto`; se niegan `--admin` y los merges inmediatos. La barrera real es el ruleset de `main`: GitHub no mergea sin approve humano |
| `settings.json` niega `gh pr review` entero | `pr-review` necesita `gh pr review --comment` para publicar su informe (DEVKIT-12) | Se permite `--comment` y se niega solo `--approve`/`-a`. Las reglas de `settings.json` son prefijos: no ven `gh pr review <N> --approve` ni una review publicada con `gh api`, así que no pueden impedir aprobar. La compuerta real es GitHub: la cuenta máquina no puede aprobar sus propios PRs y el ruleset de `main` exige una aprobación humana. Queda expuesto el caso de un PR abierto por el humano; la skill lo prohíbe por regla y una card en DEVKIT-18 propone un hook `PreToolUse` que bloquee `approve` por contenido del comando |
| `DEVKIT_VERSION`, `.python-version` y `{{CODE}}` en `AGENTS.md` como fuentes sueltas | Tres archivos/placeholders para configuración que un proyecto declara una sola vez; tres skills asumían un `DEVKIT_VERSION` que ni siquiera existía como archivo (DEVKIT-2) | `devkit.toml` único en la raíz del repo, plano y leído con expresiones regulares. Regla de reparto: al repo lo que hace falta para reconstruir el proyecto igual (`template`, `project`, `python`, `apt`, `domains`); al Mac solo lo personal e irreproducible (`devkit.env`: repo, identidad git, remoto de Dropbox). Se descartó un archivo por parámetro (desorden) y `pyproject.toml` (ataría el template a Python). `new-project.sh` no puede crear `devkit.toml` porque nunca toca el repo del proyecto: lo crea `entrypoint.sh` con placeholders en el primer arranque (DEVKIT-6) |

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
- Neovim: releases y OSC 52. https://github.com/neovim/neovim/releases
- coder/claudecode.nvim y su protocolo. https://github.com/coder/claudecode.nvim
- Agent Skills, estándar abierto. https://agentskills.io
- Apple: informe del ratón en Terminal. https://support.apple.com/guide/terminal/turn-on-mouse-reporting-trmlc69728a5/mac
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

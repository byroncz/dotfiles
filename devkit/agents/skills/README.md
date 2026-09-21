# Skills del template

Cada skill es un directorio con `SKILL.md` en formato Agent Skills
(https://agentskills.io): sirve a Claude Code y a Codex sin cambios.

Se enlazan al workspace en `.claude/skills/` al arrancar el contenedor.
Se invocan como `/nombre argumentos` en Claude Code, o de forma headless
con `claude -p "/nombre argumentos"`.

| Skill | Transición | Quién la lanza |
|---|---|---|
| `project-init` | Alta de proyecto en Notion | Humano, una vez |
| `epic-plan` | Épica en Lista → hijas en Lista | Humano, al aprobar una Épica |
| `task-create` | Nace en Por refinar | Humano o agente |
| `task-start` | Lista → En progreso | Agente; también `epic-plan` y `cola.sh` |
| `task-submit` | En progreso → Revisión automática | Agente |
| `pr-review` | Revisión automática → Lista para merge, o se queda | `watch.sh` (headless) o humano |
| `task-fix` | Revisión automática o Lista para merge → Revisión automática | `watch.sh` (headless) o humano |
| `task-document` | Entrada "decisión" (PR marcado `Tipo: decisión`) o entrada consolidada de una Épica cerrada; no cambia el Estado. La entrada "cambio" ordinaria la escribe `task-document.sh`, sin agente | `watch.sh` si el PR trae la marca; `task-close.sh` solo para una Épica |
| `project-status` | Estado del proyecto y siguiente card libre | Humano o agente |
| `template-update` | Sube la versión del template y pone al día `AGENTS.md` | Agente |
| `template-propagate` | PR de actualización en cada proyecto | Agente, desde DEVKIT |

Cerrar y bloquear no son skills desde DEVKIT-55, ni lanzar la siguiente card
de la cola desde DEVKIT-56/DEVKIT-120: son scripts bash contra la API de
Notion, con el token `notion_token`, que no gastan modelo.

| Script | Transición | Quién lo lanza |
|---|---|---|
| `task-close.sh <Clave> [PR]` | Lista para merge → Hecha; cierra la Épica y llama a `cola.sh` | `watch.sh` tras el merge; humano con `devkit-run task-close` |
| `task-document.sh <Clave> [PR]` | Escribe o reemplaza la entrada "cambio" de una card, copiando Objetivo, secciones del PR, hallazgos corregidos y marcas de modelo; no cambia el Estado. Idempotente por head | `watch.sh` al OK de `pr-review`; `task-close.sh` al merge |
| `cola.sh` | Imprime la Clave de la siguiente card de la cola del proyecto (o nada): hijas de Épicas en `Lista`, luego tareas sueltas en `Lista`, su `Depende de` en `Hecha` y nada `En progreso`/`Revisión automática` ni un `task-start` vivo. `watch.sh`/`task-close.sh` lanzan `task-start` con lo que devuelve | `watch.sh` en cada pasada del sondeo sin nada en curso y al OK de `pr-review`; `task-close.sh` al merge |
| `task-block.sh <Clave> <motivo>` | Cualquiera (salvo `Hecha`, que se niega) → Bloqueada | Agente, `watch.sh` y `devkit-run`; humano con `devkit-run task-block` |

Las skills los invocan por ruta, `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh"`:
`devkit-run` exporta esa variable al `claude -p` que lanza.

Convenciones comunes a todas:

- Identificadores de Notion en `.claude/devkit-notion.json`. Código del
  proyecto en la clave `project` de `.devkit/devkit.toml`.
- Los nombres de opción de `Estado`, `Nivel`, `Tipo`, `Agente` y `Prioridad`
  (Tareas), `Estado` (Proyectos) y `Tipo` (Documentación) están en
  `.claude/devkit-notion.json`. Las skills los citan tal cual; no inventes
  variantes.
- Prefijo de rama según `Tipo` de la card: `feature` → `feat/`, `bug` →
  `fix/`, `chore` → `chore/`. Luego la Clave y un slug corto:
  `fix/DEVKIT-7-slug`.
- `<CÓDIGO>-0` es la Clave reservada para trabajo sin card (alta de proyecto,
  actualización de template). `watch.sh` la ignora: nunca revisa ni cierra
  una card por un PR `-0`.
- Localizar una card por Clave (`DEVKIT-7`): el MCP de Notion no devuelve
  el valor de las fórmulas, así que no filtres por `Clave`. Separa código y
  número, y consulta Tareas con `ID` = número y `Proyecto` = la fila cuyo
  Código es el del proyecto (`data_source_id` de `tareas` en el JSON). Al
  escribir la Clave en ramas, commits y PRs, constrúyela tú: `<Código>-<ID>`.
- Editar una skill se hace por su ruta real en el repo del template,
  `devkit/agents/skills/<skill>/SKILL.md`, nunca por `.claude/skills/`. Ese
  directorio es un enlace simbólico al template y Claude Code no acepta
  escrituras bajo `.claude/` sin confirmación del humano, que en headless
  nadie da: la ejecución se detiene a medias. Caso de origen: DEVKIT-26,
  cuya primera ejecución se detuvo por eso.
- Todo texto sigue la guía de redacción de `AGENTS.md`.
- Idempotencia: cada skill comprueba el estado actual antes de actuar y no
  repite lo que ya está hecho.
- Nunca push a `main`, nunca force push, nunca merge desde el agente: el
  merge lo hace GitHub con auto-merge tras el approve humano.

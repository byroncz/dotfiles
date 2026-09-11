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
| `task-create` | Nace en Backlog | Humano o agente |
| `task-start` | Lista → En progreso | Agente; también `epic-plan` y `task-close` |
| `task-submit` | En progreso → Revisión automática | Agente |
| `pr-review` | Revisión automática → Lista para merge, o se queda | `watch.sh` (headless) o humano |
| `task-fix` | Revisión automática o Lista para merge → Revisión automática | `watch.sh` (headless) o humano |
| `task-close` | Lista para merge → Hecha | `watch.sh` tras el merge |
| `task-block` | Cualquiera → Bloqueada | Agente |
| `project-status` | Estado del proyecto y siguiente card libre | Humano o agente |
| `template-update` | Sube la versión del template | Agente |
| `template-propagate` | PR de actualización en cada proyecto | Agente, desde DEVKIT |

Convenciones comunes a todas:

- Identificadores de Notion en `.claude/devkit-notion.json`. Código del
  proyecto en la clave `project` de `devkit.toml`, en la raíz del workspace.
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

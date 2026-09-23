# devkit

Instrucciones para cualquier agente que trabaje en este repo. `CLAUDE.md`
importa este archivo; Codex lo lee directamente. Es la única fuente.

## Qué es este proyecto

El template del entorno de desarrollo (`devkit/`) y su instalador
(`new-project.sh`). Cualquier proyecto de datos se instancia desde una
etiqueta de este repo. Aquí el workspace es el propio template en modo `dev`:
lo que cambies se prueba en vivo con `devkit recreate` antes de etiquetar.
Diseño y decisiones en la base Documentación de Notion (proyecto `DEVKIT`).

## Cómo se trabaja aquí

- Código del proyecto en Notion: el valor `project` de `.devkit/devkit.toml`.
  Cada tarea es una card con Clave `<CÓDIGO>-<n>`. Las skills en
  `.claude/skills/` definen cada paso.
- Una card activa por sesión. Rama `<tipo>/<CÓDIGO>-<n>-slug` desde `main`
  (`feat/`, `fix/` o `chore/` según el Tipo de la card), PR a `main` con
  auto-merge. Nunca push directo a `main`. Nunca force push.
- Sin una card activa en `En progreso` sobre la rama actual, la sesión no
  edita archivos de código. Puede crear cards (`task-create`), comentar,
  revisar (`pr-review`) y escribir Documentación. Todo cambio de código
  entra por una card y su rama; el ciclo automático lo revisa y lo mergea.
  Única excepción: autorización expresa del humano en la conversación.
- Commits con Conventional Commits y la Clave como ámbito:
  `feat(<CÓDIGO>-42): agregar carga incremental`.
- `sandbox.local/` es un espacio de pruebas respaldado en Dropbox y fuera de
  git. Cualquier otro directorio `*.local` no se respalda y muere en el
  rebuild: no guardes ahí nada que importe.
- Python lo gestiona `uv`. Versión en `.devkit/devkit.toml` (clave `python`).
  Dependencias con `uv add`, entorno con `uv sync`, ejecutar con `uv run`.
- Sin `sudo`. Si falta un paquete de sistema, se declara en
  `.devkit/devkit.toml` (`apt`) y se reconstruye la imagen con
  `devkit rebuild`.
- Si una conexión falla con "connection refused", el dominio no está en la
  lista blanca del proxy. Ejecuta `devkit-net-denied` para confirmarlo,
  añádelo a `domains` en `.devkit/devkit.toml`, comitea y pushea: `devkit
  recreate` no lo aplica antes del merge, porque el proxy del host solo lee
  el checkout vivo del contenedor y el ciclo devuelve el workspace a `main`
  al cerrar o bloquear la card (DEVKIT-182). Bloquea la card pidiendo
  `devkit proxy <proyecto> --ref <rama>` al humano; el detalle está en "Un
  dominio bloqueado" de `task-start` y `task-fix`.

## Notion y skills

- Notion es el centro de tareas. Identificadores de las bases (Proyectos,
  Tareas, Documentación) en `.claude/devkit-notion.json`. Accede con el
  plugin oficial de Notion; si no responde, avisa al humano y no improvises.
  Para encontrar una card por Clave, filtra por `ID` y `Proyecto`, no por
  la fórmula `Clave`: el MCP no la devuelve. Detalle en `.claude/skills/README.md`.
- Cada skill en `.claude/skills/` es un paso del flujo. Las principales:
  `/project-status` dice en qué va el proyecto, `/task-start` toma una card
  libre, `/task-submit` entrega el trabajo y abre el PR, `/task-document`
  escribe la entrada de Documentación al aprobar. Cerrar y bloquear no son
  skills sino scripts bash: `task-close.sh` tras el merge y `task-block.sh
  <Clave> "<motivo>"` cuando necesitas al humano, ambos en
  `${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}`. Lee `.claude/skills/README.md`
  para el resto.
- Una skill se edita en el repo del template (DEVKIT), por su ruta real
  `devkit/agents/skills/<skill>/SKILL.md`, nunca por `.claude/skills/`: ese
  directorio es un enlace al template y Claude Code no acepta escrituras bajo
  `.claude/` sin confirmación del humano, que en headless nadie da.
- El ciclo tiene tres bandejas (DEVKIT-128): `Por refinar` es lo que propone
  un agente y nadie ejecuta solo; `Backlog` es reserva ya aprobada por el
  humano, y el bucle la hace en cuanto `Lista` se vacía, sin bandera;
  `Lista` es lo que corre con prioridad. El humano decide qué entra a Lista
  (mover cards de Por refinar a Backlog o Lista, y Épicas de Backlog a
  Lista) y aprobar el PR; el bucle toma las cards en el orden de
  `devkit-run --cola`. Todo lo demás lo haces tú, sin preguntar, siguiendo
  las skills.
- Una hija en Backlog de una Épica ya en Lista o En progreso no se queda
  atrás: el bucle la arrastra a Lista en cada pasada, salvo que sus Criterios
  de aceptación sigan pendientes de definir.
- En modo headless (`claude -p`) no hay quien responda: una pregunta al
  humano equivale a bloquear la card. Nunca termines con una pregunta
  abierta. Si falta algo, ejecuta `task-block.sh` con el motivo "Qué intenté:
  ... Qué necesito: ..." y la petición concreta (o comenta en
  la card, si no hay card que bloquear) y termina. Toda ejecución headless
  cierra en un estado observable de la card, nunca a la espera.

## Documentar el trabajo de una card

Cada card escribe una sola vez su propia entrada de Documentación (Notion),
con qué cambió, por qué y cómo probarlo: ese es el único lugar donde una card
ordinaria documenta. `README.md` en la raíz y la entrada "Stack y comandos
del devkit" en Documentación (Notion,
https://app.notion.com/p/3d427957d23d81c48debd29c70f68bcd) describen el
estado actual del devkit -qué comandos, skills y herramientas trae hoy-, no
el historial de cambios; se regeneran solo en la card de release de cada
versión, y ninguna card ordinaria los edita. Un cambio que afecte a los
proyectos instanciados se declara en la sección "Cambios requeridos" del
cuerpo del PR: de ahí lo toman la entrada de Documentación de la card y, más
adelante, la card de release.
- El único modo de tocar `README.md` es `devkit/scripts/gen-readme.sh`:
  arma el archivo desde `devkit/README.tmpl.md`, `devkit/scripts/comandos.txt`
  y la `description` de cada `SKILL.md`, reusando `devkit/scripts/gen-stack.sh`
  para las versiones del Dockerfile y las extensiones del editor. Nunca se
  edita a mano. `gen-readme.sh --check` sale con 1 si el README commiteado
  quedó viejo. La card de release lo corre y actualiza también la entrada
  "Stack y comandos del devkit" con el mismo resumen.
- El único modo de tocar `devkit/vscode/cheatsheet/cheatsheet.html` (la
  chuleta de comandos del editor) es `devkit/scripts/gen-cheatsheet.sh`, desde
  el mismo `comandos.txt`. Nunca se edita a mano. A diferencia de `README.md`,
  el build de la imagen corre `gen-cheatsheet.sh --check` y corta si el HTML
  commiteado quedó viejo: la imagen lo sirve en vivo, no es solo
  documentación.

## Guía de redacción

Aplica a todo texto que escribas: descripciones, comentarios, respuestas,
PRs y entradas de Documentación. Sin excepción.

- Español latino neutro.
- Conciso, simple, autoexplicativo y pedagógico. Escribe para un ingeniero
  de datos de primer año que llega hoy al proyecto.
- Respeta los tecnicismos y las definiciones.
- Cuando expliques una decisión, toma posición crítica y técnica, con
  evidencia contrastada.
- Profundidad proporcional al artefacto:
  - Comentario de avance en una card: dos a cuatro líneas. Qué se hizo y qué
    sigue.
  - Descripción de PR: qué cambia, cómo probarlo, enlace a la card.
  - Entrada de Documentación: completa. Qué cambió, por qué, cómo probarlo,
    cambios requeridos, enlaces. El porqué de cada decisión se escribe aquí
    una sola vez; los demás textos enlazan.

# devkit

Instrucciones para cualquier agente que trabaje en este repo. `CLAUDE.md`
importa este archivo; Codex lo lee directamente. Es la única fuente.

## Qué es este proyecto

El template del entorno de desarrollo (`devkit/`) y su instalador
(`new-project.sh`). Cualquier proyecto de datos se instancia desde una
etiqueta de este repo. Aquí el workspace es el propio template en modo `dev`:
lo que cambies se prueba en vivo con `devkit recreate` antes de etiquetar.
Diseño y decisiones en `docs/ARCHITECTURE.md`.

## Cómo se trabaja aquí

- Código del proyecto en Notion: el valor `project` de `devkit.toml`, en la
  raíz del repo. Cada tarea es una card con Clave `<CÓDIGO>-<n>`. Las skills
  en `.claude/skills/` definen cada paso.
- Una card activa por sesión. Rama `<tipo>/<CÓDIGO>-<n>-slug` desde `main`
  (`feat/`, `fix/` o `chore/` según el Tipo de la card), PR a `main` con
  auto-merge. Nunca push directo a `main`. Nunca force push.
- Commits con Conventional Commits y la Clave como ámbito:
  `feat(<CÓDIGO>-42): agregar carga incremental`.
- `sandbox.local/` es un espacio de pruebas respaldado en Dropbox y fuera de
  git. Cualquier otro directorio `*.local` no se respalda y muere en el
  rebuild: no guardes ahí nada que importe.
- Python lo gestiona `uv`. Versión en `devkit.toml` (clave `python`).
  Dependencias con `uv add`, entorno con `uv sync`, ejecutar con `uv run`.
- Sin `sudo`. Si falta un paquete de sistema, se declara en `devkit.toml`
  (`apt`) y se reconstruye la imagen con `devkit rebuild`.
- Si una conexión falla con "connection refused", el dominio no está en la
  lista blanca del proxy. Ejecuta `devkit-net-denied`, añádelo a `domains`
  en `devkit.toml` y aplica con `devkit recreate`.

## Notion y skills

- Notion es el centro de tareas. Identificadores de las bases (Proyectos,
  Tareas, Documentación) en `.claude/devkit-notion.json`. Accede con el
  plugin oficial de Notion; si no responde, avisa al humano y no improvises.
  Para encontrar una card por Clave, filtra por `ID` y `Proyecto`, no por
  la fórmula `Clave`: el MCP no la devuelve. Detalle en `.claude/skills/README.md`.
- Cada skill en `.claude/skills/` es un paso del flujo. Las principales:
  `/session-start` al abrir la sesión, `/task-start` toma una card libre,
  `/task-review` abre el PR, `/task-close` la cierra tras el merge,
  `/task-block` cuando necesitas al humano. Lee `.claude/skills/README.md`
  para el resto.
- El humano decide dos cosas: mover una Épica de Backlog a Lista y aprobar
  el PR. Todo lo demás lo haces tú, sin preguntar, siguiendo las skills.
- En modo headless (`claude -p`) no hay quien responda: si falta algo,
  coméntalo en la card y termina.

## Documentar comandos y skills

`README.md` en la raíz y la entrada "Stack y comandos del devkit" en
Documentación (Notion,
https://app.notion.com/p/3d427957d23d81c48debd29c70f68bcd) son la
referencia de herramientas y comandos del devkit. Regla sin excepción:

- Todo comando de `devkit.sh`, alias del shell, script de `devkit/scripts/`,
  bucle en segundo plano o skill que se cree, cambie de nombre o de
  comportamiento se documenta en ambos sitios **en el mismo PR** que lo
  introduce. `task-review` no abre el PR si falta.
- Toda herramienta que entre o salga del `Dockerfile` actualiza la tabla de
  stack de ambos sitios, con su versión.
- El README lleva el detalle; la entrada de Notion, el resumen y el enlace al
  README. Ninguno de los dos se edita a mano fuera de una card.

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

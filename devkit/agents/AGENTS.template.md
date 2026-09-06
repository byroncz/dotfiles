# {{PROJECT}}

Instrucciones para cualquier agente que trabaje en este repo. `CLAUDE.md`
importa este archivo; Codex lo lee directamente. Es la única fuente.

## Qué es este proyecto

<!-- Dos o tres líneas. Qué hace y para quién. Completar al crear el proyecto. -->

## Cómo se trabaja aquí

- Código del proyecto en Notion: `{{CODE}}`. Cada tarea es una card con
  Clave `{{CODE}}-<n>`. Las skills en `.claude/skills/` definen cada paso.
- Una card activa por sesión. Rama `feat/{{CODE}}-<n>-slug` desde `main`,
  PR a `main` con auto-merge. Nunca push directo a `main`. Nunca force push.
- Commits con Conventional Commits y la Clave como ámbito:
  `feat({{CODE}}-42): agregar carga incremental`.
- `sandbox.local/` es un espacio de pruebas respaldado en Dropbox y fuera de
  git. Cualquier otro directorio `*.local` no se respalda y muere en el
  rebuild: no guardes ahí nada que importe.
- Python lo gestiona `uv`. Versión en `.python-version`. Dependencias con
  `uv add`, entorno con `uv sync`, ejecutar con `uv run`.
- Sin `sudo`. Si falta un paquete de sistema, se declara en `devkit.env`
  (`DEVKIT_EXTRA_APT`) y se reconstruye la imagen.
- Si una conexión falla con "connection refused", el dominio no está en la
  lista blanca del proxy. Ejecuta `devkit-net-denied` y añádelo a
  `DEVKIT_ALLOW_DOMAINS` en `devkit.env`.

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

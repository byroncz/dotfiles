---
name: project-init
description: Registra un proyecto nuevo en Notion: fila en Proyectos y vistas filtradas de Tareas y Documentación en su página. Úsala una vez, al instanciar un proyecto con new-project.sh. Argumentos: código corto y URL del repo; el nombre se toma de AGENTS.md.
---

# project-init

Argumentos: código (mayúsculas, sin espacios, por ejemplo `DATA`) y URL del
repo en GitHub.

## Pasos

1. Lee `.claude/devkit-notion.json`. Busca en Proyectos una fila con ese
   Código. Si existe, no la dupliques: verifica el resto y termina.
2. Crea la fila en Proyectos: Nombre, Código, Repo, Versión del template
   (contenido de `DEVKIT_VERSION` en el workspace, o `dev`), Estado `Activo`.
   En el cuerpo, dos líneas: qué es el proyecto y enlace a su `AGENTS.md`.
3. En la página de esa fila, crea dos vistas enlazadas:
   - `Kanban <CÓDIGO>` sobre Tareas, tipo tablero, agrupada por `Estado`,
     filtrada por `Proyecto` = esta fila, ordenada por `Orden`.
   - `Documentación <CÓDIGO>` sobre Documentación, tipo tabla, filtrada por
     `Proyecto` = esta fila, ordenada por `Fecha` descendente.
4. Verifica y reporta con una lista de tres comprobaciones: fila creada con
   URL, vista Kanban creada, vista Documentación creada.
5. Si `AGENTS.md` del workspace aún tiene el código de ejemplo, sustitúyelo
   por el código real y haz commit: `chore(<CÓDIGO>-0): registrar proyecto`.
   Usa `-0` porque aún no hay card.

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
   (clave `template` de `.devkit/devkit.toml`, o `dev`),
   Estado `Activo`. En el cuerpo, dos líneas: qué es el proyecto y enlace a
   su `AGENTS.md`.
3. En la página de esa fila, crea dos vistas enlazadas:
   - `Kanban <CÓDIGO>` sobre Tareas, tipo tablero, agrupada por `Estado`,
     filtrada por `Proyecto` = esta fila, ordenada por `Orden`, con las
     mismas propiedades en la card que el kanban de DEVKIT: `Título`,
     `Clave`, `Estado`, `Padre`, `Tipo`, `Prioridad`, `PR`. Todo tablero
     nuevo nace con "ocultar grupos vacíos" encendido, y ni `create_view` ni
     `update_view` de este MCP exponen cómo apagarlo (`configure` fuerza
     `hideEmptyGroups: true` sin excepción, verificado probando `GROUP BY`,
     `SHOW`/`HIDE` y una sobreescritura directa del campo): pide al humano
     que lo apague a mano -un clic, menú "..." de la vista → Agrupar por →
     apagar "Ocultar grupos vacíos"- y anótalo en el reporte final si quedó
     pendiente.
   - `Documentación <CÓDIGO>` sobre Documentación, tipo tabla, filtrada por
     `Proyecto` = esta fila, ordenada por `Fecha` descendente.
   - Las dos nacen tituladas "View of Tareas"/"View of Documentación": justo
     después de crear cada una, renombra la base enlazada (no la vista) a
     `Tareas <CÓDIGO>` y `Documentación <CÓDIGO>` con `notion-update-page`
     (`update_properties`, propiedad `title`) sobre el `id` del bloque
     `<database>` que devolvió `create_view`.
4. Si `.devkit/devkit.toml` aún tiene `project = "PROJ"` (placeholder de
   `entrypoint.sh`), regístralo en git. Nunca hagas push directo a `main`:
   la protección de rama lo rechaza ("Changes must be made through a pull
   request", GH013). Mismo patrón que `task-submit.sh`:
   - Crea la rama `chore/<CÓDIGO>-0-registrar-proyecto` desde `main`.
   - En `.devkit/devkit.toml`, cambia `project` por el código real.
   - Si no existe un `.gitignore` en la raíz del proyecto, créalo con un
     mínimo: `/.claude/`, `*.local`, `.devkit/costos.log`,
     `.devkit/pr-body.md`, `.devkit/review-*.md`.
   - Commitea todo lo que generó el arranque y que aún no está en git:
     `.devkit/devkit.toml`, `AGENTS.md`, `CLAUDE.md` y el `.gitignore` si lo
     creaste. Mensaje `chore(<CÓDIGO>-0): registrar proyecto`; usa `-0`
     porque todavía no hay card.
   - Sube la rama, `gh pr create` y `gh pr merge --auto --squash`. Dile al
     humano que apruebe ese PR. Hasta que se mergee, `.devkit/devkit.toml`,
     `AGENTS.md`, `CLAUDE.md` y el `.gitignore` solo existen en la rama
     `chore/<CÓDIGO>-0-registrar-proyecto`: `main` sigue sin ellos. Ninguna
     card debe pasar a Lista antes del merge: `task-begin.sh` solo revisa que
     el workspace esté limpio, no que `main` traiga estos archivos, así que
     arrancaría la card sobre una rama creada desde ese `main` incompleto.
5. Verifica y reporta con una lista de comprobaciones: fila creada con URL;
   vista Kanban creada, agrupada por Estado y mostrando sus ocho columnas
   (Por refinar, Backlog, Lista, En progreso, Revisión automática, Lista
   para merge, Hecha, Bloqueada) para que el humano las contraste sin abrir
   Notion, con una nota si "ocultar grupos vacíos" quedó pendiente de
   apagar a mano; vista Documentación creada; las dos bases enlazadas
   tituladas `Tareas <CÓDIGO>` y `Documentación <CÓDIGO>`; y
   `git status --porcelain --untracked-files=all` vacío.

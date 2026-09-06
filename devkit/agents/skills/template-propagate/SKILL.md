---
name: template-propagate
description: Desde el proyecto DEVKIT, abre un PR de actualización de template en cada proyecto registrado en Notion que esté por debajo de la última etiqueta. Úsala después de publicar una etiqueta nueva de dotfiles. Sin argumentos.
---

# template-propagate

Solo se ejecuta en el proyecto `DEVKIT`. Si `AGENTS.md` dice otro código,
detente.

## Pasos

1. Última etiqueta: `git tag --sort=-v:refname | head -1` en el workspace,
   sin la `v`.
2. Consulta Proyectos en Notion: filas con `Estado` = `Activo` y
   `Versión del template` distinta de la última y distinta de `dev`.
3. Para cada proyecto, en un directorio temporal:
   - `git clone <Repo> /tmp/propagate/<nombre>` y entra.
   - `git switch -c chore/<CÓDIGO>-template-<X.Y.Z>`.
   - Escribe la versión en `DEVKIT_VERSION`, commit
     `chore(<CÓDIGO>-0): actualizar template a <X.Y.Z>`, push.
   - `gh pr create --base main --title "<CÓDIGO>-0 Actualizar template a
     <X.Y.Z>"` con cuerpo: entradas del changelog entre versiones y, si es
     MAJOR, los cambios manuales requeridos. `gh pr merge --auto --squash`.
   - Borra el directorio temporal.
4. Reporta una línea por proyecto: nombre, versión actual, URL del PR.

## Reglas

- No toques proyectos con `Versión del template` = `dev`: son proyectos que
  desarrollan el template.
- La fila de Proyectos se actualiza cuando el PR se mergea, desde
  `template-update` en ese proyecto, no aquí.

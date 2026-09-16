---
name: template-propagate
description: Desde el proyecto DEVKIT, abre un PR de actualización de template en cada proyecto registrado en Notion que esté por debajo de la última etiqueta. Úsala después de publicar una etiqueta nueva de dotfiles. Sin argumentos.
---

# template-propagate

Solo se ejecuta en el proyecto `DEVKIT`. Si `project` de `.devkit/devkit.toml`
dice otro código, detente.

## Pasos

1. Última etiqueta: `git tag --sort=-v:refname | head -1` en el workspace,
   sin la `v`.
2. Consulta Proyectos en Notion: filas con `Estado` = `Activo` y
   `Versión del template` distinta de la última y distinta de `dev`.
3. Para cada proyecto, en un directorio temporal:
   - `git clone <Repo> /tmp/propagate/<nombre>` y entra.
   - `git switch -c chore/<CÓDIGO>-0-template-<X.Y.Z>`.
   - Cambia `template` a `<X.Y.Z>` en `.devkit/devkit.toml`, sin hacer commit
     todavía. Si el clon todavía tiene `devkit.toml` en la raíz, muévelo a
     `.devkit/devkit.toml` primero (migración de DEVKIT-53) y dilo en el
     cuerpo del PR.
   - Funde `AGENTS.md` con la plantilla de esta versión, la misma fusión que
     usa `template-update`: renderiza `devkit/agents/AGENTS.template.md` de
     este mismo repo (DEVKIT ya está en la última etiqueta, no hace falta
     descargarlo) sustituyendo `{{PROJECT}}` por el `project` del
     `.devkit/devkit.toml` clonado, y corre
     `bash devkit/scripts/agents-sync.sh <plantilla renderizada> AGENTS.md`
     (también de este repo) contra el `AGENTS.md` del clon. Código `0`:
     reemplázalo. Código `1`: no hay nada que tocar. Código `2`: no lo
     toques; agrega el diff al cuerpo del PR bajo "AGENTS.md sin marcador:
     revisar a mano".
   - Commit `chore(<CÓDIGO>-0): actualizar template a <X.Y.Z>` con
     `.devkit/devkit.toml` y, si se tocó, `AGENTS.md`. Push.
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

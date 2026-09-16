---
name: template-update
description: Sube la versión del template devkit que usa este proyecto: cambia `template` en devkit.toml, actualiza la fila del proyecto en Notion y explica qué cambia según el changelog. Úsala cuando el arranque avise de una versión nueva o el humano lo pida. Argumento: la versión destino, por ejemplo 1.4.0.
---

# template-update

Argumento: versión destino `X.Y.Z`.

## Pasos

1. Si `devkit.toml` todavía está en la raíz del workspace, muévelo a
   `.devkit/devkit.toml` (una sola vez; migración de DEVKIT-53) y dilo en el
   comentario de la card. Lee la clave `template` de `.devkit/devkit.toml`.
   Si ya es la destino, termina.
2. Descarga el changelog del template:
   `curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/v<X.Y.Z>/devkit/CHANGELOG.md`.
   Extrae las entradas entre la versión actual y la destino.
3. Si el salto es MAJOR (cambia el primer número), lee en el changelog qué
   hay que tocar fuera del template (`devkit.env`, volúmenes, secretos) y
   escríbelo en el comentario del PR. No apliques esos cambios tú: son del
   humano en su Mac.
4. Trabaja como una card: si no existe, créala con `task-create` (Tipo
   `chore`, título "Actualizar template a <X.Y.Z>") en `Lista` y arráncala
   con `task-start`.
5. Cambia `template` a la versión destino en `.devkit/devkit.toml`, sin hacer
   commit todavía.
6. Pon al día `AGENTS.md` con la plantilla de la versión destino, sin perder
   lo que el proyecto haya agregado:
   - Descarga `AGENTS.template.md` y `agents-sync.sh` de esa versión:
     `curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/v<X.Y.Z>/devkit/agents/AGENTS.template.md`
     y `.../devkit/scripts/agents-sync.sh`.
   - Renderízala: sustituye `{{PROJECT}}` por el valor de `project` en
     `.devkit/devkit.toml`.
   - `bash agents-sync.sh <plantilla renderizada> AGENTS.md > AGENTS.md.nuevo`.
     Según el código de salida:
     - `0`: reemplaza `AGENTS.md` por `AGENTS.md.nuevo`.
     - `1`: ya está al día, no hay nada que tocar.
     - `2`: el `AGENTS.md` del proyecto no tiene el marcador
       `## Reglas del proyecto` (viene de antes de esa convención). No lo
       toques: pega `diff -u AGENTS.md <plantilla renderizada>` en el cuerpo
       del PR, bajo un encabezado "AGENTS.md sin marcador: revisar a mano", y
       deja la fusión al humano.
7. Commit `chore(<Clave>): actualizar template a <X.Y.Z>` con
   `.devkit/devkit.toml` y, si el paso anterior lo tocó, `AGENTS.md`.
8. `task-submit`. En el cuerpo del PR incluye el resumen del changelog y, si
   aplica, los cambios manuales requeridos.
9. Actualiza en Notion la fila del proyecto: `Versión del template` = destino.
10. Una vez mergeado, en el Mac: `devkit update <proyecto>`. Lee `template`
    desde el contenedor, descarga esa versión y reconstruye; el `.env` del
    Mac queda al día.

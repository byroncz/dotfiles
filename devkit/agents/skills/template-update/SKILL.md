---
name: template-update
description: Sube la versión del template devkit que usa este proyecto: cambia DEVKIT_VERSION, actualiza la fila del proyecto en Notion y explica qué cambia según el changelog. Úsala cuando el arranque avise de una versión nueva o el humano lo pida. Argumento: la versión destino, por ejemplo 1.4.0.
---

# template-update

Argumento: versión destino `X.Y.Z`.

## Pasos

1. Lee `DEVKIT_VERSION` del workspace. Si ya es la destino, termina.
2. Descarga el changelog del template:
   `curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/v<X.Y.Z>/CHANGELOG.md`.
   Extrae las entradas entre la versión actual y la destino.
3. Si el salto es MAJOR (cambia el primer número), lee en el changelog qué
   hay que tocar fuera del template (`devkit.env`, volúmenes, secretos) y
   escríbelo en el comentario del PR. No apliques esos cambios tú: son del
   humano en su Mac.
4. Trabaja como una card: si no existe, créala con `task-create` (Tipo
   `chore`, título "Actualizar template a <X.Y.Z>") en `Lista` y arráncala
   con `task-start`.
5. Cambia `DEVKIT_VERSION` al valor destino. Commit
   `chore(<Clave>): actualizar template a <X.Y.Z>`.
6. `task-review`. En el cuerpo del PR incluye el resumen del changelog y, si
   aplica, los cambios manuales requeridos.
7. Actualiza en Notion la fila del proyecto: `Versión del template` = destino.

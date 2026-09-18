---
name: task-submit
description: Entrega para revisión el trabajo de una card en progreso: verifica, sube la rama, abre el PR con auto-merge, registra la URL del PR y pasa la card a Revisión automática. No emite veredicto; quien revisa es pr-review, en otro proceso. Úsala cuando los criterios de aceptación se cumplan o cuando el humano pida abrir el PR. Argumento opcional: la Clave; por defecto la card de la rama actual.
---

# task-submit

Argumento opcional: Clave. Por defecto se deduce de la rama actual.

Todo lo mecánico -verificar, comitear, subir la rama, crear o actualizar el
PR, activar auto-merge, actualizar la card, comentar y avisar al bucle- lo
hace `devkit/scripts/task-submit.sh` (DEVKIT-91). Esta skill solo aporta lo
que un script no puede: repasar los criterios y redactar el cuerpo del PR.

## Pasos

1. Repasa los criterios de aceptación de la card uno por uno y confirma cada
   uno con un comando o una observación concreta. Si alguno no se cumple,
   complétalo antes de seguir.
2. Escribe `.devkit/pr-body.md` con exactamente estas tres secciones, en este
   orden:

   ```
   ## Qué cambia
   Dos o tres líneas.

   ## Cómo probarlo
   Comandos u observaciones, en orden.

   ## Cambios requeridos
   Qué debe hacer un proyecto instanciado para adoptar este cambio
   (`devkit recreate`, reinstalar el comando del Mac, un secreto nuevo en
   Bitwarden...), o "Ninguno" si no aplica. Es la única fuente de este dato:
   de aquí lo toman la entrada de Documentación de la card y las notas de la
   próxima release.
   ```

   El script agrega la sección `## Card` (con la URL de la card y la línea
   "Implementado con ...", DEVKIT-58) y borra el archivo al terminar; no las
   escribas a mano.

3. Ejecuta:

   ```sh
   "${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-submit.sh" --mensaje "<tipo>(<Clave>): <resumen>"
   ```

   El mensaje es el del commit de lo pendiente, en Conventional Commits con
   la Clave como ámbito. El script verifica (`ruff`, `pytest`, `bash -n`
   sobre los `.sh` tocados), comitea, sube la rama, crea o actualiza el PR,
   activa auto-merge, deja `PR` y `Estado=Revisión automática` en la card,
   comenta y avisa a `watch.sh`. Si algo falla, se detiene con salida 1 y el
   error en stderr; corrígelo y vuelve a ejecutarlo.

A partir de aquí el ciclo es automático: la skill `pr-review` decide si la
card pasa a `Lista para merge` o si `task-fix` la corrige y la deja de nuevo
en `Revisión automática`. `task-submit` no vuelve a tocar esta card salvo que
el humano lo pida explícitamente.

## Reglas

- Nunca `gh pr merge` sin `--auto`, nunca `gh pr review --approve`.
- Un PR por card. Si el trabajo necesita dos PRs, la card debía ser dos.

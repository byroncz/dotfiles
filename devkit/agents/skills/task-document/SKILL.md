---
name: task-document
description: Escribe o actualiza la entrada de Documentación de una card aprobada. La lanza el bucle watch.sh cuando pr-review da OK y la card entra en Lista para merge; si la card vuelve atrás y recibe otro OK, corre de nuevo y actualiza la misma entrada. También la lanza task-close.sh si al cerrar falta la entrada, o para la entrada consolidada de una Épica. Argumentos: la Clave; opcionalmente el número de PR.
---

# task-document

Argumentos: Clave. Opcional: número o URL del PR.

La entrada se escribe al aprobar, no al cerrar: así la lee el humano antes de
aprobar el PR y refleja las correcciones de la revisión (DEVKIT-55). Esta
skill no cambia el `Estado` de la card ni toca código.

## Pasos

1. Localiza la card (por `ID` y `Proyecto`, ver `.claude/skills/README.md`).
   Si `Nivel` es Épica, salta al paso 7.
2. PR: el del argumento o la propiedad `PR` de la card. Si no hay, comenta
   en la card que falta el PR y termina. Lee el estado y el head:

   ```sh
   gh pr view <N> --json number,url,state,headRefOid,headRefName,mergeCommit,body,reviews
   ```

3. Reúne el material, sin inventar nada que no esté en él: la card completa
   (Objetivo, Criterios, Notas y comentarios), la descripción del PR, el
   diff (`gh pr diff <N>`) y los informes de `pr-review` con sus respuestas
   de `task-fix`. Los hallazgos corregidos entran en la entrada: son parte
   de lo que cambió.
4. Busca la entrada existente por la relación `Tarea`, nunca por título:

   ```sh
   "${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/notion.sh" documentacion <page_id de la card>
   ```

   Devuelve `{id, url}` si existe y sale con 1 si no.
5. Escribe la entrada con el plugin de Notion. Si existe, reemplaza su
   contenido y actualiza `PR` y `Rama`; si no, créala en **Documentación**
   con `Título` = `<Clave>: <título corto>`, `Proyecto`, `Tarea` = la card,
   `Tipo` = `cambio` (o `decisión` si la card cambió una decisión de
   diseño), `Rama` y `PR`. Cuerpo, con estas secciones en este orden y
   completas:

   ```
   ## Qué cambió
   Qué existe ahora que antes no, en términos de comportamiento observable.

   ## Por qué
   La decisión y su justificación. Si hubo alternativas, cuál se descartó y
   por qué, con evidencia si la hay. Este es el único lugar donde se escribe
   el porqué completo.

   ## Cómo probarlo
   Comandos u observaciones para verificar el cambio.

   ## Cambios requeridos
   Lo que otra persona debe hacer para usar esto: variables nuevas en
   devkit.env, secretos, paquetes, rebuild, migraciones. "Ninguno" si aplica.

   ## Enlaces
   Card, rama, PR y, si ya está mergeado, commit de merge.

   ## Modelos
   Implementado con <modelo>, esfuerzo <esfuerzo>
   Revisado con <modelo>, esfuerzo <esfuerzo> (commit <sha corto>, <OK|CAMBIOS>)
   Documentado con <modelo>, esfuerzo <esfuerzo>
   ```

   La sección "Modelos" (DEVKIT-58) copia las marcas, no las deduce: la
   línea "Implementado con ..." del cuerpo del PR, la línea "Revisado con
   ..." de cada informe `devkit-review` en orden (una por informe, con su
   `sha` y veredicto) y, al final, la tuya, que sale de las variables que
   `devkit-run` exporta al `claude -p`: `echo "Documentado con
   ${DEVKIT_MODEL:-?}, esfuerzo ${DEVKIT_EFFORT:-?}"`. Si una marca falta en
   el PR o en un informe, escribe "sin marca" en su lugar. Si tus variables
   vienen vacías (sesión interactiva), escribe el alias del modelo que te
   ejecuta y `esfuerzo sin registrar`.

6. Marcador en el PR, solo si el PR sigue abierto. Es lo que le dice a
   `watch.sh` que ese head ya está documentado; sin él, el bucle relanza
   esta skill en cada vuelta. Comprueba antes que no está para ese head:

   ```sh
   gh pr view <N> --json comments \
     --jq '[.comments[] | select(.body | test("<!-- devkit-doc sha=<headRefOid> -->"))] | length'
   ```

   Si devuelve `0`, publícalo con una sola línea de texto:

   ```sh
   gh pr comment <N> --body "<!-- devkit-doc sha=<headRefOid> -->
   Documentación: <URL de la entrada>"
   ```

   Termina aquí.
7. Épica: verifica que está `Hecha` (la cierra `task-close.sh`). Crea o
   actualiza su entrada, buscada igual por `Tarea`, con `Tipo` = `cambio`:
   una línea por hija con enlace a su entrada (`notion.sh documentacion`
   con el id de cada hija) y la sección "Cambios requeridos" unificada. Una
   hija sin entrada se nombra como tal, sin inventar su contenido. No hay PR
   ni marcador. La sección "Modelos" de la Épica lleva solo la línea
   "Documentado con ..." de esta ejecución: las marcas de cada hija están en
   su propia entrada.

## Modo headless

`watch.sh` te invoca como `claude -p "/task-document <Clave> <N>"`, y
`task-close.sh` como `devkit-run task-document <Clave>`. No hay quien
conteste: nunca termines con una pregunta. Si falta algo para escribir la
entrada (card sin PR, Notion sin acceso), comenta en la card qué falta y
termina. No bloquees la card: la falta de documentación no detiene el merge,
y `task-close.sh` vuelve a lanzar esta skill si al cerrar la entrada no
existe.

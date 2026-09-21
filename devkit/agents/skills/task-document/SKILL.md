---
name: task-document
description: Escribe la entrada de Documentación en los dos casos que necesitan criterio: una entrada "decisión" (la card cambió una decisión de diseño, marcada con "Tipo: decisión" en el cuerpo del PR) o la entrada consolidada de una Épica. La entrada "cambio" de una card ordinaria la escribe devkit/scripts/task-document.sh, sin agente (DEVKIT-92). watch.sh te lanza solo si el PR trae esa marca; task-close.sh, solo para una Épica. Argumentos: la Clave; opcionalmente el número de PR.
---

# task-document

Argumentos: Clave. Opcional: número o URL del PR.

Dos casos, y solo esos dos (DEVKIT-92): una entrada "decisión" (esta card
cambió una decisión de diseño, no solo la implementó) y la entrada
consolidada de una Épica. La entrada "cambio" de una card ordinaria -el caso
común- la escribe `devkit/scripts/task-document.sh`, en bash y sin este
agente: copia el Objetivo de la card, las secciones del cuerpo del PR y las
marcas de modelo, sin redactar nada nuevo. Si te invocaron para una card de
Nivel Tarea sin la marca de decisión (ver paso 2 de más abajo), es que algo
llamó a esta skill por error: escribe la entrada igual, pero dilo en tu
respuesta final para que se corrija la llamada.

## Caso 1: entrada "decisión"

`watch.sh` te lanza cuando el cuerpo del PR trae la línea `Tipo: decisión`
(la agrega la skill `task-submit` cuando la card cambió una decisión de
diseño). A diferencia de la entrada "cambio", aquí el "Por qué" no se copia
de ningún lado: es el único lugar donde se explica la decisión completa, con
sus alternativas.

1. Localiza la card (por `ID` y `Proyecto`, ver `.claude/skills/README.md`).
2. PR: el del argumento o la propiedad `PR` de la card. Si no hay, comenta en
   la card que falta el PR y termina. Lee el estado y el head:

   ```sh
   gh pr view <N> --json number,url,state,headRefOid,headRefName,mergeCommit,body,reviews
   ```

3. Reúne el material, sin inventar nada que no esté en él: la card completa
   (Objetivo, Criterios, Notas y comentarios), la descripción del PR, el
   diff (`gh pr diff <N>`) y los informes de `pr-review` con sus respuestas
   de `task-fix`. Los hallazgos corregidos entran en "Qué cambió": son parte
   de lo que cambió.
4. Busca la entrada existente por la relación `Tarea`, con la Clave como
   segundo argumento para descartar una entrada de referencia ligada a la
   misma card (p. ej. una decisión congelada, DEVKIT-87):

   ```sh
   <ruta>/notion.sh documentacion <page_id de la card> <Clave>
   ```

   `<ruta>` es el valor `DEVKIT_SCRIPTS_DIR` de la primera línea de este
   prompt (`(DEVKIT_SCRIPTS_DIR=... DEVKIT_MODEL=... DEVKIT_EFFORT=...)`),
   copiado tal cual, como texto plano y sin `$`: por ejemplo
   `/opt/devkit/scripts/notion.sh`. Un comando armado con
   `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/..."` no sirve aquí: Claude
   Code rechaza con "Contains expansion" cualquier Bash que traiga una
   expansión de variable, sin mirar siquiera la lista allow (DEVKIT-125). Si
   esta sesión es interactiva y esa primera línea no está, usa
   `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}"` como antes: ahí sí corre
   bajo un perfil que lo permite.

   Devuelve `{id, url}` si existe una entrada cuyo `Título` empieza por
   `<Clave>:` y sale con 1 si no.
5. Escribe la entrada con `notion.sh` (la misma API interna que usa el
   script, sin plugin). Si existe (paso 4), reemplaza su contenido y
   actualiza `Rama`/`PR`:

   ```sh
   printf '%s' "$cuerpo" | <ruta>/notion.sh reemplazar-doc <page_id de la entrada> <Rama> <PR>
   ```

   Si no existe, créala en **Documentación**, con `Título` = `<Clave>:
   <título corto>`, `Tarea` = la card y `Tipo` = `decisión`:

   ```sh
   printf '%s' "$cuerpo" | <ruta>/notion.sh crear-doc <page_id de la card> <page_id del Proyecto> "<Clave>: <título corto>" decisión <Rama> <PR>
   ```

   `$cuerpo`, con estas secciones en este orden y completas:

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
   - Implementado con <modelo>, esfuerzo <esfuerzo>
   - Revisado con <modelo>, esfuerzo <esfuerzo> (commit <sha corto>, <OK|CAMBIOS>)
   - Documentado con <modelo>, esfuerzo <esfuerzo>
   ```

   La sección "Modelos" (DEVKIT-58) copia las marcas, no las deduce: la
   línea "Implementado con ..." del cuerpo del PR, la línea "Revisado con
   ..." de cada informe `devkit-review` en orden (una por informe, con su
   `sha` y veredicto) y, al final, la tuya: "Documentado con `<modelo>`,
   esfuerzo `<esfuerzo>`", con el `<modelo>` y el `<esfuerzo>` de la primera
   línea de este prompt (`DEVKIT_MODEL=... DEVKIT_EFFORT=...`), copiados tal
   cual, sin correr `echo` ni `printenv`: bajo este perfil, Claude Code
   rechaza con "Contains expansion" cualquier Bash que expanda una variable
   (DEVKIT-125). Si una marca falta en el PR o en un informe, escribe "sin
   marca" en su lugar. Si esa primera línea no está (sesión interactiva),
   escribe el alias del modelo que te ejecuta y `esfuerzo sin registrar`.

6. Marcador en el PR, solo si sigue abierto. Es lo que le dice a `watch.sh`
   que ese head ya está documentado; sin él, el bucle te relanza en cada
   vuelta (mismo mecanismo que usa `task-document.sh` para la entrada
   "cambio"). Comprueba antes que no está para ese head:

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

## Caso 2: entrada consolidada de una Épica

`task-close.sh` te lanza cuando cierra la última hija de una Épica.

7. Verifica que está `Hecha` (la cierra `task-close.sh`). Crea o actualiza su
   entrada, buscada igual por `Tarea` con la Clave de la Épica como segundo
   argumento (`notion.sh documentacion <id de la Épica> <Clave de la
   Épica>`), con `Tipo` = `cambio`: una línea por hija con enlace a su
   entrada, buscada de la misma forma (`notion.sh documentacion <id de la
   hija> <Clave de la hija>`), y la sección "Cambios requeridos" unificada.
   Una hija sin entrada se nombra como tal, sin inventar su contenido. No hay
   PR ni marcador. La sección "Modelos" de la Épica lleva solo la línea
   "Documentado con ..." de esta ejecución: las marcas de cada hija están en
   su propia entrada.

## Modo headless

`watch.sh` te invoca como `claude -p "/task-document <Clave> <N>"` cuando el
cuerpo del PR trae la marca de decisión, y `task-close.sh` como `devkit-run
task-document <Clave>` para la entrada consolidada de una Épica. No hay
quien conteste: nunca termines con una pregunta. Si falta algo para escribir
la entrada (card sin PR, Notion sin acceso), comenta en la card qué falta y
termina. No bloquees la card: la falta de documentación no detiene el merge.

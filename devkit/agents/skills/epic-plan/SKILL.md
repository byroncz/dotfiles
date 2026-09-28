---
name: epic-plan
description: Descompone una Épica aprobada (en Lista) en Tareas hijas ordenadas, las deja en Lista, publica el desglose como comentario y arranca la primera. Si el diseño da más de ocho hijas, parte la Épica: la original sigue y lo que sobra va a una Épica nueva en Por refinar; si no se puede partir limpio, bloquea. Úsala cuando el humano mueva una Épica a Lista o pida planificarla. Argumento: la Clave de la Épica, por ejemplo DEVKIT-1.
---

# epic-plan

Argumento: Clave de la Épica (`CÓDIGO-n`).

## Pasos

1. Localiza la Épica en Tareas (por `ID` y `Proyecto`, como dice el
   `README.md` de skills). Verifica que `Nivel` es Épica y `Estado` es
   `Lista`. Si `Estado` es `En progreso`, compara los Criterios de aceptación
   vigentes -los del cuerpo tal cual están ahora, el humano pudo haberlos
   editado ahí en vez de comentar- contra el último comentario de desglose:
   si traen algo nuevo (DEVKIT-94: relanzamiento sobre una Épica ya
   planificada, para no repetir lo del grupo 3 de DEVKIT-59, que quedó sin
   hijas propias para un criterio agregado tarde), sigue igual: el paso 5
   evita duplicar las hijas que ya existen. Con cualquier otro `Estado`,
   detente y explica por qué en una línea.
2. Lee su Objetivo, Criterios de aceptación y Notas. Lee también el estado del
   repo: `git log --oneline -20`, estructura de directorios, `AGENTS.md`.
3. Diseña las hijas. Reglas de corte:
   - Cada hija cabe en una rama de menos de un día y produce un PR revisable
     en menos de quince minutos.
   - Cada hija tiene criterios de aceptación propios y verificables.
   - Tamaño de una hija (DEVKIT-94): un solo cambio observable -un comando,
     una opción, un script, una regla de una skill-, con un diff estimado de
     menos de 150 líneas y como máximo cinco criterios de aceptación. Un
     criterio que necesita otra prueba distinta del resto (otro comando para
     verificarlo, otro archivo que tocar sin relación con los demás) es otra
     card, no un sexto criterio de la misma. DEVKIT-81 agrupó cuatro
     criterios de ese tipo y costó 125 turnos y tres revisiones; DEVKIT-74,
     seis líneas de cambio, 93 turnos igual: el tamaño de la card, no el del
     cambio, dispara el costo.
   - El conjunto cubre todos los criterios de la Épica y nada más. Lo que
     exceda el alcance va a una Épica nueva en Por refinar vía `task-create`.
   - Entre tres y ocho hijas. Si el diseño da más, la Épica es demasiado
     grande: sigue con la partición del paso 4 antes de crear nada.
   - Dependencias. Para cada par de hijas, anota qué archivos va a tocar
     cada una. **Si tocan los mismos archivos, dependen**: la de mayor
     `Orden` lleva a la otra en `Depende de` y espera a que esté `Hecha`
     (mergeada). Si no comparten archivos, no dependen, aunque una siga a la
     otra en `Orden`: arrancará en cuanto la anterior pase a `Lista para
     merge`, sin esperar el approve humano (DEVKIT-56). Dos ramas que
     editan el mismo archivo en paralelo acaban en conflicto de merge; dos
     que no, no. También depende la hija que necesita código que otra crea
     (un script, una función), aunque no edite su archivo.
4. Partición (solo si el paso 3 dio más de ocho hijas):
   - Las hijas que ya existían antes de este desglose (`Padre` = la Épica,
     de un relanzamiento previo) se quedan siempre en la original: no
     cuentan para el corte de "las primeras ocho". Del resto, agrupa en dos
     conjuntos usando la matriz de archivos y de dependencias de código del
     paso 3: junta primero las que comparten archivos o dependen entre sí, y
     completa hasta ocho, en `Orden`, en la Épica original; el resto sale a
     una Épica nueva. Si algún archivo aparece en hijas de los dos
     conjuntos, la partición no es limpia: salta al último punto de este
     paso. Trata también como cruce cualquier dependencia de código del
     paso 3 entre los dos conjuntos: si una hija que se queda depende de
     código de una que sale, la partición tampoco es limpia -la original no
     puede avanzar sin una Épica que queda bloqueada en Por refinar-; si es
     al revés, la partición sigue limpia y la Épica nueva lleva a la
     original en `Depende de`, además de las dependencias propias de sus
     hijas.
   - Revisa los Criterios de aceptación vigentes de la Épica: cada uno debe
     quedar cubierto por hijas de un solo conjunto. Si alguno necesita
     hijas de los dos lados, la partición tampoco es limpia.
   - Partición limpia: crea la Épica nueva con `task-create` (nace en `Por
     refinar`, su comportamiento por defecto), con el Objetivo y los
     Criterios de aceptación que cubren solo las hijas que salieron.
     Reescribe el Objetivo y los Criterios de aceptación de la Épica
     original para que cubran solo las hijas que se quedan, y agrega en sus
     Notas la línea `Partida el <fecha ISO>: <qué salió> pasó a <Clave
     nueva>.`. Busca en Tareas del proyecto las cards (cualquier `Estado`)
     que tengan la Épica original en `Depende de` y agrégales también la
     Clave nueva: recortar los Criterios de una Épica en Lista o En
     progreso es reducción de alcance, no ampliación, así que no hace
     falta la aprobación del humano que sí pide crecer una card. Sigue con
     el paso 5 usando solo las hijas que se quedaron.
   - Partición no limpia (archivos o criterios cruzados): bloquea la
     Épica con `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh"
     <Clave> "<motivo>"`, con la propuesta de partición en el motivo -qué
     hijas irían a cada lado y qué la cruza- y termina aquí, sin crear
     ninguna hija.
5. Si alguna hija ya existe (misma Épica como Padre), no la dupliques:
   reutilízala y ajusta `Orden`.
6. Crea las hijas con `task-create`, con `Padre` = la Épica, `Nivel` Tarea,
   `Orden` 1..n, `Depende de` según la regla del paso 3 (vacío si no
   comparte archivos con ninguna anterior), y `Estado` **`Lista`**: la
   aprobación de la Épica cubre a sus hijas. En las Notas de cada hija con
   `Depende de`, una línea con el motivo: qué archivos comparten.
7. Publica en la Épica un comentario con el desglose: una línea por hija con
   Clave, título y dependencias ("espera a Hecha de X" o "arranca con la
   anterior en Lista para merge"). Si el paso 4 partió la Épica, agrega una
   línea con qué salió, la Clave nueva y que espera en Por refinar a que el
   humano la mueva a Lista. Máximo doce líneas.
8. Mueve la Épica a `En progreso`.
9. Lanza como proceso aparte la primera hija nueva que quedó `Lista` (en un
   desglose inicial, la primera de todas; en un relanzamiento sobre una
   Épica `En progreso`, la primera de las que acabas de crear, si ninguna
   otra hija sigue activa) y termina aquí:
   `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/devkit-run.sh" task-start
   <Clave>`. Por ruta, no por el alias `devkit-run`: el alias solo existe en
   `zshrc`, y esta skill corre en el Bash no interactivo de `claude -p`, que
   no lo carga (DEVKIT-54). No la trabajes en esta misma ejecución: correría
   con el rol `revisión` de `epic-plan` (modelo fuerte, esfuerzo alto) en vez
   del rol `implementación` que le toca, que es lo que resuelve `devkit-run`
   (DEVKIT-50).

## Reglas

- El humano puede vetar en cualquier momento moviendo una hija a Backlog o
  Bloqueada. No discutas el veto; respétalo.
- Si la Épica no tiene criterios de aceptación, no planifiques: bloquéala
  con `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh" <Clave>
  "<motivo>"` pidiendo criterios.

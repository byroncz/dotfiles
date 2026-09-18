---
name: epic-plan
description: Descompone una Épica aprobada (en Lista) en Tareas hijas ordenadas, las deja en Lista, publica el desglose como comentario y arranca la primera. Úsala cuando el humano mueva una Épica a Lista o pida planificarla. Argumento: la Clave de la Épica, por ejemplo DEVKIT-1.
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
   hijas propias para un criterio agregado tarde), sigue igual: el paso 4
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
     exceda el alcance va a una Épica nueva en Backlog vía `task-create`.
   - Entre tres y ocho hijas. Si salen más, la Épica es demasiado grande:
     propón partirla y detente.
   - Dependencias. Para cada par de hijas, anota qué archivos va a tocar
     cada una. **Si tocan los mismos archivos, dependen**: la de mayor
     `Orden` lleva a la otra en `Depende de` y espera a que esté `Hecha`
     (mergeada). Si no comparten archivos, no dependen, aunque una siga a la
     otra en `Orden`: arrancará en cuanto la anterior pase a `Lista para
     merge`, sin esperar el approve humano (DEVKIT-56). Dos ramas que
     editan el mismo archivo en paralelo acaban en conflicto de merge; dos
     que no, no. También depende la hija que necesita código que otra crea
     (un script, una función), aunque no edite su archivo.
4. Si alguna hija ya existe (misma Épica como Padre), no la dupliques:
   reutilízala y ajusta `Orden`.
5. Crea las hijas con `task-create`, con `Padre` = la Épica, `Nivel` Tarea,
   `Orden` 1..n, `Depende de` según la regla del paso 3 (vacío si no
   comparte archivos con ninguna anterior), y `Estado` **`Lista`**: la
   aprobación de la Épica cubre a sus hijas. En las Notas de cada hija con
   `Depende de`, una línea con el motivo: qué archivos comparten.
6. Publica en la Épica un comentario con el desglose: una línea por hija con
   Clave, título y dependencias ("espera a Hecha de X" o "arranca con la
   anterior en Lista para merge"). Máximo diez líneas.
7. Mueve la Épica a `En progreso`.
8. Lanza como proceso aparte la primera hija nueva que quedó `Lista` (en un
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

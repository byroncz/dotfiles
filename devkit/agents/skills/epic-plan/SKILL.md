---
name: epic-plan
description: Descompone una Épica aprobada (en Lista) en Tareas hijas ordenadas, las deja en Lista, publica el desglose como comentario y arranca la primera. Úsala cuando el humano mueva una Épica a Lista o pida planificarla. Argumento: la Clave de la Épica, por ejemplo DEVKIT-1.
---

# epic-plan

Argumento: Clave de la Épica (`CÓDIGO-n`).

## Pasos

1. Localiza la Épica en Tareas (por `ID` y `Proyecto`, como dice el
   `README.md` de skills). Verifica que `Nivel` es Épica y
   `Estado` es `Lista`. Si no, detente y explica por qué en una línea.
2. Lee su Objetivo, Criterios de aceptación y Notas. Lee también el estado del
   repo: `git log --oneline -20`, estructura de directorios, `AGENTS.md`.
3. Diseña las hijas. Reglas de corte:
   - Cada hija cabe en una rama de menos de un día y produce un PR revisable
     en menos de quince minutos.
   - Cada hija tiene criterios de aceptación propios y verificables.
   - El conjunto cubre todos los criterios de la Épica y nada más. Lo que
     exceda el alcance va a una Épica nueva en Backlog vía `task-create`.
   - Entre tres y ocho hijas. Si salen más, la Épica es demasiado grande:
     propón partirla y detente.
4. Si alguna hija ya existe (misma Épica como Padre), no la dupliques:
   reutilízala y ajusta `Orden`.
5. Crea las hijas con `task-create`, con `Padre` = la Épica, `Nivel` Tarea,
   `Orden` 1..n, `Depende de` cuando una necesite a otra, y `Estado`
   **`Lista`**: la aprobación de la Épica cubre a sus hijas.
6. Publica en la Épica un comentario con el desglose: una línea por hija con
   Clave, título y dependencias. Máximo diez líneas.
7. Mueve la Épica a `En progreso`.
8. Ejecuta `task-start` sin argumento: tomará la primera hija libre.

## Reglas

- El humano puede vetar en cualquier momento moviendo una hija a Backlog o
  Bloqueada. No discutas el veto; respétalo.
- Si la Épica no tiene criterios de aceptación, no planifiques: usa
  `task-block` sobre la Épica pidiendo criterios.

---
name: project-status
description: Reconcilia Notion con GitHub y resume el estado del proyecto: cierra cards en Revisión automática o Lista para merge cuyo PR ya se mergeó, señala cards huérfanas o inactivas y dice cuál es la siguiente card libre. Úsala al abrir la sesión en el proyecto o en cualquier momento en que el humano pregunte "en qué vamos".
---

# project-status

Sin argumentos.

## Pasos

1. Lee `.claude/devkit-notion.json` y `AGENTS.md` para conocer el proyecto.
2. `git fetch origin` y `git status -sb`. Si hay cambios sin commit, dilo en
   la primera línea del resumen.
3. Cards en `Revisión automática` o `Lista para merge` del proyecto: para
   cada una con `PR`, consulta `gh pr view <PR> --json state`. Si está
   `MERGED`, ciérrala con `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-close.sh"
   <Clave> <PR>` (bash, desde DEVKIT-55). Si está `CLOSED` sin merge,
   bloquéala con `task-block.sh <Clave> "<motivo>"`, en el mismo directorio,
   pidiendo decisión.
4. Cards `En progreso` de `Nivel` Tarea del proyecto: verifica que su rama
   existe en origin. Si no existe, coméntalo y ponla en `Lista`. Una Épica
   nunca tiene rama, así que queda fuera de este paso sin importar cuánto
   lleve `En progreso`.
5. Detecta anomalías y lístalas:
   - Tareas (Nivel Tarea) sin `Padre` y sin `Prioridad`: huérfanas.
   - Cards en `Lista`, `En progreso`, `Revisión automática` o `Lista para
     merge` sin actividad en catorce días: inactivas.
   - Épicas `En progreso` con todas las hijas `Hecha`: cerrar con
     `task-close.sh <Clave de la Épica>`.
6. Determina la siguiente card libre con el mismo criterio de `task-start`.

## Salida

Un resumen de máximo diez líneas, en este orden: estado del repo, cards
cerradas ahora, anomalías, siguiente card libre y cómo arrancarla
(`/task-start <Clave>`). Sin explicaciones adicionales.

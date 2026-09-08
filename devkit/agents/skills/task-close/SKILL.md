---
name: task-close
description: Cierra una card cuyo PR ya fue mergeado: la pasa a Hecha, escribe la entrada de Documentación y, si es hija de una Épica, toma la siguiente hija y la trabaja completa, o cierra la Épica. La invoca el bucle watch.sh en modo headless, o el humano. Argumento: la Clave; opcionalmente la URL del PR.
---

# task-close

Argumento: Clave. Opcional: URL del PR.

## Pasos

1. Localiza la card. Si ya está `Hecha`, responde "ya cerrada" y termina:
   este skill se ejecuta varias veces y debe ser idempotente.
   Si `Nivel` es Épica, no hay PR: verifica que todas sus hijas están
   `Hecha` y salta al cierre de Épica del paso 7. Si falta alguna, responde
   cuáles y termina.
2. Verifica el merge: `gh pr view <url o número> --json state,mergedAt,mergeCommit,url`.
   Si no recibiste URL, usa la propiedad `PR` de la card; si también está
   vacía, comenta en la card que falta el PR y termina.
   Si `state` no es `MERGED`, no cierres nada; responde "PR no mergeado" y
   termina.
3. Actualiza la card: `Estado` = `Hecha`, `Cierre` = fecha de hoy, `PR` si
   faltaba.
4. Crea la entrada en **Documentación** con `Proyecto`, `Tarea` = la card,
   `Tipo` = `cambio` (o `decisión` si la card cambió una decisión de diseño),
   `Rama`, `PR`. Cuerpo, con estas secciones en este orden y completas:

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
   Card, rama, PR, commit de merge.
   ```

5. Comenta en la card una línea: "Cerrada. Documentación: <URL>".
6. Limpieza local: `git switch main && git pull --ff-only && git branch -d
   <rama>` si la rama existe localmente.
7. Si la card tiene `Padre`:
   - Si todas las hijas del Padre están `Hecha`: pon la Épica en `Hecha` con
     `Cierre`, y crea una entrada de Documentación de tipo `cambio` para la
     Épica que consolide: una línea por hija con enlace a su entrada, y la
     sección "Cambios requeridos" unificada.
   - Si quedan hijas: ejecuta `task-start` sin argumento para tomar la
     siguiente libre y trabájala completa en esta misma ejecución, hasta
     `task-review` o `task-block`. Arrancarla y devolver el control no
     cuenta: nadie la va a retomar. Si no hay libres por dependencias,
     comenta en la Épica qué falta.

## Modo headless

`watch.sh` te invoca como `claude -p "/task-close <Clave> <URL PR>"`.
No hay quien conteste: una pregunta al humano equivale a `task-block`. Si falta
una decisión, un acceso o información para cerrar, ejecuta `task-block` con la
petición concreta y termina; si no hay card que bloquear, comenta en la card
que sí exista. Nunca termines con una pregunta abierta: la ejecución cierra en
un estado observable de la card.

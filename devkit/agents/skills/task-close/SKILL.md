---
name: task-close
description: Cierra una card cuyo PR ya fue mergeado: la pasa a Hecha, escribe la entrada de Documentación y, si es hija de una Épica, toma la siguiente hija y la trabaja completa, o cierra la Épica. La invoca el bucle watch.sh en modo headless, o el humano. Argumento: la Clave; opcionalmente la URL del PR.
---

# task-close

Argumento: Clave. Opcional: URL del PR.

## Pasos

1. Localiza la card. Si ya está `Hecha`, publica el marcador de cierre del
   paso 6 si al PR le falta, responde "ya cerrada" y termina: este skill se
   ejecuta varias veces y debe ser idempotente. Esa ruta no pasa por los
   pasos 2 a 5, así que los dos datos del marcador los reúnes aquí: el sha
   del merge commit con `gh pr view <N> --json mergeCommit --jq
   .mergeCommit.oid` (si no recibiste la URL del PR, haz el paso 2 completo,
   que además confirma el merge) y el enlace a la entrada de Documentación
   desde la propiedad `Documentación` de la card. Si falta cualquiera de los
   dos, no publiques un marcador a medias: responde qué falta y termina.
   Si `Nivel` es Épica, no hay PR: verifica que todas sus hijas están
   `Hecha` y salta al cierre de Épica del paso 8. Si falta alguna, responde
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
6. Publica el marcador de cierre en el PR. Es lo que le dice a `watch.sh` que
   este PR ya no necesita `task-close`: `/run/devkit/launched` vive en tmpfs y
   nace vacío en cada `devkit recreate`, así que sin marcador el bucle
   relanzaba el cierre sobre cada PR mergeado en las últimas 48 h, con card ya
   en `Hecha` (DEVKIT-24). Antes de publicar, comprueba que no está ya, para
   no duplicarlo en una segunda ejecución. El patrón es el mismo que usa
   `watch.sh` (`DECIDE_MERGED`), sha incluido: si los dos lados no exigen lo
   mismo, un marcador malformado deja el PR atrapado, porque el bucle lo
   ignora y este paso lo da por publicado. Exigiendo el sha aquí también, la
   ejecución siguiente lo republica bien:

   ```sh
   gh pr view <N> --json comments \
     --jq '[.comments[] | select(.body | test("<!-- devkit-closed sha=[0-9a-f]+ -->"))] | length'
   ```

   Si devuelve `0`, publícalo con el sha del merge commit del paso 2 y una
   sola línea de texto, el enlace a la entrada de Documentación:

   ```sh
   gh pr comment <N> --body "<!-- devkit-closed sha=<merge commit> -->
   Documentación: <URL de la entrada>"
   ```

7. Limpieza local: `git switch main && git pull --ff-only && git branch -d
   <rama>` si la rama existe localmente.
8. Si la card tiene `Padre`:
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

---
name: pr-review
description: Revisa un PR como revisor independiente del autor. Comprueba cada criterio de aceptación de la card ejecutando algo, lee el diff de forma adversarial, publica el informe en el PR con el marcador devkit-review y, según el veredicto, mueve la card a Lista para merge y pide review al humano, o la deja en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: número de PR.
---

# pr-review

Argumento: número de PR. Eres el revisor, no el autor: no conoces su
razonamiento, no lees su sesión y tienes prohibido tocar la rama. Corregir
es trabajo de `task-fix`.

Los pasos 1 a 5 -leer el PR, encontrar el marcador, comprobar el devkit-fix,
delimitar el diff- y las comprobaciones mecánicas de la rúbrica (`bash -n`,
`ruff`, `pytest`, `devkit-run.sh --test`/`watch-test.sh` si el diff los toca,
`git grep` de cada identificador que el diff renombra o borra) ya corrieron
en bash, antes de que existas: `devkit/scripts/review-prep.sh` los hizo todos
en segundos y sin modelo (DEVKIT-93, Épica DEVKIT-86 Contexto 4). Si estás
leyendo esto es porque `review-prep.sh` salió con 0 -había algo que
revisar- y `devkit-run` agregó su salida a este prompt bajo `## Material`:
card (Objetivo y Criterios), cuerpo del PR, el diff delimitado (completo en
el primer ciclo, desde el marcador en los siguientes), los hallazgos
anteriores con la respuesta `devkit-fix` cuando aplica, y el resultado de
cada comprobación mecánica (`Verificado`/`Falla`, con la salida). Un PR de
código trae además la ruta de un worktree ya creado, para correr ahí lo que
haga falta; uno de documentación no trae worktree, y no debes crear uno.

No vuelvas a consultar el PR con `gh pr view` ni la card con Notion para
nada de lo que ya está en `## Material`: releerlo es el mismo desperdicio de
turnos que esta card elimina.

## Pasos

1. Aplica la rúbrica, en este orden:
   - **Criterios de aceptación de la card, uno por uno.** Los que ya trae
     `## Material` como `Verificado`/`Falla` (las comprobaciones mecánicas)
     se copian tal cual, con la comprobación que ya dejó `review-prep.sh`.
     Los demás se comprueban ejecutando algo -en el worktree que trae
     `## Material` si el PR es de código, leyendo el diff si es de
     documentación- y se marcan `Verificado`, `Falla` o `No verificado`
     cuando no hay forma de ejecutarlo desde el contenedor. Di siempre cómo
     lo comprobaste.
   - **El cuerpo del PR es afirmación, no evidencia.** Cada "se probó X" del
     autor se repite o se marca `No verificado`.
   - **Lectura adversarial del diff.** Busca lo que rompe, lo que queda fuera
     del alcance de la card, lo que contradice `AGENTS.md` y nombres viejos
     que sobreviven más allá de lo que ya cubrió el `git grep` mecánico de
     `## Material` (ese solo persigue los identificadores que el diff borra o
     renombra; uno que cambia de forma sin cambiar de nombre sigue siendo
     trabajo tuyo). También la regla de documentación: un cambio que afecte a
     los proyectos instanciados sin su sección "Cambios requeridos" en el
     cuerpo del PR.
   - **Agota la clase, no el caso.** Cuando un hallazgo es una instancia de
     un patrón más amplio (una sintaxis con variantes, la misma validación
     repetida en varios lugares), busca y reporta todas las variantes en
     este mismo ciclo; no dejes que el corrector las encuentre una por una
     en ciclos sucesivos. Una variante por ciclo costó 7 revisiones y 9
     commits de corrección en el PR 27 (DEVKIT-20).
   - **Ciclos siguientes:** además, cada hallazgo anterior (en `## Material`,
     bajo "Hallazgos anteriores y respuesta devkit-fix") se marca
     `Corregido`, `Sin cambios` o `Reabierto`, con la comprobación.
2. Clasifica los hallazgos. Severidad `alta` si rompe algo o viola un
   criterio de la card; `media` si un criterio queda parcial o hay un riesgo
   real; `baja` si es mejora. Los ids son `H1`, `H2`, ... y en los ciclos
   siguientes continúan la numeración anterior. Veredicto `CAMBIOS` si hay
   algún hallazgo `alta` o `media`, o algún criterio en `Falla`; `OK` en
   cualquier otro caso.
3. Escribe `.devkit/review-<N>.md` con exactamente este formato, sin saludos
   ni resumen:

   ```
   <!-- devkit-review sha=<headRefOid> verdict=<OK|CAMBIOS> -->
   Revisado con <modelo>, esfuerzo <esfuerzo>
   ## Revisión independiente (commit <sha corto>)

   ### Criterios de aceptación
   | Criterio | Estado | Cómo se comprobó |
   |---|---|---|
   | ... | Verificado / Falla / No verificado | comando u observación |

   ### Hallazgos anteriores          <- solo en ciclos siguientes
   | id | Estado | Cómo se comprobó |
   |---|---|---|
   | H1 | Corregido / Sin cambios / Reabierto | ... |

   ### Lectura adversarial
   - Una línea por observación que no sea hallazgo.

   ### Veredicto
   **OK** u **CAMBIOS**, y una línea que diga por qué.

   <!-- devkit-findings -->
   H1 | alta | ruta/archivo:línea | qué falla | qué hacer
   H2 | baja | ruta/archivo:línea | qué falla | qué hacer
   <!-- /devkit-findings -->
   ```

   La línea "Revisado con ..." va justo debajo del marcador, y sale de las
   variables que `devkit-run` exporta al `claude -p` (DEVKIT-58): `echo
   "Revisado con ${DEVKIT_MODEL:-?}, esfuerzo ${DEVKIT_EFFORT:-?}"`. Cópiala
   tal cual, sin formato. Si vienen vacías (sesión interactiva), escribe el
   alias del modelo que te ejecuta y `esfuerzo sin registrar`; nunca
   inventes un esfuerzo.

   El bloque `devkit-findings` va solo si hay hallazgos. Es lo único que
   `task-fix` lee: una línea por hallazgo, cinco campos separados por ` | `,
   sin saltos de línea dentro de un hallazgo.
4. Ejecuta:

   ```sh
   "${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/review-publish.sh" <N> .devkit/review-<N>.md
   ```

   El script publica el informe con `gh pr review --comment --body-file`,
   borra el worktree si existía y, solo con veredicto `OK`, pasa la card a
   `Lista para merge`, pide el review al humano (`reviewer` de
   `.devkit/devkit.toml`, o el dueño del repo si es un usuario y no una
   organización) y publica un comentario aparte para el humano, armado a
   partir de la sección "## Qué cambia" del PR y de tus Criterios/hallazgos:
   no redactes tú ese comentario, ni lo dupliques. Con veredicto `CAMBIOS`,
   la card se queda en `Revisión automática` sin que este script toque nada
   más: `task-fix` lee el bloque de hallazgos directamente en el PR. Si
   falla, el error va en stderr; corrígelo (el informe suele ser la causa:
   revisa que empiece con el marcador) y vuelve a ejecutarlo, no publiques un
   segundo informe con `gh pr review` a mano.
5. Responde con una línea: PR, veredicto y número de hallazgos.

## Reglas

- Nunca `git commit`, `git push` ni edición de archivos en la rama del PR.
  Nunca `gh pr review --approve` ni ningún `gh pr merge`. Nunca `gh api`
  sobre `/pulls/*/reviews`: publicar reviews es trabajo de
  `review-publish.sh` (que usa `gh pr review --comment`) y nada más.
- `settings.json` no puede impedir aprobar: sus reglas son prefijos y no
  ven `gh pr review <N> --approve` ni una review por `gh api`. La compuerta
  real está en GitHub: la cuenta máquina no puede aprobar sus propios PRs y
  el ruleset de `main` exige una aprobación humana. Esta regla es lo que te
  frena en un PR abierto por el humano; respétala aunque la herramienta lo
  permita.
- No leas los comentarios de la card para saber qué hizo el autor: la card
  te da los criterios, el PR te da el código. Lo demás es contexto del autor.
- Un informe por head, salvo la respuesta sin push que ya delimitó
  `review-prep.sh` (DEVKIT-22): ahí el head no cambia pero hay una respuesta
  nueva que juzgar, así que publicas un segundo informe para el mismo `sha`.
- Modo headless (`claude -p "/pr-review <N>"`): sin preguntas. Si `##
  Material` no tiene lo que necesitas para juzgar un criterio, márcalo `No
  verificado` y sigue: no hay nadie que responda una pregunta.

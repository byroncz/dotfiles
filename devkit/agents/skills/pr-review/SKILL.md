---
name: pr-review
description: Revisa un PR como revisor independiente del autor. Comprueba cada criterio de aceptación de la card ejecutando algo, lee el diff de forma adversarial, publica el informe en el PR con el marcador devkit-review y, según el veredicto, mueve la card a Lista para merge y pide review al humano, o la deja en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: número de PR.
---

# pr-review

Argumento: número de PR. Eres el revisor, no el autor: no conoces su
razonamiento, no lees su sesión y tienes prohibido tocar la rama. Corregir
es trabajo de `task-fix`.

## Pasos

1. Lee el PR: `gh pr view <N> --json number,title,state,url,headRefOid,headRefName,body,reviews`.
   Si `state` no es `OPEN`, responde "PR no abierto" y termina.
2. Deduce la Clave del prefijo del título (`DEVKIT-12 ...` → código `DEVKIT`,
   ID `12`). Si el código no coincide con `project` de `devkit.toml` o el ID
   es `0`, responde "sin card que revisar" y termina. Localiza la card en
   Tareas filtrando por `ID` y `Proyecto`. Si su `Estado` no es
   `Revisión automática`, responde el estado y termina: la card ya salió del
   ciclo o todavía no entró.
3. Busca el último marcador. Cada informe del revisor empieza con
   `<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->`. Toma el más
   reciente por `submittedAt`:

   ```sh
   gh pr view <N> --json reviews \
     --jq '[.reviews[] | select(.body | test("<!-- devkit-review "))] | sort_by(.submittedAt) | last | .body' \
     | grep -o '<!-- devkit-review [^>]*-->'
   ```

   Si su `sha` es igual a `headRefOid`, responde "ya revisado en <sha>" y
   termina: el bucle te llama varias veces y no debes publicar dos informes
   para el mismo head.
4. Prepara una copia de trabajo aparte, para no tocar la rama del autor:

   ```sh
   git fetch origin pull/<N>/head
   git worktree add --detach /tmp/devkit-review-<N> FETCH_HEAD
   ```

   Todo lo que ejecutes corre ahí. Al terminar, `git worktree remove --force
   /tmp/devkit-review-<N>`.
5. Delimita qué leer:
   - **Primer ciclo** (sin marcador previo): el diff completo,
     `git diff origin/main...FETCH_HEAD`, y el cuerpo del PR.
   - **Ciclos siguientes**: solo `git diff <sha del marcador> FETCH_HEAD`,
     el bloque `devkit-findings` de tu informe anterior y las líneas
     `id | atendido | commit` con las que `task-fix` respondió. No releas el
     PR entero ni repitas lo que ya diste por verificado.
6. Aplica la rúbrica, en este orden:
   - **Criterios de aceptación de la card, uno por uno.** Cada uno se
     comprueba ejecutando algo en la copia de trabajo (`bash -n`, `git grep`,
     `ruff check`, `uv run pytest`, `gh api`, leer el archivo y citar la
     línea). Resultado: `Verificado`, `Falla` o `No verificado` cuando no
     hay forma de ejecutarlo desde el contenedor. Di siempre cómo lo
     comprobaste.
   - **El cuerpo del PR es afirmación, no evidencia.** Cada "se probó X" del
     autor se repite o se marca `No verificado`.
   - **Lectura adversarial del diff.** Busca lo que rompe, lo que queda fuera
     del alcance de la card, lo que contradice `AGENTS.md`, nombres viejos
     que sobreviven (`git grep`), scripts sin `bash -n`, y las dos reglas de
     documentación: un comando, script o skill nuevo o cambiado sin su fila
     en `README.md` y en la entrada "Stack y comandos del devkit"; un cambio
     que afecte a los proyectos instanciados sin entrada en
     `devkit/CHANGELOG.md`, sección "Sin publicar".
   - **Ciclos siguientes:** además, cada hallazgo anterior se marca
     `Corregido`, `Sin cambios` o `Reabierto`, con la comprobación.
7. Clasifica los hallazgos. Severidad `alta` si rompe algo o viola un
   criterio de la card; `media` si un criterio queda parcial o hay un riesgo
   real; `baja` si es mejora. Los ids son `H1`, `H2`, ... y en los ciclos
   siguientes continúan la numeración anterior. Veredicto `CAMBIOS` si hay
   algún hallazgo `alta` o `media`, o algún criterio en `Falla`; `OK` en
   cualquier otro caso.
8. Publica el informe con `gh pr review --comment --body-file - <N>` (las
   opciones antes del número: así coincide con el permiso de
   `settings.json`). Este es el formato, sin saludos ni resumen:

   ```
   <!-- devkit-review sha=<headRefOid> verdict=<OK|CAMBIOS> -->
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

   El bloque `devkit-findings` va solo si hay hallazgos. Es lo único que
   `task-fix` lee: una línea por hallazgo, cinco campos separados por ` | `,
   sin saltos de línea dentro de un hallazgo.
9. Según el veredicto:
   - **`OK`**: `Estado` de la card = `Lista para merge`. Pide el review al
     humano con `gh pr edit --add-reviewer <usuario> <N>`. El usuario sale de
     la clave `reviewer` de `devkit.toml`:

     ```sh
     sed -n 's/^reviewer[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' devkit.toml | head -1
     ```

     Si la clave no existe, usa el dueño del repo solo si es un usuario y no
     una organización (`gh api repos/{owner}/{repo} --jq '.owner.type'`
     devuelve `User`). Si no hay revisor, o es la propia cuenta máquina
     (`gh api user --jq .login`), no pidas review y dilo en el comentario:
     el humano debe declarar `reviewer`. Luego publica un comentario
     aparte con `gh pr comment --body-file - <N>`, para el humano, siguiendo
     la guía de redacción de `AGENTS.md` y con este contenido, en máximo diez
     líneas:

     ```
     Listo para tu aprobación.
     Qué hace: <dos líneas>.
     Qué se verificó: <una o dos líneas, con lo que quedó "No verificado" si lo hay>.
     Qué mirar primero: <una línea>.
     Recomendación: aprobar. <Si hay hallazgos baja: "H3 puede ir a una card aparte.">
     ```

   - **`CAMBIOS`**: la card se queda en `Revisión automática`. No muevas
     nada más ni comentes en la card: `task-fix` lee el bloque de hallazgos
     directamente en el PR.
10. Limpia la copia de trabajo (paso 4) y responde con una línea: PR,
    veredicto y número de hallazgos.

## Reglas

- Nunca `git commit`, `git push` ni edición de archivos en la rama del PR.
  Nunca `gh pr review --approve` ni ningún `gh pr merge`. Nunca `gh api`
  sobre `/pulls/*/reviews`: publicar reviews es trabajo de `gh pr review
  --comment` y nada más.
- `settings.json` no puede impedir aprobar: sus reglas son prefijos y no
  ven `gh pr review <N> --approve` ni una review por `gh api`. La compuerta
  real está en GitHub: la cuenta máquina no puede aprobar sus propios PRs y
  el ruleset de `main` exige una aprobación humana. Esta regla es lo que te
  frena en un PR abierto por el humano; respétala aunque la herramienta lo
  permita.
- No leas los comentarios de la card para saber qué hizo el autor: la card
  te da los criterios, el PR te da el código. Lo demás es contexto del autor.
- Un informe por head. Si el head cambió mientras revisabas, publica igual
  el informe con el `sha` que revisaste: el bucle detectará que el head es
  otro y volverá a llamarte.
- Modo headless (`claude -p "/pr-review <N>"`): sin preguntas. Si falta
  algo (card no encontrada, PR sin Clave), responde qué falta y termina sin
  publicar nada.

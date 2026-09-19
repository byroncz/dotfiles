---
name: task-fix
description: Corrige un PR dentro del ciclo automático. Lee el bloque devkit-findings del último informe de pr-review con veredicto CAMBIOS, o el comentario del humano sobre una card en Lista para merge, aplica los cambios en la rama de la card, hace push, responde en el PR con una línea por hallazgo y deja la card en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: la Clave; opcionalmente el texto de un comentario humano.
---

# task-fix

Argumento: Clave. Opcional: texto de un comentario humano. Eres el corrector,
no el revisor: no discutes el informe, lo atiendes. Revisar de nuevo es
trabajo de `pr-review`.

## Pasos

1. El argumento es la Clave, no el número de PR: si lo que llega antes del
   primer espacio es solo dígitos (sin letras ni guion), no es una Clave.
   Responde "task-fix recibe la Clave (por ejemplo DEVKIT-94), no el número
   de PR (<lo recibido>)" y termina ahí mismo, sin consultar Notion
   (DEVKIT-102: `devkit-run task-fix 68` tomó "68" como si fuera DEVKIT-68,
   una card distinta ya Hecha, y salió sin avisar del error de uso).
   Si es una Clave, localiza la card por `ID` y `Proyecto`. Su `Estado` debe
   ser `Revisión automática` o `Lista para merge`; en otro caso responde el
   estado y termina. Toma el número de PR de la propiedad `PR`; si está
   vacía, comenta en la card que falta el PR y termina.
2. Lee el PR: `gh pr view <N> --json state,url,headRefName,headRefOid,reviews,comments`.
   Si `state` no es `OPEN`, responde "PR no abierto" y termina.
3. Decide qué atender, en este orden:
   - **Texto recibido como argumento**: es un hallazgo único con id `C<n>`,
     donde `n` es uno más que el último `C` que hayas respondido en ese PR.
     Si ese texto nombra otro PR -una URL `github.com/.../pull/<M>` con `M`
     distinto de este PR, u otra Clave del proyecto que no sea la de esta
     card- no es un comentario sobre este PR: no lo trates como hallazgo.
     Comenta en la card qué llegó como argumento y por qué no aplica, y
     termina sin publicar ningún `devkit-fix` (DEVKIT-102: una fila ajena de
     `gh pr list` se coló una vez como argumento por una tubería de
     `watch.sh` sin cerrar, y el corrector la trató como un hallazgo real en
     vez de notar que hablaba de otro PR).
   - **Sin argumento y card en `Revisión automática`**: busca el último
     marcador `<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->` sobre
     `reviews` del paso 2, el mismo `jq` del paso 3 de `pr-review`:

     ```sh
     gh pr view <N> --json reviews \
       --jq '[.reviews[] | select(.body | test("<!-- devkit-review "))] | sort_by(.submittedAt) | last | .body' \
       | grep -o '<!-- devkit-review [^>]*-->'
     ```

     Si no hay marcador, o su `verdict` es `OK`, responde "nada que
     corregir" y termina. Si su `sha` no es `headRefOid`, el head ya cambió
     después del informe: responde "informe desactualizado, esperando a
     pr-review" y termina. Si ya existe un comentario de la cuenta máquina
     (`gh api user --jq .login`) cuyo marcador `devkit-fix` tenga `review=`
     igual a ese `sha`, responde "ya atendido" y termina. Este otro
     `jq`, distinto del de arriba, es solo para hallar ese marcador
     `devkit-fix` sobre `comments` del paso 2; no sirve para el marcador
     `devkit-review`, que vive en `reviews`:

     ```sh
     gh pr view <N> --json comments --jq '.comments[].body' \
       | grep -o 'devkit-fix sha=[0-9a-f]* review=[0-9a-f]*' \
       | grep -c 'review=<ese sha>'
     ```

     Si pasa todo, extrae el bloque
     `<!-- devkit-findings -->` ... `<!-- /devkit-findings -->` de ese
     informe: una línea por hallazgo, cinco campos separados por ` | `:
     `id | severidad | archivo:línea | qué falla | qué hacer`. Si ese bloque
     no trae ninguna línea con id `H<n>` -viene vacío, con otro formato, o el
     propio informe nombra un PR distinto de este-, no lo proceses como si
     tuviera hallazgos: comenta en la card qué trae el bloque y termina sin
     publicar.
   - **Sin argumento y card en `Lista para merge`**: toma los comentarios y
     reviews del PR de un autor distinto de la cuenta máquina
     (`gh api user --jq .login`), posteriores al último marcador. Cada uno es
     un hallazgo `C<n>`. Si no hay ninguno, responde "sin comentario humano"
     y termina.
4. Prepara la rama de la card:
   - Si la rama actual ya es `headRefName`, trabaja aquí. Antes,
     `git status --porcelain` debe estar vacío: si no, detente y explica.
   - Si no, usa una copia aparte para no tocar la sesión interactiva:

     ```sh
     git fetch origin <headRefName>
     git worktree add /tmp/devkit-fix-<N> <headRefName>
     ```

     Todo lo que sigue corre ahí. Al terminar, `git worktree remove --force
     /tmp/devkit-fix-<N>`.
   - `git pull --ff-only origin <headRefName>` para partir del head que el
     revisor leyó.
5. Atiende cada hallazgo, uno por uno y en orden de severidad (`alta`,
   `media`, `baja`; los `C<n>` primero):
   - Lee solo los archivos que el hallazgo nombra y lo que haga falta para
     entenderlos. No releas el PR entero ni la card.
   - Aplica el cambio mínimo que resuelve "qué falla" siguiendo "qué hacer".
     Si el hallazgo obliga a corregir la sección "Cambios requeridos" del PR
     (regla de `AGENTS.md`), hazlo en el mismo commit.
   - Un commit por hallazgo, con Conventional Commits y la Clave como
     ámbito, empezando por el id: `fix(DEVKIT-13): H2 validar el marcador`.
     Si dos hallazgos se resuelven con el mismo cambio, un solo commit y las
     dos líneas de respuesta citan el mismo sha.
   - Si un hallazgo es incorrecto, ambiguo o queda fuera del alcance de la
     card, no lo fuerces: se responde `descartado` con el motivo en una
     frase. El revisor decide en el siguiente ciclo.
   - Si un hallazgo pide retirar un dato porque el revisor no pudo
     verificarlo, y ese dato vive en un comentario de la card (el revisor
     tiene prohibido leerlos), no lo retires: cita la fuente exacta en el
     commit (URL o fecha del comentario) y responde `atendido` con esa cita.
     Retirarlo sin más perdió información real en DEVKIT-41.
6. Verificación local antes de subir, igual que en `task-submit`: `ruff
   check .` y `ruff format --check .` si hay Python, `uv run pytest` si hay
   pruebas, `bash -n` sobre cada script de shell tocado. Si algo falla,
   corrígelo dentro del commit del hallazgo correspondiente.
7. `git push origin <headRefName>`. Nunca `--force`: el revisor compara
   heads, y reescribir la historia lo dejaría sin referencia.
8. Escribe la respuesta en `.devkit/fix-<N>.md`. Solo esto, sin saludos ni
   resumen:

   ```
   <!-- devkit-fix sha=<head nuevo> review=<sha del marcador atendido><marca manual> -->
   <!-- devkit-fixes -->
   H1 | atendido | <sha corto>
   H2 | atendido | <sha corto>
   H3 | descartado | <motivo en una frase>
   C1 | atendido | <sha corto>
   <!-- /devkit-fixes -->
   ```

   Una línea por hallazgo, tres campos separados por ` | `: id, `atendido`
   o `descartado`, y el commit o el motivo. Sin saltos de línea dentro de
   una línea. Es lo único que `pr-review` lee de ti en el siguiente ciclo.
   Cuando atiendes un comentario humano sin marcador previo, `review=` lleva
   el `headRefOid` que leíste en el paso 2.
   `<marca manual>` es ` manual=1` (con el espacio delante) si no te lanzó el
   bucle, y nada si te lanzó. Lo sabes por la variable de entorno:
   `printenv DEVKIT_LANZADOR` imprime `watch` solo cuando te lanzó `watch.sh`.
   Con `manual=1`, el bucle reinicia su conteo de tres ciclos y revisa tu
   head en vez de bloquear la card (DEVKIT-56).

   Publícala con
   `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/fix-publish.sh" <N> .devkit/fix-<N>.md`
   (mismo patrón que `review-publish.sh`: arma el archivo con el número de PR
   en el nombre y el script lo borra al terminar, publique o no). El script
   toma el último marcador `devkit-review` del PR, no el que tu respuesta
   declara en `review=`: si ese último informe es CAMBIOS y tu respuesta trae
   algún id `H<n>`, o no trae ni `manual=1` ni responde a un comentario
   humano posterior al último `devkit-fix`/`devkit-block` (o, sin ellos, al
   último `devkit-review`), compara cada id contra los `H<n>` de ese informe
   y aborta antes de comentar en el PR si alguno no está -la guarda mecánica
   de DEVKIT-102, para que una lectura equivocada de un paso anterior no
   cierre un informe con hallazgos reales sin atender-. Si el último informe
   es OK, o tu respuesta solo trae `C<n>` y lleva `manual=1` o responde a ese
   comentario humano, publica sin comparar (DEVKIT-102, H5: cubre el
   `fix-humano` que lanza el bucle sobre un informe CAMBIOS vigente, sin
   `manual=1`). Si aborta, deja el motivo en watch.log y en la card. Si
   aborta, no insistas ni reescribas la respuesta para forzarla: ya quedó el
   motivo; termina sin repetir el paso 9.
9. `Estado` de la card = `Revisión automática`, venga de ahí o de
   `Lista para merge`. No comentes en la card: el ciclo vive en el PR.
10. Limpia la copia de trabajo si la creaste (paso 4).
11. `touch /run/devkit/poke`. Despierta a `watch.sh`, que duerme en tramos de
    5 s, para que no espere el resto del intervalo antes de revisar la
    corrección. Es solo un aviso, no lanza nada ni decide nada. Escribe el
    comando tal cual, sin redirecciones ni `|| true`: así es como lo autoriza
    `settings.json`. Si falla, no pasa nada y no se reintenta: el bucle llega
    igual en el siguiente intervalo.
12. Responde con una línea: PR, hallazgos atendidos y descartados, head nuevo.

## Reglas

- Nunca `gh pr review` de ningún tipo, nunca `gh pr merge`, nunca push a
  `main`, nunca `--force`. El corrector solo escribe en la rama de la card y
  en los comentarios del PR.
- No amplíes el alcance: un hallazgo no autoriza a refactorizar lo que no
  nombra. Lo que descubras fuera del alcance va a una card nueva con
  `task-create`, y se menciona en la línea de respuesta del hallazgo.
- La guardia contra bucles infinitos (tres ciclos respondidos y otro
  `CAMBIOS` sobre el head vigente → `task-block.sh`) la aplica el bucle del
  contenedor, no esta skill. Si recibes un hallazgo
  que ya atendiste dos veces con el mismo texto, en vez de insistir bloquea
  la card con `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh"
  <Clave> "<motivo>"`, con ese hallazgo como motivo.
- Modo headless (`claude -p "/task-fix <Clave> [texto]"`): sin preguntas.
  Si falta algo (card sin PR, PR cerrado, hallazgo ilegible), responde qué
  falta y termina sin tocar la rama. Un hallazgo ilegible se responde como
  `descartado | formato inválido` y se sigue con los demás.

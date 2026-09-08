---
name: task-fix
description: Corrige un PR dentro del ciclo automático. Lee el bloque devkit-findings del último informe de pr-review con veredicto CAMBIOS, o el comentario del humano sobre una card en Lista para merge, aplica los cambios en la rama de la card, hace push, responde en el PR con una línea por hallazgo y deja la card en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: la Clave; opcionalmente el texto de un comentario humano.
---

# task-fix

Argumento: Clave. Opcional: texto de un comentario humano. Eres el corrector,
no el revisor: no discutes el informe, lo atiendes. Revisar de nuevo es
trabajo de `pr-review`.

## Pasos

1. Localiza la card por `ID` y `Proyecto`. Su `Estado` debe ser
   `Revisión automática` o `Lista para merge`; en otro caso responde el
   estado y termina. Toma el número de PR de la propiedad `PR`; si está
   vacía, comenta en la card que falta el PR y termina.
2. Lee el PR: `gh pr view <N> --json state,url,headRefName,headRefOid,reviews,comments`.
   Si `state` no es `OPEN`, responde "PR no abierto" y termina.
3. Decide qué atender, en este orden:
   - **Texto recibido como argumento**: es un hallazgo único con id `C<n>`,
     donde `n` es uno más que el último `C` que hayas respondido en ese PR.
   - **Sin argumento y card en `Revisión automática`**: busca el último
     marcador `<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->`
     (el `jq` del paso 3 de `pr-review`). Si no hay marcador, o su `verdict`
     es `OK`, responde "nada que corregir" y termina. Si su `sha` no es
     `headRefOid`, el head ya cambió después del informe: responde
     "informe desactualizado, esperando a pr-review" y termina. Si ya
     existe un comentario tuyo con `<!-- devkit-fix review=<ese sha> -->`,
     responde "ya atendido" y termina. Si pasa todo, extrae el bloque
     `<!-- devkit-findings -->` ... `<!-- /devkit-findings -->` de ese
     informe: una línea por hallazgo, cinco campos separados por ` | `:
     `id | severidad | archivo:línea | qué falla | qué hacer`.
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
     Si el hallazgo obliga a tocar documentación (regla de `AGENTS.md`:
     README, Notion, `CHANGELOG.md`), hazlo en el mismo commit.
   - Un commit por hallazgo, con Conventional Commits y la Clave como
     ámbito, empezando por el id: `fix(DEVKIT-13): H2 validar el marcador`.
     Si dos hallazgos se resuelven con el mismo cambio, un solo commit y las
     dos líneas de respuesta citan el mismo sha.
   - Si un hallazgo es incorrecto, ambiguo o queda fuera del alcance de la
     card, no lo fuerces: se responde `descartado` con el motivo en una
     frase. El revisor decide en el siguiente ciclo.
6. Verificación local antes de subir, igual que en `task-review`: `ruff
   check .` y `ruff format --check .` si hay Python, `uv run pytest` si hay
   pruebas, `bash -n` sobre cada script de shell tocado. Si algo falla,
   corrígelo dentro del commit del hallazgo correspondiente.
7. `git push origin <headRefName>`. Nunca `--force`: el revisor compara
   heads, y reescribir la historia lo dejaría sin referencia.
8. Responde en el PR con `gh pr comment --body-file - <N>`. Solo esto, sin
   saludos ni resumen:

   ```
   <!-- devkit-fix sha=<head nuevo> review=<sha del marcador atendido> -->
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
9. `Estado` de la card = `Revisión automática`, venga de ahí o de
   `Lista para merge`. No comentes en la card: el ciclo vive en el PR.
10. Limpia la copia de trabajo si la creaste (paso 4) y responde con una
    línea: PR, hallazgos atendidos y descartados, head nuevo.

## Reglas

- Nunca `gh pr review` de ningún tipo, nunca `gh pr merge`, nunca push a
  `main`, nunca `--force`. El corrector solo escribe en la rama de la card y
  en los comentarios del PR.
- No amplíes el alcance: un hallazgo no autoriza a refactorizar lo que no
  nombra. Lo que descubras fuera del alcance va a una card nueva con
  `task-create`, y se menciona en la línea de respuesta del hallazgo.
- La guardia contra bucles infinitos (tres ciclos sin `OK` → `task-block`)
  la aplica el bucle del contenedor, no esta skill. Si recibes un hallazgo
  que ya atendiste dos veces con el mismo texto, en vez de insistir usa
  `task-block` con la Clave y ese hallazgo como motivo.
- Modo headless (`claude -p "/task-fix <Clave> [texto]"`): sin preguntas.
  Si falta algo (card sin PR, PR cerrado, hallazgo ilegible), responde qué
  falta y termina sin tocar la rama. Un hallazgo ilegible se responde como
  `descartado | formato inválido` y se sigue con los demás.

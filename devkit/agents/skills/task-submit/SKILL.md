---
name: task-submit
description: Entrega para revisión el trabajo de una card en progreso: verifica, sube la rama, abre el PR con auto-merge, registra la URL del PR y pasa la card a Revisión automática. No emite veredicto; quien revisa es pr-review, en otro proceso. Úsala cuando los criterios de aceptación se cumplan o cuando el humano pida abrir el PR. Argumento opcional: la Clave; por defecto la card de la rama actual.
---

# task-submit

Argumento opcional: Clave. Por defecto se deduce de la rama actual.

## Pasos

1. Deduce la Clave de la rama (`feat/DEVKIT-3-...` → `DEVKIT-3`) y localiza
   la card. Verifica que está `En progreso`.
2. Verificación local, en este orden, y detente si algo falla:
   - `ruff check .` y `ruff format --check .` si hay Python.
   - `uv run pytest` si existe `tests/` o `pyproject.toml` con pytest.
   - `bash -n` sobre cada script de shell tocado.
   - Repasa los criterios de aceptación de la card uno por uno y confirma
     cada uno con un comando o una observación concreta.
3. Commit de lo pendiente con Conventional Commits y la Clave como ámbito.
   `git push`.
4. Si ya existe un PR para la rama (`gh pr view --json url`), no crees otro:
   actualiza su descripción si cambió el alcance (conserva la línea
   "Implementado con ..." del paso 5; si falta, agrégala) y salta al paso 6.
5. Crea el PR con `gh pr create --base main --title "<Clave> <título de la
   card>" --body-file -` y este cuerpo:

   ```
   ## Qué cambia
   Dos o tres líneas.

   ## Cómo probarlo
   Comandos u observaciones, en orden.

   ## Card
   <URL de la card en Notion>

   Implementado con <modelo>, esfuerzo <esfuerzo>
   ```

   La última línea sale de las variables que `devkit-run` exporta al
   `claude -p` (DEVKIT-58):

   ```sh
   echo "Implementado con ${DEVKIT_MODEL:-?}, esfuerzo ${DEVKIT_EFFORT:-?}"
   ```

   Cópiala tal cual, en una línea propia y sin formato. Si las variables
   vienen vacías (sesión interactiva, sin `devkit-run`), escribe el alias del
   modelo que te ejecuta (`fable`, `opus`, `sonnet`) y `esfuerzo sin
   registrar`; nunca inventes un esfuerzo. `task-close.sh` lee esta línea
   para el comentario de cierre.

6. Activa el auto-merge: `gh pr merge --auto --squash`. Si GitHub lo rechaza
   porque el repo no lo permite, comenta en la card que falta activar
   "Allow auto-merge" y sigue.
7. Actualiza la card: `PR` = URL del PR, `Estado` = `Revisión automática`.
8. Comenta en la card, dos a cuatro líneas: qué se entregó y qué debe mirar
   el revisor primero.
9. `touch /run/devkit/poke`, como último paso. Despierta a `watch.sh`, que
   duerme en tramos de 5 s, para que no espere el resto del intervalo antes de
   lanzar `pr-review`. Es solo un aviso, no lanza nada ni decide nada. Escribe
   el comando tal cual, sin redirecciones ni `|| true`: así es como lo autoriza
   `settings.json`. Si falla, no pasa nada y no se reintenta: el bucle llega
   igual en el siguiente intervalo.

A partir de aquí el ciclo es automático: la skill `pr-review` decide si la
card pasa a `Lista para merge` o si `task-fix` la corrige y la deja de nuevo
en `Revisión automática`. `task-submit` no vuelve a tocar esta card salvo que
el humano lo pida explícitamente.

## Reglas

- Nunca `gh pr merge` sin `--auto`, nunca `gh pr review --approve`.
- Un PR por card. Si el trabajo necesita dos PRs, la card debía ser dos.

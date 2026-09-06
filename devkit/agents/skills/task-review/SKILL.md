---
name: task-review
description: Cierra el trabajo de una card en progreso: verifica, sube la rama, abre el PR con auto-merge, registra la URL del PR y pasa la card a En revisión. Úsala cuando los criterios de aceptación se cumplan o cuando el humano pida abrir el PR. Argumento opcional: la Clave; por defecto la card de la rama actual.
---

# task-review

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
   actualiza su descripción si cambió el alcance y salta al paso 6.
5. Crea el PR con `gh pr create --base main --title "<Clave> <título de la
   card>" --body-file -` y este cuerpo:

   ```
   ## Qué cambia
   Dos o tres líneas.

   ## Cómo probarlo
   Comandos u observaciones, en orden.

   ## Card
   <URL de la card en Notion>
   ```

6. Activa el auto-merge: `gh pr merge --auto --squash`. Si GitHub lo rechaza
   porque el repo no lo permite, comenta en la card que falta activar
   "Allow auto-merge" y sigue.
7. Actualiza la card: `PR` = URL del PR, `Estado` = `En revisión`.
8. Comenta en la card, dos a cuatro líneas: qué se entregó y qué debe mirar
   el revisor primero.

## Tras comentarios del revisor

Si el humano pide cambios en el PR: la card vuelve a `En progreso`, aplica
los cambios, push, y la card vuelve a `En revisión` con un comentario de una
línea. El approve invalidado por el push se vuelve a pedir con
`gh pr edit --add-reviewer <usuario>` si es necesario.

## Reglas

- Nunca `gh pr merge` sin `--auto`, nunca `gh pr review --approve`.
- Un PR por card. Si el trabajo necesita dos PRs, la card debía ser dos.

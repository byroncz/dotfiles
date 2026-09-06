---
name: task-start
description: Toma una card en Lista, la pasa a En progreso, crea su rama desde main y registra la URL de la rama y un comentario con el plan. Úsala para empezar a trabajar una card. Argumento opcional: la Clave; sin argumento toma la siguiente hija libre del proyecto.
---

# task-start

Argumento opcional: Clave de la card. Sin argumento, elige la siguiente.

## Elegir la card (sin argumento)

1. Consulta Tareas del proyecto con `Estado` = `Lista` y `Nivel` = Tarea.
2. Descarta las que tengan alguna card en `Depende de` que no esté `Hecha`.
3. Ordena por `Orden` ascendente y luego por `Prioridad` (alta, media,
   baja). Toma la primera.
4. Si no hay ninguna, responde "No hay cards libres en Lista" y termina.

## Pasos

1. Verifica que el workspace está limpio: `git status --porcelain` vacío. Si
   hay cambios sin commit, detente y explica; no mezcles trabajo de dos cards.
2. Verifica que la card está en `Lista`. Si está en `En progreso` con `Rama`
   asignada, cámbiate a esa rama y continúa: es una reanudación.
3. Actualiza `main`: `git fetch origin && git switch main && git pull --ff-only`.
4. Nombre de rama: prefijo por `Tipo` (`feat/`, `fix/`, `chore/`), la Clave
   en minúsculas no, la Clave tal cual, y un slug corto del título en
   minúsculas con guiones. Ejemplo: `feat/DEVKIT-3-skills-del-flujo`.
5. `git switch -c <rama>` y `git push -u origin <rama>`.
6. Actualiza la card: `Estado` = `En progreso`, `Agente` = tu nombre
   (`claude` o `codex`), `Rama` = `https://github.com/<owner>/<repo>/tree/<rama>`.
7. Comenta en la card el plan en dos a cuatro líneas: qué vas a cambiar y en
   qué orden. Sin justificaciones largas.
8. Trabaja la card. Commits con Conventional Commits y la Clave como ámbito:
   `feat(DEVKIT-3): crear skill task-start`. Haz push con frecuencia.
9. Al cumplir los criterios de aceptación, ejecuta `task-review`.

## Reglas

- Una card activa por sesión.
- Nunca `git push origin main`, nunca `--force`.
- Si te bloqueas más de dos intentos en el mismo problema, usa `task-block`.

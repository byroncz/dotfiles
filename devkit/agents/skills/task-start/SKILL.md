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

## La card, ya lista para trabajar

Los pasos mecánicos (workspace limpio, la card por Notion, la rama, el
Estado) los corre `devkit/scripts/task-begin.sh` en bash, antes de que
existas: `devkit-run` lo ejecuta antes de lanzarte y agrega su salida al
final de este prompt bajo un encabezado `## Card`, con las propiedades de la
card, su Objetivo, Criterios de aceptación, Notas y todos sus comentarios en
orden -los que amplían el alcance cuentan, DEVKIT-41-.

- Si ese bloque `## Card` está en este prompt: la card ya quedó `En
  progreso`, con su rama creada y en uso (o, en una reanudación, ya estás
  sobre ella). No vuelvas a consultar Notion ni a tocar git para nada de
  esto: ya está hecho. Sigue directo a "Comenta el plan".
- Si no está -te invocaron a mano, sin pasar por `devkit-run`, por ejemplo
  desde una sesión interactiva- ejecútalo tú mismo:
  `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-begin.sh" <Clave>`
  Sale con 0 y el mismo volcado en stdout si dejó la card lista: úsalo
  exactamente igual que el bloque `## Card`. Si sale con 1, el motivo va en
  stderr; responde según cuál sea, sin tocar git ni Notion más allá de lo
  que ya hizo el script:
  - `<Clave> está en Backlog; el humano debe moverla a Lista.` o `<Clave>
    está Por refinar; el humano debe moverla a Lista o Backlog.` → responde
    eso y termina.
  - `<Clave> ya está en <Estado> ...; no hay nada que hacer.` (Hecha, Lista
    para merge o Revisión automática) → responde eso y termina.
  - `<Clave> está bloqueada; el humano debe moverla a En progreso antes de
    relanzar.` → responde eso y termina.
  - Cualquier otro motivo (workspace con cambios sin commit, otro agente
    ocupando el workspace, un fallo de git o de Notion): bloquea la card con
    `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh" <Clave> "<motivo que dio task-begin.sh>"`
    y termina.

## Comenta el plan

Comenta en la card el plan en dos a cuatro líneas: qué vas a cambiar y en
qué orden. Si los comentarios de la card (ya los tienes, del bloque `## Card`
o de `task-begin.sh`) traen una ampliación, corrección o precisión del
alcance original, una línea por cada una, citando qué comentario la
originó. Sin justificaciones largas. Ignorar un comentario dejó las notas de
la versión `1.0.0` con un dato falso (DEVKIT-41).

## Trabaja la card

Incluidas las ampliaciones que encontraste en los comentarios. Commits con
Conventional Commits y la Clave como ámbito: `feat(DEVKIT-3): crear skill
task-start`. Haz push con frecuencia.

Al cumplir los criterios de aceptación, ejecuta `task-submit`.

## Un dominio bloqueado

Si un comando falla con "connection refused", corre `devkit-net-denied` para
confirmarlo. Sobre la rama de una card, `devkit recreate` no sirve: el proxy
del host solo lee `domains` del checkout que esté vivo en el contenedor, y el
ciclo devuelve el workspace a `main` al cerrar o bloquear la card, así que el
dominio nunca le llega antes del merge (DEVKIT-182). En su lugar:

1. Agrega el dominio a `domains` de `.devkit/devkit.toml`, comitea
   (`feat(<Clave>): agregar <dominio> a domains`) y pushea.
2. Resuelve `hostname` y `git branch --show-current` como comandos aparte,
   no como sustitución dentro del argumento de `task-block.sh`: en headless,
   un `Bash` con `$(...)` pide aprobación aunque el prefijo esté permitido, y
   nadie la da (H4, DEVKIT-182). Con esos dos valores literales, bloquea la
   card:
   `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh" <Clave> "Qué
   intenté: <comando> necesitaba <dominio(s)>, rechazados por el proxy. Qué
   necesito: corre devkit proxy <proyecto> --ref <rama> en el host, mueve la
   card a En progreso y relanza con dk task-start <Clave>."`
   y termina ahí: el motivo lleva los dominios para que el humano los vea
   antes de aprobarlos.

## Modo headless

`task-close.sh` (vía `devkit-run`), `epic-plan` o el humano te invocan como
`claude -p "/task-start <Clave>"`.
No hay quien conteste: si terminas preguntando, el proceso muere con la card
`En progreso` y nadie trabajándola.

- No hagas preguntas. Tras comentar el plan sigue de largo: implementa la
  card hasta cumplir todos los criterios de aceptación y termina ejecutando
  `task-submit`.
- Una ejecución que no deja la card en `Revisión automática` o `Bloqueada`
  es un corte, no un avance.
- Si falta una decisión, un acceso o un criterio de aceptación, o te bloqueas
  más de dos intentos en el mismo problema, bloquea la card con
  `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/task-block.sh" <Clave> "<motivo>"`, con la
  petición concreta al humano. Nunca termines con una pregunta abierta.

## Reglas

- Una card activa por sesión.
- Nunca `git push origin main`, nunca `--force`.
- Si te bloqueas más de dos intentos en el mismo problema, usa `task-block.sh`.

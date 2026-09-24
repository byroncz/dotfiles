---
name: task-create
description: Crea una o varias cards en Notion en estado Por refinar para el proyecto actual, con la plantilla de objetivo, criterios de aceptación y notas. Úsala cuando el humano pida registrar trabajo pendiente o cuando descubras una necesidad fuera del alcance de la card activa.
---

# task-create

Crea cards en la base **Tareas** de Notion. Argumento: una descripción en
lenguaje natural de una o varias tareas, o una Épica.

## Pasos

1. Lee `.claude/devkit-notion.json` para obtener el `data_source_id` de
   Tareas, y la clave `project` de `.devkit/devkit.toml` para el
   código del proyecto. Busca en Proyectos la fila cuyo Código coincide; su
   URL es la relación Proyecto.
   Excepción (DEVKIT-184): si la tarea es un hallazgo sobre el template
   -algo roto o incompleto cuya corrección vive en el repo del template
   (scripts, skills, monitor, `devkit.toml` como esquema), no en el repo de
   este proyecto-, busca en cambio la fila cuyo Código es `DEVKIT` y úsala
   como Proyecto. Sin esto la card contamina el Kanban de un proyecto que no
   puede resolverla y hay que reasignarla a mano, como pasó con DEVKIT-180 a
   183. Agrega en `## Notas` una línea "Detectado en `<Clave>`" con la Clave
   de la card sobre la que trabajabas cuando lo notaste (o, sin una card
   activa, el proyecto), para no perder de dónde salió.
2. Para cada tarea pedida, decide `Nivel`: Épica si agrupa varios entregables
   o exige más de un día de trabajo; Tarea si cabe en una rama de menos de un
   día. Una Tarea suelta sin Épica es válida.
3. Crea la página con estas propiedades: Título, Estado `Por refinar`,
   Nivel, Proyecto, Tipo (`feature`, `bug` o `chore`), Prioridad (`alta`,
   `media` o `baja`), Agente `humano` si la creó un humano o el agente
   actual (`claude` o `codex`) si nace de tu trabajo. Si es hija de una
   Épica, relaciona `Padre` y asigna `Orden`.
   Excepción a `Por refinar`: si te invoca `epic-plan` (hijas de una Épica
   ya aprobada) o `template-update` (a petición del humano), la card nace en
   `Lista`; la aprobación ya la dio el humano.
4. Cuerpo de la card, siempre con estas tres secciones y en este orden:

   ```
   ## Objetivo
   Una o dos frases: qué debe existir al terminar y para qué.

   ## Criterios de aceptación
   - Lista verificable. Cada punto se puede comprobar con un comando o una observación.

   ## Notas
   Contexto, enlaces, decisiones previas. Puede quedar vacío.
   ```

5. Responde con la Clave y la URL de cada card creada. Nada más.

## Reglas

- No crees cards duplicadas: busca antes por título en Tareas del mismo
  proyecto.
- No muevas ninguna card fuera de Por refinar: esa transición es del
  humano. La única excepción es la del paso 3.
- Redacta según la guía de `AGENTS.md`: conciso, pedagógico, español neutro.

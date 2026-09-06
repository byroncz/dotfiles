---
name: task-block
description: Marca una card como Bloqueada y explica en un comentario exactamente qué se necesita del humano para continuar. Úsala cuando no puedas avanzar tras dos intentos, cuando falte una decisión, un acceso o un criterio de aceptación. Argumentos: la Clave y el motivo.
---

# task-block

Argumentos: Clave y motivo en una frase.

## Pasos

1. Localiza la card. Guarda su `Estado` actual en el comentario para poder
   volver a él.
2. `Estado` = `Bloqueada`.
3. Comenta con esta forma, máximo seis líneas:

   ```
   Bloqueada desde <estado anterior>.
   Qué intenté: <uno o dos intentos, una línea cada uno>.
   Qué necesito: <una petición concreta al humano>.
   ```

4. Si la card tiene rama con cambios, haz commit y push de lo que haya con
   el ámbito de la Clave y el prefijo `wip:` en el mensaje, para no perder
   trabajo.
5. Responde al humano con la misma petición concreta y termina. No sigas
   trabajando la card.

## Desbloqueo

Cuando el humano responda y mueva la card de vuelta a `Lista` o
`En progreso`, `task-start` con su Clave la reanuda desde la rama existente.

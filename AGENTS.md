# AGENTS.md

Instrucciones para cualquier agente que trabaje en este repositorio. **Fuente
única**: `CLAUDE.md` solo apunta aquí, y no debe crecer. Si añades una
instrucción, va en este archivo.

## Qué es este repositorio

Un **template de devcontainers**, no un proyecto. No se ejecuta: se copia.

```bash
cp -r ruta/a/este/repo/.devcontainer mi-proyecto/.devcontainer
```

El objetivo de fondo: al formatear el portátil, instalar Docker y clonar dos
repos. Todo lo demás se reconstruye.

Eso tiene una consecuencia que gobierna casi todas las decisiones: **el código
que escribas aquí se va a ejecutar dentro del repositorio de un cliente**. Un
script que deje archivos sueltos, que escriba en el `.gitignore` del proyecto o
que cambie permisos a través del bind mount, no ensucia este repo: ensucia el de
un cliente, donde alguien lo commitea sin querer.

## Qué hay dónde

| Ruta | Qué es |
|---|---|
| `.devcontainer/` | El template. Ordenado por fase del pipeline; ver su `README.md` |
| `git/`, `nvim/` | Dotfiles versionados. Se **enlazan** en el container, no se copian |
| `AGENTS.md`, `CLAUDE.md` | Esto |

`.devcontainer/README.md` es la referencia detallada: estructura, qué persiste
en qué volumen, el ecosistema de agentes y las decisiones de diseño. No la
repitas aquí.

## Decisiones cerradas

No las reabras sin decirlo antes. Están así porque la alternativa falló.

| Tema | Decisión |
|---|---|
| Aislamiento | **Nunca** un bind del `~/.claude` del host. Un volumen por cliente |
| Nada bajo `.claude` | Conocimiento e historial van **fuera**, para que Codex y OpenCode los alcancen |
| Config vs datos | Configuración → git. Datos irreemplazables → respaldo cifrado |
| Binarios | Al `Dockerfile`, tras un build arg. Su caché → volumen sin respaldar |
| Secretos | Fuera del repo, en `~/.config/`, por `env_file`. **Nunca** además en `environment:` |
| Base de la imagen | `debian:trixie-slim`. No bajar a bookworm: su glibc 2.36 rompe el tree-sitter de Mason, que pide 2.39 |
| MCP | Un solo origen (`.devcontainer/mcp/servers.json`); las configs de cada agente se **generan** |

Al añadir un volumen, clasifícalo: **caché** (reconstruible, no se respalda) o
**datos irreemplazables** (respaldo cifrado). Si no sabes en cuál cae, no es
caché.

## Cómo trabajar

- **Responde en español.** Los mensajes de commit, en inglés, con
  Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`).
- **Explica el por qué en el propio archivo.** Los comentarios de este repo
  dicen qué falló y por qué la solución es esa, no qué hace la línea
  siguiente. Un comentario que solo parafrasea el código sobra.
- **Incremental.** Un cambio, verificado, commiteado. No cinco a la vez.
- **Si una decisión te parece equivocada, dilo.** Es preferible discutirlo a
  descubrirlo en producción.

## Cómo verificar

Hay Docker. **Nada se reporta como hecho sin haberlo ejecutado.**

```bash
cd .devcontainer
docker compose -p <proyecto> --env-file .env build dev
docker compose -p <proyecto> --env-file .env up -d
docker compose -p <proyecto> exec dev bash -lc '<comprobación>'
```

Cuatro reglas que salieron de fallos reales:

1. **Prueba tu comando de verificación contra un caso de resultado conocido**
   antes de confiar en él. Un `grep` con la opción equivocada devuelve vacío y
   parece un éxito. Han estado a punto de colarse varios falsos negativos así.
2. **Un `ERROR` en el log de un servicio sano es una avería, no ruido.**
3. **Mira el valor, no solo el comportamiento.** El peor fallo encontrado en
   este repo fue una contraseña de cifrado que era, literalmente, la ruta del
   remoto: cifraba, descifraba y subía sin un error, y todas las pruebas
   funcionales pasaban. Solo se veía mirando el valor.
4. **Limpia lo que ensucies**: contenedores, volúmenes y archivos de prueba.
   Y comprueba que `git status` queda limpio: arrancar el devcontainer no puede
   dejar el repo sucio.

Después de tocar algo del respaldo:

```bash
.devcontainer/backup/rclone-setup.sh check   # debe decir ok
docker compose -p <proyecto> logs --tail=20 sync-claude   # debe traer ": ok"
```

## Secretos

No hay secretos en este repositorio y no debe haberlos. Viven en
`~/.config/rclone/` del host y entran por `env_file`.

- No pegues un token ni una contraseña en la conversación. Si hay que
  inspeccionar un secreto, entrega el comando para que lo ejecute quien pueda.
- El template es **agnóstico**: ningún nombre de cliente ni de proyecto en
  archivos versionados. Esos van en `.devcontainer/.env`, que no se versiona.

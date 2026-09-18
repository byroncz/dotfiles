# devkit

Entorno de desarrollo reproducible para proyectos de datos, pensado para que
lo operen agentes de IA con un humano como única compuerta. El Mac solo
necesita Docker; todo lo demás vive en un contenedor que se reconstruye desde
este repo, y las tareas se gestionan en Notion.

## Instalación en el Mac

```sh
curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/new-project.sh | sh -s -- <proyecto> --version X.Y.Z
devkit up <proyecto>
devkit code <proyecto>
```

El primer comando instala `~/.devkit/bin/devkit` y deja el proyecto listo en
`~/.devkit/<proyecto>/`. El segundo levanta los contenedores y construye la
imagen la primera vez. El tercero abre el editor en el navegador, ya
autenticado con un token por proyecto.

## Stack

| Herramienta | Para qué se usa aquí |
|---|---|
| Docker + Compose | Única dependencia del Mac. Dos contenedores por proyecto: `dev` (trabajo, sin salida directa) y `proxy` (única salida, con lista blanca). |
| Debian trixie-slim | Imagen base sin lenguaje. Usuario `dev` sin `sudo`. |
| tinyproxy | Proxy de salida con lista blanca de dominios (`allowlist.base` más `domains` de `.devkit/devkit.toml`). |
| uv | Instala la versión de Python de `.devkit/devkit.toml` y gestiona dependencias y entornos. |
| Python | Lenguaje de los proyectos de datos. No viene en la imagen: cada proyecto fija su versión. |
| openvscode-server | Único editor del devkit: `devkit code <proyecto>` abre la URL con token. |
| zsh + starship | Shell y prompt de una sola línea: proyecto, rama, cambios, agentes vivos y alarmas. |
| Claude Code | Agente principal. Lee `AGENTS.md`, ejecuta las skills, abre PRs y actualiza Notion. |
| Codex | Segundo agente, preparado pero no instalado: mismo `AGENTS.md` y skills. |
| GitHub + gh | Código, PRs y la compuerta humana: `main` exige PR con una aprobación; auto-merge activado. |
| Git | Una rama por card, Conventional Commits con la Clave como ámbito. |
| Notion | Centro de tareas: bases Proyectos, Tareas y Documentación. |
| Bitwarden Secrets Manager | Único lugar de los secretos del proyecto. |
| rclone + Dropbox | Respaldo continuo de `sandbox.local/`, cada minuto. |
| Terminal.app | Terminal de macOS; ahí corre el comando `devkit`. |

Generadas por `gen-readme.sh` (verificado con `--check`), no a mano:

Versiones fijadas en `devkit/Dockerfile`: uv 0.12.7, gh 2.100.0, rclone 1.75.1, bws 2.1.0, starship 1.24.2, openvscode-server 1.109.5.
Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: Anthropic.claude-code latest, GitHub.vscode-pull-request-github 0.128.0.

## Comandos

### En el Mac: `devkit`

| Comando | Qué hace |
|---|---|
| `devkit up <proyecto>` | Levanta los contenedores (construye la imagen si falta). |
| `devkit shell <proyecto>` | Abre una shell dentro del contenedor. |
| `devkit code <proyecto>` | Abre el editor VS Code del proyecto en el navegador. |
| `devkit stop <proyecto>` | Detiene sin perder nada. |
| `devkit down <proyecto>` | Destruye el contenedor; lo no commiteado se pierde. |
| `devkit recreate <proyecto>` | Recrea los contenedores, reconstruyendo solo las capas que cambiaron. |
| `devkit rebuild <proyecto>` | Reconstruye las imágenes desde cero y recrea. |
| `devkit update <proyecto>` | Sube a la versión de template que pide `.devkit/devkit.toml`. |
| `devkit logs <proyecto>` | Arranque y bucles del contenedor. |
| `devkit net-open <proyecto>` | Red abierta en esta sesión, solo para depurar. |
| `devkit awake <proyecto>` | Impide que el Mac se suspenda mientras el contenedor esté vivo. |
| `devkit ls` | Lista los proyectos instanciados. |

### Dentro del contenedor

| Comando | Qué hace |
|---|---|
| `claude` | Abre Claude Code en el workspace. |
| `devkit-net-denied` | Lista los dominios que el proxy rechazó recientemente. |
| `g` | Alias de `git`. |
| `gs` | Alias de `git status -sb`. |
| `gl` | Alias de `git log` gráfico. |
| `ll` | Alias de `ls -lah`. |
| `c` | Alias de `clear`. |
| `devkit-run <skill> <Clave>` | Lanza una skill en segundo plano, con el modelo y el esfuerzo que le tocan por rol. |
| `devkit-run --estado [--seguir]` | Tabla de los últimos lanzamientos y el consumo de cuota, sin lanzar ningún agente. |
| `devkit-run --tablero [--seguir]` | Cards activas del proyecto en una tabla de consola. |
| `devkit-run --otros-agentes` | Dice si otro agente ya ocupa el workspace. |
| `devkit-run task-close <Clave> [PR]` | Cierra una card con el PR mergeado, en bash. |
| `devkit-run task-block <Clave> <motivo>` | Bloquea una card con un motivo, en bash. |

### Scripts de `devkit/scripts/`

| Comando | Qué hace |
|---|---|
| `gen-stack.sh` | Genera la línea de extensiones y de versiones de la sección Stack del README. |
| `gen-readme.sh` | Genera y verifica `README.md` completo desde la plantilla. |
| `devkit-run.sh` | Único punto de lanzamiento de una skill (ver `devkit-run` más arriba). |
| `watch.sh` | Bucle que revisa PRs abiertos y cierra los mergeados, lanzando la skill que toca. |
| `watch-test.sh` | Prueba `watch.sh` sin GitHub y sin gastar cuota. |
| `notion.sh` | Cliente de la API de Notion para bash: leer y escribir cards y Documentación. |
| `task-close.sh <Clave> [PR]` | Cierra una card mergeada: `Estado` a `Hecha` y marcador en el PR. |
| `task-block.sh <Clave> <motivo>` | Bloquea una card y anota el motivo. |
| `task-next.sh <Clave>` | Lanza la siguiente hija libre de la Épica de la card. |
| `prompt-status.sh` | Arma la línea dinámica del prompt de starship. |
| `dropbox-setup.sh` | Autoriza Dropbox una vez y genera el secreto `rclone_conf_b64`. |
| `sync-sandbox.sh` | Respalda `sandbox.local/` en Dropbox cada minuto. |
| `slugify.sh` | Convierte un texto libre en el slug de una rama. |
| `image-drift.sh` | Lista qué del template solo entra por imagen y ya no coincide con ella. |
| `agents-sync.sh` | Funde el `AGENTS.md` de un proyecto con la plantilla destino. |
| `pr-guard.sh` | Hook que bloquea aprobar o mergear un PR, o exponer un token, desde `claude -p`. |

## Skills (comandos `/nombre` dentro de `claude`)

| Skill | Qué hace |
|---|---|
| `/project-init` | Registra un proyecto nuevo en Notion: fila en Proyectos y vistas filtradas de Tareas y Documentación en su página. Úsala una vez, al instanciar un proyecto con new-project.sh. Argumentos: código corto y URL del repo; el nombre se toma de AGENTS.md. |
| `/epic-plan` | Descompone una Épica aprobada (en Lista) en Tareas hijas ordenadas, las deja en Lista, publica el desglose como comentario y arranca la primera. Úsala cuando el humano mueva una Épica a Lista o pida planificarla. Argumento: la Clave de la Épica, por ejemplo DEVKIT-1. |
| `/task-create` | Crea una o varias cards en Notion en estado Backlog para el proyecto actual, con la plantilla de objetivo, criterios de aceptación y notas. Úsala cuando el humano pida registrar trabajo pendiente o cuando descubras una necesidad fuera del alcance de la card activa. |
| `/task-start` | Toma una card en Lista, la pasa a En progreso, crea su rama desde main y registra la URL de la rama y un comentario con el plan. Úsala para empezar a trabajar una card. Argumento opcional: la Clave; sin argumento toma la siguiente hija libre del proyecto. |
| `/task-submit` | Entrega para revisión el trabajo de una card en progreso: verifica, sube la rama, abre el PR con auto-merge, registra la URL del PR y pasa la card a Revisión automática. No emite veredicto; quien revisa es pr-review, en otro proceso. Úsala cuando los criterios de aceptación se cumplan o cuando el humano pida abrir el PR. Argumento opcional: la Clave; por defecto la card de la rama actual. |
| `/pr-review` | Revisa un PR como revisor independiente del autor. Comprueba cada criterio de aceptación de la card ejecutando algo, lee el diff de forma adversarial, publica el informe en el PR con el marcador devkit-review y, según el veredicto, mueve la card a Lista para merge y pide review al humano, o la deja en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: número de PR. |
| `/task-fix` | Corrige un PR dentro del ciclo automático. Lee el bloque devkit-findings del último informe de pr-review con veredicto CAMBIOS, o el comentario del humano sobre una card en Lista para merge, aplica los cambios en la rama de la card, hace push, responde en el PR con una línea por hallazgo y deja la card en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: la Clave; opcionalmente el texto de un comentario humano. |
| `/task-document` | Escribe o actualiza la entrada de Documentación de una card aprobada. La lanza el bucle watch.sh cuando pr-review da OK y la card entra en Lista para merge; si la card vuelve atrás y recibe otro OK, corre de nuevo y actualiza la misma entrada. También la lanza task-close.sh si al cerrar falta la entrada, o para la entrada consolidada de una Épica. Argumentos: la Clave; opcionalmente el número de PR. |
| `/project-status` | Reconcilia Notion con GitHub y resume el estado del proyecto: cierra cards en Revisión automática o Lista para merge cuyo PR ya se mergeó, señala cards huérfanas o inactivas y dice cuál es la siguiente card libre. Úsala al abrir la sesión en el proyecto o en cualquier momento en que el humano pregunte "en qué vamos". |
| `/template-update` | Sube la versión del template devkit que usa este proyecto: cambia `template` en devkit.toml, actualiza la fila del proyecto en Notion y explica qué cambia según las notas de la release. Úsala cuando el arranque avise de una versión nueva o el humano lo pida. Argumento: la versión destino, por ejemplo 1.4.0. |
| `/template-propagate` | Desde el proyecto DEVKIT, abre un PR de actualización de template en cada proyecto registrado en Notion que esté por debajo de la última etiqueta. Úsala después de publicar una etiqueta nueva de dotfiles. Sin argumentos. |

Detalle y convenciones de cada transición:
[`devkit/agents/skills/README.md`](devkit/agents/skills/README.md).

## Integraciones

- **Notion**: centro de tareas (bases Proyectos, Tareas y Documentación). Los
  agentes leen y escriben con el plugin oficial de Notion para Claude Code;
  los scripts bash (`notion.sh`, `task-close.sh`, `task-block.sh`) usan la
  API de Notion con el token del secreto `notion_token`. Identificadores de
  las bases en `.claude/devkit-notion.json`.
- **GitHub**: código, PRs y la compuerta humana (`main` exige PR con una
  aprobación, auto-merge activado). Los agentes actúan con la cuenta máquina
  `byroncz-bot`; su token llega como secreto de Bitwarden.
- **Bitwarden Secrets Manager**: único lugar de los secretos del proyecto. Un
  token en `~/.devkit/bws-token` del Mac los trae al arrancar a un `tmpfs`
  que muere con el contenedor.
- **Dropbox**: respaldo continuo de `sandbox.local/`, vía `rclone`. Se
  autoriza una vez con `dropbox-setup.sh`, que genera el secreto
  `rclone_conf_b64`.
- **Open VSX**: registro de extensiones del editor. Se declaran en
  `devkit/vscode/extensions.toml` y se resuelven contra Open VSX al
  construir la imagen.

## Documentación

Diseño, decisiones y la entrada de cada card: base
[Documentación](https://app.notion.com/p/8670f0a8753a4e798e7aa7ab5a9d207d) de
Notion, proyecto `DEVKIT`. Resumen de este README, para quien no tiene el
repo a mano: entrada
["Stack y comandos del devkit"](https://app.notion.com/p/3d427957d23d81c48debd29c70f68bcd).

Este README se genera con `devkit/scripts/gen-readme.sh` y solo cambia en la
card de release de cada versión; ninguna card ordinaria lo edita (regla
completa en [`AGENTS.md`](AGENTS.md)).

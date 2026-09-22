# devkit

Entorno de desarrollo reproducible para proyectos de datos, pensado para que
lo operen agentes de IA con un humano como única compuerta. El host solo
necesita Docker; todo lo demás vive en un contenedor que se reconstruye desde
este repo, y las tareas se gestionan en Notion.

## Instalación en el host

El host necesita bash y Docker Compose. macOS y Linux corren tal cual; en
Windows, con WSL. `devkit awake` solo funciona en macOS (usa `caffeinate`);
`devkit code` abre el navegador con `open` y, donde no existe, imprime la
URL para pegarla a mano.

```sh
curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/new-project.sh | sh -s -- <proyecto> --version X.Y.Z
devkit up <proyecto>
devkit code <proyecto>
```

El primer comando instala `~/.devkit/bin/devkit` y deja el proyecto listo en
`~/.devkit/<proyecto>/`. El segundo levanta los contenedores y construye la
imagen la primera vez. El tercero abre el editor en el navegador, ya
autenticado con un token por proyecto.

Si el editor responde `403 Forbidden` en vez de abrir, no es que el token se
haya perdido ni que el contenedor falle: la cookie de sesión de
openvscode-server vence a los 7 días sin una carga real de la página (una
pestaña ya abierta no cuenta, sigue por websocket). `devkit code <proyecto>`
vuelve a inyectar el token y renueva la cookie por otros 7 días.

Cada proyecto recibe su propio par de puertos de host (editor y retorno
OAuth), asignado por `new-project.sh` al instalarlo: para verlos, `cat
~/.devkit/<proyecto>/.env`.

Cada proyecto tiene también un volumen `editor-<proyecto>` que conserva el
estado del editor VS Code del lado del servidor (estado de las extensiones,
perfiles en caché y logs) entre reconstrucciones. No guarda las extensiones en
sí: esas vienen en la imagen, así que una que instales a mano desde el editor
no sobrevive al `devkit rebuild`. `devkit down` no borra el volumen, igual que
al resto de los volúmenes con nombre; para reiniciarlo desde cero hace falta
`docker volume rm editor-<proyecto>`.

## Stack

| Herramienta | Para qué se usa aquí | Versión |
|---|---|---|
| Docker + Compose | Única dependencia del host. Dos contenedores por proyecto: `dev` (trabajo, sin salida directa) y `proxy` (única salida, con lista blanca). | — |
| Debian | Imagen base sin lenguaje. Usuario `dev` sin `sudo`. | debian:trixie-slim |
| tinyproxy | Proxy de salida con lista blanca de dominios (`allowlist.base` más `domains` de `.devkit/devkit.toml`). | alpine 3.22 |
| uv | Instala la versión de Python de `.devkit/devkit.toml` y gestiona dependencias y entornos. | 0.12.7 |
| Python | Lenguaje de los proyectos de datos. No viene en la imagen: cada proyecto fija su versión. | — |
| openvscode-server | Único editor del devkit: `devkit code <proyecto>` abre la URL con token. | 1.109.5 |
| zsh + starship | Shell y prompt de una sola línea: proyecto, rama, cambios, agentes vivos y alarmas. | starship 1.24.2 |
| Claude Code | Agente principal. Lee `AGENTS.md`, ejecuta las skills, abre PRs y actualiza Notion. | — |
| Codex | Segundo agente, preparado pero no instalado: mismo `AGENTS.md` y skills. | — |
| GitHub + gh | Código, PRs y la compuerta humana: `main` exige PR con una aprobación; auto-merge activado. | gh 2.100.0 |
| Git | Una rama por card, Conventional Commits con la Clave como ámbito. | — |
| Notion | Centro de tareas: bases Proyectos, Tareas y Documentación. | — |
| Bitwarden Secrets Manager | Único lugar de los secretos del proyecto. | bws 2.1.0 |
| rclone + Dropbox | Respaldo continuo de `sandbox.local/`, cada minuto. | rclone 1.75.1 |
| Terminal del host | cualquier terminal con bash; ahí corre el comando `devkit`. | — |

Generada por `gen-readme.sh` (verificado con `--check`), no a mano:

Extensiones del editor, versionadas en `devkit/vscode/extensions.toml`: Anthropic.claude-code latest, GitHub.vscode-pull-request-github 0.128.0.

## Comandos

### En el host: `devkit`

| Comando | Qué hace |
|---|---|
| `devkit up <proyecto>` | Levanta los contenedores (construye la imagen si falta). |
| `devkit shell <proyecto>` | Abre una shell dentro del contenedor. Úsalo para depurar o correr un comando suelto sin abrir el editor. |
| `devkit code <proyecto>` | Abre el editor en el navegador; sin `open`, imprime la URL para pegarla a mano (macOS la abre sola). Úsalo para el trabajo del día a día. Si ves `403 Forbidden`, la cookie del token venció (7 días, valor fijo de openvscode-server): repite el comando para renovarla. |
| `devkit stop <proyecto>` | Detiene sin perder nada. |
| `devkit down <proyecto>` | Destruye el contenedor; lo no commiteado se pierde. |
| `devkit recreate <proyecto>` | Recrea los contenedores, reconstruyendo solo las capas que cambiaron. Úsalo tras tocar `.devkit/devkit.toml` o, en modo dev, el propio `devkit/`. Se niega si hay un agente en curso; `--force` salta la guarda. |
| `devkit rebuild <proyecto>` | Reconstruye las imágenes desde cero y recrea. Úsalo cuando cambies el Dockerfile o sospeches que la imagen quedó corrupta; `recreate` no alcanza. Misma guarda de agentes en curso que `recreate`. |
| `devkit update <proyecto>` | Sube a la versión de template que pide `.devkit/devkit.toml`. |
| `devkit logs <proyecto>` | Arranque y bucles del contenedor. |
| `devkit net-open <proyecto>` | Red abierta en esta sesión, solo para depurar. |
| `devkit awake <proyecto>` | Solo macOS: evita que el host se suspenda mientras el contenedor esté vivo (`caffeinate`); en otro host avisa y no hace nada. Úsalo antes de un lanzamiento largo sin supervisión. |
| `devkit ls` | Lista los proyectos instanciados. |

### Dentro del contenedor

| Comando | Qué hace |
|---|---|
| `claude` | Abre Claude Code en el workspace. |
| `devkit-net-denied` | Lista los dominios que el proxy rechazó recientemente. Úsalo cuando una conexión falle con "connection refused", para saber qué dominio falta en la lista blanca. |
| `g` | Alias de `git`. |
| `gs` | Alias de `git status -sb`. |
| `gl` | Alias de `git log` gráfico. |
| `ll` | Alias de `ls -lah`. |
| `c` | Alias de `clear`. |
| `dk <skill> <Clave>` | Lanza una skill en segundo plano y se queda mostrando su avance hasta que termina. Úsalo para lanzar cualquier skill a mano, fuera del ciclo automático del bucle. Alias largo: `devkit-run`, mismo script y mismos argumentos; los agentes lo invocan así. |
| `dk --estado [--seguir]` | Muestra todos los agentes del contenedor y se refresca cada 3 s. Úsalo para saber qué está corriendo; Ctrl-C cierra solo el monitor. La columna PR muestra `#<número>` y, en una terminal que soporte hipervínculos, se abre con Ctrl/Cmd+clic. |
| `dk --tablero [--seguir]` | Muestra las cards activas del proyecto en una tabla y se refresca cada 30 s. Úsalo para ver de un vistazo qué card está en progreso o bloqueada. |
| `dk --cola` | Muestra las primeras diez cards de la cola, en el orden en que el bucle las va a tomar. Úsalo para ver qué sigue antes de que arranque. |
| `dk --agentes-vivos` | Lista PID, Clave y paso de cada agente en curso en el contenedor, o dice que no hay ninguno. Úsalo antes de un `devkit recreate`/`devkit rebuild` a mano. |
| `dk --pausa` | Pone el interruptor en pausa: el bucle deja de tomar cards nuevas de la cola cuando la obedezca; un lanzamiento manual sigue permitido. |
| `dk --alto` | Pone el interruptor en alto: el bucle se detiene del todo cuando la obedezca y un lanzamiento manual se rechaza. Úsalo antes de una intervención que no debe cruzarse con ningún agente. |
| `dk --reanudar` | Vuelve el interruptor al modo trabajo. |
| `dk pr-review <N>` | Revisa el PR número `<N>` como revisor independiente y publica el veredicto. Úsalo para forzar una revisión sin esperar al bucle. |
| `dk task-fix <N>` | Corrige el PR número `<N>` según los hallazgos de la última revisión. Úsalo para forzar una corrección sin esperar al bucle. |
| `dk --otros-agentes` | Dice si otro agente ya ocupa el workspace. |
| `dk task-close <Clave> [PR]` | Cierra una card con el PR mergeado, en bash. |
| `dk task-block <Clave> <motivo>` | Bloquea una card con un motivo, en bash. |

### Python

| Comando | Qué hace |
|---|---|
| `uv add <paquete>` | Agrega una dependencia al proyecto y la fija en `pyproject.toml`. Úsalo para instalar una librería nueva. |
| `uv sync` | Instala en el entorno del proyecto exactamente las dependencias de `pyproject.toml`. Úsalo tras cambiar de rama o editar `pyproject.toml` a mano. |
| `uv run <comando>` | Corre un comando dentro del entorno del proyecto, sin activarlo a mano. Úsalo para ejecutar un script o una prueba puntual. |

### Scripts de `devkit/scripts/`

| Comando | Qué hace |
|---|---|
| `gen-stack.sh` | Genera la tabla Stack y la línea de extensiones del README. |
| `gen-readme.sh` | Genera y verifica `README.md` completo desde la plantilla. |
| `gen-cheatsheet.sh` | Genera y verifica `cheatsheet.html` y los SVG `cheatsheet-light.svg`/`cheatsheet-dark.svg`, la chuleta de comandos del editor (panel a pedido y marca de agua del editor vacío). |
| `devkit-run.sh` | Único punto de lanzamiento de una skill (ver `devkit-run` más arriba). |
| `watch.sh` | Bucle que revisa PRs abiertos y cierra los mergeados, lanzando la skill que toca. |
| `watch-test.sh` | Prueba `watch.sh` sin GitHub y sin gastar cuota. |
| `notion.sh` | Cliente de la API de Notion para bash: leer y escribir cards y Documentación. |
| `task-close.sh <Clave> [PR]` | Cierra una card mergeada: `Estado` a `Hecha` y marcador en el PR. Úsalo tras mergear a mano, cuando el bucle no la alcanzó a cerrar solo. |
| `task-block.sh <Clave> <motivo>` | Bloquea una card y anota el motivo. Úsalo cuando falte algo del humano y no puedas seguir sin preguntar. |
| `cola.sh [--lista]` | Imprime la Clave de la siguiente card de la cola, o con `--lista`, las primeras diez. |
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
| `/task-create` | Crea una o varias cards en Notion en estado Por refinar para el proyecto actual, con la plantilla de objetivo, criterios de aceptación y notas. Úsala cuando el humano pida registrar trabajo pendiente o cuando descubras una necesidad fuera del alcance de la card activa. |
| `/task-start` | Toma una card en Lista, la pasa a En progreso, crea su rama desde main y registra la URL de la rama y un comentario con el plan. Úsala para empezar a trabajar una card. Argumento opcional: la Clave; sin argumento toma la siguiente hija libre del proyecto. |
| `/task-submit` | Entrega para revisión el trabajo de una card en progreso: verifica, sube la rama, abre el PR con auto-merge, registra la URL del PR y pasa la card a Revisión automática. No emite veredicto; quien revisa es pr-review, en otro proceso. Úsala cuando los criterios de aceptación se cumplan o cuando el humano pida abrir el PR. Argumento opcional: la Clave; por defecto la card de la rama actual. |
| `/pr-review` | Revisa un PR como revisor independiente del autor. Comprueba cada criterio de aceptación de la card ejecutando algo, lee el diff de forma adversarial, publica el informe en el PR con el marcador devkit-review y, según el veredicto, mueve la card a Lista para merge y pide review al humano, o la deja en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: número de PR. |
| `/task-fix` | Corrige un PR dentro del ciclo automático. Lee el bloque devkit-findings del último informe de pr-review con veredicto CAMBIOS, o el comentario del humano sobre una card en Lista para merge, aplica los cambios en la rama de la card, hace push, responde en el PR con una línea por hallazgo y deja la card en Revisión automática. La lanza el bucle del contenedor en modo headless, o el humano. Argumento: la Clave; opcionalmente el texto de un comentario humano. |
| `/task-document` | Escribe la entrada de Documentación en los dos casos que necesitan criterio: una entrada "decisión" (la card cambió una decisión de diseño, marcada con "Tipo: decisión" en el cuerpo del PR) o la entrada consolidada de una Épica. La entrada "cambio" de una card ordinaria la escribe devkit/scripts/task-document.sh, sin agente (DEVKIT-92). watch.sh te lanza solo si el PR trae esa marca; task-close.sh, solo para una Épica. Argumentos: la Clave; opcionalmente el número de PR. |
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
  token en `~/.devkit/bws-token` del host los trae al arrancar a un `tmpfs`
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

# devkit

Entorno de desarrollo reproducible para proyectos de datos, pensado para que
lo operen agentes de IA con un humano como única compuerta. El Mac solo
necesita Docker; todo lo demás vive en un contenedor que se reconstruye desde
este repo, y las tareas se gestionan en Notion.

Diseño completo y decisiones: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
Cambios por versión: [`devkit/CHANGELOG.md`](devkit/CHANGELOG.md).

## Cómo funciona, en una vuelta

1. Tú mueves una Épica de **Backlog** a **Lista** en Notion.
2. Un agente la descompone en cards hijas, crea una rama por card, trabaja y
   abre un PR a `main`.
3. Un bucle dentro del contenedor lanza un revisor independiente sobre el PR.
   Si pide cambios, un corrector los atiende y el revisor vuelve a mirar;
   cuando da el OK, te pide el review. Tras tres ciclos sin OK, bloquea la
   card y te avisa.
4. Tú apruebas el PR y GitHub lo mergea solo. Si en vez de aprobar comentas,
   el corrector atiende tu comentario y el ciclo sigue.
5. El mismo bucle detecta el merge, cierra la card, escribe la entrada de
   Documentación y trabaja la siguiente hija hasta dejar su PR abierto.

Estados de una card: `Backlog → Lista → En progreso → Revisión automática →
Lista para merge → Hecha`, más `Bloqueada` cuando el agente necesita algo de
ti.

## Stack

| | Herramienta | Para qué se usa aquí |
|---|---|---|
| ![Docker](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white) | **Docker + Compose** | Única dependencia del Mac. Dos contenedores por proyecto: `dev` (trabajo, sin salida directa a internet) y `proxy` (única salida, con lista blanca). |
| ![Debian](https://img.shields.io/badge/Debian_trixie--slim-A81D33?logo=debian&logoColor=white) | **Debian trixie-slim** | Imagen base sin lenguaje preinstalado. Usuario `dev` sin `sudo`. |
| ![tinyproxy](https://img.shields.io/badge/tinyproxy-555555) | **tinyproxy** | Proxy de salida con lista blanca de dominios (`devkit/proxy/allowlist.base` más `domains` de `devkit.toml`). `devkit-net-denied` muestra qué se bloqueó. |
| ![uv](https://img.shields.io/badge/uv-DE5FE9?logo=astral&logoColor=white) | **uv** | Instala la versión de Python que declara `devkit.toml` y gestiona dependencias y entornos (`uv add`, `uv sync`, `uv run`). |
| ![Python](https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=white) | **Python** | Lenguaje de los proyectos de datos. No viene en la imagen: cada proyecto fija su versión. `ruff` y `basedpyright` llegan como herramientas de `uv`. |
| ![Neovim](https://img.shields.io/badge/Neovim-57A143?logo=neovim&logoColor=white) | **Neovim** | Editor en terminal, con plugins fijados por lockfile: LSP, autocompletado, Telescope, gitsigns y `claudecode.nvim` para hablar con Claude desde el editor. Los archivos que un agente cambia en disco se releen solos cada segundo, sin `:e`. |
| ![tmux](https://img.shields.io/badge/tmux-1BB91F?logo=tmux&logoColor=white) | **tmux** | Sesión persistente dentro del contenedor: si cierras la terminal, el trabajo sigue. `devkit attach` vuelve a ella. |
| ![zsh](https://img.shields.io/badge/zsh_+_starship-F15A24?logo=zsh&logoColor=white) | **zsh + starship** | Shell y prompt. El prompt muestra rama, estado de git y que estás dentro del contenedor. |
| ![Claude Code](https://img.shields.io/badge/Claude_Code-D97757?logo=claude&logoColor=white) | **Claude Code** | Agente principal. Lee `AGENTS.md`, ejecuta las skills, abre PRs y actualiza Notion. En modo headless (`claude -p`) revisa, corrige y cierra cards sin intervención. |
| ![Codex](https://img.shields.io/badge/Codex-000000?logo=openai&logoColor=white) | **Codex** | Segundo agente, preparado pero no instalado: lee el mismo `AGENTS.md` y las mismas skills (estándar Agent Skills). |
| ![GitHub](https://img.shields.io/badge/GitHub-181717?logo=github&logoColor=white) | **GitHub + gh** | Código, PRs y la compuerta humana: `main` exige PR con una aprobación; auto-merge y borrado de ramas activados. Los agentes actúan con la cuenta máquina `byroncz-bot`. |
| ![Git](https://img.shields.io/badge/Git-F05032?logo=git&logoColor=white) | **Git** | Una rama por card, un commit squash en `main` por PR, Conventional Commits con la Clave como ámbito. |
| ![Notion](https://img.shields.io/badge/Notion-000000?logo=notion&logoColor=white) | **Notion** | Centro de tareas: bases Proyectos, Tareas y Documentación. Los agentes la leen y escriben con el plugin oficial de Notion para Claude Code. |
| ![Bitwarden](https://img.shields.io/badge/Bitwarden_Secrets-175DDC?logo=bitwarden&logoColor=white) | **Bitwarden Secrets Manager** | Único lugar de los secretos. Un token en `~/.devkit/bws-token` los trae al arrancar a un `tmpfs` que muere con el contenedor. |
| ![rclone](https://img.shields.io/badge/rclone_+_Dropbox-0061FF?logo=dropbox&logoColor=white) | **rclone + Dropbox** | Respaldo continuo de `sandbox.local/`, el único directorio fuera de git que sobrevive a un rebuild. Cada minuto, con papelera por día. |
| ![Terminal](https://img.shields.io/badge/Terminal.app-000000?logo=apple&logoColor=white) | **Terminal.app** | La terminal de macOS, sin instalar nada. Truco para copiar URLs largas desde tmux: `pbpaste \| tr -d ' \n' \| pbcopy`. |

Versiones fijadas en [`devkit/Dockerfile`](devkit/Dockerfile): uv 0.12.7,
Neovim 0.12.5, gh 2.100.0, rclone 1.75.1, bws 2.1.0, starship 1.24.2.

## Comandos

### En el Mac: `devkit`

Lo instala `new-project.sh` en `~/.devkit/bin/devkit`.

| Comando | Qué hace |
|---|---|
| `devkit up <proyecto>` | Levanta los contenedores (construye la imagen si falta) y entra. |
| `devkit attach <proyecto>` | Vuelve a la sesión de tmux. |
| `devkit stop <proyecto>` | Detiene sin perder nada. |
| `devkit down <proyecto>` | Destruye el contenedor. Lo no committeado se pierde. |
| `devkit recreate <proyecto>` | Recrea los contenedores: relee secretos y `devkit.env`, reconstruye solo las capas que cambiaron. |
| `devkit rebuild <proyecto>` | Reconstruye las imágenes desde cero y recrea. |
| `devkit update <proyecto>` | Sube a la versión de template que pide `devkit.toml` del repo. |
| `devkit logs <proyecto>` | Arranque y bucles. |
| `devkit net-open <proyecto>` | Red abierta en esta sesión, solo para depurar. |
| `devkit ls` | Proyectos instanciados. |

Crear un proyecto nuevo:

```sh
curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/new-project.sh | sh -s -- <proyecto> --version 0.1.0
```

### Dentro del contenedor

| Comando | Qué hace |
|---|---|
| `claude` | Abre Claude Code en el workspace. |
| `devkit-net-denied` | Lista los dominios que el proxy bloqueó en esta sesión. |
| `v`, `g`, `gs`, `gl`, `ll` | Alias: `nvim`, `git`, `git status -sb`, `git log` gráfico, `ls -lah`. |
| `/opt/devkit/scripts/dropbox-setup.sh` | Autoriza Dropbox una vez y genera el secreto `rclone_conf_b64`. |
| `/opt/devkit/scripts/watch-test.sh` | Prueba la tabla de decisión de `watch.sh` con PRs sintéticos; sale con 1 si un caso falla. |
| `/opt/devkit/scripts/slugify.sh` | Convierte un texto libre en un slug de minúsculas separado por guiones (formato de las ramas). `--test` corre su tabla de autoprueba. |

Bucles en segundo plano: `sync-sandbox.sh` (respaldo cada 60 s) y `watch.sh`
(cada 5 min). `watch.sh` mira cada PR cuyo título empieza por una Clave del
proyecto y lanza en modo headless la skill que toca. Su único estado son los
marcadores que las skills dejan en el PR; un rebuild no pierde nada.

| Lo que ve en el PR | Qué lanza |
|---|---|
| Abierto y el head sin marcador `devkit-review` | `/pr-review <N>` |
| Último marcador `verdict=CAMBIOS` para el head, sin respuesta `devkit-fix` | `/task-fix <Clave>` |
| Último marcador `OK` y un comentario o review tuyo posterior (un approve no cuenta) | `/task-fix <Clave> "<tu comentario>"`; la card vuelve a `Revisión automática` |
| Tres informes `CAMBIOS` desde el último `OK` o el último bloqueo, ya atendidos | Marcador `<!-- devkit-block sha=<head> -->` en el PR y `/task-block <Clave>`. No lo toca más hasta que muevas la card a `Revisión automática` y comentes en el PR qué hacer |
| Mergeado en las últimas 48 h y sin marcador `devkit-closed` | `/task-close <Clave> <URL>`, que al terminar deja el marcador `<!-- devkit-closed sha=<merge commit> -->` en el PR |
| Mergeado y con marcador `devkit-closed` | Nada: una línea `ya cerrado` en el log |

Cada ejecución deja su log en `/run/devkit/<skill>-<N>.log`; la última línea
trae el costo y los tokens, que es la medida de cada ciclo. Al terminar cada
`claude -p`, el bucle registra además una línea `estado:` con la rama en la que
quedó el workspace, sus commits sobre `main` y su PR (`rama de card sin PR` si
no lo hay, `PR desconocido` si `gh` no respondió). Es una observación de git y
GitHub, no del Estado de la card: una rama de card sin PR es la señal de que la
ejecución pudo cortarse a medias, y solo Notion dice qué le pasó a la card.
Variables:
`DEVKIT_WATCH_INTERVAL` (segundos, 300) y `DEVKIT_WATCH_MAX_CYCLES` (3). Para
ver qué decidiría sobre un PR sin esperar al bucle:

```sh
gh pr view <N> --json headRefOid,reviews,comments | bash /opt/devkit/scripts/watch.sh --decide
gh pr view <N> --json comments | bash /opt/devkit/scripts/watch.sh --decide-merged
```

`--decide` responde por un PR abierto; `--decide-merged`, por uno ya mergeado
(`cerrar` o `cerrada <sha>`), que no tiene head que revisar y solo se pregunta
si `task-close` ya pasó.

La tabla de decisión tiene una prueba reproducible sin GitHub:
`bash /opt/devkit/scripts/watch-test.sh` corre cada caso (PR vacío, `CAMBIOS`
con y sin respuesta, comentario humano, tres ciclos, bloqueo y reanudación, y
la rama de cierre con y sin marcador) contra `watch.sh --decide` y
`--decide-merged`, y falla si alguno no da la acción esperada.

Revisión de PRs: `/pr-review <N>` actúa como revisor independiente del
autor. Comprueba cada criterio de aceptación de la card ejecutando algo, lee
el diff de forma adversarial y publica el informe en el PR con el marcador
`<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->`. Con `OK` mueve la
card a `Lista para merge` y te pide el review; con `CAMBIOS` deja los
hallazgos en un bloque `devkit-findings` (una línea por hallazgo:
`id | severidad | archivo:línea | qué falla | qué hacer`) para que `task-fix`
los atienda. El revisor nunca corrige ni aprueba: `settings.json` niega
`gh pr review --approve` y todo `gh pr merge` que no sea `--auto`, y la
compuerta real es GitHub (sin autoaprobación, ruleset de `main`); el detalle
está en `docs/ARCHITECTURE.md`, sección 12b.

Corrección de PRs: `/task-fix <Clave> [texto]` es el corrector del ciclo.
Sin texto, lee el bloque `devkit-findings` del último informe con veredicto
`CAMBIOS` y solo los archivos que nombra; con texto, o si la card está en
`Lista para merge` y hay un comentario tuyo en el PR, atiende ese comentario
como un hallazgo único `C<n>`. Un commit por hallazgo con la Clave como
ámbito, push sin `--force`, y una respuesta en el PR dentro del bloque
`devkit-fixes` (`id | atendido o descartado | commit o motivo`) que es lo
único que `pr-review` relee en el ciclo siguiente. Al terminar deja la card
en `Revisión automática`. Nunca revisa, aprueba ni mergea.

Cierre de PRs: `/task-close <Clave> [URL]` deja la card en `Hecha`, escribe la
entrada de Documentación y publica en el PR el marcador
`<!-- devkit-closed sha=<merge commit> -->` con el enlace a esa entrada, o
solo, si la card ya estaba `Hecha` y no tiene entrada que enlazar.
El marcador es lo que impide repetir el cierre: `/run/devkit/launched` vive en
tmpfs y nace vacío en cada `devkit recreate`, así que antes el bucle relanzaba
`task-close` sobre cada PR mergeado en las últimas 48 h, con card ya cerrada
(unos 0,47 USD y 150 s por ejecución inútil). Para ponerlo a mano en un PR ya
cerrado, o para poner al día un repo que viene de una versión anterior:

```sh
gh pr comment <N> --body "<!-- devkit-closed sha=$(gh pr view <N> --json mergeCommit --jq .mergeCommit.oid) -->"
```

### Skills (comandos `/nombre` dentro de `claude`)

| Skill | Transición | Quién la lanza |
|---|---|---|
| `/project-init` | Alta de proyecto en Notion | Humano, una vez |
| `/epic-plan <Clave>` | Épica en Lista → hijas en Lista | Humano, al aprobar una Épica |
| `/task-create <texto>` | Nace en Backlog | Humano o agente |
| `/task-start [Clave]` | Lista → En progreso | Agente; también `epic-plan` y `task-close` |
| `/task-review [Clave]` | En progreso → Revisión automática | Agente |
| `/pr-review <número de PR>` | Revisión automática → Lista para merge, o se queda | `watch.sh` (headless) o humano |
| `/task-fix <Clave> [texto]` | Revisión automática o Lista para merge → Revisión automática | `watch.sh` (headless) o humano |
| `/task-close <Clave>` | Lista para merge → Hecha | `watch.sh` tras el merge |
| `/task-block <Clave> <motivo>` | Cualquiera → Bloqueada | Agente |
| `/session-start` | Estado del proyecto y siguiente card libre | Humano o agente |
| `/template-update <X.Y.Z>` | Sube la versión del template del proyecto | Agente |
| `/template-propagate` | PR de actualización en cada proyecto | Agente, desde DEVKIT |

Detalle y convenciones: [`devkit/agents/skills/README.md`](devkit/agents/skills/README.md).

**Modo headless.** `watch.sh` invoca las skills con `claude -p`, donde no hay
quien conteste: una pregunta al humano mata el proceso y deja la card a medias,
así que equivale a `/task-block`. Toda ejecución headless termina en un estado
observable de la card, nunca a la espera. Dos skills lo hacen explícito:

- `/task-start` no se detiene tras crear la rama y comentar el plan: implementa
  la card hasta cumplir todos los criterios de aceptación y termina ejecutando
  `/task-review`. Si falta una decisión, un acceso o un criterio de aceptación,
  o se atasca más de dos intentos en el mismo problema, ejecuta `/task-block`
  con la petición concreta. Una ejecución que no deja la card en `Revisión
  automática` o `Bloqueada` es un corte, no un avance.
- `/task-close`, al cerrar una hija de una Épica que aún tiene hermanas
  pendientes, toma la siguiente con `/task-start` y la trabaja completa en la
  misma ejecución, hasta `/task-review` o `/task-block`. Arrancarla y devolver
  el control no cuenta: nadie la retomaría.

## Qué declara cada proyecto

Un solo archivo en la raíz, `devkit.toml`:

```toml
[devkit]
template = "0.1.0"     # versión del template
project  = "DATA"      # código del proyecto en Notion
python   = "3.13"      # opcional
apt      = []          # opcional: paquetes de sistema extra
domains  = []          # opcional: dominios extra para el proxy
reviewer = "usuario"   # opcional: usuario de GitHub al que pr-review pide el review
```

Sin `reviewer`, `pr-review` usa el dueño del repo si es un usuario; en una
organización hay que declararlo.

En el Mac, `~/.devkit/<proyecto>/devkit.env` guarda solo lo personal: URL del
repo, identidad git y remoto de Dropbox.

## Mantener este documento

Este README y la entrada "Stack y comandos del devkit" en Documentación
(Notion) son la referencia de comandos del devkit. Todo comando, alias, script
o skill nuevo o cambiado se documenta en ambos, en el mismo PR. La regla está
en [`AGENTS.md`](AGENTS.md).

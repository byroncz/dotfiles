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
3. Tú apruebas el PR. GitHub lo mergea solo.
4. Un bucle dentro del contenedor detecta el merge, cierra la card, escribe la
   entrada de Documentación y arranca la siguiente hija.

Estados de una card: `Backlog → Lista → En progreso → En revisión → Hecha`,
más `Bloqueada` cuando el agente necesita algo de ti.

## Stack

| | Herramienta | Para qué se usa aquí |
|---|---|---|
| ![Docker](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white) | **Docker + Compose** | Única dependencia del Mac. Dos contenedores por proyecto: `dev` (trabajo, sin salida directa a internet) y `proxy` (única salida, con lista blanca). |
| ![Debian](https://img.shields.io/badge/Debian_trixie--slim-A81D33?logo=debian&logoColor=white) | **Debian trixie-slim** | Imagen base sin lenguaje preinstalado. Usuario `dev` sin `sudo`. |
| ![tinyproxy](https://img.shields.io/badge/tinyproxy-555555) | **tinyproxy** | Proxy de salida con lista blanca de dominios (`devkit/proxy/allowlist.base` más `domains` de `devkit.toml`). `devkit-net-denied` muestra qué se bloqueó. |
| ![uv](https://img.shields.io/badge/uv-DE5FE9?logo=astral&logoColor=white) | **uv** | Instala la versión de Python que declara `devkit.toml` y gestiona dependencias y entornos (`uv add`, `uv sync`, `uv run`). |
| ![Python](https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=white) | **Python** | Lenguaje de los proyectos de datos. No viene en la imagen: cada proyecto fija su versión. `ruff` y `basedpyright` llegan como herramientas de `uv`. |
| ![Neovim](https://img.shields.io/badge/Neovim-57A143?logo=neovim&logoColor=white) | **Neovim** | Editor en terminal, con plugins fijados por lockfile: LSP, autocompletado, Telescope, gitsigns y `claudecode.nvim` para hablar con Claude desde el editor. |
| ![tmux](https://img.shields.io/badge/tmux-1BB91F?logo=tmux&logoColor=white) | **tmux** | Sesión persistente dentro del contenedor: si cierras la terminal, el trabajo sigue. `devkit attach` vuelve a ella. |
| ![zsh](https://img.shields.io/badge/zsh_+_starship-F15A24?logo=zsh&logoColor=white) | **zsh + starship** | Shell y prompt. El prompt muestra rama, estado de git y que estás dentro del contenedor. |
| ![Claude Code](https://img.shields.io/badge/Claude_Code-D97757?logo=claude&logoColor=white) | **Claude Code** | Agente principal. Lee `AGENTS.md`, ejecuta las skills, abre PRs y actualiza Notion. En modo headless (`claude -p`) cierra cards sin intervención. |
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

Bucles en segundo plano: `sync-sandbox.sh` (respaldo cada 60 s) y
`watch-merged.sh` (cada 5 min busca PRs mergeados y lanza `task-close`).

### Skills (comandos `/nombre` dentro de `claude`)

| Skill | Transición | Quién la lanza |
|---|---|---|
| `/project-init` | Alta de proyecto en Notion | Humano, una vez |
| `/epic-plan <Clave>` | Épica en Lista → hijas en Lista | Humano, al aprobar una Épica |
| `/task-create <texto>` | Nace en Backlog | Humano o agente |
| `/task-start [Clave]` | Lista → En progreso | Agente; también `epic-plan` y `task-close` |
| `/task-review [Clave]` | En progreso → En revisión | Agente |
| `/task-close <Clave>` | En revisión → Hecha | `watch-merged.sh` tras el merge |
| `/task-block <Clave> <motivo>` | Cualquiera → Bloqueada | Agente |
| `/session-start` | Estado del proyecto y siguiente card libre | Humano o agente |
| `/template-update <X.Y.Z>` | Sube la versión del template del proyecto | Agente |
| `/template-propagate` | PR de actualización en cada proyecto | Agente, desde DEVKIT |

Detalle y convenciones: [`devkit/agents/skills/README.md`](devkit/agents/skills/README.md).

## Qué declara cada proyecto

Un solo archivo en la raíz, `devkit.toml`:

```toml
[devkit]
template = "0.1.0"     # versión del template
project  = "DATA"      # código del proyecto en Notion
python   = "3.13"      # opcional
apt      = []          # opcional: paquetes de sistema extra
domains  = []          # opcional: dominios extra para el proxy
```

En el Mac, `~/.devkit/<proyecto>/devkit.env` guarda solo lo personal: URL del
repo, identidad git y remoto de Dropbox.

## Mantener este documento

Este README y la entrada "Stack y comandos del devkit" en Documentación
(Notion) son la referencia de comandos del devkit. Todo comando, alias, script
o skill nuevo o cambiado se documenta en ambos, en el mismo PR. La regla está
en [`AGENTS.md`](AGENTS.md).

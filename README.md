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
   cuando da el OK, te pide el review, escribe la entrada de Documentación,
   para que la leas antes de aprobar, y arranca la siguiente hija libre de la
   Épica sin esperar tu approve. Si tras tres ciclos corregidos el revisor
   vuelve a pedir cambios sobre el código vigente, bloquea la card y te avisa.
4. Tú apruebas el PR y GitHub lo mergea solo. Si en vez de aprobar comentas,
   el corrector atiende tu comentario y el ciclo sigue.
5. El mismo bucle detecta el merge en menos de un minuto, cierra la card en
   bash (sin lanzar un agente) y arranca la siguiente hija libre, si no había
   arrancado ya: las que dependen de la card mergeada esperaban este momento.

Estados de una card: `Backlog → Lista → En progreso → Revisión automática →
Lista para merge → Hecha`, más `Bloqueada` cuando el agente necesita algo de
ti.

## Stack

| | Herramienta | Para qué se usa aquí |
|---|---|---|
| ![Docker](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white) | **Docker + Compose** | Única dependencia del Mac. Dos contenedores por proyecto: `dev` (trabajo, sin salida directa a internet) y `proxy` (única salida, con lista blanca). |
| ![Debian](https://img.shields.io/badge/Debian_trixie--slim-A81D33?logo=debian&logoColor=white) | **Debian trixie-slim** | Imagen base sin lenguaje preinstalado. Usuario `dev` sin `sudo`. |
| ![tinyproxy](https://img.shields.io/badge/tinyproxy-555555) | **tinyproxy** | Proxy de salida con lista blanca de dominios (`devkit/proxy/allowlist.base` más `domains` de `.devkit/devkit.toml`). `devkit-net-denied` muestra qué se bloqueó. |
| ![uv](https://img.shields.io/badge/uv-DE5FE9?logo=astral&logoColor=white) | **uv** | Instala la versión de Python que declara `.devkit/devkit.toml` y gestiona dependencias y entornos (`uv add`, `uv sync`, `uv run`). |
| ![Python](https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=white) | **Python** | Lenguaje de los proyectos de datos. No viene en la imagen: cada proyecto fija su versión. `ruff` y `basedpyright` llegan como herramientas de `uv`. |
| ![VS Code](https://img.shields.io/badge/openvscode--server-2F80ED?logo=visualstudiocode&logoColor=white) | **openvscode-server** | Único editor del devkit: `devkit code <proyecto>` abre la URL con token, ya en `/workspace`. Con la extensión Claude Code instalada desde Open VSX. Trae `"chat.disableAIFeatures": true` para apagar el chat integrado de VS Code, pero en esta build de openvscode-server (1.109.5) el ajuste no oculta el comando `Chat: Open Chat` de la paleta; limitación conocida, sin arreglo (DEVKIT-66). Claude Code es una extensión aparte y no depende de este ajuste. Su terminal integrada abre ahí mismo y sostiene la sesión: si cierras la pestaña, se reconecta hasta tres horas después. Las skills solo funcionan desde `/workspace` (regla de `AGENTS.md`), así que la terminal integrada ya arranca en el lugar correcto. Publicado solo en `127.0.0.1` del Mac y gateado por un token de conexión por proyecto, en Bitwarden ([amenazas y mitigaciones](docs/ARCHITECTURE.md#8-seguridad)). |
| ![zsh](https://img.shields.io/badge/zsh_+_starship-F15A24?logo=zsh&logoColor=white) | **zsh + starship** | Shell y prompt. El prompt muestra rama, estado de git y que estás dentro del contenedor. `devkit shell` abre una shell suelta, sin la persistencia del editor. |
| ![Claude Code](https://img.shields.io/badge/Claude_Code-D97757?logo=claude&logoColor=white) | **Claude Code** | Agente principal. Lee `AGENTS.md`, ejecuta las skills, abre PRs y actualiza Notion. En modo headless (`claude -p`) revisa, corrige y cierra cards sin intervención. |
| ![Codex](https://img.shields.io/badge/Codex-000000?logo=openai&logoColor=white) | **Codex** | Segundo agente, preparado pero no instalado: lee el mismo `AGENTS.md` y las mismas skills (estándar Agent Skills). |
| ![GitHub](https://img.shields.io/badge/GitHub-181717?logo=github&logoColor=white) | **GitHub + gh** | Código, PRs y la compuerta humana: `main` exige PR con una aprobación; auto-merge y borrado de ramas activados. Los agentes actúan con la cuenta máquina `byroncz-bot`. |
| ![Git](https://img.shields.io/badge/Git-F05032?logo=git&logoColor=white) | **Git** | Una rama por card, un commit squash en `main` por PR, Conventional Commits con la Clave como ámbito. |
| ![Notion](https://img.shields.io/badge/Notion-000000?logo=notion&logoColor=white) | **Notion** | Centro de tareas: bases Proyectos, Tareas y Documentación. Los agentes la leen y escriben con el plugin oficial de Notion para Claude Code; los scripts bash (`notion.sh`, `task-close.sh`, `task-block.sh`), con la API de Notion y el token de una conexión interna (secreto `notion_token`). |
| ![Bitwarden](https://img.shields.io/badge/Bitwarden_Secrets-175DDC?logo=bitwarden&logoColor=white) | **Bitwarden Secrets Manager** | Único lugar de los secretos. Un token en `~/.devkit/bws-token` los trae al arrancar a un `tmpfs` que muere con el contenedor. |
| ![rclone](https://img.shields.io/badge/rclone_+_Dropbox-0061FF?logo=dropbox&logoColor=white) | **rclone + Dropbox** | Respaldo continuo de `sandbox.local/`, el único directorio fuera de git que sobrevive a un rebuild. Cada minuto, con papelera por día. |
| ![Terminal](https://img.shields.io/badge/Terminal.app-000000?logo=apple&logoColor=white) | **Terminal.app** | La terminal de macOS, sin instalar nada. Ahí corre el comando `devkit`. |

Versiones fijadas en [`devkit/Dockerfile`](devkit/Dockerfile): uv 0.12.7,
gh 2.100.0, rclone 1.75.1, bws 2.1.0, starship 1.24.2,
openvscode-server 1.109.5, extensión Claude Code 2.1.270.

## Comandos

### En el Mac: `devkit`

Lo instala `new-project.sh` en `~/.devkit/bin/devkit`.

| Comando | Qué hace |
|---|---|
| `devkit up <proyecto>` | Levanta los contenedores (construye la imagen si falta). |
| `devkit shell <proyecto>` | Abre una shell dentro del contenedor. |
| `devkit code <proyecto>` | Abre el editor VS Code del proyecto en el navegador. Solo imprime la URL con el token en la terminal si `open` falta o falla. |
| `devkit stop <proyecto>` | Detiene sin perder nada. |
| `devkit down <proyecto>` | Destruye el contenedor. Lo no committeado se pierde. |
| `devkit recreate <proyecto>` | Recrea los contenedores: relee secretos y `devkit.env`, reconstruye solo las capas que cambiaron. En modo dev, primero rearma el contexto de build desde el workspace. |
| `devkit rebuild <proyecto>` | Reconstruye las imágenes desde cero y recrea. En modo dev, también rearma el contexto de build. |
| `devkit update <proyecto>` | Sube a la versión de template que pide `.devkit/devkit.toml` del repo. En modo dev no hay etiqueta que bajar: te manda a `recreate`. |
| `devkit logs <proyecto>` | Arranque y bucles. |
| `devkit net-open <proyecto>` | Red abierta en esta sesión, solo para depurar. |
| `devkit awake <proyecto>` | Impide que el Mac se suspenda por inactividad mientras el contenedor esté vivo: corre `caffeinate -i docker wait devkit-<proyecto>` en primer plano y suelta la aserción cuando el contenedor se detiene o con Ctrl-C. Sin eso, el reposo del Mac congela la VM de Docker y los bucles del contenedor dejan de correr. No evita el reposo al cerrar la tapa. Falla si el contenedor no corre o si falta `caffeinate` (fuera de macOS). |
| `devkit ls` | Proyectos instanciados. |

Si el editor no abre: `docker exec devkit-<proyecto> pgrep -af server-main.js`
para ver si el servidor está vivo, y `devkit logs <proyecto>` para el log de
arranque. Diagnóstico completo, causas y rotación del token en el runbook "El
editor no abre" (Documentación,
https://app.notion.com/p/3db27957d23d81d690f1ea533a6a652c).

Crear un proyecto nuevo:

```sh
curl -fsSL https://raw.githubusercontent.com/byroncz/dotfiles/main/new-project.sh | sh -s -- <proyecto> --version 0.1.0
```

### Modo dev: probar el template antes de etiquetarlo

Solo aplica al repo del template (`DEVKIT`), que se instancia con
`new-project.sh <proyecto> --ref main` y queda con `DEVKIT_VERSION=dev`. Ahí el
workspace **es** el template: `devkit/` del repo es lo que se prueba.

Qué llega al contenedor y cuándo:

| Qué cambias | Cómo se activa |
|---|---|
| `devkit/entrypoint.sh`, `devkit/scripts/` | Solo con recrear el contenedor: el arranque los lee del workspace. |
| `devkit/agents/` (skills, `settings.json`, `notion.json`) | Al instante: están enlazados al workspace. |
| `devkit/Dockerfile`, `devkit/zsh/`, `devkit/proxy/`, `devkit/vscode/` | Solo reconstruyendo la imagen: `devkit recreate <proyecto>`. |

El contexto de build es `~/.devkit/<proyecto>/template/`, una copia del
template en el Mac. En modo dev, `devkit up`, `recreate` y `rebuild` la rearman
antes de construir copiando `devkit/` del workspace con `docker cp`, porque el
workspace solo existe dentro del contenedor. Si el contenedor no responde
(primer `up`, contenedor destruido), lo dicen y construyen con la copia que
haya.

Al arrancar, si lo que solo entra por imagen difiere de la copia con la que se
construyó, el log avisa: `hay cambios que requieren devkit recreate: <qué>`.
Míralo con `devkit logs <proyecto>`.

`~/.devkit/<proyecto>/compose.yaml` y el propio comando `~/.devkit/bin/devkit`
los instala `new-project.sh` y no los refresca nadie: si cambian en el
workspace, `recreate` avisa y se reinstalan con
`new-project.sh <proyecto> --ref <rama>`, que respeta `devkit.env`.

### Dentro del contenedor

| Comando | Qué hace |
|---|---|
| `claude` | Abre Claude Code en el workspace. |
| `devkit-net-denied` | Lista los dominios que el proxy rechazó en los últimos 15 min (`DEVKIT_NET_DENIED_WINDOW`) y confirma con `curl` cuál sigue bloqueado ahora mismo; sin la ventana ni la confirmación, un rechazo de hace días parecía de ahora y producía un bloqueo falso (DEVKIT-38). |
| `g`, `gs`, `gl`, `ll`, `c` | Alias: `git`, `git status -sb`, `git log` gráfico, `ls -lah`, `clear`. |
| `devkit-run` | Alias a `$DEVKIT_SCRIPTS_DIR/devkit-run.sh` (ver la fila de más abajo): así se lanza sin escribir la ruta completa. `DEVKIT_SCRIPTS_DIR` lo exporta el arranque a `/run/devkit/env`, y es `/workspace/devkit/scripts` en modo dev o `/opt/devkit/scripts` si no: el mismo `SCRIPTS_DIR` que usa `watch.sh`, para que un cambio al script en dev corra igual desde la skill y a mano, sin esperar a un `devkit recreate`. |
| `/opt/devkit/scripts/dropbox-setup.sh` | Autoriza Dropbox una vez y genera el secreto `rclone_conf_b64`. |
| `/opt/devkit/scripts/watch-test.sh` | Prueba `watch.sh` sin GitHub y sin gastar cuota: la tabla de decisión con PRs sintéticos, el relanzamiento por cuota agotada con logs falsos, las cinco alarmas del monitoreo mínimo (la quinta, `task-fix` vacío, con su relanzamiento y bloqueo), el ciclo OK → documentar → merge → cerrar con `task-close.sh` y `task-block.sh` reales contra dobles de `gh` y de `notion.sh`, y la siguiente hija al OK con `task-next.sh` real; sale con 1 si un caso falla. |
| `/opt/devkit/scripts/task-next.sh <Clave>` | Lanza con `devkit-run task-start` la siguiente hija libre de la Épica de la card (DEVKIT-56): `Lista`, nivel Tarea, todo `Depende de` en `Hecha`, por `Orden` y luego `Prioridad`. Una hija sin `Depende de` hacia la card arranca aunque esta siga en `Lista para merge`; una que depende espera a `Hecha`. No lanza nada si una hermana está `En progreso` o `Revisión automática`, ni si ya hay un `task-start` vivo (corriendo o esperando `skill.lock`) para una hermana en `Lista`: así una sola hija avanza a la vez y las dos llamadas no la duplican. Lo llaman `watch.sh` al `OK` del revisor y `task-close.sh` al merge. Si nada queda libre y ninguna hermana espera merge, lo comenta en la Épica. Idempotente. |
| `/opt/devkit/scripts/notion.sh` | Cliente de la API de Notion para bash (DEVKIT-55): `card <Clave>` (la card como JSON, buscada por `ID` y `Proyecto`), `set <page_id> Prop=valor...` (el tipo de cada propiedad sale de la página; `Prop=` vacío la borra), `comentar <page_id> <texto>` (las URL quedan como enlace), `documentacion <page_id>` (entrada de Documentación por la relación `Tarea`), y `pagina`, `hijas` y `criterios`, que usa `task-close.sh` para la Épica. Lee el token de `/run/devkit/notion_token` y se lo pasa a `curl` por descriptor, nunca por argumento ni variable de entorno. Reintenta un `429` o un `5xx`. Sin el token sale con 3 y lo dice. `--test` corre su autoprueba con un doble de `curl`. |
| `/opt/devkit/scripts/task-close.sh <Clave> [PR]` (o `devkit-run task-close <Clave> [PR]`) | Cierra una card con el PR mergeado, en bash (antes era la skill `task-close`): `Estado` = `Hecha`, `Cierre`, `PR` si faltaba, comentario "Cerrada. Documentación: <URL>. Implementado con <modelo>, esfuerzo <x>. Revisado con <modelo>, esfuerzo <x>. Cierre sin modelo (task-close.sh)." (las dos marcas las copia del cuerpo del PR y del último informe `devkit-review`; si falta una, dice "sin marca", DEVKIT-58) y marcador `<!-- devkit-closed sha=<merge commit> -->` en el PR. Si la card no tiene entrada de Documentación, lanza `task-document`, salvo que ya haya uno corriendo para esa Clave (merge aprobado mientras escribe la entrada): entonces comenta "la está escribiendo task-document" y no lo relanza. Si es la última hija de su Épica, cierra la Épica con la regla de DEVKIT-44 (`En progreso` y Criterios de aceptación definidos) y lanza `task-document` para la entrada consolidada; si no, llama a `task-next.sh`, que lanza la siguiente hija libre si no arrancó ya al `OK`. Borra la rama local solo con el workspace libre y si su punta es el head mergeado. Idempotente: una card ya `Hecha` solo recibe el marcador si le falta. |
| `/opt/devkit/scripts/task-block.sh <Clave> <motivo>` (o `devkit-run task-block <Clave> <motivo>`) | Bloquea una card, en bash (antes era la skill `task-block`): `Estado` = `Bloqueada` y un comentario "Bloqueada desde <estado anterior>." con el motivo. Si el workspace está en la rama de la card con cambios sin commit y nadie más lo ocupa, los guarda en un commit `wip(<Clave>)` y hace push. Lo usan `watch.sh`, `devkit-run` y las skills, por ruta; una card ya `Bloqueada` no se toca. Deja en `watch.log` la línea `task-block.sh <Clave> Bloqueada desde <estado>: <motivo>`, de la que `devkit-run --estado` saca el motivo (DEVKIT-57). El motivo recomendado para un agente: "Qué intenté: ... Qué necesito: ...". |
| `/opt/devkit/scripts/slugify.sh` | Convierte un texto libre en un slug de minúsculas separado por guiones (formato de las ramas). `--test` corre su tabla de autoprueba. |
| `/opt/devkit/scripts/image-drift.sh` | Lista qué del template solo entra por imagen y ya no coincide con ella. La usa el arranque en modo dev para avisar del `devkit recreate` pendiente. `--test` corre su autoprueba. |
| `/opt/devkit/scripts/agents-sync.sh` | Funde el `AGENTS.md` de un proyecto con la plantilla destino: si el archivo tiene el marcador `## Reglas del proyecto`, reemplaza todo lo de arriba y conserva todo lo de abajo tal cual; si no lo tiene, no toca nada y sale con el código 2. La usa `template-update`. `--test` corre su autoprueba. |
| `/opt/devkit/scripts/pr-guard.sh` | Hook `PreToolUse` de `settings.json`: inspecciona el texto del comando `Bash` completo, en cualquier posición de sus argumentos, y bloquea (salida 2) aprobar un PR, mergearlo sin `--auto` o con `--admin`, empujar a `main` o una mutación de GraphQL que apruebe o mergee, aunque el comando evada el deny por prefijo (`git -C <dir> push`, `gh api` crudo). También bloquea cualquier segmento que mencione `/run/devkit/vscode-token` o `/run/devkit/notion_token`, salvo que solo compruebe que el archivo existe (`test`, `[` o `[[` con `-e`, `-f`, `-r` o `-s`): esos archivos son el token del editor y el de Notion en crudo, y no se pegan en un chat ni en una card (DEVKIT-51, DEVKIT-55). Para hablar con Notion desde bash está `notion.sh`, que lee el token sin imprimirlo. Es una inspección de texto, no una sandbox: no ve variables de shell ni alias de `gh`; la compuerta real es GitHub. Cada bloqueo queda en `/run/devkit/denials.log`, para revisar si hay que ampliar una regla. `--test` corre su autoprueba. |
| `/opt/devkit/scripts/devkit-run.sh` (alias `devkit-run`, solo en la shell interactiva) | Único punto de lanzamiento de una skill: `devkit-run [--modelo <alias>] [--esfuerzo <low\|medium\|high\|xhigh\|max>] <skill> <Clave> [texto extra...]` la corre en segundo plano con `nohup` desde `/workspace`, sin que copies el comando largo a mano, y vuelve en cuanto confirma que arrancó. Antes de lanzar espera el marcador `/run/devkit/ready` que escribe el arranque del contenedor (hasta `DEVKIT_READY_TIMEOUT`, 120 s); si no aparece, no lanza, lo explica y sale con 69. Tras lanzar mira al worker hasta `DEVKIT_ARRANQUE_ESPERA` segundos (5): vivo, dice si su `claude -p` corre o espera el candado; muerto sin resumen `terminado`, imprime las últimas líneas del log y las alarmas, deja `ALARMA: no arrancó` en `watch.log` y sale con 70 (DEVKIT-57: un `task-start` lanzado con el editor recién abierto imprimió su PID y nunca corrió). Cada lanzamiento deja antes en `watch.log` la línea `<id> lanzando (origen=<quién>): "<prompt>" log=<log>`, donde `<id>` es el nombre del log y el origen sale de `DEVKIT_ORIGEN` (`task-close.sh` pone `task-close`, `watch.sh` pone `bucle`) o, si no viene, del primer `claude -p /<skill>` entre los procesos padre (`epic-plan`), y si no hay ninguno, `humano`. `devkit-run --estado` lee esas líneas y muestra una tabla de los últimos 20 lanzamientos (`DEVKIT_ESTADO_FILAS`): skill, card, quién lanzó, hace cuánto, estado y detalle, sin lanzar ningún agente. El estado es `en curso` (su proceso vive, se lanzó hace menos de `DEVKIT_ESTADO_GRACIA` segundos —120— aunque su `claude -p` aún no exista, o espera el candado), `terminó`, `error` (rc distinto de cero, o log escrito sin resumen ni proceso), `bloqueada` (`task-block.sh` bloqueó su card después de lanzarlo; el detalle es el motivo) o `no arrancó` (sin proceso, log ni resumen pasado el margen). `devkit-run --estado --seguir` la refresca cada 3 s (`DEVKIT_ESTADO_INTERVALO`) hasta Ctrl-C. Lo lanza con el modelo y el esfuerzo que le tocan por su papel en el flujo (resueltos en `$DEVKIT_ROLES_FILE` si se define, luego `.devkit/roles.toml` del proyecto si existe, luego `devkit/agents/roles.toml` del template, al final `/opt/devkit/template/agents/roles.toml`; ver "Qué declara cada proyecto") y el mismo candado que usa `watch.sh` para no pisarle la rama a otra skill. En `task-fix` y `task-document`, el modelo y el esfuerzo dependen además de la ronda del PR si el rol declara `rondas` (DEVKIT-61, ver "Escalera de modelos por ronda"); la ronda sale también en la línea `lanzado` y en el resumen como `ronda=<n>`. `--modelo`/`--esfuerzo` anulan el rol resuelto (y la ronda) para ese lanzamiento puntual, sin tocar `roles.toml`; la línea de resumen lo marca `(anulación manual)`. Log en `/run/devkit/<skill>-<n>.log`; al terminar, agrega a `watch.log` una línea con modelo, esfuerzo, costo y turnos, más las mismas alarmas de `watch.sh` (error, skill lenta, pregunta abierta) y, si el `result` termina en pregunta, bloquea la card con `task-block.sh` y un motivo forzado. `devkit-run task-close ...` y `devkit-run task-block ...` no lanzan modelo: corren en primer plano `task-close.sh` y `task-block.sh` (DEVKIT-55); `--sync` hace lo mismo con los prompts `/task-close` y `/task-block`, que todavía pide un `watch.sh` anterior hasta el próximo `devkit recreate`. Exporta `DEVKIT_MODEL` y `DEVKIT_EFFORT` al `claude -p` que lanza, con el modelo y el esfuerzo que recibió de verdad (rol, caída en `frontera`, `--modelo`/`--esfuerzo` o `DEVKIT_MODELO_FORZADO`), no los que traiga el entorno: de ahí sacan las skills las marcas "Implementado/Revisado/Documentado con <modelo>, esfuerzo <x>" (DEVKIT-58, ver "Modelo y esfuerzo visibles"). Exporta también `DEVKIT_SCRIPTS_DIR` (su propio directorio) y `DEVKIT_RUN_DIR` al `claude -p` que lanza (y `DEVKIT_LOCK_HELD=1` en `--worker`, que corre con el candado tomado; `watch.sh` la pasa a `--sync` por lo mismo: así `task-block.sh` guarda el `wip` sin pedir otra vez el candado; `watch.sh` pasa además `DEVKIT_LANZADOR=watch`, que un lanzamiento en segundo plano borra, para que `task-fix` sepa si lo lanzó el bucle), para que una skill que invoca otro script por ruta llegue a la misma copia y no a la de la imagen, vieja en modo dev. Arma el entorno del `claude -p` hijo con `env -i` y una lista blanca, y antes de lanzar prueba con `claude mcp list` que Notion está conectada; si no, no lanza (ver "Entorno del `claude -p` hijo y comprobación de Notion", DEVKIT-65). Si el modelo resuelto sale vacío, no lanza: sale con 65 y deja `ALARMA: modelo vacío` en `watch.log` (antes la CLI moría con un 400 en el primer turno, DEVKIT-55). `task-next.sh` y `epic-plan` lo usan para lanzar la siguiente/primera hija como proceso aparte, así corre con el rol que le toca; `epic-plan` lo llama por ruta explícita (`"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/devkit-run.sh"`), no por el alias `devkit-run`, porque su `SKILL.md` corre en el Bash no interactivo de `claude -p`, que no carga `zshrc` (DEVKIT-54). `watch.sh` lo usa también (ver más abajo). `devkit-run --otros-agentes` responde si otro agente ya ocupa el workspace: imprime los procesos `claude -p` ajenos y sale 0 si está libre, 1 si no. Es lo que debe usar una skill en vez de un `pgrep -f <Clave>`, que devuelve como ajenos los cuatro procesos propios del lanzamiento (el `--worker`, su subshell, su vigilante y el `claude -p` de uno mismo) porque la Clave viaja en sus argumentos; ese falso positivo bloqueó una card sin motivo en DEVKIT-54. `devkit-run --siguiente-modelo <alias>` imprime el modelo disponible que sigue a `<alias>` en `frontera` (tras el último, el primero); lo usa `watch.sh` para relanzar un `task-fix` vacío, y `--sync` toma ese modelo de `DEVKIT_MODELO_FORZADO`. `--test` corre su autoprueba. |
| `bash devkit/host/devkit-test.sh` | Solo en el repo del template: prueba el comando `devkit` del Mac con un doble de `docker`, sin Docker ni contenedores. Sale con 1 si un caso falla. |

Bucles en segundo plano: `sync-sandbox.sh` (respaldo cada 60 s) y `watch.sh`
(cada 5 min los PRs abiertos, cada 30 s los mergeados). `watch.sh` mira cada
PR cuyo título empieza por una Clave del proyecto y lanza en modo headless la
skill que toca, o el script bash si es cerrar o bloquear. Su único estado son
los marcadores que las skills y los scripts dejan en el PR; un rebuild no
pierde nada.

Los PRs mergeados tienen su propio bucle dentro de `watch.sh`, cada
`DEVKIT_WATCH_MERGED_INTERVAL` segundos (30), aparte del de los abiertos: ese
se queda esperando mientras corre una skill, que puede tardar veinte minutos,
y un merge en ese rato no se cerraba hasta que terminara. El cierre en bash
tarda segundos y deja en `watch.log` cuánto pasó desde el merge:

```
task-close-40 terminado: bash, cerrado 34s después del merge :: task-close: lanzada la siguiente hija: task-start DEVKIT-56
```

| Lo que ve en el PR | Qué lanza |
|---|---|
| Abierto y el head sin marcador `devkit-review` | `/pr-review <N>` |
| Último marcador `verdict=CAMBIOS` para el head, sin respuesta `devkit-fix` | `/task-fix <Clave>` |
| Último marcador `verdict=CAMBIOS` para el head, con respuesta `devkit-fix` sin push nuevo (descartó todo o solo comentó) | `/pr-review <N>` otra vez, con la respuesta a la vista |
| Último marcador `OK` y un comentario o review tuyo posterior (un approve no cuenta) | `/task-fix <Clave> "<tu comentario>"`; la card vuelve a `Revisión automática` |
| Último marcador `OK` para el head, sin marcador `<!-- devkit-doc sha=<head> -->` | `/task-document <Clave> <N>`, que escribe o actualiza la entrada de Documentación y deja ese marcador. Si la card vuelve atrás y un head nuevo recibe `OK`, corre otra vez sobre la misma entrada |
| Último marcador `OK` para el head (tras documentar, o ya documentado) | `task-next.sh <Clave>`, una vez por head: arranca la siguiente hija libre mientras el PR espera tu approve. Deja `task-next-<N> terminado: bash, <Clave> en Lista para merge :: ...` en `watch.log` |
| Tres ciclos atendidos (informe `CAMBIOS` con su respuesta `devkit-fix`) desde el último `OK`, bloqueo o `devkit-fix` con `manual=1`, y el último informe es `CAMBIOS` sobre el head vigente | Marcador `<!-- devkit-block sha=<head> -->` en el PR y `task-block.sh <Clave> <motivo>`. No lo toca más hasta que muevas la card a `Revisión automática` y comentes en el PR qué hacer. Un `CAMBIOS` sobre un head que el corrector ya superó no bloquea: ese head se revisa primero. Un `task-fix` que no lanzó el bucle (por ejemplo `devkit-run --modelo opus task-fix <Clave>`) firma `manual=1` y el conteo vuelve a cero |
| Mergeado en las últimas 48 h y sin marcador `devkit-closed` | `task-close.sh <Clave> <URL>`, que al terminar deja el marcador `<!-- devkit-closed sha=<merge commit> -->` en el PR |
| Mergeado y con marcador `devkit-closed` | Nada: una línea `ya cerrado` en el log |

El bucle no siempre espera el intervalo completo: duerme en tramos de 5 s y
despierta en cuanto existe `/run/devkit/poke`, que `task-submit` y `task-fix`
crean con `touch /run/devkit/poke` como último paso, escrito tal cual: la regla
de `allow` en `settings.json` es de coincidencia exacta y no cubre variantes con
redirección o `|| true`. Así el ciclo revisar → corregir → revisar encadena en
segundos en vez de perder hasta 5 min por salto. El aviso solo adelanta el
reloj: no lanza nada, la decisión sigue saliendo de los marcadores del PR, y si
el `touch` falla el bucle llega igual en el siguiente intervalo.

Cada vuelta del bucle abre con una línea `consultando GitHub`, que es lo que se
mira para comprobar que el aviso funcionó. La cota de 5 s solo vale si el
bucle estaba durmiendo cuando llegó el `touch`, que es el caso de un humano
ejecutando `/pr-review` a mano; si el aviso llega mientras el bucle ya está
despierto atendiendo otro PR (el caso normal del ciclo automático), la línea
`consultando GitHub` sale recién cuando termina esa vuelta, no a los 5 s.
Cada ejecución deja su log en `/run/devkit/<skill>-<N>.log`; la última
línea trae el costo y los tokens, que es la medida de cada ciclo. Al terminar
cada `claude -p`, el bucle registra además una línea `estado:` con la rama en
la que quedó el workspace, sus commits sobre `main` y su PR (`rama de card sin
PR` si no lo hay, `PR desconocido` si `gh` no respondió). Es una observación de
git y GitHub, no del Estado de la card: una rama de card sin PR es la señal de
que la ejecución pudo cortarse a medias, y solo Notion dice qué le pasó a la
card.

**Modelo, esfuerzo y costo por rol.** `watch.sh` lanza cada skill a través de
`devkit-run.sh`, que resuelve modelo y esfuerzo según el papel de la skill en
el flujo, leído de `devkit/agents/roles.toml` (DEVKIT-54, reemplaza el reparto
por `Tipo` de DEVKIT-45): `roles.toml` declara una lista `frontera` ordenada
de alias de modelo (hoy `fable, opus, sonnet`) y cada rol un `model_index`,
la posición desde la que empieza a buscar el primero disponible.
`revisión` (`pr-review` y `epic-plan`, desde DEVKIT-50: un mal desglose de
Épica cuesta más que cualquier card) usa el segundo modelo de la lista
(`revision.model_index = 2`, hoy `opus`: la mitad de costo por token de
entrada/salida que el primero, `fable`, y sin ciclos de corrección de sobra
como implementador -- los PR 39 a 43 necesitaron 1, 1, 0, 0 y 0, DEVKIT-72);
`implementación` (`task-start`, `task-fix`, `task-submit`, `task-document`)
también el segundo, salvo que el rol declare `rondas` (ver "Escalera de
modelos por ronda" más abajo), que manda sobre `model_index` mientras esté
activa. Tanto el modelo (`model_index`) como el esfuerzo (`effort`) admiten
además una anulación por skill sobre el valor del rol: `epic-plan` declara
`epic-plan.model_index = 1` para quedarse en el primer modelo de frontera
-un mal desglose de Épica se paga en todas sus hijas, así que no baja de
calidad- igual que ya declaraba `epic-plan.effort = "max"`. Cerrar y bloquear
no tienen rol: desde DEVKIT-55 son bash (`task-close.sh`, `task-block.sh`) y
no lanzan modelo, así que el rol `contabilidad` que los agrupaba se retiró.
El esfuerzo es `high` en todos los roles salvo `epic-plan`, que sube a `max`,
y salvo que `rondas` fije uno distinto por ronda: un mal desglose se paga en
todas sus hijas. El `Tipo` de la card (`feature`, `bug`, `chore`) ya no elige
modelo ni esfuerzo; sigue eligiendo el prefijo de rama y la sección del
CHANGELOG. La disponibilidad de cada modelo se comprueba una sola vez por
arranque del contenedor y el resultado queda cacheado en
`/run/devkit/frontera/<alias>` (tmpfs: se vuelve a comprobar en cada `devkit
recreate`). Un `si` vale todo el arranque; un `no` caduca a los 600 s
(`DEVKIT_MODEL_RETRY`) y se vuelve a sondear, porque la sonda no distingue un
modelo inexistente de una cuota agotada o un corte de red. Si el modelo que le toca a un rol no responde, `devkit-run` cae al
siguiente de la lista y lo deja escrito en `watch.log`:

```
devkit-run sonda de modelo: fable no responde en 30s; cae al siguiente de la lista
devkit-run sonda de modelo: opus responde
```

"No responde en Ns" es solo el timeout. Si la CLI falla por otra causa
(alias desconocido, cuota, red), la línea dice `falló (rc=N): <primera línea
de stderr>`, y el stderr completo queda en `/run/devkit/frontera/<alias>.err`
para diagnosticar sin repetir la sonda.

Esa sonda corre aislada a propósito: desde un directorio vacío, con
`--strict-mcp-config --mcp-config '{"mcpServers":{}}'` y sin herramientas. Sin
ese aislamiento no es una sonda, porque hereda todo el contexto de
`/workspace` —`AGENTS.md`, las skills, los servidores MCP— y el "ok" pasa a
costar lo que una tarea: medido en DEVKIT-54, `fable` tardaba 41 s y USD 0.95
en responderlo, por encima del timeout de 30 s, así que el primer modelo de la
lista se marcaba caído en cada arranque y todo el flujo caía al segundo sin
que nada lo avisara. Aislada, la misma sonda tarda 2 s. La
tabla también lleva un `max_turns` por rol, pero es un presupuesto, no un
límite: la CLI instalada no tiene una opción `--max-turns` (`claude --help`,
versión 2.1.270), así que `devkit-run` solo compara `num_turns` del resultado
contra ese número y avisa en el log si se excede. La línea de resumen queda
así:

```
pr-review-31-a1b2c3d terminado: modelo=opus esfuerzo=high ronda=- costo=0.42 turnos=12 tokens: ... :: PR #31: veredicto OK...
task-fix-31-e4f5g6h terminado: modelo=opus esfuerzo=high ronda=3 costo=0.61 turnos=18 tokens: ... :: H1 | atendido | 1234abc
```

**Escalera de modelos por ronda (DEVKIT-61).** Un experimento para gastar
menos: la implementación empieza con un modelo barato y solo sube si el PR no
pasa la revisión. `roles.toml` lo declara así:

```toml
implementacion.rondas = ["sonnet:high", "sonnet:high", "opus:high"]
```

Cada elemento es `<alias de claude --model>:<esfuerzo>` y su posición es la
ronda. La regla:

| Skill | Ronda |
|---|---|
| `task-start`, `task-submit` | 1: todavía no hay PR |
| `task-fix`, `task-document` | 1 más el número de comentarios `<!-- devkit-fix` del PR de la card |
| `pr-review`, `epic-plan` | No tienen ronda (`ronda=-`): el revisor no escala |

Una ronda mayor que la lista usa el último elemento. Con la lista del
template, el primer `task-fix` (sin `devkit-fix` previos) va en `sonnet`, el
segundo también y del tercero en adelante en `opus`.

Cómo se lee la ronda: `devkit-run` busca la card en Notion con `notion.sh
card <Clave>` y toma la URL de `PR`; si falta, busca el PR por la rama de la
card (o, sin Notion, por la rama local o remota que lleva la Clave) con `gh
pr list --head <rama>`. Luego cuenta los comentarios `devkit-fix` con `gh pr
view`. Si no puede leer el PR, usa la ronda 1 y lo escribe en `watch.log`
(`devkit-run ronda de "<prompt>": ... uso la ronda 1`). `watch.sh` lee la
ronda una sola vez con `--rol` y se la pasa a `--sync` en `DEVKIT_RONDA`,
para no consultar dos veces.

El alias de la ronda pasa por la misma sonda que `frontera` (caché en
`/run/devkit/frontera`). Si no responde, se usa el modelo que resuelve
`model_index` del rol, con el esfuerzo de la ronda, y `watch.log` lo dice
(`ronda 3 pide opus, que no responde; uso sonnet (model_index del rol)`).
`--modelo`, `--esfuerzo` y `DEVKIT_MODELO_FORZADO` (el relanzamiento de un
`task-fix` vacío) siguen mandando por encima de la ronda.

`revision.rondas` se ignora a propósito, con una línea en `watch.log`:
`pr-review` sigue con el modelo de `revision.model_index` (hoy el segundo de
`frontera`, `opus`) y `epic-plan` con el primero (`epic-plan.model_index`),
los dos en esfuerzo `high` (`max` para `epic-plan`). El revisor es la
compuerta de calidad, y uno más débil da OK falsos que nadie detecta.

Para desactivar la escalera, quita la línea `implementacion.rondas` (del
template o de `.devkit/roles.toml`): `model_index` y `effort` vuelven a
mandar. La línea de resumen sigue anotando `ronda=<n>`, así que el dato para
comparar ciclos y costo por card no se pierde.

Al terminar `task-close.sh` de un PR mergeado, el bucle suma el `costo=` de todas
las líneas de ese número de PR en `watch.log` (todas sus rondas de revisión y
corrección, no solo la del cierre) y deja una línea con el total del ciclo:

```
PR #31 (DEVKIT-45) costo total del ciclo: $0.6700 USD
```

**Modelo y esfuerzo visibles (DEVKIT-58).** `watch.log` dice qué corrió,
pero se pierde en cada `devkit recreate` y nadie lo lee al aprobar. Por eso
cada artefacto lleva su marca, en una línea propia y con el mismo formato,
para comparar con evidencia si un modelo más barato alcanza para un papel:

| Dónde | Marca | Quién la escribe |
|---|---|---|
| Cuerpo del PR | `Implementado con <modelo>, esfuerzo <x>` | `task-submit` |
| Cada informe `devkit-review`, debajo del marcador | `Revisado con <modelo>, esfuerzo <x>` | `pr-review` |
| Entrada de Documentación, sección "Modelos" | Las anteriores y `Documentado con <modelo>, esfuerzo <x>` | `task-document` |
| Comentario de cierre en la card | La de implementación y la del último informe, más "Cierre sin modelo" | `task-close.sh` |

Las skills toman los valores de `DEVKIT_MODEL` y `DEVKIT_EFFORT`, que
`devkit-run` exporta al `claude -p`. En una sesión interactiva, sin
`devkit-run`, escriben el alias del modelo que las ejecuta y `esfuerzo sin
registrar`. `task-close.sh` es bash y no usa modelo: copia las marcas, no las
deduce de `roles.toml`, y dice "sin marca" si faltan.

Un humano lanza la misma tabla a mano con `devkit-run <skill> <Clave>` (por
ejemplo `devkit-run task-start DEVKIT-45`), sin escribir el `nohup claude -p
... &` completo: ver la fila de `devkit-run.sh` en la tabla de comandos, más
arriba.

**Permisos en modo headless.** `devkit-run` corre cada `claude -p` con
`--permission-mode acceptEdits`, igual que antes; no cambia a
`--permission-mode dontAsk`. Se probó con `claude -p` real: un comando que no
está en la lista `allow` de `settings.json` corre igual en modo headless, con
`acceptEdits` o con `dontAsk` (el campo `permission_denials` del JSON de
salida queda vacío en ambos casos). La lista `allow` no es una lista blanca
que restrinja nada en `-p`: solo evita el diálogo de confirmación en una
sesión interactiva. La compuerta real en headless es la lista `deny` de
`settings.json` más el hook `pr-guard.sh`, como ya documenta
`docs/ARCHITECTURE.md` (sección 8.2); por eso el registro de denegaciones que
pedía DEVKIT-45 vive en `pr-guard.sh` (cada bloqueo suyo, en
`/run/devkit/denials.log`) y no en un intento de hacer cumplir la lista
`allow`, que no bloquea nada que hacer cumplir.

**Entorno del `claude -p` hijo y comprobación de Notion (DEVKIT-65).** Un
`task-start` lanzado por `epic-plan` corre dentro de un `claude -p` que a su
vez es otro `claude -p`. Tres incidentes reales del 2026-09-16 mostraron el
síntoma: la CLI hija montaba el conector de Notion con otro nombre de
servidor (`claude_ai_Notion` en vez de `plugin:Notion:notion`),
`--allowedTools` dejaba de cubrirlo y la skill terminaba pidiendo autorizar
el conector o bloqueada sin poder leer ni escribir en la card. La hipótesis
sobre la causa -que el hijo hereda del padre las variables que Claude Code
usa para marcar una sesión anidada (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
`CLAUDE_CODE_CHILD_SESSION`, ...)- no quedó confirmada: en este contenedor,
`claude mcp list` con esas marcas puestas a mano y con la lista blanca de
abajo dio el mismo resultado (Notion conectada) en ambos casos (comentario
de la card, 2026-09-17 04:11; repetido en la revisión de `pr-review` sobre
el commit `ef9a3fe`). `run_claude` (la función interna que arma cada
`claude -p`) ya no pasa el entorno tal cual: como medida defensiva, lo arma
de cero con `env -i` y una lista blanca
(`HOME`, `PATH`, `LANG`, `LC_ALL`, `TZ`, `CLAUDE_CONFIG_DIR`,
`CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, las variables de proxy,
`DISABLE_AUTOUPDATER` y `MCP_OAUTH_CALLBACK_PORT`, las dos últimas fijas en
el `Dockerfile` y en `compose.yaml` respectivamente), en vez de una lista
negra de marcas de sesión anidada: una versión nueva de la CLI puede sumar
una marca que hoy no existe, y una lista negra la dejaría pasar igual.
`TERM` y los `UV_PYTHON_INSTALL_DIR`/`UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` del
`Dockerfile` quedan fuera a propósito: `claude -p` no es interactivo, y los
tres `UV_*` ya apuntan a rutas bajo `$HOME`, que sí viaja en la lista. Con ese entorno ya armado, antes de lanzar de verdad prueba con
`claude mcp list` que Notion está conectada; si no, no lanza, lo dice por
`stderr` y deja `ALARMA: sin Notion conectado` en `watch.log` en vez de
gastar turnos en una skill que no va a poder leer la card. Aunque la sonda
haya visto Notion conectada, el final del `claude -p` cuenta igual que la
pregunta abierta (`ALARMA: terminó sin acceso a Notion` y bloqueo de la card
con `task-block.sh`) si el campo `permission_denials` del evento `result`
lista una herramienta de Notion (`mcp__*notion*`). Es la única señal que
bloquea. Como respaldo, si el texto del `result` dice en la misma oración
"notion" y una forma de falta de acceso ("no tiene permiso", "no tengo
acceso", "sin acceso", "no tengo/estoy/están autorizado(s)"), o una forma de
"autorizar" seguida de `mcp__…Notion`, solo deja `ALARMA: el resultado describe falta de acceso a
Notion (ver resultado)` en `watch.log`, sin bloquear: un agente que termina
bien describe este mismo mecanismo con esas frases, y tres `result` reales
de este PR habrían bloqueado la card por eso (H10 y H13 de `pr-review`).
La búsqueda va sobre el `result` crudo, con comillas y backticks: el agente
suele escribir así el nombre del plugin o de la herramienta, y descartarlos
ocultaba los incidentes reales (H14). "No autorizado" a secas,
sin mencionar Notion, tampoco cuenta: coincidía con un `result` que solo
citaba un comando bloqueado por `pr-guard` (H6 y H9, DEVKIT-65). Por si el nombre del servidor vuelve a
cambiar con otra versión de la CLI, `--allowedTools` trae los dos nombres
conocidos (`mcp__plugin_Notion_notion` y `mcp__claude_ai_Notion`), y
`devkit/agents/settings.json` los autoriza también para la sesión
interactiva. `DEVKIT_NOTION_CHECK=0` y `DEVKIT_ENV_LIMPIO=0` apagan,
respectivamente, la sonda y la lista blanca: los usa `watch-test.sh`, cuyos
dobles de `claude` no entienden `mcp list` y simulan su propio estado con
variables sueltas (`FIX_DIR`, el contador de llamadas de la cuota agotada)
que quedarían fuera de la lista blanca; la comprobación de las dos cosas vive
en la autoprueba de `devkit-run.sh`.

**Cuota agotada.** Si un `claude -p` muere porque se acabó la cuota de la
suscripción, el agente no puede reaccionar: sin cuota no habla con el modelo y
ninguna skill sirve. Reacciona el bucle, que es bash. Lo
reconoce por el código de salida distinto de cero más el aviso del límite en el
log de la skill, saca de ahí la hora en que se reinicia la ventana y deja dos
líneas en `watch.log`:

```
cuota agotada: pr-review-31-a1b2c3d en pausa hasta 2026-09-11T20:00:00Z (intento 2 de 3)
cuota reanudada: relanzando pr-review-31-a1b2c3d
```

La espera corre en segundo plano, así que el bucle sigue atendiendo otros PRs,
y el relanzamiento usa el mismo prompt y los mismos flags: las skills son
reanudables. Si el aviso no trae hora legible, espera lo que diga
`DEVKIT_WATCH_QUOTA_WAIT` y lo dice en el log. Un solo relanzamiento en curso
por skill y PR, y como mucho `DEVKIT_WATCH_QUOTA_RETRIES` intentos; al llegar
al tope escribe `sin más intentos` y lo deja para ti. No toca Notion ni comenta
en el PR: una card puede morir antes de tener PR y el mecanismo vale igual para
todas. Desde este cambio solo corre un `claude -p` a la vez: un relanzamiento
puede despertar mientras el bucle atiende otro PR, y dos agentes sobre el mismo
workspace se pisarían la rama; el que llega segundo escribe `espera: otra skill
ocupa el workspace` y arranca al quedar libre.

**Monitoreo mínimo sin modelo.** Cinco alarmas en bash dentro de `watch.sh`,
sin gastar tokens, todas como líneas `ALARMA: ...` en `watch.log` (la petición
formal de review en GitHub ya cubre el aviso externo, así que no hay canal
aparte): una skill que termina con error; una skill que lleva más de
`DEVKIT_WATCH_SKILL_TIMEOUT` segundos corriendo (1200 por defecto, sondeada
cada `DEVKIT_WATCH_SKILL_POLL` segundos); un `result` que termina en pregunta
en vez de resolver en un estado observable (el defecto de headless que
`AGENTS.md` prohíbe: no se comprueba el Estado de la card en Notion, porque el
bucle no la consulta desde bash, así que alarma cualquier pregunta final,
esté o no la card `En progreso`); y la rama en la que quedó el workspace, sin
PR y sin ningún `claude -p` vivo (sin `skill.lock` tomado) hace más de
`DEVKIT_WATCH_ORPHAN_AGE` segundos (1800 por defecto). La quinta (DEVKIT-57):
un `task-fix` que responde "nada que corregir" o "informe desactualizado"
mientras el último informe sobre ese mismo head sigue siendo `CAMBIOS`. Ese
fix no corrigió nada y el ciclo quedaría quieto, sin `devkit-fix` que
dispare otra revisión. El bucle escribe `ALARMA: task-fix-<N>-<head> terminó
con "<frase>" con CAMBIOS vigente...`, relanza una vez `task-fix` con el
siguiente modelo de `frontera` (log `task-fix-<N>-<head>-reintento`) y, si
responde igual, bloquea la card con el marcador `devkit-block` y
`task-block.sh`. Un "informe desactualizado" con el head ya cambiado es
legítimo y no alarma.

Para ver en qué va cada agente, sin gastar un agente en averiguarlo:

```sh
devkit-run --estado            # o --estado --seguir, que refresca cada 3 s
# SKILL          CARD        LANZÓ       HACE    ESTADO      DETALLE
# pr-review      DEVKIT-56   bucle       1h00m   terminó     -
# task-start     DEVKIT-59   epic-plan   30m     bloqueada   Qué intenté: X. Qué necesito: ...
# task-start     DEVKIT-60   humano      20m     no arrancó  sin proceso, log ni resumen tras 20m
```

`--estado` parte de las líneas `lanzando` de `watch.log`, no de los procesos:
el 2026-09-16, `--agentes-vivos` respondió "sin agentes vivos" dos segundos
después de que el bucle escribiera "lanzando pr-review", porque entre esa
línea y el `claude -p` pasan el candado y la sonda de modelos. Para ver solo
los procesos vivos, con su Clave y el paso (skill), sigue
`--agentes-vivos`, que desde DEVKIT-57 también ve lo que lanza el bucle
(`devkit-run.sh --sync`):

```sh
bash /opt/devkit/scripts/watch.sh --agentes-vivos
# <PID>  DEVKIT-46  task-fix
# o, sin ninguno vivo: "sin agentes vivos" y código de salida 0.
```

Variables: `DEVKIT_WATCH_INTERVAL` (segundos, 300), `DEVKIT_WATCH_MAX_CYCLES`
(3), `DEVKIT_WATCH_QUOTA_RETRIES` (3), `DEVKIT_WATCH_QUOTA_WAIT` (1800, la
espera fija), `DEVKIT_WATCH_QUOTA_MIN_WAIT` (60), `DEVKIT_WATCH_QUOTA_MAX_WAIT`
(86400, tope por si el aviso trae una hora absurda), `DEVKIT_WATCH_SKILL_TIMEOUT`
(1200), `DEVKIT_WATCH_SKILL_POLL` (5), `DEVKIT_WATCH_ORPHAN_AGE` (1800) y
`DEVKIT_WATCH_MERGED_INTERVAL` (30, el bucle de PRs mergeados). Para
ver qué decidiría sobre un PR sin esperar al bucle:

```sh
gh pr view <N> --json headRefOid,reviews,comments | bash /opt/devkit/scripts/watch.sh --decide
gh pr view <N> --json comments | bash /opt/devkit/scripts/watch.sh --decide-merged
```

`--decide` responde por un PR abierto; `--decide-merged`, por uno ya mergeado
(`cerrar` o `cerrada <sha>`), que no tiene head que revisar y solo se pregunta
si `task-close.sh` ya pasó.

La tabla de decisión tiene una prueba reproducible sin GitHub:
`bash /opt/devkit/scripts/watch-test.sh` corre cada caso (PR vacío, `CAMBIOS`
sin respuesta, con respuesta y head nuevo, con respuesta sin cambiar el head,
comentario humano, tres ciclos sobre el head vigente o ya superado, fix
manual, bloqueo y reanudación, y la rama de cierre con
y sin marcador) contra `watch.sh --decide` y
`--decide-merged`, y falla si alguno no da la acción esperada. El mismo archivo
prueba la cuota agotada sin gastar cuota: `--quota-hit` y `--quota-reset`
reciben avisos de límite de mentira y comprueban la detección y la hora
extraída, y `--run-skill` corre `run_skill` contra un doble de `claude` que
muere por cuota la primera vez, para ver las dos líneas del log, el
relanzamiento y el tope de intentos. También comprueba que la línea de
resumen trae el modelo del rol resuelto por `devkit-run.sh` y que
`--cycle-cost <N>` suma el costo de todas las líneas de ese PR en un log
dado. `devkit-run.sh --test` prueba aparte la resolución de rol, el
lanzamiento en segundo plano (numeración del log, candado con `watch.sh`), el
aviso de presupuesto de turnos excedido, la cadena `epic-plan` → `task-start`
(dos resúmenes con roles distintos), la anulación manual por
`--modelo`/`--esfuerzo`, el bloqueo con `task-block.sh` ante una pregunta
abierta, la delegación de `devkit-run task-block` al script, que un modelo
vacío no se lanza, la escalera de DEVKIT-61 con un doble de `gh` y de
`notion.sh` (un caso por ronda: 1, 2, 3 y una cuarta que repite el último
elemento; `task-start` sin consultar el PR; el PR buscado por la rama; el PR
ilegible y el alias caído, con su línea en `watch.log`; `revision.rondas`
ignorada; `--modelo` y `DEVKIT_MODELO_FORZADO` por encima de la ronda; y
`ronda=` en la línea de resumen), y que el `claude -p` recibe `DEVKIT_SCRIPTS_DIR` y
`DEVKIT_RUN_DIR` del lanzador aunque el entorno no los traiga o traiga la
copia de la imagen. De la lista `frontera` prueba la resolución normal, la caída
al siguiente modelo cuando el primero no responde, que la caída queda en
`watch.log` y que con la caché escrita no se vuelve a sondear. Esa prueba de
caída usa tres modelos, no dos, a propósito: con dos, "el siguiente de la
lista" y "el último recurso" son el mismo valor y la prueba pasa aunque la
resolución esté rota, que fue justo lo que dejó pasar un fallo real en
DEVKIT-54. Un doble que lee stdin cubre esa regresión. La comprobación de
concurrencia (`--otros-agentes`) se prueba con una tabla de procesos fija
copiada de un `ps` real, para fijar que los cuatro procesos propios del
lanzamiento no cuentan como agente ajeno. De DEVKIT-57 prueba el origen por
procesos padre con una tabla fija, el siguiente modelo de `frontera`, dos
arranques fallidos (sin marcador `ready`: sale con 69 sin lanzar; `claude -p`
que muere al instante: sale con 70 e imprime el log) y `--estado` con un
`watch.log`, un `ps` y una hora fijos, un caso por cada uno de los cinco
estados, incluido `en curso` dos segundos después de "lanzando" sin proceso.

`watch-test.sh` cubre la quinta alarma con el hook `--fix <num> <Clave>
<url> <head> <ref>`, que corre el caso `fix` completo contra un `gh` y un
`claude` de mentira: dos respuestas vacías relanzan con `fable` tras `sonnet`
(la ronda 1 de la escalera) y bloquean; una segunda respuesta que corrige no
bloquea; y un "informe desactualizado" con el head ya cambiado no alarma. Con
el mismo hook, un PR con dos `devkit-fix` escala a la tercera ronda: el
`task-fix` corre con `opus` y esfuerzo `high`, y `watch.log` dice `ronda=3`
(DEVKIT-61).

Las cuatro primeras alarmas del monitoreo mínimo tienen un caso cada una: el doble de
`claude` de `--run-skill` cubre el error genérico (sin relación con la
cuota, para no confundirla con el relanzamiento), la skill lenta (con
`DEVKIT_WATCH_SKILL_TIMEOUT`/`DEVKIT_WATCH_SKILL_POLL` acortados para la
prueba) y el `result` que termina en pregunta; la alarma de rama huérfana se
prueba aparte con el hook `--orphan-branch <edad> <tiene PR: si|no> <skill
viva: si|no>`, que llama a la decisión pura sin tocar git ni `gh`. El comando
`--agentes-vivos` se prueba contra un doble con la misma forma de línea de
proceso que arma `devkit-run.sh --worker`, sin lanzar un `claude -p` real.

El ciclo OK → documentar → merge → cerrar (DEVKIT-55) se prueba de punta a
punta: `--decide` pasa de `documentar` a `nada` cuando aparece el marcador
`devkit-doc` del head; `--run-skill` corre `task-document` con la ronda 1 de
la escalera (`sonnet`, esfuerzo `high`); y el hook `--merged-once` corre una pasada del bucle
de mergeados contra un `gh` de mentira, con `task-close.sh` real y un doble
de `notion.sh`. Comprueba la card en `Hecha` con `Cierre` y `PR`, el
comentario con el enlace, el marcador `devkit-closed`, la siguiente hija
libre elegida por `Orden` y dependencias, el cierre en menos de 60 s desde
el merge y que una segunda pasada no repite nada. Casos aparte cubren la card
ya `Hecha`, el PR sin merge, la entrada de Documentación que falta, la última
hija que cierra la Épica, la Épica sin criterios y el bloqueo con
`--block-pr` y `task-block.sh`. `notion.sh --test` prueba el cliente contra
un doble de `curl`: el filtro por `ID` y `Proyecto`, que el token viaja solo
como cabecera por descriptor, los tipos de `set`, los enlaces y tramos de
`comentar`, la búsqueda por `Tarea`, la sección de criterios, los errores y
el reintento de un `429`.

La siguiente hija al `OK` y la guarda de tres ciclos (DEVKIT-56) tienen sus
casos. El hook `--chain-next <N> <Clave>` corre `task-next.sh` real contra el
doble de `notion.sh`: con dos hijas en `Lista`, arranca la que no depende de
la card aprobada y la dependiente espera a `Hecha` sin comentar en la Épica;
con una hermana `En progreso` o un `task-start` ya vivo, no lanza nada. En la
tabla de `--decide`: un fix manual (`manual=1`) tras tres `CAMBIOS` lleva a
`revisar` y un `CAMBIOS` sobre su head a `fix`, no a `bloquear`; y un
`CAMBIOS` sobre un head ya superado lleva a `revisar`.

Revisión de PRs: `/pr-review <N>` actúa como revisor independiente del
autor. Comprueba cada criterio de aceptación de la card ejecutando algo, lee
el diff de forma adversarial y agota en el mismo ciclo la clase de un
hallazgo que tenga variantes (por ejemplo, una sintaxis con varios flags):
busca y reporta cada variante, no una por ciclo. Publica el informe en el PR
con el marcador
`<!-- devkit-review sha=<head> verdict=<OK|CAMBIOS> -->`. Con `OK` mueve la
card a `Lista para merge` y te pide el review con `gh pr edit --add-reviewer`,
que exige que el token de la cuenta máquina tenga el alcance `read:org` además
de `repo` (sección 8.1 de `docs/ARCHITECTURE.md`); sin él, el comando falla
con 403 aunque el repo no tenga organización. Con `CAMBIOS` deja los
hallazgos en un bloque `devkit-findings` (una línea por hallazgo:
`id | severidad | archivo:línea | qué falla | qué hacer`) para que `task-fix`
los atienda. El revisor nunca corrige ni aprueba: el hook `pr-guard.sh`
inspecciona el texto del comando y bloquea `gh pr review --approve`, `gh pr
merge` sin `--auto` o con `--admin`, `git push` a `main` y mutaciones de
GraphQL que aprueben o mergeen, y las reglas `deny` de `settings.json` quedan
como segunda barrera. Es una inspección de texto: reduce las evasiones
accidentales o perezosas, no las garantiza contra variables de shell, alias
de `gh` o una API que el hook no conozca. La compuerta real es GitHub: la
cuenta máquina no puede aprobar sus propios PRs y el ruleset de `main` exige
PR y aprobación humana. El detalle está en `docs/ARCHITECTURE.md`, secciones
8.2 y 12b.

Si el último informe fue `CAMBIOS` para el head vigente y `task-fix` ya
respondió sin empujar commits (descartó todos los hallazgos, o solo
comentó), `pr-review` no termina con "ya revisado": vuelve a juzgar ese mismo
head con la respuesta a la vista, con un diff vacío entre el marcador
anterior y el head (DEVKIT-22). Si acepta todos los descartes y no hay
hallazgos nuevos, publica `OK`; si reabre alguno, publica `CAMBIOS` de nuevo,
y ese informe cuenta para la guardia de tres ciclos.

Corrección de PRs: `/task-fix <Clave> [texto]` es el corrector del ciclo.
Sin texto, lee el bloque `devkit-findings` del último informe con veredicto
`CAMBIOS` y solo los archivos que nombra; con texto, o si la card está en
`Lista para merge` y hay un comentario tuyo en el PR, atiende ese comentario
como un hallazgo único `C<n>`. Si un hallazgo pide retirar un dato que el
revisor no pudo verificar porque vive en un comentario de la card (el
revisor tiene prohibido leerlos), no lo retira: cita la fuente exacta en el
commit. Un commit por hallazgo con la Clave como
ámbito, push sin `--force`, y una respuesta en el PR dentro del bloque
`devkit-fixes` (`id | atendido o descartado | commit o motivo`) que es lo
único que `pr-review` relee en el ciclo siguiente. Al terminar deja la card
en `Revisión automática`. Nunca revisa, aprueba ni mergea.

Documentación al aprobar: `/task-document <Clave> [N]` escribe la entrada de
Documentación de la card (Qué cambió, Por qué, Cómo probarlo, Cambios
requeridos, Enlaces y Modelos, con las marcas de modelo y esfuerzo de
DEVKIT-58) cuando `pr-review` da `OK`, y deja en el PR el marcador
`<!-- devkit-doc sha=<head> -->`. Antes la escribía `task-close` al cerrar,
cuando ya nadie la leía para revisar; ahora está lista antes de que apruebes, y
si la revisión vuelve a abrir la card, la siguiente pasada actualiza la misma
entrada, que encuentra por la relación `Tarea`. Nunca cambia el `Estado`.

Cierre de PRs: `task-close.sh <Clave> [URL]` deja la card en `Hecha` y publica
en el PR el marcador `<!-- devkit-closed sha=<merge commit> -->` con el enlace
a la entrada de Documentación, o solo, si no hay entrada que enlazar.
El marcador es lo que impide repetir el cierre: `/run/devkit/launched` vive en
tmpfs y nace vacío en cada `devkit recreate`, así que antes el bucle relanzaba
el cierre sobre cada PR mergeado en las últimas 48 h, con card ya cerrada
(unos 0,47 USD y 150 s por ejecución inútil cuando era una skill). Para ponerlo a mano en un PR ya
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
| `/task-start [Clave]` | Lista → En progreso | Agente; también `epic-plan` y `task-next.sh` (desde `watch.sh` al `OK` y desde `task-close.sh` al merge) |
| `/task-submit [Clave]` | En progreso → Revisión automática | Agente |
| `/pr-review <número de PR>` | Revisión automática → Lista para merge, o se queda | `watch.sh` (headless) o humano |
| `/task-fix <Clave> [texto]` | Revisión automática o Lista para merge → Revisión automática | `watch.sh` (headless) o humano |
| `/task-document <Clave> [N]` | Entrada de Documentación de una card en Lista para merge (o de una Épica cerrada); no cambia el Estado | `watch.sh` tras el `OK` de `pr-review`; `task-close.sh` si falta |
| `/project-status` | Estado del proyecto y siguiente card libre | Humano o agente |
| `/template-update <X.Y.Z>` | Sube la versión del template del proyecto y pone al día `AGENTS.md` | Agente |
| `/template-propagate` | PR de actualización en cada proyecto | Agente, desde DEVKIT |

Cerrar y bloquear ya no son skills (DEVKIT-55): `task-close.sh` (Lista para
merge → Hecha, lo lanza `watch.sh` tras el merge) y `task-block.sh`
(Cualquiera → Bloqueada, lo lanzan el agente, `watch.sh` y `devkit-run`). La
siguiente hija la arranca `task-next.sh` (DEVKIT-56). Ver sus filas en la
tabla de comandos.

Detalle y convenciones: [`devkit/agents/skills/README.md`](devkit/agents/skills/README.md).

**Modo headless.** `watch.sh` invoca las skills con `claude -p`, donde no hay
quien conteste: una pregunta al humano mata el proceso y deja la card a medias,
así que equivale a bloquear la card con `task-block.sh`. Toda ejecución headless termina en un estado
observable de la card, nunca a la espera. Dos skills lo hacen explícito:

- `/task-start` lee los comentarios de la card antes de publicar el plan:
  cualquiera que amplíe, corrija o precise el alcance original es una
  ampliación, y el plan cita cada una en una línea aparte. No se detiene tras
  crear la rama y comentar el plan: implementa la card hasta cumplir todos
  los criterios de aceptación y termina ejecutando `/task-submit`. Si falta
  una decisión, un acceso o un criterio de aceptación, o se atasca más de dos
  intentos en el mismo problema, ejecuta `task-block.sh` con la petición
  concreta. Una ejecución que no deja la card en `Revisión automática` o
  `Bloqueada` es un corte, no un avance.
- `task-next.sh` lanza la siguiente hija con `devkit-run task-start <Clave>`
  como proceso aparte, con el rol que le toca (DEVKIT-50). Lo llama
  `watch.sh` en cuanto una hija recibe `OK` y `task-close.sh` al mergearla
  (DEVKIT-56). `/epic-plan` hace lo
  mismo con la primera hija, por ruta explícita,
  `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/devkit-run.sh"`, no por el
  alias `devkit-run`: el alias vive en `zshrc` y el Bash no interactivo de
  `claude -p` no lo carga (DEVKIT-54). Cuando todas las hijas terminan,
  `task-close.sh` cierra la Épica solo si está `En progreso` y tiene
  Criterios de aceptación; si no cumple alguna, lo deja anotado en la Épica y
  no la mueve a `Hecha`.

## Qué declara cada proyecto

Un archivo obligatorio, versionado en `.devkit/devkit.toml`, y opcionalmente
un segundo archivo de anulación de roles, `.devkit/roles.toml` (la raíz del
proyecto queda libre para sus propios `AGENTS.md`, `CLAUDE.md` y `README.md`):

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

Opcionalmente, `.devkit/roles.toml` anula la tabla de roles del template y
controla qué modelo y esfuerzo recibe cada skill en este proyecto. Si existe,
`devkit-run.sh` lo resuelve primero; sin él, todos los proyectos usan la tabla
que viene en `devkit/agents/roles.toml` del template.

En el Mac, `~/.devkit/<proyecto>/devkit.env` guarda solo lo personal: URL del
repo, identidad git y remoto de Dropbox. **Importante**: cuando actualices a una
versión que mueva `devkit.toml` a `.devkit/` (DEVKIT-53 en adelante),
reinstala el comando local con `new-project.sh <proyecto> --version <X.Y.Z>`
para que lea la nueva ruta. Sin esto, `devkit update` falla cuando el comando
viejo intenta abrir el archivo en la ubicación antigua.

## Mantener este documento

Este README y la entrada "Stack y comandos del devkit" en Documentación
(Notion) son la referencia de comandos del devkit. Todo comando, alias, script
o skill nuevo o cambiado se documenta en ambos, en el mismo PR. La regla está
en [`AGENTS.md`](AGENTS.md).

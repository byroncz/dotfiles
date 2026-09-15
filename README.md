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
| ![VS Code](https://img.shields.io/badge/openvscode--server-2F80ED?logo=visualstudiocode&logoColor=white) | **openvscode-server** | Único editor del devkit: `devkit code <proyecto>` abre la URL con token, ya en `/workspace`. Con la extensión Claude Code instalada desde Open VSX. Su terminal integrada abre ahí mismo y sostiene la sesión: si cierras la pestaña, se reconecta hasta tres horas después. Las skills solo funcionan desde `/workspace` (regla de `AGENTS.md`), así que la terminal integrada ya arranca en el lugar correcto. Publicado solo en `127.0.0.1` del Mac y gateado por un token de conexión por proyecto, en Bitwarden ([amenazas y mitigaciones](docs/ARCHITECTURE.md#8-seguridad)). |
| ![zsh](https://img.shields.io/badge/zsh_+_starship-F15A24?logo=zsh&logoColor=white) | **zsh + starship** | Shell y prompt. El prompt muestra rama, estado de git y que estás dentro del contenedor. `devkit shell` abre una shell suelta, sin la persistencia del editor. |
| ![Claude Code](https://img.shields.io/badge/Claude_Code-D97757?logo=claude&logoColor=white) | **Claude Code** | Agente principal. Lee `AGENTS.md`, ejecuta las skills, abre PRs y actualiza Notion. En modo headless (`claude -p`) revisa, corrige y cierra cards sin intervención. |
| ![Codex](https://img.shields.io/badge/Codex-000000?logo=openai&logoColor=white) | **Codex** | Segundo agente, preparado pero no instalado: lee el mismo `AGENTS.md` y las mismas skills (estándar Agent Skills). |
| ![GitHub](https://img.shields.io/badge/GitHub-181717?logo=github&logoColor=white) | **GitHub + gh** | Código, PRs y la compuerta humana: `main` exige PR con una aprobación; auto-merge y borrado de ramas activados. Los agentes actúan con la cuenta máquina `byroncz-bot`. |
| ![Git](https://img.shields.io/badge/Git-F05032?logo=git&logoColor=white) | **Git** | Una rama por card, un commit squash en `main` por PR, Conventional Commits con la Clave como ámbito. |
| ![Notion](https://img.shields.io/badge/Notion-000000?logo=notion&logoColor=white) | **Notion** | Centro de tareas: bases Proyectos, Tareas y Documentación. Los agentes la leen y escriben con el plugin oficial de Notion para Claude Code. |
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
| `devkit code <proyecto>` | Abre el editor VS Code del proyecto en el navegador, con el token de conexión ya en la URL. |
| `devkit stop <proyecto>` | Detiene sin perder nada. |
| `devkit down <proyecto>` | Destruye el contenedor. Lo no committeado se pierde. |
| `devkit recreate <proyecto>` | Recrea los contenedores: relee secretos y `devkit.env`, reconstruye solo las capas que cambiaron. En modo dev, primero rearma el contexto de build desde el workspace. |
| `devkit rebuild <proyecto>` | Reconstruye las imágenes desde cero y recrea. En modo dev, también rearma el contexto de build. |
| `devkit update <proyecto>` | Sube a la versión de template que pide `devkit.toml` del repo. En modo dev no hay etiqueta que bajar: te manda a `recreate`. |
| `devkit logs <proyecto>` | Arranque y bucles. |
| `devkit net-open <proyecto>` | Red abierta en esta sesión, solo para depurar. |
| `devkit ls` | Proyectos instanciados. |

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
| `g`, `gs`, `gl`, `ll` | Alias: `git`, `git status -sb`, `git log` gráfico, `ls -lah`. |
| `devkit-run` | Alias a `$DEVKIT_SCRIPTS_DIR/devkit-run.sh` (ver la fila de más abajo): así se lanza sin escribir la ruta completa. `DEVKIT_SCRIPTS_DIR` lo exporta el arranque a `/run/devkit/env`, y es `/workspace/devkit/scripts` en modo dev o `/opt/devkit/scripts` si no: el mismo `SCRIPTS_DIR` que usa `watch.sh`, para que un cambio al script en dev corra igual desde la skill y a mano, sin esperar a un `devkit recreate`. |
| `/opt/devkit/scripts/dropbox-setup.sh` | Autoriza Dropbox una vez y genera el secreto `rclone_conf_b64`. |
| `/opt/devkit/scripts/watch-test.sh` | Prueba `watch.sh` sin GitHub y sin gastar cuota: la tabla de decisión con PRs sintéticos, el relanzamiento por cuota agotada con logs falsos y las cuatro alarmas del monitoreo mínimo; sale con 1 si un caso falla. |
| `/opt/devkit/scripts/slugify.sh` | Convierte un texto libre en un slug de minúsculas separado por guiones (formato de las ramas). `--test` corre su tabla de autoprueba. |
| `/opt/devkit/scripts/image-drift.sh` | Lista qué del template solo entra por imagen y ya no coincide con ella. La usa el arranque en modo dev para avisar del `devkit recreate` pendiente. `--test` corre su autoprueba. |
| `/opt/devkit/scripts/agents-sync.sh` | Funde el `AGENTS.md` de un proyecto con la plantilla destino: si el archivo tiene el marcador `## Reglas del proyecto`, reemplaza todo lo de arriba y conserva todo lo de abajo tal cual; si no lo tiene, no toca nada y sale con el código 2. La usa `template-update`. `--test` corre su autoprueba. |
| `/opt/devkit/scripts/pr-guard.sh` | Hook `PreToolUse` de `settings.json`: inspecciona el texto del comando `Bash` completo, en cualquier posición de sus argumentos, y bloquea (salida 2) aprobar un PR, mergearlo sin `--auto` o con `--admin`, empujar a `main` o una mutación de GraphQL que apruebe o mergee, aunque el comando evada el deny por prefijo (`git -C <dir> push`, `gh api` crudo). Es una inspección de texto, no una sandbox: no ve variables de shell ni alias de `gh`; la compuerta real es GitHub. Cada bloqueo queda en `/run/devkit/denials.log`, para revisar si hay que ampliar una regla. `--test` corre su autoprueba. |
| `/opt/devkit/scripts/devkit-run.sh` (alias `devkit-run`) | Único punto de lanzamiento de una skill: `devkit-run [--modelo <alias>] [--esfuerzo <low\|medium\|high>] <skill> <Clave> [texto extra...]` la corre en segundo plano con `nohup` desde `/workspace`, sin que copies el comando largo a mano, con el modelo y el esfuerzo que le tocan por rol (`devkit/agents/roles.toml`) y el mismo candado que usa `watch.sh` para no pisarle la rama a otra skill. `--modelo`/`--esfuerzo` anulan el rol resuelto para ese lanzamiento puntual, sin tocar `roles.toml`; la línea de resumen lo marca `(anulación manual)`. Log en `/run/devkit/<skill>-<n>.log`; al terminar, agrega a `watch.log` una línea con modelo, esfuerzo, costo y turnos, más las mismas alarmas de `watch.sh` (error, skill lenta, pregunta abierta) y, si el `result` termina en pregunta, relanza `task-block` una vez con un motivo forzado (salvo que el que preguntó ya fuera `task-block` o `task-close`). `task-close` y `epic-plan` lo usan para lanzar la siguiente/primera hija como proceso aparte en vez de trabajarla en su propia ejecución, así corre con el rol que le toca por su propio `Tipo`. `watch.sh` lo usa también (ver más abajo). `--test` corre su autoprueba. |
| `bash devkit/host/devkit-test.sh` | Solo en el repo del template: prueba el comando `devkit` del Mac con un doble de `docker`, sin Docker ni contenedores. Sale con 1 si un caso falla. |

Bucles en segundo plano: `sync-sandbox.sh` (respaldo cada 60 s) y `watch.sh`
(cada 5 min). `watch.sh` mira cada PR cuyo título empieza por una Clave del
proyecto y lanza en modo headless la skill que toca. Su único estado son los
marcadores que las skills dejan en el PR; un rebuild no pierde nada.

| Lo que ve en el PR | Qué lanza |
|---|---|
| Abierto y el head sin marcador `devkit-review` | `/pr-review <N>` |
| Último marcador `verdict=CAMBIOS` para el head, sin respuesta `devkit-fix` | `/task-fix <Clave>` |
| Último marcador `verdict=CAMBIOS` para el head, con respuesta `devkit-fix` sin push nuevo (descartó todo o solo comentó) | `/pr-review <N>` otra vez, con la respuesta a la vista |
| Último marcador `OK` y un comentario o review tuyo posterior (un approve no cuenta) | `/task-fix <Clave> "<tu comentario>"`; la card vuelve a `Revisión automática` |
| Tres informes `CAMBIOS` desde el último `OK` o el último bloqueo, ya atendidos | Marcador `<!-- devkit-block sha=<head> -->` en el PR y `/task-block <Clave>`. No lo toca más hasta que muevas la card a `Revisión automática` y comentes en el PR qué hacer |
| Mergeado en las últimas 48 h y sin marcador `devkit-closed` | `/task-close <Clave> <URL>`, que al terminar deja el marcador `<!-- devkit-closed sha=<merge commit> -->` en el PR |
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
`devkit-run.sh`, que resuelve modelo y esfuerzo según el rol de la skill, leído
de `devkit/agents/roles.toml`: `contabilidad` (`task-close`, `task-block`, que
solo comentan o cierran) usa el modelo más barato con esfuerzo bajo;
`implementación` (el resto: `task-start`, `task-fix`, etc.) usa el modelo y
esfuerzo de la fila que corresponde al `Tipo` de la card (`feature`, `bug` o
`chore`), tomado del prefijo de la rama porque el bucle no consulta Notion
desde bash; `revisión` (`pr-review` y `epic-plan`, desde DEVKIT-50: un mal
desglose de Épica cuesta más que cualquier card) siempre usa el modelo más
fuerte con esfuerzo alto, sin importar el `Tipo`. La tabla también lleva un
`max_turns` por rol, pero es un presupuesto, no un límite: la CLI instalada no
tiene una opción `--max-turns` (`claude --help`, versión 2.1.270), así que
`devkit-run` solo compara `num_turns` del resultado contra ese número y avisa
en el log si se excede. La línea de resumen queda así:

```
pr-review-31-a1b2c3d terminado: modelo=claude-opus-5 esfuerzo=high costo=0.42 turnos=12 tokens: ... :: PR #31: veredicto OK...
```

Al terminar `task-close` de un PR mergeado, el bucle suma el `costo=` de todas
las líneas de ese número de PR en `watch.log` (todas sus rondas de revisión y
corrección, no solo la del cierre) y deja una línea con el total del ciclo:

```
PR #31 (DEVKIT-45) costo total del ciclo: $0.6700 USD
```

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

**Cuota agotada.** Si un `claude -p` muere porque se acabó la cuota de la
suscripción, el agente no puede reaccionar: sin cuota no habla con el modelo y
ninguna skill sirve, `task-block` incluida. Reacciona el bucle, que es bash. Lo
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

**Monitoreo mínimo sin modelo.** Cuatro alarmas en bash dentro de `watch.sh`,
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
`DEVKIT_WATCH_ORPHAN_AGE` segundos (1800 por defecto). Para ver quién sigue
vivo ahora mismo, con su Clave y el paso (skill) en el que está:

```sh
bash /opt/devkit/scripts/watch.sh --agentes-vivos
# <PID>  DEVKIT-46  task-fix
# o, sin ninguno vivo: "sin agentes vivos" y código de salida 0.
```

Variables: `DEVKIT_WATCH_INTERVAL` (segundos, 300), `DEVKIT_WATCH_MAX_CYCLES`
(3), `DEVKIT_WATCH_QUOTA_RETRIES` (3), `DEVKIT_WATCH_QUOTA_WAIT` (1800, la
espera fija), `DEVKIT_WATCH_QUOTA_MIN_WAIT` (60), `DEVKIT_WATCH_QUOTA_MAX_WAIT`
(86400, tope por si el aviso trae una hora absurda), `DEVKIT_WATCH_SKILL_TIMEOUT`
(1200), `DEVKIT_WATCH_SKILL_POLL` (5) y `DEVKIT_WATCH_ORPHAN_AGE` (1800). Para
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
sin respuesta, con respuesta y head nuevo, con respuesta sin cambiar el head,
comentario humano, tres ciclos, bloqueo y reanudación, y la rama de cierre con
y sin marcador) contra `watch.sh --decide` y
`--decide-merged`, y falla si alguno no da la acción esperada. El mismo archivo
prueba la cuota agotada sin gastar cuota: `--quota-hit` y `--quota-reset`
reciben avisos de límite de mentira y comprueban la detección y la hora
extraída, y `--run-skill` corre `run_skill` contra un doble de `claude` que
muere por cuota la primera vez, para ver las dos líneas del log, el
relanzamiento y el tope de intentos. También comprueba que la línea de
resumen trae el modelo del rol resuelto por `devkit-run.sh` y que
`--cycle-cost <N>` suma el costo de todas las líneas de ese PR en un log
dado. `devkit-run.sh --test` prueba aparte la resolución de rol y Tipo, el
lanzamiento en segundo plano (numeración del log, candado con `watch.sh`), el
aviso de presupuesto de turnos excedido, la cadena `task-close` → `task-start`
(dos resúmenes con roles distintos), la anulación manual por
`--modelo`/`--esfuerzo` y el relanzamiento forzado de `task-block` ante una
pregunta abierta.

Las cuatro alarmas del monitoreo mínimo tienen un caso cada una: el doble de
`claude` de `--run-skill` cubre el error genérico (sin relación con la
cuota, para no confundirla con el relanzamiento), la skill lenta (con
`DEVKIT_WATCH_SKILL_TIMEOUT`/`DEVKIT_WATCH_SKILL_POLL` acortados para la
prueba) y el `result` que termina en pregunta; la alarma de rama huérfana se
prueba aparte con el hook `--orphan-branch <edad> <tiene PR: si|no> <skill
viva: si|no>`, que llama a la decisión pura sin tocar git ni `gh`. El comando
`--agentes-vivos` se prueba contra un doble con la misma forma de línea de
proceso que arma `devkit-run.sh --worker`, sin lanzar un `claude -p` real.

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
| `/task-submit [Clave]` | En progreso → Revisión automática | Agente |
| `/pr-review <número de PR>` | Revisión automática → Lista para merge, o se queda | `watch.sh` (headless) o humano |
| `/task-fix <Clave> [texto]` | Revisión automática o Lista para merge → Revisión automática | `watch.sh` (headless) o humano |
| `/task-close <Clave>` | Lista para merge → Hecha | `watch.sh` tras el merge |
| `/task-block <Clave> <motivo>` | Cualquiera → Bloqueada | Agente |
| `/project-status` | Estado del proyecto y siguiente card libre | Humano o agente |
| `/template-update <X.Y.Z>` | Sube la versión del template del proyecto y pone al día `AGENTS.md` | Agente |
| `/template-propagate` | PR de actualización en cada proyecto | Agente, desde DEVKIT |

Detalle y convenciones: [`devkit/agents/skills/README.md`](devkit/agents/skills/README.md).

**Modo headless.** `watch.sh` invoca las skills con `claude -p`, donde no hay
quien conteste: una pregunta al humano mata el proceso y deja la card a medias,
así que equivale a `/task-block`. Toda ejecución headless termina en un estado
observable de la card, nunca a la espera. Dos skills lo hacen explícito:

- `/task-start` lee los comentarios de la card antes de publicar el plan:
  cualquiera que amplíe, corrija o precise el alcance original es una
  ampliación, y el plan cita cada una en una línea aparte. No se detiene tras
  crear la rama y comentar el plan: implementa la card hasta cumplir todos
  los criterios de aceptación y termina ejecutando `/task-submit`. Si falta
  una decisión, un acceso o un criterio de aceptación, o se atasca más de dos
  intentos en el mismo problema, ejecuta `/task-block` con la petición
  concreta. Una ejecución que no deja la card en `Revisión automática` o
  `Bloqueada` es un corte, no un avance.
- `/task-close`, al cerrar una hija de una Épica que aún tiene hermanas
  pendientes, lanza la siguiente con `devkit-run task-start <Clave>` como
  proceso aparte y termina ahí mismo (DEVKIT-50): trabajarla en la misma
  ejecución la dejaba correr con el rol de contabilidad de `task-close` en
  vez del que le toca por su propio `Tipo`. `/epic-plan` hace lo mismo con la
  primera hija. Cuando todas las hijas terminan, `task-close` cierra la
  Épica solo si está `En progreso` y tiene Criterios de aceptación; si no
  cumple alguna, lo deja anotado en la Épica y no la mueve a `Hecha`.

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

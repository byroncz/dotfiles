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
estado del editor VS Code del lado del servidor (extensiones instaladas,
perfiles en caché y logs) entre reconstrucciones. `devkit down` no lo borra,
igual que al resto de los volúmenes con nombre; para reiniciarlo desde cero
hace falta `docker volume rm editor-<proyecto>`.

## Stack

{{STACK}}

## Comandos

{{COMANDOS}}

## Skills (comandos `/nombre` dentro de `claude`)

{{SKILLS}}

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

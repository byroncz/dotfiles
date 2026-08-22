# Antigravity IDE + Devcontainer: Guía de diagnóstico y solución

Este documento describe los problemas reales encontrados al configurar un devcontainer en **Antigravity IDE** (fork de VS Code basado en `1.107.0`, publisher `google.antigravity-dev-containers`) y cómo resolverlos paso a paso sin ambigüedad.

---

## Contexto del entorno

- **IDE**: Antigravity IDE (Google). Versión del servidor interno: `2.0.4`. VS Code engine: `1.107.0`.
- **Extensión de devcontainers**: `google.antigravity-dev-containers` v0.0.1 (muy básica).
- **Host**: macOS Apple Silicon (arm64), Docker Desktop con OrbStack o Docker Desktop estándar.
- **Container base**: Debian Linux arm64.
- **Registry de extensiones**: Open VSX (`https://open-vsx.org`). Antigravity **no** tiene acceso al VS Code Marketplace de Microsoft.

---

## Problema 1: Nombres de container aleatorios e IDs no descriptivos

### Síntoma
Al hacer "Reopen in Container", Docker asigna nombres aleatorios (`goofy_chatelet`, `nifty_tu`, etc.) y hashes como nombres de imagen.

### Causa
Por defecto, devcontainer CLI asigna nombres basados en un hash del workspace path. Sin `runArgs`, el nombre del container es aleatorio.

### Solución
Añadir `runArgs` con `--name` en `devcontainer.json`:

```json
"runArgs": ["--name", "nombre-descriptivo"]
```

**Restricción importante**: Con nombre fijo, solo puede existir un container con ese nombre a la vez. Si ya existe uno (incluso detenido), Docker fallará al crear uno nuevo. Antes de cada rebuild, verificar con `docker ps -a` y eliminar el container anterior si existe:

```bash
docker rm -f nombre-descriptivo
```

---

## Problema 2: "Dev Containers: Rebuild Container" no disponible en Antigravity

### Síntoma
El comando `Dev Containers: Rebuild Container` no existe en el Command Palette de Antigravity IDE.

### Causa
Ese comando pertenece a la extensión `ms-vscode-remote.remote-containers` de Microsoft, que **no tiene licencia para VS Code forks**.

### Solución: CLI de devcontainer

Instalar el CLI oficial (requiere Node.js, instalar con Homebrew si no está):

```bash
brew install node
npm install -g @devcontainers/cli
```

Hacer rebuild:
```bash
devcontainer up --workspace-folder /ruta/al/workspace --remove-existing-container
```

El flag `--remove-existing-container` elimina el container anterior y lo recrea aplicando todos los cambios de `devcontainer.json`.

### Alternativa UI
La extensión **`DDorch.codium-devcontainer`** en Open VSX proporciona UI de rebuild para VS Code forks. Instalarla desde el panel de extensiones buscando ese ID.

---

## Problema 3: Extensiones no se instalan automáticamente

### Síntoma
El campo `customizations.vscode.extensions` en `devcontainer.json` es ignorado por Antigravity. Las extensiones listadas ahí **nunca se instalan** en el container.

### Causa
`google.antigravity-dev-containers` v0.0.1 no implementa el procesamiento de `customizations.vscode.extensions`. Confirmado inspeccionando su `package.json` dentro del container.

### Diagnóstico
```bash
docker exec <nombre-container> cat \
  /home/vscode/.antigravity-ide-server/bin/*/extensions/antigravity-dev-containers/package.json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('version:', d.get('version'))"
```
Si la versión es `0.0.1`, el campo de extensiones es ignorado.

### Solución: Script de instalación vía Open VSX

Las extensiones se instalan descargando VSIXs desde Open VSX y extrayéndolos en el directorio de extensiones del servidor de Antigravity **antes** de que el IDE conecte.

**Archivos necesarios:**

1. **`.devcontainer/install-extensions.sh`** (script de instalación)
2. Llamarlo desde **`postCreateCommand`** en `devcontainer.json`
3. Volumen persistente montado en `/home/vscode/.antigravity-ide-server/extensions`

**Contenido de `install-extensions.sh`:**

```bash
#!/bin/bash
set -euo pipefail

EXTENSIONS_DIR="/home/vscode/.antigravity-ide-server/extensions"
EXTENSIONS_JSON="${EXTENSIONS_DIR}/extensions.json"
ARCH=$(uname -m)
PLATFORM="linux-x64"
[ "$ARCH" = "aarch64" ] && PLATFORM="linux-arm64"

[ -f "$EXTENSIONS_JSON" ] || echo "[]" > "$EXTENSIONS_JSON"

register_extension() {
  local extid="$1" version="$2" extdir="$3"
  python3 - "$extid" "$version" "$extdir" "$EXTENSIONS_JSON" <<'EOF'
import json, sys
extid, version, extdir, path = sys.argv[1:]
with open(path) as f:
    exts = json.load(f)
exts = [e for e in exts if e['identifier']['id'] != extid]
exts.append({
    'identifier': {'id': extid},
    'version': version,
    'location': {'$mid': 1, 'path': extdir, 'scheme': 'file'},
    'relativeLocation': extdir.split('/')[-1]
})
with open(path, 'w') as f:
    json.dump(exts, f)
EOF
}

# install_vsix <publisher> <name> [pinned-version]
install_vsix() {
  local publisher="$1" name="$2" pinned="${3:-}"
  local extid
  extid="$(echo "$publisher" | tr '[:upper:]' '[:lower:]').${name}"

  local version
  if [ -n "$pinned" ]; then
    version="$pinned"
  else
    version=$(curl -sf "https://open-vsx.org/api/${publisher}/${name}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])") || {
      echo "[ext] WARN: ${extid} not on Open VSX, skipping"
      return 0
    }
  fi

  local extdir="${EXTENSIONS_DIR}/${extid}-${version}"

  # Eliminar versiones anteriores incompatibles
  for old in "${EXTENSIONS_DIR}/${extid}"-*/; do
    [ -d "$old" ] && [ "$old" != "${extdir}/" ] && rm -rf "$old"
  done

  if [ -d "$extdir" ]; then
    echo "[ext] ${extid}@${version} already installed"
    register_extension "$extid" "$version" "$extdir"
    return 0
  fi

  local download_url
  download_url=$(curl -sf "https://open-vsx.org/api/${publisher}/${name}/${PLATFORM}/${version}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('files',{}).get('download',''))" 2>/dev/null || true)

  if [ -z "$download_url" ]; then
    download_url="https://open-vsx.org/api/${publisher}/${name}/${version}/file/${publisher}.${name}-${version}.vsix"
  fi

  echo "[ext] Installing ${extid}@${version} (${PLATFORM})..."
  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" RETURN

  curl -sfL "$download_url" -o "$tmp/ext.vsix" || {
    echo "[ext] WARN: download failed for ${extid}, skipping"
    return 0
  }
  unzip -q "$tmp/ext.vsix" "extension/*" -d "$tmp/extracted" || {
    echo "[ext] WARN: unzip failed for ${extid}, skipping"
    return 0
  }
  mv "$tmp/extracted/extension" "$extdir"
  register_extension "$extid" "$version" "$extdir"
  echo "[ext] Installed ${extid}@${version}"
}
```

---

## Problema 4: Extensiones platform-specific y capitalización del publisher

### Síntoma
La extensión `anthropic.claude-code` no se instala aunque está en Open VSX. Error silencioso (el script continúa pero no aparece el directorio).

### Causa
Dos sub-problemas:

1. **Publisher con mayúscula**: En Open VSX, el publisher real es `Anthropic` (con A mayúscula), no `anthropic`. La URL genérica construida con publisher en minúsculas falla.

2. **VSIX platform-specific**: `anthropic.claude-code` no tiene un VSIX genérico — solo tiene builds por plataforma (`linux-arm64`, `linux-x64`, `alpine-arm64`). El container en macOS Apple Silicon es Debian `linux-arm64` (no Alpine).

### Diagnóstico
```bash
curl -sf "https://open-vsx.org/api/anthropic/claude-code" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('files',{}))"
```
Si el campo `download` contiene `alpine-arm64` o `linux-arm64` en la URL, es platform-specific.

### Solución
El script `install_vsix` ya maneja esto: primero intenta la URL platform-specific, luego cae en la URL genérica. El `extid` (nombre del directorio) siempre se construye en minúsculas independientemente del publisher real.

**Para llamar la función correctamente con Anthropic:**
```bash
install_vsix Anthropic claude-code
```
El directorio resultante será `anthropic.claude-code-2.1.183` (minúsculas), que es lo que Antigravity espera.

---

## Problema 5: Extensiones instaladas no reconocidas por Antigravity

### Síntoma
Los archivos de la extensión están en `/home/vscode/.antigravity-ide-server/extensions/` pero el IDE no la muestra como instalada. Sigue pidiendo "Install in Container".

### Causa
Antigravity **no escanea el directorio** automáticamente — lee `extensions.json` como fuente de verdad. Si `extensions.json` no incluye la entrada, la extensión es invisible aunque los archivos estén presentes.

### Diagnóstico
```bash
docker exec <container> cat /home/vscode/.antigravity-ide-server/extensions/extensions.json
```
Si la extensión no aparece en el JSON, no está registrada.

### Solución
El script `register_extension` actualiza `extensions.json` después de cada instalación. Esta función es **obligatoria** — sin ella, colocar los archivos no es suficiente.

Para registrar manualmente una extensión ya instalada:
```bash
docker exec <container> python3 -c "
import json
path = '/home/vscode/.antigravity-ide-server/extensions/extensions.json'
with open(path) as f:
    exts = json.load(f)
exts.append({
    'identifier': {'id': 'publisher.name'},
    'version': 'X.Y.Z',
    'location': {'\$mid': 1, 'path': '/home/vscode/.antigravity-ide-server/extensions/publisher.name-X.Y.Z', 'scheme': 'file'},
    'relativeLocation': 'publisher.name-X.Y.Z'
})
open(path, 'w').write(json.dumps(exts))
print('registered')
"
```

---

## Problema 6: Incompatibilidad de versiones de extensiones

### Síntoma
Antigravity muestra: *"Some extensions are disabled due to version incompatibility"*. Las extensiones afectadas aparecen en el panel con un warning.

### Causa
Las versiones más recientes de algunas extensiones requieren un VS Code engine más nuevo que el de Antigravity (`1.107.0`). Ejemplos reales:
- `latex-workshop 10.16.1` requiere `^1.114.0` → incompatible
- `ms-python.vscode-python-envs 1.36.0` requiere `^1.110.0` → incompatible

### Diagnóstico completo
Ejecutar dentro del container para ver todas las extensiones instaladas y su compatibilidad:

```bash
docker exec <container> python3 -c "
import json, glob, os
ext_dir = '/home/vscode/.antigravity-ide-server/extensions'
ag_version = '1.107.0'  # ajustar si la versión de Antigravity cambia

def compat(req, actual):
    if not req: return True
    req_parts = [int(x.split('-')[0]) for x in req.lstrip('^>=~').split('.')[:3]]
    act_parts = [int(x) for x in actual.split('.')[:3]]
    return act_parts >= req_parts

for pkg in sorted(glob.glob(f'{ext_dir}/*/package.json')):
    d = json.load(open(pkg))
    eng = d.get('engines', {}).get('vscode', '')
    status = 'OK' if compat(eng, ag_version) else 'INCOMPATIBLE'
    print(f'{status}: {os.path.basename(os.path.dirname(pkg))} needs {eng}')
"
```

### Solución
Para cada extensión incompatible, encontrar la última versión compatible:

```bash
# Listar versiones disponibles en Open VSX
curl -sf "https://open-vsx.org/api/<publisher>/<name>/versions" \
  | python3 -c "import sys,json; print(list(json.load(sys.stdin).get('versions',{}).keys()))"

# Para cada versión candidata, verificar el engine requerido
curl -sf "https://open-vsx.org/api/<publisher>/<name>/<version>" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('engines',{}))"
```

**Versiones pinneadas conocidas para Antigravity 2.0.4 (VS Code 1.107.0):**

| Extensión | Última versión | Última compatible | Engine requerido |
|-----------|---------------|-------------------|-----------------|
| `james-yu.latex-workshop` | 10.16.1 | **10.13.1** | `^1.96.0` |
| `ms-python.vscode-python-envs` | 1.36.0 | **1.20.1** | `^1.106.0` |

En el script, usar el tercer parámetro de `install_vsix` para pinear:
```bash
install_vsix james-yu  latex-workshop      10.13.1
install_vsix ms-python vscode-python-envs  1.20.1
```

El script elimina automáticamente versiones anteriores del mismo publisher.name antes de instalar la nueva.

---

## Problema 7b: "Permission denied" al instalar el servidor de Antigravity + "flock: Bad file descriptor"

### Síntoma
Al hacer "Reopen in Container", el log del devcontainer muestra:
```
mkdir: cannot create directory '/home/vscode/.antigravity-ide-server/bin': Permission denied
flock: 200: Bad file descriptor
```
El IDE no conecta al container.

### Causa
Docker crea el mount point de un volumen como **`root:root`** si el directorio padre no pre-existe en la imagen. La cadena de eventos:

1. Docker monta el volumen en `/home/vscode/.antigravity-ide-server/extensions`
2. Como `.antigravity-ide-server/` no existe en la imagen, Docker lo crea — pero como **`root:root 755`**
3. El servidor de Antigravity intenta instalar su binario en `.antigravity-ide-server/bin/` **ANTES** de que corra `postCreateCommand` → Permission denied
4. El script del instalador hace `exec 200>/ruta/lock ; flock 200 ...` — como el open falla por permisos, fd 200 nunca se abre → "flock: 200: Bad file descriptor" (error en cascada)
5. `postCreateCommand` con `sudo chown -R vscode...` llega demasiado tarde

### Diagnóstico
```bash
docker exec <container> stat -c "%U %G %a %n" /home/vscode/.antigravity-ide-server
# Si muestra "root root 755" → este es el problema

docker exec -u vscode <container> mkdir -p /home/vscode/.antigravity-ide-server/bin
# Si falla con "Permission denied" → confirmado
```

### Solución
Pre-crear el directorio en el **Dockerfile** con ownership correcto. Docker nunca cambia el ownership del padre de un mount point — solo lo crea si no existe. Si ya existe con el owner correcto, el volumen se monta sin tocar el padre:

```dockerfile
# En el RUN de mount targets, incluir el directorio padre del volumen:
RUN mkdir -p /commandhistory "/home/${USERNAME}/.claude" "/home/${USERNAME}/.antigravity-ide-server/extensions" \
  && chown -R "${USER_UID}:${USER_GID}" /commandhistory "/home/${USERNAME}/.claude" "/home/${USERNAME}/.antigravity-ide-server"
```

**Regla general para futuros repos**: Cualquier directorio que sea **padre** de un volumen montado debe pre-existir en la imagen con el ownership del usuario no-root. Si el volumen se monta en `/home/user/foo/bar`, el directorio `/home/user/foo` debe estar en la imagen con `chown user:user`.

---

## Problema 7: Las extensiones no persisten tras rebuild

### Síntoma
Después de `devcontainer up --remove-existing-container`, las extensiones desaparecen y hay que instalarlas de nuevo.

### Causa
El directorio `/home/vscode/.antigravity-ide-server/extensions/` vive en el filesystem del container, que se destruye con cada rebuild.

### Solución
Montar un volumen Docker con nombre fijo en ese directorio. El nombre fijo (sin `${devcontainerId}`) garantiza que el volumen persiste independientemente de cambios en `devcontainer.json`.

En `devcontainer.json`:
```json
"mounts": [
  "source=NOMBRE-PROYECTO-ide-extensions,target=/home/vscode/.antigravity-ide-server/extensions,type=volume"
]
```

El `postCreateCommand` ejecuta `install-extensions.sh`, que detecta extensiones ya instaladas (`if [ -d "$extdir" ]`) y las salta. Solo descarga las que faltan.

---

## Problema 8: Compartir sesiones de Claude Code entre host y container

### Síntoma
Las sesiones de Claude Code del host no son visibles dentro del container y viceversa.

### Causa parcial (solucionable)
El directorio `~/.claude` del host no está montado en el container — en cambio, se usa un volumen Docker vacío.

### Solución
Bind mount del `~/.claude` del host:

```json
"mounts": [
  "source=${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind,consistency=cached"
]
```

**Lo que SÍ se comparte con esto:**
- Credenciales / API key (no necesitas hacer login dos veces)
- Settings globales de Claude Code
- CLAUDE.md global y sistema de memoria
- Historial global

**Lo que NO se comparte (limitación estructural):**
- Sesiones de proyecto específico. Claude Code identifica proyectos por su ruta absoluta en el filesystem. La ruta difiere entre host (`/Users/usuario/dev/proyecto`) y container (`/workspaces/proyecto`), por lo que cada entorno mantiene sus propias sesiones bajo claves distintas en `~/.claude/projects/`.

> **Nota**: el bind mount y el volumen persistente del Problema 11 son mutuamente excluyentes (mismo destino). Este repo usa el volumen; elige el bind mount solo si quieres compartir el estado con el host.

---

## Problema 9b: postCreateCommand falla con "chdir ... no such file or directory"

### Síntoma
```
OCI runtime exec failed: exec failed: unable to start container process:
chdir to cwd ("/workspaces/nombre-que-pusiste") set in config.json failed: no such file or directory
postCreateCommand from devcontainer.json failed with exit code 127.
```

### Causa
El `workspaceFolder` en `devcontainer.json` no coincide con la ruta real donde devcontainer CLI monta el workspace. El devcontainer CLI monta el workspace usando el **nombre exacto del directorio local** (case-sensitive, con espacios incluidos). Si el directorio local se llama `Claude Code`, el mount point será `/workspaces/Claude Code`, no `/workspaces/claude-code`.

El `postCreateCommand` se ejecuta con ese `workspaceFolder` como CWD. Si el directorio no existe, el proceso falla antes de correr una sola línea.

### Diagnóstico
```bash
docker exec <container-id> ls /workspaces/
# Muestra el nombre real del directorio montado
```

### Solución
Poner en `workspaceFolder` exactamente el nombre del directorio local (case-sensitive):
```json
"workspaceFolder": "/workspaces/Claude Code"
```

**Regla general para futuros repos**: Si el directorio local del proyecto tiene mayúsculas o espacios, el `workspaceFolder` debe preservarlos. Verificar siempre con `ls /workspaces/` dentro del container recién creado.

---

## Problema 9: postCreateCommand falla con `build.sh`

### Síntoma
El log de `postCreateCommand` muestra: `chmod: cannot access './build.sh': No such file or directory`

### Causa
El comando `chmod +x ./build.sh` referencia un archivo que no existe en el proyecto.

### Solución
Usar wildcard para aplicar a todos los `.sh` del proyecto:
```json
"postCreateCommand": "... chmod +x ./*.sh ; true"
```
El `; true` al final garantiza que el comando total sea exitoso aunque ningún `.sh` exista.

---

## Problema 10: Terminal pelada, sin contexto ni ayudas (no hay oh-my-zsh)

### Síntoma
La terminal del container es `bash` puro: prompt mínimo (`devuser@host:/workspace$`), sin rama de git, sin estado del último comando, sin autocompletado decente y con historial pobre. La experiencia es tortuosa comparada con oh-my-zsh.

### Causa
La imagen base (`python:3.11-slim`, Debian) trae bash minimal. El `~/.bashrc` de skel no configura prompt informativo y **falta el paquete `bash-completion`** (el loader). Además `git-prompt.sh` no viene incluido en Debian (solo `git-completion`).

### Decisión de diseño
oh-my-zsh / starship añaden dependencias y, sobre todo, los temas powerline **requieren Nerd Fonts** en el terminal integrado del IDE — si la fuente no las tiene, el prompt se ve roto (cuadritos). Solución adoptada: **bash mejorado, ASCII-safe, cero dependencias externas** (solo el paquete `bash-completion` de apt). Funciona con cualquier fuente.

### Solución
1. **`.devcontainer/bash-enhancements.sh`** — script sourceado desde `~/.bashrc`. Aporta:
   - Prompt con código de salida del último comando, `user@host`, cwd, **venv de Python** y **rama de git con marcador `*` de dirty** (función propia con `git symbolic-ref`, sin depender de `git-prompt.sh`).
   - Historial grande, deduplicado, compartido entre sesiones (`history -a` en cada prompt), con timestamp.
   - `shopt`: `globstar`, `autocd`, `cdspell`, `checkwinsize`.
   - Colores y aliases (`ll`, `gs`, `gl`, `gd`, `..`, etc.).
   - Carga directa de `git-completion` como fallback si el loader de bash-completion no está.

2. **Dockerfile** — añadir `bash-completion` a las deps de apt y conectar el script:
   ```dockerfile
   # en el apt-get install: ... bash-completion ...
   COPY --chown=devuser:devuser bash-enhancements.sh /home/devuser/.bash_enhancements.sh
   RUN printf '\n# devcontainer bash enhancements\n[ -f "$HOME/.bash_enhancements.sh" ] && . "$HOME/.bash_enhancements.sh"\n' \
       >> /home/devuser/.bashrc
   ```

**Regla general**: el home no persiste entre rebuilds (salvo el volumen `~/.claude`), por lo que la config de shell debe inyectarse vía Dockerfile (COPY + append al `~/.bashrc`), no editando el home en runtime.

### Aplicar en vivo sin rebuild
```bash
cp /workspace/.devcontainer/bash-enhancements.sh ~/.bash_enhancements.sh
grep -q .bash_enhancements.sh ~/.bashrc || \
  printf '\n[ -f "$HOME/.bash_enhancements.sh" ] && . "$HOME/.bash_enhancements.sh"\n' >> ~/.bashrc
source ~/.bashrc   # o simplemente abrir una terminal nueva
```
(`bash-completion` como tal requiere el rebuild, ya que `devuser` no tiene sudo; el resto funciona al instante.)

---

## Problema 11: Las conversaciones y credenciales de Claude Code se pierden al rehacer el container

### Síntoma
Tras `devcontainer up --remove-existing-container` (o `docker rm -f`), dentro del container hay que volver a hacer login en Claude Code y `claude --resume` no muestra ninguna sesión anterior.

### Causa
Todo el estado de Claude Code vive en el home del usuario del container, que se destruye con el container:

- `~/.claude/projects/<proyecto>/<sesión>.jsonl` — transcripción completa de cada conversación
- `~/.claude/.credentials.json` — sesión OAuth / API key (en Linux; en macOS va al Keychain)
- `~/.claude/settings.json`, `~/.claude/plugins/`, `~/.claude/history.jsonl`
- `~/.claude.json` — **fuera** de `~/.claude`: login, MCP servers de usuario, `trust` por proyecto

Montar un volumen solo en `~/.claude` **no basta**: `~/.claude.json` queda fuera y se pierde en cada rebuild, así que Claude Code vuelve a pedir login y a preguntar si confía en la carpeta.

### Solución

**1. Volumen con nombre fijo montado en `~/.claude`** (sin `${devcontainerId}`, para que sobreviva a cambios en `devcontainer.json`):

```json
"mounts": [
  "source=capta-claude-config,target=/home/devuser/.claude,type=volume"
]
```

**2. `CLAUDE_CONFIG_DIR` apuntando al mismo directorio**, para que `.claude.json` también caiga dentro del volumen:

```json
"containerEnv": {
  "CLAUDE_CONFIG_DIR": "/home/devuser/.claude"
}
```

Comprobado en Claude Code 2.1.240: con `CLAUDE_CONFIG_DIR=$DIR`, el archivo de configuración se escribe en `$DIR/.claude.json` y no se crea nada en `$HOME`.

```bash
CLAUDE_CONFIG_DIR=/tmp/cfg HOME=/tmp/home claude mcp list
ls -a /tmp/cfg   # .claude.json, backups/, ...
ls -a /tmp/home  # vacío
```

**3. Pre-crear el mount point en el `Dockerfile`** con el owner correcto (misma regla del Problema 7b). Un volumen nombrado vacío hereda contenido y ownership del directorio de la imagen la primera vez que se monta:

```dockerfile
RUN mkdir -p "/home/${USERNAME}/.claude" \
 && chown -R "${USER_UID}:${USER_GID}" "/home/${USERNAME}/.claude" \
 && chmod 700 "/home/${USERNAME}/.claude"
```

Sin esto, el volumen aparece como `root:root` y Claude Code no puede escribir transcripciones ni credenciales.

### Diagnóstico
```bash
# ¿El volumen está montado y con el owner correcto?
docker exec <container> stat -c "%U %G %a %n" /home/devuser/.claude

# ¿Dónde acabó .claude.json?
docker exec <container> sh -c 'ls -la ~/.claude.json ~/.claude/.claude.json 2>&1'

# ¿Qué hay realmente guardado en el volumen?
docker run --rm -v capta-claude-config:/claude alpine sh -c \
  'ls /claude; find /claude/projects -name "*.jsonl" | wc -l'
```

### Ojo con estos casos
- `docker volume prune` borra cualquier volumen que no esté en uso por un container existente — incluido `capta-claude-config` si en ese momento no hay container. Hacer backup antes.
- El volumen contiene credenciales en claro; un `tar` del volumen es un secreto.
- Los nombres llevan el prefijo del proyecto (`capta-`), así que el estado no se comparte con otros devcontainers. Para un único login e historial en toda la máquina, usar un nombre común (p. ej. `claude-home`) en todos los proyectos.
- Las sesiones siguen indexadas por ruta absoluta: las de `/workspaces/proyecto` no se mezclan con las del host aunque compartas el directorio (Problema 8).

---

## Problema 12: El gitignore global y la identidad de git se pierden al rehacer el container

### Síntoma
Tras un rebuild, `git config --global user.email` está vacío y las reglas del **gitignore global** desaparecen: archivos que antes estaban ignorados en todos los repos (`.env`, credenciales, `settings.local.json`) vuelven a aparecer como untracked y pueden acabar commiteados por error.

### Causa
Son archivos del **home**, no de los repos:

- `~/.config/git/ignore` — gitignore global, aplica a todos los repos del container
- `~/.config/git/config` (o `~/.gitconfig`) — identidad, alias, `core.excludesFile`

El `.gitignore` de cada repositorio viaja dentro del repo y no corre peligro; estos dos viven en el home del container y se destruyen con él.

Hay una trampa añadida: git prefiere `~/.gitconfig` sobre `~/.config/git/config`. Si el IDE copia el `.gitconfig` del host al home del container, o si alguien ejecuta `git config --global ...`, el archivo que manda queda **fuera** del volumen.

### Solución

**1. Volumen con nombre fijo en el directorio de config de git del home:**

```json
"mounts": [
  "source=capta-git-config,target=/home/devuser/.config/git,type=volume"
]
```

`~/.config/git/ignore` es el excludesFile por defecto de git cuando `core.excludesFile` no está fijado, así que con montar ese directorio el gitignore global ya persiste.

**2. `GIT_CONFIG_GLOBAL` apuntando al config dentro del volumen**, para que git lea **y escriba** ahí:

```json
"containerEnv": {
  "GIT_CONFIG_GLOBAL": "/home/devuser/.config/git/config"
}
```

Comprobado en git 2.43: con `GIT_CONFIG_GLOBAL` fijado, `git config --global core.excludesFile <ruta>` escribe en ese archivo y **no** crea `~/.gitconfig`.

**3. Semilla en el `Dockerfile`** (un volumen vacío copia el contenido de la imagen la primera vez que se monta), y **fusión de lo que quede fuera** en `post-create.sh`: si aparecen `~/.gitconfig` o `~/.gitignore_global` (copiados del host o heredados de un container anterior), se anexan una sola vez al archivo del volumen — con un marcador que evita duplicados — y el original se renombra a `*.pre-volume`.

### Diagnóstico
```bash
# ¿Qué archivo global está usando git dentro del container?
docker exec <container> sh -c 'echo $GIT_CONFIG_GLOBAL; git config --global --list --show-origin | head'

# ¿Qué gitignore global se aplica y qué reglas tiene?
docker exec <container> sh -c 'git config --global core.excludesFile; cat "$(git config --global core.excludesFile)"'

# ¿Hay un ~/.gitconfig fuera del volumen pisando al del volumen?
docker exec <container> ls -la /home/devuser/.gitconfig

# Comprobar que una regla global ignora de verdad en cualquier repo
docker exec <container> sh -c 'cd /tmp && rm -rf t && mkdir t && cd t && git init -q . && touch .env visible.txt && git status --porcelain'
# Debe listar solo "?? visible.txt"
```

### Ojo con estos casos
- El volumen `capta-git-config` es de este proyecto. Para una sola identidad y un solo gitignore global en toda la máquina, usar un nombre común en todos los devcontainers.
- El gitignore global **no** sustituye al `.gitignore` del repo: las reglas que el equipo debe compartir van en el repo; las personales, aquí.
- `core.excludesFile` con una ruta fuera del volumen (por ejemplo `~/.gitignore_global`) rompe la persistencia aunque el volumen esté montado; `post-create.sh` la reapunta al archivo del volumen.

---

## Configuración final de referencia

### `devcontainer.json` completo

Es el `devcontainer.json` de este repositorio (ver también `README.md`):

```json
{
  "name": "gt-algorithia-capta-homologacion",
  "build": { "dockerfile": "Dockerfile", "context": "." },
  "runArgs": ["--name", "gt-algorithia-capta-homologacion"],
  "remoteUser": "devuser",
  "workspaceFolder": "/workspace",

  "mounts": [
    "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
    "source=capta-claude-config,target=/home/devuser/.claude,type=volume",
    "source=capta-git-config,target=/home/devuser/.config/git,type=volume",
    "source=capta-bash-history,target=/commandhistory,type=volume",
    "source=capta-ide-extensions,target=/home/devuser/.antigravity-ide-server/extensions,type=volume"
  ],

  "containerEnv": {
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CONFIG_DIR": "/home/devuser/.claude",
    "GIT_CONFIG_GLOBAL": "/home/devuser/.config/git/config"
  },

  "customizations": {
    "vscode": {
      "extensions": ["ms-python.python", "ms-toolsai.jupyter", "anthropic.claude-code"]
    }
  },

  "postCreateCommand": "bash .devcontainer/post-create.sh"
}
```

Notas sobre los montajes:

- `capta-claude-config` es un **volumen**, no un bind mount al `~/.claude` del host: persiste conversaciones y credenciales entre rebuilds (Problema 11). El bind mount del Problema 8 es la alternativa excluyente si se quiere compartir estado con el host.
- `capta-git-config` persiste el **gitignore global del home** (`~/.config/git/ignore`) y la config global de git (Problema 12). No tiene nada que ver con el `.gitignore` de cada repositorio, que viaja dentro del repo.
- Los nombres de volumen **no llevan `${devcontainerId}`**: ese ID cambia al modificar `devcontainer.json` y con él se "pierde" el volumen anterior (sigue existiendo, pero ya no se monta).
- `post-create.sh` concentra el postCreateCommand: permisos de los volúmenes, migración al volumen de `~/.claude.json`, `~/.gitconfig` y `~/.gitignore_global`, `core.excludesFile`, sanity checks del stack (aws, nbformat, boto3) e `install-extensions.sh`.

### Orden de operaciones en cada rebuild

1. `devcontainer up --workspace-folder /ruta --remove-existing-container`
2. Docker crea el container con el nombre fijo y monta los volúmenes
3. `postCreateCommand` ejecuta `post-create.sh`:
   - `mkdir -p` + `chown` → garantiza permisos en los volúmenes de `.claude`, de git y de extensiones
   - migra al volumen `~/.claude.json`, `~/.gitconfig` y `~/.gitignore_global` si venían de fuera
   - reapunta `core.excludesFile` al gitignore global del volumen
   - sanity checks de `aws`, `nbformat` y `boto3`
   - `install-extensions.sh` → descarga VSIXs faltantes de Open VSX, actualiza `extensions.json`
4. Antigravity conecta al container, lee `extensions.json`, carga las extensiones
5. Reload Window si las extensiones no aparecen inmediatamente

### Ejecutar el script sin rebuild (fix rápido en container corriendo)

```bash
docker exec -u vscode <nombre-container> bash /workspaces/proyecto/.devcontainer/install-extensions.sh
```
Luego hacer "Developer: Reload Window" en Antigravity.

---

## Checklist para añadir una nueva extensión

1. Verificar que existe en Open VSX:
   ```bash
   curl -sf "https://open-vsx.org/api/<publisher>/<name>" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version', 'NOT FOUND'))"
   ```

2. Verificar compatibilidad de engine con Antigravity `1.107.0`:
   ```bash
   curl -sf "https://open-vsx.org/api/<publisher>/<name>" | python3 -c "import sys,json; print(json.load(sys.stdin).get('engines',{}))"
   ```
   Si el engine requerido es mayor a `1.107.0`, buscar versión anterior compatible (ver Problema 6).

3. Añadir al final de `install-extensions.sh`:
   ```bash
   install_vsix publisher name           # sin pin → última versión
   install_vsix publisher name X.Y.Z    # con pin → versión específica
   ```

4. Añadir a `customizations.vscode.extensions` en `devcontainer.json` (para documentación y compatibilidad futura).

5. Ejecutar el script en el container corriendo o hacer rebuild.

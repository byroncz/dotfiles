# Configuración manual

Todo lo que el template **no puede** hacer por ti: crear la cuenta de Google
Drive, autorizar por OAuth, generar las claves de cifrado y guardarlas donde
sobrevivan a un formateo. Son pasos de una sola vez por máquina.

El resto —contenedores, volúmenes, sidecars de respaldo— es automático y está
en [`README.md`](README.md).

> **Léelo entero antes de ejecutar nada.** Hay un punto sin retorno: si
> pierdes la contraseña del remoto `crypt`, los datos respaldados son
> **matemáticamente irrecuperables**. No hay soporte, ni recuperación, ni
> "olvidé mi contraseña". Ni Google ni nadie puede leerlos, que es justo lo
> que queremos y justo lo que hace que perderlos sea definitivo.

---

## Requisitos del host

| Requisito | Por qué | Comprobación |
|---|---|---|
| Docker (OrbStack o Docker Desktop) | Lo ejecuta todo | `docker version` |
| Terminal con **OSC 52** | Copiar al portapapeles del Mac desde dentro del contenedor | Kitty, WezTerm, Ghostty, Alacritty |
| **Nerd Font** *(opcional)* | Iconos de Neovim/LazyVim. Solo si pones `NERD_FONT=true` en `.env` | `brew install --cask font-jetbrains-mono-nerd-font` |
| Cuenta de Google con Drive | Destino del respaldo | — |

**No hace falta instalar rclone.** Todo corre en contenedores efímeros a
través de [`rclone-setup.sh`](rclone-setup.sh).

---

## Los tres secretos

Al terminar tendrás tres secretos distintos. Confundirlos es el error más
común, así que conviene tenerlos claros desde el principio:

| # | Secreto | Protege | Si lo pierdes |
|---|---|---|---|
| 1 | **Contraseña del `crypt`** | El contenido de los archivos y los nombres | Los datos respaldados se pierden **para siempre** |
| 2 | **Salt del `crypt`** | Refuerza la derivación de la clave | Igual que el anterior: sin él no se descifra |
| 3 | **Contraseña del `rclone.conf`** | El archivo de configuración local | Molesto, no fatal: se rehace la configuración desde 1 y 2 |

Los tres van a NordPass. Los dos primeros van **además en papel**.

---

## Paso 1 — Crear el remoto `gdrive` (OAuth)

```bash
cd .devcontainer
./rclone-setup.sh config
```

Se abre la sesión interactiva de rclone dentro de un contenedor. Responde:

```
n) New remote
name> gdrive
Storage> drive                    (Google Drive)
client_id>                        (vacío: usa el de rclone, sirve de sobra)
client_secret>                    (vacío)
scope> 1                          (drive — acceso completo)
service_account_file>             (vacío)
Edit advanced config? n
Use web browser to automatically authenticate? y
```

rclone intentará abrir un navegador, **fallará** (no hay ninguno en el
contenedor) y escribirá algo así:

```
Please go to the following link: http://127.0.0.1:53682/auth?state=...
```

**Abre ese enlace tú, en el navegador del Mac.** Autoriza la cuenta. Google
redirige a `127.0.0.1:53682`, el script tiene montado un puente hasta el
contenedor y rclone recoge el token solo.

> **Por qué hace falta el puente.** rclone escucha su callback en la
> *loopback del contenedor*, mientras que `docker run -p` publica sobre
> `eth0`. Sin un `socat` que una las dos, la redirección de Google muere en
> el navegador y el `rclone config` se queda esperando un código que nunca
> llega. `rclone-setup.sh` lo monta por ti; verificado con rclone v1.75.0
> sobre OrbStack.

Termina con `Configure this as a Shared Drive? n` y `y) Yes this is OK`.

---

## Paso 2 — Crear el remoto `crypt` (uno por cliente)

**Un crypt por cliente**, con contraseña y salt propios. Así el respaldo de un
cliente no se puede descifrar con las claves de otro, aunque los dos vivan en
la misma cuenta de Drive.

En la misma sesión de `rclone config`:

```
n) New remote
name> crypt-capta                          <- el nombre lleva el cliente
Storage> crypt
remote> gdrive:respaldo-capta              <- carpeta destino DENTRO de gdrive
filename_encryption> 1                     (standard: cifra también los nombres)
directory_name_encryption> 1               (true)
```

Y aquí viene lo que importa:

```
Password or pass phrase for encryption.
y) Yes, type in my own password
g) Generate random password                <- ELIGE g
q) Quit
y/g/q> g
Bits> 128
Use this password? y

Password or pass phrase for salt. Optional but recommended.
y) Yes, type in my own password
g) Generate random password                <- ELIGE g TAMBIÉN AQUÍ
n) No, leave this optional password blank
y/g/n> g
Bits> 128
Use this password? y
```

**Usa `g` en las dos.** Una contraseña inventada por una persona tiene mucha
menos entropía real que 128 bits aleatorios, y aquí no hay nada que ganar
recordándola de memoria: va a vivir en un gestor de contraseñas de todos modos.

> ### Punto sin retorno
>
> rclone te enseña la contraseña y el salt generados **una sola vez**, en esta
> pantalla. **Cópialos ahora**, antes de pulsar nada más. Cuando la sesión
> termine y cifres el `rclone.conf`, recuperarlos requiere la contraseña del
> `.conf`; y si esa también se pierde, se acabó.

Repite este paso por cada cliente: `crypt-otrocliente` → `gdrive:respaldo-otrocliente`.

Sal con `q) Quit config`.

---

## Paso 3 — Guardar los secretos

Antes de seguir. No después, no "luego lo apunto".

**En NordPass**, tres entradas separadas:

| Entrada | Contenido |
|---|---|
| `rclone crypt-capta — password` | La contraseña del paso 2 |
| `rclone crypt-capta — salt` | El salt del paso 2 |
| `rclone.conf — password` | La del paso 4 (aún no la tienes) |

**En papel**, la contraseña y el salt de cada crypt. Guardado físicamente
donde guardarías un pasaporte. Esto no es paranoia de más: NordPass es un
único punto de fallo, y a diferencia de una contraseña de un servicio web,
aquí no existe un botón de "recuperar cuenta".

---

## Paso 4 — Cifrar el `rclone.conf`

Sin este paso, cualquiera con acceso de lectura a tu Mac se lleva el respaldo
entero. El archivo guarda la contraseña del crypt "ofuscada" con una clave
**estática y pública** —está en el código fuente de rclone, es reversible en
un segundo— y el token OAuth de Google ni siquiera eso: va en claro.

En una sesión de `./rclone-setup.sh config`:

```
s) Set configuration password
a) Add password
Enter NEW configuration password:
Confirm NEW configuration password:
```

Usa una contraseña larga generada por NordPass y guárdala ahí mismo (entrada 3
de la tabla anterior).

Comprueba:

```bash
./rclone-setup.sh check
```

Debe decir `OK: cifrado` y listar `gdrive:` y `crypt-capta:`.

---

## Paso 5 — Inyectar la contraseña a los sidecars

Los sidecars de respaldo necesitan descifrar el `rclone.conf` al arrancar, así
que hay que pasarles la contraseña del paso 4. Va en un archivo **fuera del
repositorio**:

```bash
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/devcontainer.env <<'EOF'
RCLONE_CONFIG_PASS=la-contraseña-del-paso-4
EOF
chmod 600 ~/.config/rclone/devcontainer.env
```

El `docker-compose.yml` lo consume así:

```yaml
env_file:
  - ${HOME}/.config/rclone/devcontainer.env
```

Dos trampas que este diseño esquiva a propósito, y conviene no "arreglarlas"
más adelante sin leer esto:

- **`~` no se expande en compose.** `env_file: ~/.config/...` no falla con un
  error claro: busca un directorio llamado `~` dentro de `.devcontainer/`. Hay
  que escribir `${HOME}`.
- **`environment:` gana a `env_file:`.** Si además declararas
  `RCLONE_CONFIG_PASS: ${RCLONE_CONFIG_PASS}` en `environment:`, y la variable
  no estuviera exportada en la shell, compose la interpola como **cadena
  vacía** y pisa el valor bueno del `env_file`. El síntoma es un sidecar que
  reinicia en bucle quejándose de la contraseña mientras el archivo la tiene
  bien. Por eso se usa **un solo mecanismo**: `env_file`, nunca los dos.

---

## Paso 6 — Prueba de restauración (no es opcional)

Un respaldo que nunca se ha restaurado no es un respaldo: es una carpeta con
ruido en Google Drive. Este paso es el único que demuestra que el sistema
funciona.

```bash
./rclone-setup.sh restore-test
```

Arranca una sesión de rclone con un directorio de configuración **vacío y
temporal**, que ignora por completo tu `rclone.conf`. Ahí reconstruyes
`gdrive` (OAuth otra vez) y el crypt, y listas el contenido.

**Las reglas del simulacro:**

1. La contraseña y el salt los sacas de **NordPass**, no del historial del
   terminal ni de scrollback. Si te apoyas en algo que un formateo se llevaría
   por delante, la prueba no vale.
2. Lo ideal es hacerlo en **otra máquina**, o al menos con otro usuario de
   macOS. En tu portátil de siempre es fácil que algo funcione por una razón
   que no estarás replicando el día que importe.
3. Al terminar, `rclone ls crypt-capta:workspace` debe devolver archivos con
   nombres legibles.

Repítelo cada pocos meses, y sin falta después de cambiar cualquier clave.

---

## Lo que verás en Google Drive

Carpetas y archivos con nombres como `qmt3nk8h1s5v...`. **Es correcto.** Con
`filename_encryption: standard` se cifran también los nombres, de modo que ni
Google ni nadie con acceso a la cuenta puede deducir a qué cliente pertenece
un archivo, cómo se llama o de qué trata.

El corolario incómodo: **la interfaz web de Drive no te sirve para recuperar
nada**. La única vista legible pasa por rclone con las claves. Es exactamente
el motivo del paso 6.

---

## Apéndice A — Límites de inotify (corrección importante)

Los sidecars vigilan cambios con `inotify`, que tiene un límite de directorios
observados. Al agotarse, el vigilante muere y el respaldo se para en silencio.

**En macOS, `sudo sysctl fs.inotify.max_user_watches` no hace nada.** Ese
parámetro no existe en Darwin: el comando responde `unknown oid` y no cambia
nada. inotify es una API del kernel de **Linux**, y en un Mac el Linux que
importa es el de la VM de Docker, no el sistema operativo del portátil.

**Consultar el valor real** (funciona con cualquier runtime):

```bash
docker run --rm --privileged alpine sysctl fs.inotify.max_user_watches
```

**Subirlo, según el runtime:**

- **OrbStack** — entra en la VM y persístelo:
  ```bash
  orb -m docker sudo sh -c 'echo fs.inotify.max_user_watches=1048576 >> /etc/sysctl.conf'
  ```
- **Docker Desktop** — la VM se recrea al reiniciar, así que un `sysctl`
  suelto no sobrevive. Se declara en Settings → Docker Engine, o se aplica en
  cada arranque con un contenedor privilegiado:
  ```bash
  docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_watches=1048576
  ```

**En esta máquina ya está bien.** Medido el 2026-08-22 sobre OrbStack:
`fs.inotify.max_user_watches = 1048576` y `max_user_instances = 1048576`. No
hay nada que tocar; queda documentado para el día que cambie el runtime o el
portátil.

---

## Apéndice B — Migrar el volumen de Claude Code

El esquema anterior guardaba la sesión de Claude Code en un volumen con otro
nombre. El nuevo usa `claude-${CLIENTE}`. Si el volumen viejo sigue por ahí,
cópialo **antes** de levantar el devcontainer nuevo — si no, arrancará vacío y
pedirá `/login`:

```bash
# 1. Copia de seguridad primero (contiene credenciales: trátala como un secreto)
CLAUDE_VOLUME=capta-claude-config ./claude-volume.sh backup ~/backups

# 2. Migración al nombre nuevo
docker volume create claude-capta
docker run --rm -v capta-claude-config:/src:ro -v claude-capta:/dst alpine:3.20 \
  sh -c 'cp -a /src/. /dst/ && chown -R 1000:1000 /dst'

# 3. Comprobación: debe decir "credenciales: sí"
CLAUDE_VOLUME=claude-capta ./claude-volume.sh info
```

**No ejecutes `docker volume prune` hasta haber comprobado el paso 3.** Se
lleva por delante cualquier volumen sin contenedor asociado, y con él el login
y todo el historial de conversaciones.

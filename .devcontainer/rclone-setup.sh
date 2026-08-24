#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────────────
#  Ayudante para la configuración manual de rclone. Se ejecuta EN EL HOST.
#
#  No instala rclone en la máquina: todo corre dentro de un contenedor
#  efímero (rclone/rclone:latest). Lo único que queda en el host es el
#  archivo de configuración, en ~/.config/rclone/rclone.conf, cifrado.
#
#    ./rclone-setup.sh config        sesión interactiva de `rclone config`
#    ./rclone-setup.sh check         estado: remotos, cifrado del .conf
#    ./rclone-setup.sh ls <remoto>   lista un remoto (p. ej. crypt-<cliente>:)
#    ./rclone-setup.sh restore-test  simulacro de restauración en limpio
#
#  Los pasos y el porqué de cada uno están en CONFIGURACION-MANUAL.md.
#  Lee ese documento antes de ejecutar nada de aquí.
# ───────────────────────────────────────────────────────────────────────────
set -euo pipefail

IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"
CONF_DIR="${RCLONE_CONF_DIR:-${HOME}/.config/rclone}"
AUTH_PORT=53682   # Fijo: es el redirect URI que Google tiene registrado.

die() { echo "error: $*" >&2; exit 1; }
command -v docker >/dev/null || die "docker no está en el PATH"

# ── El puente de OAuth ─────────────────────────────────────────────────────
# rclone levanta su servidor de callback en 127.0.0.1:53682 DENTRO del
# contenedor, así que `docker run -p 53682:53682` por sí solo no lo alcanza:
# el publicado entra por eth0, no por la loopback del contenedor. socat hace
# de puente eth0:53682 -> 127.0.0.1:53682. Se enlaza a la IP concreta de
# eth0, no a 0.0.0.0, porque si no chocaría con el propio rclone.
_inner_script() {
  cat <<'INNER'
#!/bin/sh
set -e
if ! command -v socat >/dev/null 2>&1; then apk add -q socat; fi
IP="$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)"
# stderr a /dev/null: en cuanto rclone recibe el código cierra su servidor,
# y el navegador suele mandar una conexión más (el favicon). socat la
# intenta reenviar y escupe "Connection refused", que parece un fallo grave
# y no lo es: para entonces la autenticación ya ha terminado bien.
socat "TCP-LISTEN:53682,fork,reuseaddr,bind=${IP}" TCP:127.0.0.1:53682 2>/dev/null &
sleep 1
exec rclone "$@"
INNER
}

# run_rclone <interactivo:0|1> <args...>
run_rclone() {
  local interactive="$1"; shift
  local tmp; tmp="$(mktemp -t rclone-inner)"
  _inner_script >"$tmp"; chmod +x "$tmp"

  local flags=(--rm -v "${CONF_DIR}:/config/rclone" -v "${tmp}:/inner.sh:ro")
  if [ "$interactive" = "1" ]; then
    flags+=(-it -p "${AUTH_PORT}:${AUTH_PORT}")
  fi

  # `|| rc=$?` en vez de un trap RETURN: el trap se queda instalado y vuelve
  # a dispararse cuando retorna la función llamante, donde $tmp ya no existe
  # y `set -u` mata el script. Y sin el `||`, `set -e` saldría antes del `rm`.
  local rc=0
  docker run "${flags[@]}" --entrypoint sh "$IMAGE" /inner.sh "$@" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

port_libre() {
  if lsof -nP -iTCP:"$AUTH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "el puerto ${AUTH_PORT} está ocupado; ciérralo (lo necesita el callback de Google)"
  fi
}

cmd_config() {
  mkdir -p "$CONF_DIR"
  port_libre
  cat <<'AVISO'
─────────────────────────────────────────────────────────────────────────────
 Sesión interactiva de rclone.

 Cuando cree el remoto de Google Drive y pregunte por el navegador, responde
 que SÍ. No podrá abrirlo (no hay navegador en el contenedor) pero imprimirá
 un enlace http://127.0.0.1:53682/auth?state=... — ábrelo TÚ en el navegador
 del Mac. El puente ya está montado, así que la redirección vuelve al
 contenedor y rclone recoge el token.

 Para el remoto `crypt`: contraseña Y salt con la opción `g` (aleatoria,
 128 bits). No inventes contraseñas a mano. Apunta las dos ANTES de cerrar.
─────────────────────────────────────────────────────────────────────────────
AVISO
  run_rclone 1 config
}

cmd_check() {
  [ -f "${CONF_DIR}/rclone.conf" ] || die "no existe ${CONF_DIR}/rclone.conf (ejecuta: $0 config)"
  echo "Config:  ${CONF_DIR}/rclone.conf"
  echo "Permisos: $(stat -f '%Sp %Su' "${CONF_DIR}/rclone.conf" 2>/dev/null || echo '?')"
  echo
  echo "── ¿Está cifrado el archivo de configuración? ──"
  # Solo interesa el código de salida: en caso de fallo rclone escupe además
  # el `usage` completo del subcomando, que aquí solo es ruido.
  if run_rclone 0 config encryption check >/dev/null 2>&1; then
    echo "OK: cifrado."
  else
    echo "AVISO: el .conf NO está cifrado. La contraseña del crypt que guarda"
    echo "       dentro solo está ofuscada con una clave estática (pública), y"
    echo "       el token OAuth de Google está en claro. Cífralo:"
    echo "         $0 config   ->  s) Set configuration password"
  fi
  echo
  echo "── Remotos configurados ──"
  run_rclone 0 listremotes 2>&1 || true
}

cmd_ls() {
  local remoto="${1:-}"
  [ -n "$remoto" ] || die "uso: $0 ls <remoto:ruta>   (p. ej. crypt-<cliente>:claude)"
  run_rclone 0 ls "$remoto"
}

cmd_restore_test() {
  cat <<'AVISO'
─────────────────────────────────────────────────────────────────────────────
 SIMULACRO DE RESTAURACIÓN

 Usa un directorio de configuración VACÍO y temporal: ignora por completo tu
 rclone.conf actual. Es la única forma de comprobar que podrías recuperar los
 datos desde cero tras formatear el portátil.

 Vas a necesitar, sacadas de NordPass (NO del historial del terminal):
   1. La contraseña del remoto crypt
   2. El salt del remoto crypt
 Y volver a autorizar Google Drive por OAuth.

 Si no puedes completar esto, tu respaldo no existe: solo tienes datos
 cifrados que nadie sabe descifrar.
─────────────────────────────────────────────────────────────────────────────
AVISO
  printf "¿Continuar? [y/N] "; read -r ans
  case "$ans" in y|Y|s|S|si|SI|yes) ;; *) echo "cancelado"; exit 0 ;; esac

  local tmpconf; tmpconf="$(mktemp -d -t rclone-restore)"
  echo
  echo "Directorio de configuración temporal: ${tmpconf}"
  echo "Reconstruye ahí el remoto de almacenamiento y UN crypt, con la"
  echo "contraseña y el salt sacados de NordPass. Luego sal con 'q'."
  echo
  port_libre
  CONF_DIR="$tmpconf"   # run_rclone monta $CONF_DIR; así el simulacro no ve
                        # ni por accidente el rclone.conf real.
  run_rclone 1 config

  # ── La verificación ─────────────────────────────────────────────────────
  # Va AQUÍ y no en las manos del usuario. Antes el script abría rclone,
  # borraba el directorio temporal al salir y daba el simulacro por hecho sin
  # haber leído un solo archivo: te hacía repetir todo el trabajo y tiraba la
  # única evidencia que importaba.
  echo
  local remotos
  remotos="$(run_rclone 0 listremotes 2>/dev/null | grep -v '^$' || true)"
  if [ -z "$remotos" ]; then
    echo "No creaste ningún remoto: no hay nada que verificar."
    rm -rf "$tmpconf"
    return 1
  fi

  echo "Remotos reconstruidos:"
  echo "$remotos" | sed 's/^/   /'
  echo
  printf "¿Cuál contiene los datos a recuperar? (p. ej. crypt-x-workspace:) "
  read -r remoto
  [ -n "$remoto" ] || { echo "cancelado"; rm -rf "$tmpconf"; return 1; }
  case "$remoto" in *:) ;; *) remoto="${remoto}:" ;; esac

  echo
  echo "── Listando ${remoto} con las claves de NordPass ──"
  local salida rc=0
  salida="$(run_rclone 0 ls "$remoto" 2>&1)" || rc=$?
  local n
  n="$(printf '%s\n' "$salida" | grep -cE '^[[:space:]]*[0-9]+ ' || true)"

  if [ "$rc" -eq 0 ] && [ "$n" -gt 0 ]; then
    printf '%s\n' "$salida" | head -15 | sed 's/^/   /'
    [ "$n" -gt 15 ] && echo "   ... y $((n - 15)) más"
    echo
    echo "SIMULACRO SUPERADO: ${n} archivos recuperados con nombres legibles,"
    echo "usando solo lo que guardaste fuera de esta máquina."
    rm -rf "$tmpconf"
  else
    printf '%s\n' "$salida" | tail -5 | sed 's/^/   /'
    echo
    echo "SIMULACRO FALLIDO. Puede ser un error al teclear la contraseña o el"
    echo "salt, o una ruta de remoto distinta a la original. Si las claves de"
    echo "NordPass no son las buenas, esos datos NO son recuperables: revísalo"
    echo "AHORA, que todavía puedes volver a subirlos con claves nuevas."
    echo
    echo "La configuración temporal se conserva para que reintentes sin"
    echo "rehacer el OAuth:  RCLONE_CONF_DIR='${tmpconf}' $0 ls ${remoto}"
  fi
}

case "${1:-check}" in
  config)       shift || true; cmd_config ;;
  check)        shift || true; cmd_check ;;
  ls)           shift || true; cmd_ls "$@" ;;
  restore-test) shift || true; cmd_restore_test ;;
  -h|--help|help) sed -n '2,16p' "$0" ;;
  *) die "comando desconocido '${1}'. Usa: config | check | ls | restore-test" ;;
esac

#!/bin/bash
# devkit (DEVKIT-259): reemplaza el socat que reenviaba el 3001 tal cual a
# dev:3001. openvscode-server nunca crea el almacén persistente de secretos
# del workbench web (la sesión de GitHub Pull Requests, entre otros) porque
# le falta la cookie vscode-secret-key-path y el endpoint que la cifra; este
# script los agrega en el camino, sin tocar el binario del editor.
#
# socat invoca este script una vez por conexión (EXEC:, ver entrypoint.sh),
# con stdin/stdout atados al socket del navegador. Solo dos casos se tratan
# distinto; todo lo demás -assets, /callback, el websocket del editor- se
# reenvía byte a byte hacia dev:3001, sin entender su contenido: un pipe
# crudo ya es transparente para WebSocket, no hace falta interpretarlo.
#
#   GET|HEAD /  (con o sin ?tkn=): se agrega Set-Cookie a la respuesta.
#   POST /devkit/secret-key: no llega a dev. Reenvía la cookie vscode-tkn
#     (la de sesión de openvscode-server, verificada con curl contra 1.109.5)
#     a dev:$DIGEST_PORT, que solo responde el dígesto si coincide con el
#     token de conexión; sin cookie o si no coincide, 403 (DEVKIT-259, H4:
#     la comparación queda en dev, este script nunca guarda el token, solo
#     lo relee de la petición y lo reenvía).
#   Éxito: 32 bytes = SHA-256 del token, consultado en dev:$DIGEST_PORT en
#     cada llamada: no se cachea, así que sobrevive a un proxy recién
#     recreado sin volumen propio.
#
# Cada request que no sea el especial de arriba se fuerza a "Connection:
# close" (salvo un upgrade de WebSocket, que debe seguir vivo): este parser
# de línea solo reconoce una petición por conexión, así que forzar el cierre
# evita tener que interpretar una segunda petición dentro del mismo socket.
set -u
UPSTREAM_HOST="${DEVKIT_SHIM_UPSTREAM:-dev}"
UPSTREAM_PORT="${DEVKIT_SHIM_UPSTREAM_PORT:-3001}"
DIGEST_PORT="${DEVKIT_SHIM_DIGEST_PORT:-3002}"

# hex_to_bin <64 hex chars> -> 32 bytes crudos en stdout. Sin xxd/openssl:
# alpine no los trae por defecto y no vale la pena sumarlos por esto.
hex_to_bin() {
  local hex="$1" i=0 len=${#hex} byte oct
  while [ "$i" -lt "$len" ]; do
    byte="${hex:$i:2}"
    oct=$(printf '%03o' "$((16#$byte))")
    printf "\\$oct"
    i=$((i + 2))
  done
}

# --- Línea de petición -------------------------------------------------------
IFS= read -r request_line || exit 0
request_line="${request_line%$'\r'}"
method="${request_line%% *}"
rest="${request_line#* }"
path="${rest%% *}"
path_sin_query="${path%%\?*}"

# --- Encabezados: se guardan en un arreglo para poder filtrar Connection
# después de ver si hubo Upgrade, sin importar el orden en que llegaron. ---
headers=()
content_length=""
es_upgrade=0
tkn_cookie=""
while IFS= read -r line; do
  line="${line%$'\r'}"
  [ -z "$line" ] && break
  headers+=("$line")
  low="${line,,}"
  case "$low" in
    content-length:*) content_length="$(printf '%s' "${line#*:}" | tr -dc '0-9')" ;;
    upgrade:*) es_upgrade=1 ;;
    cookie:*)
      # vscode-tkn: cookie de sesión de openvscode-server (verificada con
      # curl contra 1.109.5), entre las demás separadas por "; ".
      cookie_rest="${line#*:}"
      cookie_rest="${cookie_rest# }"
      while [ -n "$cookie_rest" ]; do
        cookie_par="${cookie_rest%%;*}"
        cookie_par="${cookie_par# }"
        case "$cookie_par" in
          vscode-tkn=*) tkn_cookie="${cookie_par#vscode-tkn=}" ;;
        esac
        [ "$cookie_rest" = "$cookie_par" ] && break
        cookie_rest="${cookie_rest#*;}"
      done
      ;;
  esac
done

# --- Caso especial: la clave del almacén de secretos ------------------------
if [ "$method" = "POST" ] && [ "$path_sin_query" = "/devkit/secret-key" ]; then
  if [ -n "$content_length" ] && [ "$content_length" -gt 0 ] 2>/dev/null; then
    dd bs=1 count="$content_length" >/dev/null 2>&1
  fi
  hex="$(printf '%s' "$tkn_cookie" | timeout 3 socat -t 2 - "TCP:${UPSTREAM_HOST}:${DIGEST_PORT}" 2>/dev/null | tr -dc '0-9a-fA-F')"
  if [ "${#hex}" = 64 ]; then
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 32\r\nConnection: close\r\n\r\n'
    hex_to_bin "$hex"
  else
    printf 'HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'
  fi
  exit 0
fi

# --- Todo lo demás: relé hacia dev, con la cookie si es la raíz -------------
# Nada de coproc: sus descriptores no sobreviven a un `&` ni a un subshell de
# tubería en bash (probado a mano, DEVKIT-259), así que el relé usa tuberías
# normales -socat habla con dev y con nuestro stdin/stdout directamente,
# nunca con un fd intermedio que bash pueda cerrar solo.
fwd="$request_line"$'\r\n'
for line in "${headers[@]}"; do
  case "${line,,}" in
    connection:* | keep-alive:*) [ "$es_upgrade" = 1 ] && fwd+="$line"$'\r\n' ;;
    *) fwd+="$line"$'\r\n' ;;
  esac
done
[ "$es_upgrade" = 1 ] || fwd+="Connection: close"$'\r\n'
fwd+=$'\r\n'

enviar() {
  printf '%s' "$fwd"
  if [ -n "$content_length" ] && [ "$content_length" -gt 0 ] 2>/dev/null; then
    dd bs=1 count="$content_length" 2>/dev/null
  fi
  # Navegador -> dev: todo lo que llegue después (frames de WebSocket, sobre
  # todo) pasa crudo. `read` nunca lee de más, así que esto arranca justo
  # donde se quedó la lectura de encabezados/cuerpo de arriba.
  cat
}

if { [ "$method" = "GET" ] || [ "$method" = "HEAD" ]; } && [ "$path_sin_query" = "/" ]; then
  # Se usa enviar (no un printf suelto) para no cerrar el lado de escritura
  # hacia dev: un printf que termina hace EOF en el pipe, socat responde con
  # un half-close hacia dev, y Node (httpAllowHalfOpen=false) puede cortar su
  # propia respuesta si el handler todavía la está armando (DEVKIT-259, H1).
  # La raíz nunca lleva cuerpo ni upgrade, así que esta rama sí puede leer la
  # respuesta en el propio script (tercer eslabón de la tubería) para
  # agregar la cookie.
  enviar | socat - "TCP:${UPSTREAM_HOST}:${UPSTREAM_PORT}" | {
    resp=""
    while IFS= read -r line; do
      line="${line%$'\r'}"
      resp+="$line"$'\r\n'
      [ -z "$line" ] && break
    done
    resp="${resp%$'\r\n'}"
    printf '%sSet-Cookie: vscode-secret-key-path=/devkit/secret-key; Path=/; SameSite=Lax\r\n\r\n' "$resp"
    cat
  }
else
  # socat escribe la respuesta directo en su stdout heredado (el socket del
  # navegador): no pasa por bash, así que un WebSocket queda intacto.
  enviar | socat - "TCP:${UPSTREAM_HOST}:${UPSTREAM_PORT}"
fi

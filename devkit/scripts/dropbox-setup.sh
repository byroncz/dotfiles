#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Autoriza rclone contra una app propia de Dropbox (tipo "App folder") sin
#  navegador en el contenedor: Dropbox muestra un código, y este script lo
#  cambia por un refresh token con la API. Resultado: la configuración de
#  rclone en base64, lista para guardarla en Bitwarden como rclone_conf_b64.
#
#  Requisitos previos (una vez, en https://www.dropbox.com/developers/apps):
#    Create app -> Scoped access -> App folder -> nombre (p. ej. devkit-<tu usuario>)
#    Pestaña Permissions: files.metadata.read/write y files.content.read/write -> Submit
#    Pestaña Settings: App key y App secret
# ---------------------------------------------------------------------------
set -euo pipefail

printf 'App key de Dropbox: '; read -r APP_KEY
printf 'App secret de Dropbox (no se muestra): '; read -rs APP_SECRET; echo
[ -n "$APP_KEY" ] && [ -n "$APP_SECRET" ] || { echo "faltan datos" >&2; exit 1; }

cat <<EOF

1. Abre esta dirección en Safari, en el Mac, y pulsa "Permitir":

https://www.dropbox.com/oauth2/authorize?client_id=${APP_KEY}&response_type=code&token_access_type=offline

2. Dropbox mostrará un código. Cópialo y pégalo aquí.

EOF
printf 'Código: '; read -r CODE
CODE="$(printf '%s' "$CODE" | tr -d '[:space:]')"

resp="$(curl -fsS https://api.dropboxapi.com/oauth2/token \
  -u "${APP_KEY}:${APP_SECRET}" \
  -d "code=${CODE}" -d grant_type=authorization_code)" \
  || { echo "Dropbox rechazó el código. Vuelve a ejecutar el script y usa un código nuevo." >&2; exit 1; }

refresh="$(printf '%s' "$resp" | jq -r '.refresh_token // empty')"
[ -n "$refresh" ] || { echo "respuesta sin refresh_token: $resp" >&2; exit 1; }

conf_dir="$HOME/.config/rclone"; mkdir -p "$conf_dir"
conf="$conf_dir/rclone.conf"
# expiry en el pasado obliga a rclone a renovar con el refresh_token al primer uso.
cat > "$conf" <<EOF
[dropbox]
type = dropbox
client_id = ${APP_KEY}
client_secret = ${APP_SECRET}
token = {"access_token":"","token_type":"bearer","refresh_token":"${refresh}","expiry":"2000-01-01T00:00:00Z"}
EOF
chmod 600 "$conf"

echo
echo "Probando acceso..."
rclone mkdir dropbox:devkit
rclone lsd dropbox: >/dev/null && echo "Dropbox responde. Carpeta de la app lista."

echo
echo "Guarda en Bitwarden un secreto llamado  rclone_conf_b64  con este valor (una sola línea):"
echo
base64 -w0 "$conf"
echo
echo

#!/usr/bin/env bash
# Dígesto del token del editor para el almacén persistente de secretos del
# workbench web (DEVKIT-259). socat lo lanza una vez por conexión en dev:3002
# (EXEC:, ver entrypoint.sh), con stdin y stdout atados al socket del shim
# del proxy (devkit/proxy/proxy-shim.sh).
#
# El shim manda como cuerpo la cookie vscode-tkn que trajo el navegador. Si
# coincide con el token de conexión real, responde su SHA-256 en hex; si no
# coincide, no responde nada y el shim contesta 403 (DEVKIT-259, H4). La
# comparación vive en dev, donde vive el token: el proxy lo ve de paso en la
# petición, pero nunca lo guarda.
#
# Es un archivo propio y no un SYSTEM:"..." dentro de entrypoint.sh para que
# devkit-test.sh pruebe este mismo código, no una copia (DEVKIT-259, H8).
# Uso: vscode-secret-digest.sh <archivo-token>
set -u

token_file="${1:?uso: vscode-secret-digest.sh <archivo-token>}"
presentado="$(cat)"
[ -s "$token_file" ] || exit 0
if [ "$presentado" = "$(cat "$token_file")" ]; then
  sha256sum "$token_file" | cut -c1-64
fi

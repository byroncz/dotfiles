#!/bin/sh
# Construye la lista blanca final y arranca tinyproxy en primer plano.
#   DEVKIT_ALLOW_DOMAINS  dominios extra del proyecto, separados por espacios
#   DEVKIT_NET_OPEN=1     red abierta para depurar (registra, no bloquea)
set -eu
conf=/etc/tinyproxy/tinyproxy.conf
{
  grep -v '^\s*#' /etc/tinyproxy/allowlist.base | grep -v '^\s*$'
  for d in ${DEVKIT_ALLOW_DOMAINS:-}; do echo "$d"; done
} > /etc/tinyproxy/allowlist

if [ "${DEVKIT_NET_OPEN:-0}" = "1" ]; then
  echo "FilterDefaultDeny No" >> "$conf"
  echo "[proxy] RED ABIERTA: solo registra, no bloquea" >&2
else
  echo "FilterDefaultDeny Yes" >> "$conf"
  echo "[proxy] lista blanca activa: $(wc -l < /etc/tinyproxy/allowlist) dominios" >&2
fi
touch /var/log/tinyproxy/tinyproxy.log; chown tinyproxy:tinyproxy /var/log/tinyproxy/tinyproxy.log
# Retorno OAuth de MCP: lo que llega del Mac al 45454 va al contenedor dev.
# Puerto fijo, ajeno a la familia 54545/54546/... de DEVKIT_OAUTH_PORT
# (DEVKIT-155, H5).
socat TCP-LISTEN:45454,fork,reuseaddr TCP:dev:45454 &
# Editor VS Code: lo que llega del Mac al 3001 ya no se reenvía tal cual
# (DEVKIT-259). El shim habla HTTP y WebSocket, agrega la cookie del
# almacén de secretos en la respuesta de la raíz y responde
# POST /devkit/secret-key sin llegar a dev; todo lo demás pasa crudo.
# ,pipes y no el socketpair por defecto de EXEC: con socat 1.8.1.3 (alpine) el
# socat interno del shim no lee la petición hasta que el navegador cierra la
# conexión, y la pestaña queda cargando para siempre (DEVKIT-264).
socat TCP-LISTEN:3001,fork,reuseaddr,bind=0.0.0.0 EXEC:/opt/devkit/proxy-shim.sh,pipes &
exec tinyproxy -d -c "$conf"

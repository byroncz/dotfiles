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
exec tinyproxy -d -c "$conf"

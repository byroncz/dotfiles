#!/usr/bin/env bash
# Muestra los dominios que el proxy rechazó en la ventana reciente y confirma
# con curl cuál sigue bloqueado ahora mismo. El log es del contenedor
# completo, no de la sesión actual: sin ventana ni confirmación, un rechazo
# de hace días aparece junto a uno de ahora y produce un bloqueo falso
# (DEVKIT-38, con `open-vsx.org` ya resuelto días antes).
set -euo pipefail

LOG="/var/log/devkit-proxy/tinyproxy.log"
WINDOW_MIN="${DEVKIT_NET_DENIED_WINDOW:-15}"

if [ ! -f "$LOG" ]; then
  echo "sin registro del proxy"
  exit 0
fi

cutoff=$(date -d "-${WINDOW_MIN} minutes" +%s)

domains=$(grep -h "Rejected\|Denied\|refused" "$LOG" 2>/dev/null | while IFS= read -r line; do
  ts=$(printf '%s' "$line" | grep -oE '[A-Z][a-z]{2} +[0-9]{1,2} [0-9:.]+')
  [ -n "$ts" ] || continue
  epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
  [ "$epoch" -ge "$cutoff" ] || continue
  printf '%s\n' "$line" | grep -oE '"[^"]+"' | tr -d '"'
done | sort -u)

if [ -z "$domains" ]; then
  echo "sin rechazos en los últimos ${WINDOW_MIN} min"
  exit 0
fi

while IFS= read -r domain; do
  err=$(curl -sS --connect-timeout 3 -o /dev/null "https://$domain" 2>&1) && ok=1 || ok=0
  if [ "$ok" = 1 ]; then
    echo "$domain: ya no está bloqueado; no hace falta añadirlo a domains"
  elif printf '%s' "$err" | grep -q "tunnel failed"; then
    echo "$domain: sigue bloqueado por el proxy"
  else
    echo "$domain: no se pudo confirmar ($err)"
  fi
done <<<"$domains"

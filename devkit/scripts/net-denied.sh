#!/usr/bin/env bash
# Muestra los destinos que el proxy rechazó. Útil cuando algo dice
# "connection refused": el dominio falta en la lista blanca.
# El proxy escribe su log en un volumen compartido, montado aquí en solo lectura.
grep -h "Rejected\|Denied\|refused" /var/log/devkit-proxy/tinyproxy.log 2>/dev/null | tail -n 30 || echo "sin registro del proxy"

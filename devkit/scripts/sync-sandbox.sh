#!/usr/bin/env bash
# Sube sandbox.local a Dropbox cada 60 s, solo si hubo cambios.
#   $1 directorio local   $2 remoto rclone (ej. dropbox:devkit/sandbox.local)
# Una sola dirección: el contenedor escribe, Dropbox recibe. --backup-dir
# guarda en Dropbox lo que se borre localmente, por fecha.
set -u
local_dir="$1"; remote="$2"
stamp="$local_dir/.last-sync"
[ -f "$stamp" ] || touch -d '1970-01-01' "$stamp"
while true; do
  if [ -n "$(find "$local_dir" -newer "$stamp" -not -name '.last-sync' -print -quit 2>/dev/null)" ]; then
    touch "$stamp"
    rclone sync "$local_dir" "$remote" \
      --exclude '.last-sync' --exclude '.restored' \
      --backup-dir "${remote%/*}/.trash/$(date -u +%Y%m%d)" \
      --transfers 2 --checkers 4 --quiet \
      || echo "$(date -u +%FT%TZ) sync falló" >&2
  fi
  sleep 60
done

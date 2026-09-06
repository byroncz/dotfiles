#!/usr/bin/env bash
# Cada 5 min: ¿hay PRs mergeados de cards que siguen "En revisión"?
# Si los hay, lanza task-close en modo headless.
# Pendiente hasta que existan las skills (fase 3 del plan). Por ahora solo
# registra los PRs mergeados de la cuenta máquina en las últimas 24 h.
set -u
cd /workspace 2>/dev/null || exit 0
while true; do
  if [ -d .git ]; then
    gh pr list --state merged --limit 20 --json number,title,mergedAt \
      --jq '.[] | select(.mergedAt > (now - 86400 | todate)) | "\(.number)\t\(.title)"' 2>/dev/null \
      | while IFS=$'\t' read -r n t; do echo "$(date -u +%FT%TZ) merged #$n $t"; done
  fi
  sleep 300
done

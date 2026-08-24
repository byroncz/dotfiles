#!/bin/sh
# ───────────────────────────────────────────────────────────────────────────
#  Vigila un directorio y lo sube cifrado cuando cambia.
#
#  Un solo script para TODOS los sidecars de respaldo: lo que cambia entre
#  uno y otro son estas variables, no el código.
#
#    NOMBRE            etiqueta para los logs                   (obligatoria)
#    DESTINO           remoto rclone de destino, p. ej. crypt-x:datos
#    DESTINO_VERSIONES dónde apartar las versiones anteriores
#                      (por defecto: DESTINO + "-versiones")
#    ORIGEN          directorio a vigilar                       (/origen)
#    INTERVALO       segundos entre comprobaciones              (60)
#    MAX_INTERVAL    sube aunque no haya cambios, cada N seg    (3600)
#    RCLONE_FILTERS  ruta a un archivo de filtros               (opcional)
#
#  Corre dentro de rclone/rclone:latest, con el origen montado en SOLO
#  LECTURA: aunque este script tuviera un fallo, no puede tocar los datos
#  que vigila.
# ───────────────────────────────────────────────────────────────────────────
set -eu

NOMBRE="${NOMBRE:-respaldo}"
ORIGEN="${ORIGEN:-/origen}"
INTERVALO="${INTERVALO:-60}"
MAX_INTERVAL="${MAX_INTERVAL:-3600}"
RCLONE_FILTERS="${RCLONE_FILTERS:-}"
MARCA=/tmp/hay-cambios

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${NOMBRE}: $*"; }
morir() { log "ERROR: $*"; exit 1; }

# ── Comprobaciones previas ────────────────────────────────────────────────
# Fallar aquí, ruidosamente y al arrancar, es mucho mejor que descubrir
# dentro de tres semanas que no había respaldo.
[ -n "${DESTINO:-}" ] || morir "falta DESTINO (el remoto rclone de destino)"
[ -d "$ORIGEN" ]      || morir "el origen '${ORIGEN}' no existe o no está montado"

REMOTO="${DESTINO%%:*}"
if ! rclone listremotes 2>/dev/null | grep -qx "${REMOTO}:"; then
  log "el remoto '${REMOTO}:' no existe en la configuración de rclone."
  log "¿Has hecho ya la configuración manual? Ver docs/CONFIGURACION-MANUAL.md."
  morir "sin remoto no hay respaldo"
fi

[ -z "$RCLONE_FILTERS" ] || [ -f "$RCLONE_FILTERS" ] \
  || morir "RCLONE_FILTERS apunta a '${RCLONE_FILTERS}', que no existe"

# ── La subida ─────────────────────────────────────────────────────────────
# `sync`, NUNCA `bisync`: el respaldo es de un solo sentido. bisync propaga
# los cambios en ambas direcciones, así que un borrado accidental en el
# destino volvería al origen. Aquí el destino es un espejo desechable.
#
# --backup-dir da el versionado: en vez de pisar la versión anterior, la
# aparta a una carpeta con fecha y hora. Si borras algo por error y el
# sidecar sube el borrado, la copia previa sigue estando.
sync_now() {
  motivo="$1"
  # Base configurable: con un crypt por volumen, DESTINO y las versiones son
  # dos subcarpetas hermanas dentro del MISMO crypt, no dos rutas con sufijo.
  versiones="${DESTINO_VERSIONES:-${DESTINO}-versiones}/$(date '+%Y-%m-%d_%H')"
  log "sincronizando (${motivo}) -> ${DESTINO}"
  inicio="$(date +%s)"
  # shellcheck disable=SC2086
  if rclone sync "$ORIGEN" "$DESTINO" \
       --backup-dir "$versiones" \
       ${RCLONE_FILTERS:+--filter-from "$RCLONE_FILTERS"} \
       --transfers 8 --checkers 16 \
       --log-level NOTICE; then
    log "ok ($(( $(date +%s) - inicio ))s)"
  else
    # No se sale: un fallo de red no debe matar el vigilante. Se reintenta
    # en la siguiente vuelta, y la marca se vuelve a poner abajo.
    log "FALLO en la subida; se reintenta en ${INTERVALO}s"
    touch "$MARCA"
  fi
}

# ── Rama A: el vigilante ──────────────────────────────────────────────────
# Solo toca una marca; no sincroniza. Así mil cambios en un segundo cuestan
# mil `touch` a un archivo local, no mil subidas.
rm -f "$MARCA"
VIGILANTE=""

if ! command -v inotifywait >/dev/null 2>&1; then
  log "instalando inotify-tools"
  apk add -q --no-cache inotify-tools 2>/dev/null || log "no pude instalar inotify-tools"
fi

if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -m -r -q \
    -e modify -e create -e delete -e move -e close_write \
    "$ORIGEN" 2>/dev/null | while read -r _; do touch "$MARCA"; done &
  VIGILANTE=$!
  log "vigilante activo (pid ${VIGILANTE}) sobre ${ORIGEN}"
else
  # Degradación deliberada: sin inotify se sigue respaldando, solo que
  # únicamente por el suelo temporal. Peor, pero no roto ni en silencio.
  log "AVISO: sin inotify; solo se respaldará cada ${MAX_INTERVAL}s"
fi

# ── Arranque ──────────────────────────────────────────────────────────────
log "origen=${ORIGEN} destino=${DESTINO} intervalo=${INTERVALO}s suelo=${MAX_INTERVAL}s"
[ -z "$RCLONE_FILTERS" ] || log "filtros=${RCLONE_FILTERS}"
sync_now "inicial"
ULTIMO="$(date +%s)"

# ── Rama B: el repartidor ─────────────────────────────────────────────────
while true; do
  sleep "$INTERVALO"

  # Detector de vigilante muerto. Sin esto, si inotifywait se cae (lo típico
  # es agotar fs.inotify.max_user_watches) este bucle seguiría girando sobre
  # una marca que ya nadie escribe: el contenedor se vería "sano" y el
  # respaldo estaría muerto en silencio durante semanas. `set -e` no lo
  # detecta porque la rama A corre en segundo plano.
  # Salir con error hace que `restart: unless-stopped` reinicie de verdad.
  if [ -n "$VIGILANTE" ] && ! kill -0 "$VIGILANTE" 2>/dev/null; then
    morir "el vigilante ha muerto; salgo para que Docker me reinicie"
  fi

  AHORA="$(date +%s)"

  if [ -f "$MARCA" ]; then
    # Se borra ANTES de subir: si algo cambia durante la subida, la marca
    # se vuelve a poner y la siguiente vuelta lo recoge.
    rm -f "$MARCA"
    sync_now "cambios detectados"
    ULTIMO="$AHORA"
  elif [ $((AHORA - ULTIMO)) -ge "$MAX_INTERVAL" ]; then
    # Suelo temporal: la red por si el vigilante deja de ver algo. Sobre
    # bind mounts los eventos llegan a ratos y con retraso, así que no sobra.
    sync_now "suelo temporal"
    ULTIMO="$AHORA"
  fi
done

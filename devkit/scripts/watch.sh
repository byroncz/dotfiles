#!/usr/bin/env bash
# Bucle del contenedor. Cada 2 min mira los PRs cuyo título empieza por una
# Clave del proyecto (CODIGO-n) y lanza la skill que toca, en modo headless:
#
#   PR abierto, head sin marcador devkit-review            -> pr-review
#   último marcador CAMBIOS para el head, sin respuesta     -> task-fix
#   último marcador CAMBIOS para el head, respuesta sin push -> pr-review de nuevo
#   último marcador OK y comentario humano posterior        -> task-fix "<texto>"
#   último marcador OK para el head, sin devkit-doc del head -> task-document.sh
#                                                                (o la skill, si el PR trae "Tipo: decisión")
#   último marcador OK para el head                         -> cola.sh
#   3 ciclos respondidos y CAMBIOS otra vez en el head      -> task-block.sh
#   PR mergeado, sin marcador devkit-closed                 -> task-close.sh
#
# cola.sh arranca la siguiente card de la cola del proyecto en cuanto una
# card entra en `Lista para merge`, sin esperar el approve humano ni el
# merge (DEVKIT-56). Desde DEVKIT-120 también se llama en cada pasada del
# sondeo sin nada en curso, así que cualquier card libre en Lista arranca
# sola, no solo las hijas de una Épica en curso: `lanzar_cola`, más abajo, es
# el único punto que lo hace. Es idempotente (la guarda de "algo en curso"
# vive dentro de cola.sh), así que repetirlo tras un rebuild, o dos pasadas
# seguidas, no lanza nada dos veces.
#
# Antes de eso, cada pasada también corre `arrastrar_hijas` (DEVKIT-121): una
# Épica en Lista o En progreso con hijas en Backlog -creadas a mano, o antes
# de aprobar la Épica- las pasa a Lista, así cola.sh ya las ve en esa misma
# vuelta. Una hija con Criterios de aceptación pendientes de definir no se
# mueve; el comentario que deja en la Épica dice qué se movió y qué quedó.
#
# task-block.sh y task-close.sh son bash contra la API de Notion (DEVKIT-55),
# no skills: no gastan modelo ni esperan el candado de `claude -p`. Los PRs
# mergeados los atiende un segundo bucle, cada DEVKIT_WATCH_MERGED_INTERVAL
# segundos (30 por defecto), para que una card quede cerrada y la siguiente
# hija lanzada en menos de un minuto desde el merge, en vez de esperar el
# intervalo del bucle principal y la skill que esté corriendo.
#
# Decisión inmediata (DEVKIT-108): `procesar_pr` no lanza una sola skill por
# vuelta, encadena. Apenas `run_skill` termina una skill lanzada por el
# bucle sobre un PR (pr-review, task-fix, el task-document agente), vuelve a
# consultar `decide` sobre ese mismo PR ahí mismo, sin dormir: un CAMBIOS
# lanza task-fix, una respuesta sin push lanza pr-review otra vez, un OK
# dispara task-document.sh y lanzar_cola, todo en la misma pasada. La cadena
# solo para cuando `decide` repite la misma tupla que la vuelta anterior (ya
# no hay nada nuevo que lanzar, `launched` lo confirma) o llega a un estado
# terminal (nada, bloqueado). Antes, cada transición del ciclo esperaba el
# resto del intervalo completo aunque la skill hubiera terminado en
# segundos (evidencia del PR 75/DEVKIT-78: informe CAMBIOS a las 11:40:05,
# task-fix lanzado a las 11:45:14, con `DEVKIT_WATCH_INTERVAL` en 300).
#
# El estado del ciclo vive en GitHub, en los marcadores de reviews y
# comentarios del PR (<!-- devkit-review -->, <!-- devkit-fix -->,
# <!-- devkit-doc -->, <!-- devkit-block -->, <!-- devkit-closed -->): un
# rebuild no lo pierde.
# /run/devkit/launched (tmpfs) solo evita relanzar lo mismo dentro de una vida
# del contenedor; cada skill es idempotente, así que repetir tras un rebuild no
# daña, pero cuesta dinero y tiempo: por eso el cierre también deja marcador.
#
# Si un `claude -p` muere porque se agotó la cuota de la suscripción, el bucle
# lo anota, espera a que la ventana se reinicie y relanza la misma skill con el
# mismo prompt, en segundo plano. Ver "Cuota agotada" más abajo.
#
# Si en cambio muere por un error transitorio del proveedor antes de que el
# agente alcance a trabajar -529 Overloaded, otro 5xx, "overloaded" o
# timeout, con turnos <= 1 y costo = 0 en la respuesta-, el bucle reintenta
# hasta tres veces con espera creciente (2, 5 y 15 min) y, a diferencia de la
# cuota, no deja el sha marcado como lanzado mientras reintenta: la
# ejecución no llegó a trabajar de verdad. Al cuarto fallo seguido deja la
# ALARMA de siempre y no reintenta más (DEVKIT-124: un 529 en el turno 1
# dejaba la card en Revisión automática sin que nadie la retomara). Ver
# "Error transitorio de la API" más abajo.
#
# /run/devkit/poke: `task-submit.sh`, `review-publish.sh` y `devkit-run.sh
# --worker` lo tocan (`touch`) como último paso de cualquier lanzamiento
# humano (task-fix ya lo hacía a mano, en el paso final de su SKILL.md). Con
# la decisión inmediata de arriba, un pr-review o task-fix que lanza el
# propio bucle (`--sync`) ya no necesita poke: `procesar_pr` reacciona sin
# dormir. Poke sigue haciendo falta para lo que el bucle no ve venir: un
# `pr-review`/`task-fix` que corre el humano a mano con `devkit-run`, fuera
# del ciclo automático. El bucle duerme en tramos de 5 s y sale antes si el
# archivo aparece; al despertar lo borra y sigue con la consulta a GitHub.
# Quien lo toca no decide nada, solo adelanta el reloj.
#
# Uso de prueba: `bash watch.sh --decide < pr.json` imprime la decisión para
# el JSON de `gh pr view <N> --json headRefOid,reviews,comments`, y
# `bash watch.sh --decide-merged < pr.json` la del PR mergeado, para el JSON
# de `gh pr view <N> --json comments`. Los hooks `--quota-hit`, `--quota-reset`
# y `--run-skill` prueban el relanzamiento por cuota agotada y por error
# transitorio; ver watch-test.sh.
#
# Monitoreo mínimo sin modelo (DEVKIT-46): cinco alarmas en bash, todas como
# líneas "ALARMA: ..." en watch.log, sin costo de tokens. Las cuatro primeras
# son estas (la quinta, más abajo): skill que terminó
# con error, skill de más de `DEVKIT_WATCH_SKILL_TIMEOUT` segundos corriendo
# (1200 por defecto), `result` que termina en pregunta en vez de un estado
# observable (`devkit-run --pregunta-abierta`, no solo cuando termina en "?"),
# y rama de una card sin PR y sin `claude -p` vivo hace más de
# `DEVKIT_WATCH_ORPHAN_AGE` segundos (1800 por defecto). `bash watch.sh
# --agentes-vivos` lista PID, Clave y paso de cada skill en curso. El hook
# `--orphan-branch <edad> <tiene PR: si|no> <skill viva: si|no>` prueba la
# cuarta alarma sin git ni gh; ver watch-test.sh.
#
# Quinta alarma (DEVKIT-57): task-fix que responde "nada que corregir" o
# "informe desactualizado" con el último informe CAMBIOS sobre el mismo head.
# Se relanza una vez con el siguiente modelo de `frontera` y, si repite, se
# bloquea la card. Cada lanzamiento deja antes una línea "<nombre> lanzando
# (origen=bucle): ..." que `devkit-run --estado` usa para mostrarlo en curso
# aunque su `claude -p` todavía no exista.
#
# Tope duro de tiempo (DEVKIT-185): a diferencia de SKILL_TIMEOUT, que solo
# avisa, `DEVKIT_WATCH_SKILL_KILL` (3600s por defecto, 3x SKILL_TIMEOUT) sí
# corta -matar tarde es mejor que no matar-. `watch_long_running` mata el
# árbol con `detener_arbol` (el mismo mecanismo del modo alto, DEVKIT-137),
# deja "ALARMA: <nombre> matada a los N min" en watch.log y, al volver de
# `wait`, `run_skill` avisa a la card con la causa, la duración y el comando
# para relanzar a mano (`dk <skill> <Clave>`) vía `devkit-run --skill-matada`
# -sin relanzo automático, ni por cuota ni por error transitorio: el sha
# queda marcado como un fallo normal, igual que cualquier otro rc distinto de
# cero-. `devkit-run.sh --worker` repite el mismo mecanismo para un
# lanzamiento manual o de task-close/epic-plan, que no corre por acá.
#
# Interruptor de tres posiciones (DEVKIT-136/DEVKIT-137), leído de MODO_FILE
# con `devkit-run --pausa/--alto/--reanudar`: en pausa, `pasada` (el cuerpo
# de cada vuelta) deja de llamar a `intentar_lanzar_cola` -no toma la
# siguiente card- pero sigue encadenando pr-review/task-fix/task-document de
# las cards ya en curso; en alto, `pasada` ni siquiera consulta GitHub, y un
# vigilante aparte (`vigilar_alto_once`, en su propio proceso porque el
# principal queda bloqueado en `wait` durante una skill síncrona) mata la
# skill que `run_skill` tenga corriendo -SIGTERM y, a los 10 s, SIGKILL-,
# libera skill.lock y bloquea su card con `task-block.sh <Clave> "alto del
# humano"`. Los hooks `--modo-actual`, `--intentar-lanzar-cola`,
# `--vigilar-alto-once`, `--pasada` y `--pasada-n` prueban cada pieza sin
# tocar GitHub; ver watch-test.sh.
set -u
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
LAUNCHED="$RUN_DIR/launched"
POKE="$RUN_DIR/poke"
LOCK="$RUN_DIR/skill.lock"
WATCH_LOG_FILE="${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}"
# Interruptor de tres posiciones (DEVKIT-136/DEVKIT-137): mismo archivo que
# escribe `devkit-run --pausa/--alto/--reanudar`. devkit-run.sh ya lo obedece
# para un lanzamiento manual (rechaza en alto); este bucle es quien de
# verdad lo hace parar -pausa deja terminar lo que ya está en curso y no toma
# la siguiente card, alto además mata la skill que esté corriendo-.
MODO_FILE="${DEVKIT_MODO_FILE:-$RUN_DIR/modo}"
# La skill que `run_skill` tiene en curso ahora mismo -nombre, Clave y pid
# del proceso que lanzó `devkit-run --sync`, con su `claude -p` como
# descendiente-, para que el vigilante de modo alto sepa a quién matar y qué
# card bloquear (DEVKIT-137). Vive en tmpfs, como skill.lock: sobra entre
# lanzamientos y un `devkit recreate` no necesita arrastrarla.
EN_CURSO="${DEVKIT_EN_CURSO_FILE:-$RUN_DIR/en-curso}"
# Copia de las líneas `lanzando`/`terminado` fuera de tmpfs (DEVKIT-89): sin
# ella, la única evidencia de costo por card muere en cada `devkit recreate`.
# devkit-run.sh no se importa de este archivo: repite la misma variable y las
# mismas funciones (mismo patrón que INTERVALO_BUCLE en ese script).
COSTOS_LOG_FILE="${DEVKIT_COSTOS_LOG:-$WS/.devkit/costos.log}"
# 120 s por defecto (DEVKIT-108, bajado de 300): con la decisión inmediata de
# `procesar_pr`, este intervalo ya no gobierna las transiciones internas del
# ciclo (revisar -> fix -> revisar -> documentar), solo cuánto tarda en
# notarse algo que llega de fuera -un comentario humano en el PR- cuando
# nadie tocó /run/devkit/poke. Costo: una `gh pr list` más una `gh pr view`
# por PR abierto cada 2 min, muy por debajo del límite de 5000 peticiones por
# hora del token (con 30 PRs abiertos, 31 llamadas cada 120 s son ~930/h).
INTERVAL="${DEVKIT_WATCH_INTERVAL:-120}"
MAX_CYCLES="${DEVKIT_WATCH_MAX_CYCLES:-3}"
# `devkit-run.sh` es el único punto de lanzamiento (DEVKIT-45): resuelve
# modelo y esfuerzo por rol desde `devkit/agents/roles.toml` y corre
# `claude -p`; `run_skill` sigue dueño del candado, la cuota agotada y el
# registro en watch.log.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVKIT_RUN="${DEVKIT_RUN_BIN:-$SCRIPTS_DIR/devkit-run.sh}"
QUOTA_RETRIES="${DEVKIT_WATCH_QUOTA_RETRIES:-3}"
QUOTA_WAIT="${DEVKIT_WATCH_QUOTA_WAIT:-1800}"
QUOTA_MIN_WAIT="${DEVKIT_WATCH_QUOTA_MIN_WAIT:-60}"
QUOTA_MAX_WAIT="${DEVKIT_WATCH_QUOTA_MAX_WAIT:-86400}"
# Error transitorio de la API antes del primer turno (DEVKIT-124): espera
# creciente por intento, en segundos (2, 5 y 15 min por defecto). El tope de
# intentos es el tamaño de la lista, no un número aparte: tres esperas, tres
# reintentos.
IFS=',' read -r -a TRANSIENT_WAITS <<<"${DEVKIT_WATCH_TRANSIENT_WAITS:-120,300,900}"
TRANSIENT_RETRIES=${#TRANSIENT_WAITS[@]}
# Monitoreo mínimo sin modelo (DEVKIT-46): cinco alarmas en bash, todas como
# líneas "ALARMA: ..." en watch.log. `SKILL_TIMEOUT`/`SKILL_POLL` gobiernan la
# alarma de skill lenta; `ORPHAN_MAX_AGE`, la de rama huérfana.
SKILL_TIMEOUT="${DEVKIT_WATCH_SKILL_TIMEOUT:-1200}"
SKILL_POLL="${DEVKIT_WATCH_SKILL_POLL:-5}"
# Tope duro de tiempo (DEVKIT-185): a diferencia de SKILL_TIMEOUT, que solo
# avisa, superar este umbral mata la skill con `detener_arbol` -matar tarde
# es mejor que no matar-. 3x por defecto: deja margen a un task-start largo
# (presupuesto 120 turnos) sin dejar que una skill perdida corra toda la
# noche. `devkit-run.sh` repite la misma variable para `--worker`, mismo
# patrón que SKILL_TIMEOUT/SKILL_POLL: los dos scripts no se importan entre sí.
SKILL_KILL="${DEVKIT_WATCH_SKILL_KILL:-$((SKILL_TIMEOUT * 3))}"
ORPHAN_MAX_AGE="${DEVKIT_WATCH_ORPHAN_AGE:-1800}"
# Cierre y bloqueo en bash (DEVKIT-55). MERGED_INTERVAL es el tick del bucle de
# PRs mergeados: una consulta liviana a GitHub (una lista de PRs) cada 30 s
# cabe de sobra en el límite de 5000 peticiones por hora del token.
TASK_CLOSE="${DEVKIT_TASK_CLOSE_BIN:-$SCRIPTS_DIR/task-close.sh}"
TASK_BLOCK="${DEVKIT_TASK_BLOCK_BIN:-$SCRIPTS_DIR/task-block.sh}"
# La siguiente card de la cola del proyecto (DEVKIT-119/DEVKIT-120), que
# `lanzar_cola` usa en los tres momentos descritos en la cabecera. Sustituye
# a task-next.sh (DEVKIT-56): cola.sh ya trae su propia guarda de "algo en
# curso", así que `lanzar_cola` no necesita repetirla.
COLA_BIN="${DEVKIT_COLA_BIN:-$SCRIPTS_DIR/cola.sh}"
# task-document.sh escribe la entrada de tipo "cambio" en bash, sin agente
# (DEVKIT-92); el agente solo corre cuando el cuerpo del PR trae la marca
# "Tipo: decisión" (ver documentar_pr más abajo).
TASK_DOCUMENT="${DEVKIT_TASK_DOCUMENT_BIN:-$SCRIPTS_DIR/task-document.sh}"
MERGED_INTERVAL="${DEVKIT_WATCH_MERGED_INTERVAL:-30}"
# Arrastre de hijas de Backlog a Lista (DEVKIT-121): notion.sh directo, mismo
# trato que `bloqueos`/`epicas` en `devkit-run.sh`, no un script propio -no
# hay más lógica que una consulta y un `set` por hija.
NOTION_BIN="${DEVKIT_NOTION_BIN:-$SCRIPTS_DIR/notion.sh}"

# Decisión sobre un PR abierto. Entrada: el JSON de gh pr view. Salida: una
# línea con cinco campos separados por tabulador (acción, head, referencia,
# extra, informe), nunca vacíos ("-" si no aplica):
#   revisar    <head> <sha del marcador anterior o el propio head> - <informe>
#   fix        <head> <sha del marcador CAMBIOS>      -              <informe>
#   fix-humano <head> <fecha del último comentario>   <texto b64>    <informe>
#   documentar <head> OK                              -              <informe>
#   bloquear   <head> <ciclos respondidos sin OK>     -              <informe>
#   bloqueado  <head> <fecha del bloqueo>             -              <informe>
#   nada       <head> <veredicto vigente>             -              <informe>
# `informe` es el submittedAt del último devkit-review (o "-" sin ninguno):
# dos rondas de `fix` o `revisar` sobre el mismo head, una tras otra, traen
# informes distintos y por lo tanto claves de `launched` distintas (DEVKIT-101:
# antes esas claves solo llevaban el sha, y una segunda ronda de CAMBIOS sobre
# el mismo head -el corrector respondió sin empujar commits, dos veces- se
# perdía porque `launched` ya tenía la clave de la primera).
# Los marcadores se reconocen por su texto, no por su autor: así valen aunque
# el informe lo haya publicado el humano desde otra sesión. Lo humano es todo
# lo que no lleva marcador, no lo firma la cuenta máquina y llega después del
# último devkit-fix o devkit-block que lo haya atendido (DEVKIT-101): un
# devkit-review posterior no cuenta para este corte, porque revisar no es
# atender un comentario -solo corregir lo hace-, y si no ha habido ningún
# devkit-fix ni devkit-block todavía se usa el último devkit-review como
# corte, para no reabrir un comentario que ya quedó atrás cuando se cerró el
# primer ciclo (caso "comentario humano anterior al marcador" de
# watch-test.sh). Los approve no cuentan (los cierra el auto-merge).
# Un bloqueo manda hasta que aparece un devkit-fix posterior a él: esa
# respuesta del corrector (al comentario humano) reanuda el ciclo y el head
# nuevo vuelve a la rama normal (revisar). Los casos están en watch-test.sh.
# `revisar` también sale cuando el último informe es CAMBIOS para el head
# vigente y el corrector ya respondió sin empujar commits (descartó todo o
# solo comentó, DEVKIT-22): la referencia es igual al head y le dice a
# `pr-review` que ese sha ya tiene respuesta y debe juzgarla, no responder
# "ya revisado" y salir. Sin esa respuesta, sigue siendo `fix` (pendiente).
# `documentar` sale cuando el último informe es OK para el head vigente y no
# hay marcador `devkit-doc` de ese mismo head (DEVKIT-55): la entrada de
# Documentación se escribe al aprobar, no al cerrar. Si la card vuelve atrás
# y un head nuevo recibe otro OK, falta el marcador de ese head y task-document
# corre de nuevo sobre la misma entrada. Un comentario humano manda sobre
# documentar y sobre corregir: con el head vigente (OK o CAMBIOS, con o sin
# respuesta), un comentario humano posterior siempre lanza `fix-humano`
# primero (DEVKIT-101, ampliación del 2026-09-18 18:20: antes solo mandaba
# sobre un OK, y con CAMBIOS vigente el comentario se ignoraba).
#
# Excepción a lo anterior (DEVKIT-142): si el último devkit-fix sobre el head
# vigente descartó un hallazgo con la frase fija "necesita aprobación humana"
# (SKILL.md de task-fix) y no hay una revisión nueva todavía sin responder,
# el ciclo se corta -sin marcador devkit-block- igual que un bloqueo: sin
# comentario humano nuevo, `nada` (ni pr-review ni task-fix se relanzan sobre
# el mismo hallazgo); con uno, `fix-humano`, aunque el informe siga en
# CAMBIOS. `decide` no consulta Notion -task-block.sh deja la card Bloqueada
# ahí, no en el PR- así que se guía solo por esa frase en el propio PR.
#
# La guarda de tres ciclos (DEVKIT-56). Un ciclo es un informe CAMBIOS que el
# corrector respondió con su `devkit-fix`. `bloquear` sale solo cuando ya hay
# `max` ciclos y el último informe es CAMBIOS sobre el head vigente: un
# CAMBIOS sobre un head que el corrector ya superó no dice nada del código
# actual, y ese head se revisa primero. El conteo vuelve a cero con un OK, un
# bloqueo o un `devkit-fix` con `manual=1`: lo publica un task-fix que no lanzó
# este bucle (un humano con `devkit-run`, a menudo con `--modelo`, que
# watch.log marca "anulación manual"). Antes, ese fix manual sobre un head nuevo
# completaba el tercer ciclo y el bucle bloqueaba sin revisarlo (PR 38).
DECIDE='
def markers($re; $ts):
  [ .[] | . as $x | ($x.body // "" | capture($re)) | . + {at: $x[$ts]} ];

.headRefOid as $head
| (.reviews | markers("<!-- devkit-review sha=(?<sha>[0-9a-f]+) verdict=(?<verdict>OK|CAMBIOS) -->"; "submittedAt")
   | sort_by(.at)) as $reviews
| (.comments | markers("<!-- devkit-fix sha=(?<sha>[0-9a-f]+) review=(?<review>[0-9a-f]+)(?<manual> manual=1)? -->"; "createdAt")) as $fixes
| (.comments | markers("<!-- devkit-block sha=(?<sha>[0-9a-f]+) -->"; "createdAt") | sort_by(.at)) as $blocks
| (.comments | markers("<!-- devkit-doc sha=(?<sha>[0-9a-f]+) -->"; "createdAt")) as $docs
# Hallazgo descartado por necesitar aprobación humana (DEVKIT-142): task-fix lo
# marca con la frase fija "descartado | necesita aprobación humana" en la
# línea del hallazgo, dentro del bloque devkit-fixes (SKILL.md de task-fix),
# en vez de resolverlo o descartarlo en silencio. Se busca solo ahí -no en el
# cuerpo completo del comentario- para no confundir esa espera con otra línea
# que solo mencione la aprobación de pasada (por ejemplo, un hallazgo
# "atendido" tras resolverse la decisión). Se busca en el último devkit-fix de
# la cuenta máquina sobre el propio $head -no sobre el sha del último
# informe: un task-fix que sí empujó commits para otros hallazgos deja el
# head vigente distinto del sha que revisó pr-review, y aun así el hallazgo
# sigue pendiente.
| ((.comments // [])
   | map(select(.author.login == $bot and ((.body // "") | test("<!-- devkit-fix sha=" + $head + " "))))
   | sort_by(.createdAt) | last | .body // "") as $head_fix_body
| ($head_fix_body
   | test("<!-- devkit-fixes -->[\\s\\S]*?\\n\\S+ \\| descartado \\| necesita aprobaci[oó]n humana[\\s\\S]*?<!-- /devkit-fixes -->"; "i")
  ) as $needs_approval
| ($reviews | last) as $last
| (($blocks | last | .at) // "") as $block_at
| ($block_at != "" and ([$fixes[] | select(.at > $block_at)] | length) > 0) as $resumed
| ($block_at != "" and $last != null and $block_at > $last.at and ($resumed | not)) as $blocked
| (([$reviews[] | select(.verdict == "OK") | .at] | max) // "") as $ok_at
| (([$fixes[] | select(.manual != null) | .at] | max) // "") as $manual_at
| ([$ok_at, $block_at, $manual_at] | max) as $reset_at
| ([$reviews[] | select(.verdict == "CAMBIOS" and .at > $reset_at) | . as $r
    | select(any($fixes[]; .review == $r.sha and .at > $r.at))] | length) as $ciclos
# Corte para "qué comentario humano ya está atendido": solo un devkit-fix o un
# devkit-block lo atienden; un devkit-review no (DEVKIT-101). Sin ningún fix ni
# block todavía, se usa el último devkit-review como corte, igual que antes:
# así un comentario anterior al primer informe, ya cerrado con OK y
# documentado, no reabre el ciclo (caso "comentario humano anterior al
# marcador" de watch-test.sh).
| (([$fixes[].at, $blocks[].at] | max)
   // ($reviews | map(.at) | max)
   // "") as $human_cutoff
| ([ (.reviews[] | select(.state != "APPROVED" and .state != "DISMISSED")
       | {body, at: .submittedAt, login: .author.login}),
     (.comments[] | {body, at: .createdAt, login: .author.login}) ]
   | map(select(.login != $bot
                and ((.body // "") | test("<!-- devkit-") | not)
                and ((.body // "") | gsub("\\s"; "") != "")
                and .at > $human_cutoff))
   | sort_by(.at)) as $human
| (if $last != null then
     [$fixes[] | select(.review == $last.sha and .at > $last.at)] | length
   else 0 end) as $fix_after
| ($last != null and $last.verdict == "CAMBIOS" and $last.sha == $head
   and $fix_after == 0) as $pending_fix
| ($last != null and $last.verdict == "CAMBIOS" and $last.sha == $head
   and $fix_after > 0) as $fix_responded
# Ciclo cortado en espera de una decisión humana (DEVKIT-142), sin marcador
# devkit-block: mientras $needs_approval siga vigente y no haya una revisión
# nueva sin responder ($pending_fix manda sobre esto, no al revés: un informe
# fresco sí hay que corregirlo), el bucle no relanza pr-review ni task-fix
# sobre el mismo hallazgo. Se resuelve solo: el próximo devkit-fix sobre el
# head vigente (la respuesta de fix-humano a la decisión, o un push nuevo)
# reemplaza a $head_fix_body y, si ya no repite la frase, $needs_approval cae
# sola en la siguiente vuelta.
| ($needs_approval and ($pending_fix | not)) as $approval_pending
| ($human | map(.body) | join("\n\n") | @base64) as $human_text
| (($human | last | .at) // "-") as $human_at
| ($last.at // "-") as $informe
| if $blocked then
    (if ($human | length) > 0 then ["fix-humano", $head, $human_at, $human_text, $informe]
     else ["bloqueado", $head, $block_at, "-", $informe] end)
  elif $approval_pending then
    (if ($human | length) > 0 then ["fix-humano", $head, $human_at, $human_text, $informe]
     else ["nada", $head, ($last.verdict // "-"), "-", $informe] end)
  elif ($human | length) > 0 and $last != null and $last.sha == $head then
    ["fix-humano", $head, $human_at, $human_text, $informe]
  elif $ciclos >= $max and $last != null and $last.verdict == "CAMBIOS" and $last.sha == $head then
    ["bloquear", $head, ($ciclos | tostring), "-", $informe]
  elif $last == null or $last.sha != $head then
    ["revisar", $head, ($last.sha // "-"), "-", $informe]
  elif $pending_fix then
    ["fix", $head, $last.sha, "-", $informe]
  elif $fix_responded then
    ["revisar", $head, $last.sha, "-", $informe]
  elif $last.verdict == "OK" and ([$docs[] | select(.sha == $head)] | length) == 0 then
    ["documentar", $head, "OK", "-", $informe]
  else
    ["nada", $head, $last.verdict, "-", $informe]
  end
| @tsv
'

decide() {  # decide <login de la cuenta máquina>  (JSON por stdin)
  jq -r --arg bot "$1" --argjson max "$MAX_CYCLES" "$DECIDE"
}

# Decisión sobre un PR ya mergeado. Entrada: el JSON de
# `gh pr view <N> --json comments`. Salida: una línea con dos campos separados
# por tabulador, nunca vacíos:
#   cerrar  -                       (no hay marcador: hay que lanzar task-close)
#   cerrada <sha del merge commit>  (task-close ya terminó sobre este PR)
# El marcador es lo que sobrevive a un `devkit recreate`: `launched` vive en
# tmpfs y nace vacío, así que sin él el bucle relanzaba task-close sobre cada
# PR mergeado en las últimas 48 h, con card ya en Hecha (DEVKIT-24). Como el
# resto de la familia, se reconoce por su texto y no por su autor.
DECIDE_MERGED='
[ (.comments // [])[]
  | (.body // "" | capture("<!-- devkit-closed sha=(?<sha>[0-9a-f]+) -->")) ]
| if length > 0 then ["cerrada", (last | .sha)] else ["cerrar", "-"] end
| @tsv
'

decide_merged() {  # (JSON por stdin)
  jq -r "$DECIDE_MERGED"
}

if [ "${1:-}" = "--decide" ]; then
  decide "${DEVKIT_WATCH_BOT:-$(gh api user --jq .login 2>/dev/null)}"
  exit $?
fi

if [ "${1:-}" = "--decide-merged" ]; then
  decide_merged
  exit $?
fi

cd "$WS" 2>/dev/null || exit 0
mkdir -p "$RUN_DIR"
touch "$LAUNCHED"

# ¿La línea (ya con fecha) es un lanzamiento o un cierre -exitoso o con
# error- de una de las seis skills que mide `devkit-run --costos` (DEVKIT-89:
# task-start, pr-review, task-fix, task-document, task-close, epic-plan)? Un
# cierre con error también gastó turnos y costo, así que cuenta igual que uno
# exitoso (H2 de pr-review en DEVKIT-89): "ALARMA: <id> terminó con error" es
# el formato de `run_skill` de aquí mismo, "falló (rc=" el de `devkit-run.sh`
# y el de `task-close-N`. Sin este filtro, costos.log arrastraría también
# las líneas narrativas ("PR #31 ... lanzando pr-review") y las de
# task-block/cola, que no aportan costo/turnos y solo inflarían un archivo
# que vive fuera de tmpfs y no se rota nunca.
costos_log_candidata() {  # costos_log_candidata <línea con fecha>
  case "$1" in
    *" lanzando "*|*" terminado"*|*" terminó con error"*|*" falló (rc="*|*" no lanzó: "*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '[ \[](task-start|pr-review|task-fix|task-document|task-close|epic-plan)-'
}

# Copia a costos.log, si corresponde (DEVKIT-89). devkit-run.sh tiene su
# propia copia de esta función: los dos scripts no se importan entre sí.
costos_log() {  # costos_log <línea completa, con fecha>
  costos_log_candidata "$1" || return 0
  mkdir -p "$(dirname "$COSTOS_LOG_FILE")" 2>/dev/null
  printf '%s\n' "$1" >> "$COSTOS_LOG_FILE" 2>/dev/null
}

log() {
  local linea
  linea="$(date +%FT%T%:z) $*"
  printf '%s\n' "$linea"
  costos_log "$linea"
}

# Copia de `modo_actual()` de devkit-run.sh (DEVKIT-137): los dos scripts no
# se importan entre sí, mismo patrón que `costos_log`/`INTERVALO_BUCLE`. Lee
# MODO_FILE y responde "trabajo" (por defecto, sin archivo o con un valor que
# no reconoce), "pausa" o "alto".
modo_actual() {
  local m
  m=$(tr -d '[:space:]' 2>/dev/null < "$MODO_FILE")
  case "$m" in
    pausa|alto) printf '%s' "$m" ;;
    *) printf trabajo ;;
  esac
}

# `cuota:<clave>` es la misma entrada, reescrita mientras la skill espera a que
# se reinicie la cuota (DEVKIT-27): para el bucle cuenta como lanzada, así que
# no nace una segunda copia en paralelo, y el relanzamiento la restituye al
# despertar. La carrera entre el bucle y el relanzamiento al reescribir el
# archivo es inocua: lo peor que pasa es repetir o perder una línea, y toda
# skill es idempotente.
launched() { grep -qxF "$1" "$LAUNCHED" || grep -qxF "cuota:$1" "$LAUNCHED" || grep -qxF "transitorio:$1" "$LAUNCHED"; }
paused() { grep -qxF "cuota:$1" "$LAUNCHED"; }
mark() { echo "$1" >> "$LAUNCHED"; }
unmark() { grep -vxF "$1" "$LAUNCHED" > "$LAUNCHED.tmp" 2>/dev/null; mv "$LAUNCHED.tmp" "$LAUNCHED"; }

# Duerme hasta completar $1 segundos, en tramos de 5, o hasta que aparezca
# $POKE. Lo borra al despertar, antes de que el bucle vuelva a consultar
# GitHub, para que un aviso llegado durante la consulta no se pierda.
sleep_or_poke() {
  local total=$1 waited=0 step
  while [ "$waited" -lt "$total" ]; do
    [ -e "$POKE" ] && break
    step=$(( total - waited < 5 ? total - waited : 5 ))
    sleep "$step"
    waited=$((waited + step))
  done
  rm -f "$POKE"
}

# Estado en el que quedó el trabajo tras un `claude -p`. Notion no se consulta
# desde bash, así que se registra solo lo observable en git y GitHub: la rama en
# la que quedó el workspace, sus commits sobre main y su PR. La línea no afirma
# en qué Estado quedó la card, que solo lo sabe Notion; "rama de card sin PR" es
# la señal de que la ejecución pudo cortarse, y quien lea el log decide.
work_state() {
  local branch key ahead pr prs
  branch=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null)
  # HEAD desprendido va aparte: no se sabe qué rama se estaba trabajando, así
  # que tampoco se puede afirmar que no haya card en progreso.
  if [ "$branch" = "HEAD" ]; then
    log "  estado: workspace en HEAD desprendido, estado desconocido"
    return
  fi
  if [ -z "$branch" ] || [ "$branch" = "main" ]; then
    log "  estado: workspace en '${branch:-?}', ninguna card en progreso"
    return
  fi
  key=$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  ahead=$(git -C "$WS" rev-list --count "main..$branch" 2>/dev/null) || ahead="?"
  # El código de salida distingue "gh no respondió" de "no hay PR": sin esa
  # comprobación, un fallo de token o de red se leería como una rama sin PR.
  if prs=$(gh pr list --head "$branch" --state all --limit 1 --json number,state \
             --jq '.[] | "PR #\(.number) \(.state)"' 2>/dev/null); then
    pr="${prs:-rama de card sin PR}"
  else
    pr="PR desconocido: gh no respondió"
  fi
  log "  estado: ${key:-sin Clave} en $branch, $ahead commits sobre main, $pr"
}

# --- Cuota agotada de la suscripción (DEVKIT-27) ----------------------------
# Un `claude -p` que se queda sin cuota muere con rc distinto de cero y deja el
# aviso del límite en su log. El agente ya no puede reaccionar (sin cuota no
# habla con el modelo, así que ninguna skill sirve, `task-block` incluida);
# quien reacciona es este bucle, que es bash y sobrevive: anota la pausa, espera
# a que la ventana se reinicie y relanza la misma skill con el mismo prompt y
# los mismos flags. No se toca Notion ni el PR: una card puede morir antes de
# tener PR y el mecanismo debe valer igual para todas.

# Formas conocidas del aviso. Claude Code no ofrece comando ni endpoint para
# consultar la cuota desde un script, ni hook para este fallo: el texto del log
# es lo único legible. Si aparece una forma nueva, se añade aquí y se cubre con
# un caso en watch-test.sh.
QUOTA_RE='usage limit reached|limit will reset|(hit|reached) your (usage |session |weekly |5-hour )*limit|(session|weekly|5-hour|five-hour|opus) limit reached'

quota_hit() { grep -qiE "$QUOTA_RE" "$1" 2>/dev/null; }

# Hora en que se reinicia la cuota. Lee el texto del log por stdin e imprime el
# epoch en segundos; no imprime nada si no encuentra ninguna hora, y entonces
# quien llama usa la espera fija.
quota_reset_epoch() {
  local text stamp frag tz day hhmm hh mm ampm spec now target
  text=$(tr '\n' ' ' | tr -s ' ')

  # 1. Forma legible por máquina: `Claude AI usage limit reached|1757558400`,
  #    el epoch en segundos (o en milisegundos, de ahí los 13 dígitos).
  stamp=$(printf '%s' "$text" | grep -oiE 'usage limit reached\|[0-9]{9,13}' | head -1)
  if [ -n "$stamp" ]; then
    stamp=${stamp##*|}
    [ "${#stamp}" -ge 12 ] && stamp=$((stamp / 1000))
    printf '%s' "$stamp"
    return 0
  fi

  # 2. Forma para el humano: "resets 3pm (America/Los_Angeles)", "your limit
  #    will reset at 10:30am", "weekly limit reached ∙ resets Feb 3 at 10am".
  frag=$(printf '%s' "$text" | grep -oiE 'reset[s]?[^.;]{0,60}' | head -1)
  [ -n "$frag" ] || return 1
  tz=$(printf '%s' "$frag" | grep -oE '[A-Za-z]+/[A-Za-z_]+' | head -1)
  day=$(printf '%s' "$frag" | grep -oiE '(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* [0-9]{1,2}' | head -1)
  hhmm=$(printf '%s' "$frag" | grep -oiE '[0-9]{1,2}(:[0-9]{2})? ?(am|pm)' | head -1)
  if [ -n "$hhmm" ]; then
    ampm=$(printf '%s' "$hhmm" | grep -oiE 'am|pm' | tr '[:upper:]' '[:lower:]')
    mm=$(printf '%s' "$hhmm" | grep -oE ':[0-9]{2}' | tr -d ':')
    hh=$(printf '%s' "$hhmm" | grep -oE '^[0-9]{1,2}')
    hh=$((10#$hh % 12))
    [ "$ampm" = "pm" ] && hh=$((hh + 12))
  else
    hhmm=$(printf '%s' "$frag" | grep -oE '[0-9]{1,2}:[0-9]{2}' | head -1)
    [ -n "$hhmm" ] || return 1
    hh=${hhmm%%:*}
    mm=${hhmm##*:}
  fi
  spec=$(printf '%02d:%02d' "$((10#$hh))" "$((10#${mm:-0}))")
  [ -n "$day" ] && spec="$day $spec"
  # Sin zona en el mensaje se usa la del contenedor: es la única disponible y
  # una hora mal interpretada solo alarga o acorta la espera, nunca pierde el
  # relanzamiento, que además está acotado por QUOTA_MIN_WAIT y QUOTA_MAX_WAIT.
  if [ -n "$tz" ]; then
    target=$(TZ="$tz" date -d "$spec" +%s 2>/dev/null) || return 1
  else
    target=$(date -d "$spec" +%s 2>/dev/null) || return 1
  fi
  [ -n "$target" ] || return 1
  now=$(date +%s)
  # "3pm" sin fecha y ya pasado es el de mañana.
  if [ -z "$day" ] && [ "$target" -le "$now" ]; then
    target=$((target + 86400))
  fi
  printf '%s' "$target"
}

# Pausa por cuota agotada: anota hasta cuándo y relanza al reanudarse. La
# espera corre en segundo plano para que el bucle siga atendiendo otros PRs; el
# candado de run_skill impide que el relanzamiento coincida con otra skill.
quota_pause() {  # quota_pause <nombre> <prompt> <clave de launched o -> <intento> <log> [modelo forzado] [Clave de Notion]
  local name=$1 prompt=$2 key=$3 attempt=$4 logf=$5 forzado=${6:-} clave=${7:-} epoch now wait until
  if [ "$key" != "-" ] && paused "$key"; then
    log "cuota agotada: $name ya tiene un relanzamiento programado; no se duplica"
    return
  fi
  if [ "$attempt" -ge "$QUOTA_RETRIES" ]; then
    log "cuota agotada: $name sin más intentos (tope de $QUOTA_RETRIES); no se relanza, ver $logf"
    return
  fi
  now=$(date +%s)
  epoch=$(quota_reset_epoch < "$logf")
  if [ -n "$epoch" ]; then
    wait=$((epoch - now))
  else
    wait=$QUOTA_WAIT
    log "cuota agotada: $name sin hora de reinicio legible en el aviso; espera fija de ${QUOTA_WAIT}s"
  fi
  [ "$wait" -lt "$QUOTA_MIN_WAIT" ] && wait=$QUOTA_MIN_WAIT
  [ "$wait" -gt "$QUOTA_MAX_WAIT" ] && wait=$QUOTA_MAX_WAIT
  until=$(date -d "@$((now + wait))" +%FT%T%:z)
  if [ "$key" != "-" ]; then unmark "$key"; mark "cuota:$key"; fi
  log "cuota agotada: $name en pausa hasta $until (intento $((attempt + 1)) de $QUOTA_RETRIES)"
  (
    sleep "$wait"
    if [ "$key" != "-" ]; then unmark "cuota:$key"; mark "$key"; fi
    log "cuota reanudada: relanzando $name"
    run_skill "$name" "$prompt" "$key" "$((attempt + 1))" "$forzado" "$clave"
  ) &
}

# --- Error transitorio de la API antes del primer turno (DEVKIT-124) --------
# Un `claude -p` puede morir con un 529 Overloaded, otro 5xx, un "overloaded"
# genérico o un timeout de conexión antes de que el agente alcance a hacer
# nada: la evidencia es la misma respuesta de siempre (JSON con `result`,
# `num_turns` y `total_cost_usd`), pero con turnos <= 1 y costo = 0 -no llegó
# a trabajar-. Un turno con más trabajo o algún costo ya no cuenta: ahí el
# agente sí llegó a hacer algo y un reintento automático pisaría ese trabajo.

TRANSIENT_RE='API [Ee]rror:[[:space:]]*5[0-9]{2}|[Oo]verloaded|[Tt]imed? ?out'

# ¿La respuesta de <logf> es un error transitorio de la API? Turnos y costo
# se leen del mismo JSON que ya usa `--resumen`.
transient_hit() {  # transient_hit <logf>
  local logf=$1 resultado turnos costo
  resultado=$(tail -1 "$logf" 2>/dev/null | jq -r '.result // ""' 2>/dev/null)
  printf '%s' "$resultado" | grep -qE "$TRANSIENT_RE" || return 1
  turnos=$(tail -1 "$logf" 2>/dev/null | jq -r '.num_turns // empty' 2>/dev/null)
  [ -n "$turnos" ] || return 1
  [ "$turnos" -le 1 ] 2>/dev/null || return 1
  costo=$(tail -1 "$logf" 2>/dev/null | jq -r '.total_cost_usd // empty' 2>/dev/null)
  [ -n "$costo" ] || return 1
  awk -v c="$costo" 'BEGIN { exit !(c == 0) }'
}

# Reintento con espera creciente (DEVKIT_WATCH_TRANSIENT_WAITS, 2/5/15 min por
# defecto) y tope de $TRANSIENT_RETRIES intentos. Igual que `quota_pause`, la
# entrada de `launched` se reescribe como `transitorio:<clave>` mientras el
# reintento espera -el bucle principal no debe relanzar la misma skill por su
# cuenta durante la espera- y vuelve a su forma normal justo antes de correr
# `run_skill` de nuevo. Al cuarto fallo seguido no hace nada más: la ALARMA ya
# quedó en watch.log (la registra `run_skill`, igual que cualquier otro
# error) y el sha queda marcado como hoy, sin relanzarse solo.
transient_retry() {  # transient_retry <nombre> <prompt> <clave de launched o -> <intento> <log> [modelo forzado] [Clave]
  local name=$1 prompt=$2 key=$3 attempt=$4 logf=$5 forzado=${6:-} clave=${7:-} wait idx
  if [ "$attempt" -gt "$TRANSIENT_RETRIES" ]; then
    log "$name sin más reintentos por error transitorio de la API (tope de $TRANSIENT_RETRIES); ver $logf"
    return
  fi
  if [ "$key" != "-" ]; then unmark "$key"; mark "transitorio:$key"; fi
  idx=$((attempt - 1))
  wait=${TRANSIENT_WAITS[$idx]}
  log "$name reintento $attempt/$TRANSIENT_RETRIES por error transitorio de la API, en ${wait}s: ver $logf"
  (
    sleep "$wait"
    if [ "$key" != "-" ]; then unmark "transitorio:$key"; mark "$key"; fi
    run_skill "$name" "$prompt" "$key" "$((attempt + 1))" "$forzado" "$clave"
  ) &
}

# Alarma 1 de 4 (DEVKIT-46): mientras el `claude -p` de un skill corre en
# segundo plano, avisa una sola vez si supera SKILL_TIMEOUT segundos. Sondea
# cada SKILL_POLL segundos con `kill -0`; ambos son configurables para que la
# prueba no tenga que esperar 20 minutos de verdad.
#
# Tope duro (DEVKIT-185): a los SKILL_KILL segundos ya no solo avisa, mata el
# árbol completo con `detener_arbol` -mismo mecanismo que el vigilante de
# modo alto, DEVKIT-137- y dejar una marca en `$RUN_DIR/$name.matada` con los
# segundos corridos, antes de matar: `run_skill` la lee al volver de `wait`
# para saber que el corte fue el tope de tiempo, no un error cualquiera, y
# avisar a la card en vez de reintentar solo.
watch_long_running() {  # watch_long_running <nombre> <pid>
  local name=$1 pid=$2 waited=0 alarmed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$SKILL_POLL"
    waited=$((waited + SKILL_POLL))
    if [ "$alarmed" -eq 0 ] && [ "$waited" -ge "$SKILL_TIMEOUT" ]; then
      log "ALARMA: $name lleva $((waited / 60)) min corriendo (límite ${SKILL_TIMEOUT}s)"
      alarmed=1
    fi
    if [ "$waited" -ge "$SKILL_KILL" ]; then
      echo "$waited" > "$RUN_DIR/$name.matada" 2>/dev/null
      detener_arbol "$pid"
      log "ALARMA: $name matada a los $((waited / 60)) min (tope de tiempo, límite ${SKILL_KILL}s)"
      break
    fi
  done
}

# --- Modo alto: terminar la skill en curso (DEVKIT-137) --------------------
# `run_skill` lanza `devkit-run --sync` en segundo plano y espera con `wait`
# (más abajo): un SIGTERM al pid que guarda no basta, bash no lo reenvía a
# sus hijos, y el `claude -p` real es descendiente de ese proceso, no el
# proceso mismo. `matar_arbol` baja por `pgrep -P` antes de matar cada nivel,
# de las hojas hacia la raíz, para no perder de vista a un hijo cuyo padre ya
# murió.
matar_arbol() {  # matar_arbol <pid> <señal>
  local pid=$1 senal=$2 hijo
  for hijo in $(pgrep -P "$pid" 2>/dev/null); do
    matar_arbol "$hijo" "$senal"
  done
  kill -s "$senal" "$pid" 2>/dev/null
}

# SIGTERM al árbol completo y, si sigue vivo a los ALTO_KILL_WAIT segundos
# (10 por defecto, criterio de aceptación de DEVKIT-137), SIGKILL.
ALTO_KILL_WAIT="${DEVKIT_WATCH_ALTO_KILL_WAIT:-10}"
detener_arbol() {  # detener_arbol <pid raíz>
  local pid=$1 esperado=0
  matar_arbol "$pid" TERM
  while [ "$esperado" -lt "$ALTO_KILL_WAIT" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    esperado=$((esperado + 1))
  done
  kill -0 "$pid" 2>/dev/null && matar_arbol "$pid" KILL
  return 0
}

# Una pasada del vigilante de modo alto: si hay una skill en curso (EN_CURSO,
# que `run_skill` escribe y borra) y el modo es alto, la mata, libera
# skill.lock -al morir el pid que `run_skill` espera con `wait`, ese mismo
# proceso sigue su curso normal y suelta el candado él solo, sin que este
# vigilante lo toque- y bloquea la card con el motivo del humano. Corre en un
# proceso aparte del bucle principal (más abajo, junto a MERGED_PID): el
# bucle está bloqueado en `wait` durante toda la skill, así que nada dentro
# de él puede notar el cambio de modo a tiempo.
vigilar_alto_once() {
  [ "$(modo_actual)" = alto ] || return 0
  [ -f "$EN_CURSO" ] || return 0
  local name clave pid
  IFS=$'\t' read -r name clave pid < "$EN_CURSO"
  if [ -z "${pid:-}" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$EN_CURSO"
    return 0
  fi
  detener_arbol "$pid"
  log "modo alto: detenido $name ${clave:--}"
  if [ -n "$clave" ] && [ "$clave" != - ]; then
    "$TASK_BLOCK" "$clave" "alto del humano" >/dev/null 2>&1
  fi
  rm -f "$EN_CURSO"
}

# run_skill <nombre del log> <prompt> [clave de launched] [intento]. Lanza el
# prompt con `devkit-run.sh --sync`, que resuelve modelo y esfuerzo por rol y
# corre `claude -p`; la última línea de su JSON trae costo, tokens y turnos,
# que es la medida de cada ciclo. Al terminar se registra el estado del
# trabajo, para que un corte sea visible, y si el corte fue por cuota se
# programa el relanzamiento.
#
# <modelo forzado> (quinto argumento, opcional) reemplaza al modelo del rol:
# lo usa el relanzamiento de un task-fix vacío (DEVKIT-57). El modelo con el
# que corrió queda en ULTIMO_MODELO para quien llama.
#
# <clave> (sexto argumento, opcional): la Clave de Notion, para el corte por
# presupuesto (DEVKIT-94). task-fix y task-document ya la traen en `prompt`
# ("/task-fix DEVKIT-94 ..."); pr-review no ("/pr-review 68"), así que quien
# la conoce por el título del PR la pasa aparte.
run_skill() {
  local name=$1 prompt=$2 key=${3:--} attempt=${4:-1} forzado=${5:-} clave=${6:-} logf rc summary modelo esfuerzo presupuesto ronda skill_pid watcher_pid resultado en_linea turnos_reales clave_en_curso matada_min
  # Guarda de modo (DEVKIT-137, H3 de la revisión sobre el PR #103): en alto
  # no se lanza nada, ni siquiera un relanzamiento ya programado por
  # `quota_pause`/`transient_retry` que despierta después del corte. Se
  # comprueba antes de resolver modelo/candado (para no gastar la sonda de
  # `--rol` en vano) y otra vez justo después de tomar el candado, porque la
  # espera de `flock` puede tardar y el modo cambiar mientras tanto.
  #
  # `unmark`: quien llama (`caso_fix`/`caso_revisar`/`caso_fix_humano`,
  # `quota_pause`/`transient_retry`) ya marcó `$key` en `launched` antes de
  # este `run_skill` que corta sin lanzar nada. Sin desmarcarla, la próxima
  # pasada en trabajo la ve marcada y `avisar_si_lanzada` deja el PR "ya
  # lanzada; esperando" para siempre (H6 de la revisión sobre el PR #103).
  if [ "$(modo_actual)" = alto ]; then
    log "$name no se lanza: modo alto"
    [ "$key" = - ] || unmark "$key"
    return 76
  fi
  logf="$RUN_DIR/$name.log"
  # `--rol` antes de la línea "lanzando" (DEVKIT-81): la fila de --estado
  # muestra modelo y esfuerzo desde que aparece, no solo al terminar. Costo:
  # mientras `--rol` espera la sonda de modelo (`modelo_disponible`), hasta
  # `MODEL_CHECK_TIMEOUT` por modelo de `frontera`, el lanzamiento no tiene
  # ninguna línea en watch.log -la de la sonda recién se escribe cuando esta
  # termina, no mientras corre- y por lo tanto no aparece en `--estado`. Es la
  # misma espera que ya describía la ampliación de DEVKIT-57 ("aunque
  # espere ... a la sonda de modelos"), sin cubrirla.
  read -r modelo esfuerzo presupuesto ronda < <("$DEVKIT_RUN" --rol "$prompt")
  [ -z "$forzado" ] || modelo=$forzado
  ULTIMO_MODELO=$modelo
  # Se corta por caracteres, como `prompt_en_linea` de devkit-run.sh: `cut -c`
  # corta por bytes y partiría un acento, y --estado ya no reconocería la
  # línea.
  en_linea=$(printf '%s' "$prompt" | tr '\n"' '  ')
  log "$(printf '%s lanzando (origen=bucle) modelo=%s esfuerzo=%s ronda=%s: "%s" log=%s' \
    "$name" "${modelo:--}" "${esfuerzo:--}" "${ronda:--}" "${en_linea:0:120}" "$logf")"
  # Un solo `claude -p` a la vez: desde DEVKIT-27 un relanzamiento por cuota
  # puede despertar mientras el bucle atiende otro PR, y dos agentes sobre el
  # mismo workspace se pisarían la rama.
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log "$name espera: otra skill ocupa el workspace"
    flock 9
  fi
  if [ "$(modo_actual)" = alto ]; then
    log "$name no se lanza: modo alto (tras esperar el candado)"
    [ "$key" = - ] || unmark "$key"
    flock -u 9
    exec 9>&-
    return 76
  fi
  # Con el candado tomado: task-block.sh, llamado por la skill o por --sync,
  # lo sabe por DEVKIT_LOCK_HELD y guarda el wip sin pedirlo otra vez.
  # DEVKIT_LANZADOR=watch le dice a task-fix que lo lanzó el bucle: sin ella,
  # su `devkit-fix` lleva `manual=1` y reinicia la guarda (DEVKIT-56).
  # DEVKIT_RONDA pasa la ronda que ya leyó `--rol`: `--sync` no vuelve a
  # consultar el PR ni repite sus avisos (DEVKIT-61).
  DEVKIT_LOCK_HELD=1 DEVKIT_LANZADOR=watch DEVKIT_MODELO_FORZADO="$forzado" DEVKIT_RONDA="${ronda:-}" \
    "$DEVKIT_RUN" --sync "$prompt" >"$logf" 2>&1 &
  skill_pid=$!
  # Clave del EN_CURSO: la que ya nos pasaron (pr-review, que no la trae en
  # su propio prompt) o la que aparece en el prompt (task-fix/task-document,
  # que sí la traen, DEVKIT-137). El vigilante de modo alto la usa para
  # bloquear la card correcta.
  clave_en_curso=${clave:-$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)}
  printf '%s\t%s\t%s\n' "$name" "${clave_en_curso:--}" "$skill_pid" > "$EN_CURSO" 2>/dev/null
  watch_long_running "$name" "$skill_pid" &
  watcher_pid=$!
  wait "$skill_pid"
  rc=$?
  rm -f "$EN_CURSO"
  # DEVKIT-185: si el corte fue el tope de tiempo, `watch_long_running` es
  # quien mató a `$skill_pid` y todavía le falta dejar su propia ALARMA antes
  # de volver -la marca ya existe para entonces, escrita antes de matar-.
  # Matarlo también, como el resto de los casos, es una carrera real que
  # puede cortarle esa línea a medias: alcanza con esperarlo, ya rompió su
  # propio bucle y va a terminar solo, apenas un instante más tarde.
  if [ -f "$RUN_DIR/$name.matada" ]; then
    wait "$watcher_pid" 2>/dev/null
  else
    kill "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
  fi
  flock -u 9
  exec 9>&-
  matada_min=""
  if [ -f "$RUN_DIR/$name.matada" ]; then
    matada_min=$(( $(cat "$RUN_DIR/$name.matada" 2>/dev/null || echo 0) / 60 ))
    rm -f "$RUN_DIR/$name.matada"
  fi
  summary=$("$DEVKIT_RUN" --resumen "$logf" "$modelo" "$esfuerzo" "$presupuesto" "${ronda:--}")
  # rc=3 (DEVKIT-93, "nada que revisar") corta antes de cualquier `claude -p`
  # real: no hay session_id que buscar. `guardar_transcripcion` vive en
  # devkit-run.sh (DEVKIT-102): así también cubre `--worker` (task-start,
  # task-close, epic-plan y los lanzamientos manuales), no solo el bucle.
  [ "$rc" -eq 3 ] || "$DEVKIT_RUN" --guardar-transcripcion "$logf" "$RUN_DIR/$name-transcript.jsonl"
  if [ $rc -eq 0 ]; then
    log "$name terminado: $summary"
    # Alarma 2 de 4: un `result` que termina en pregunta es la card en curso
    # cortando en seco en vez de resolver en un estado observable (AGENTS.md).
    resultado=$(tail -1 "$logf" 2>/dev/null | jq -r '.result // ""' 2>/dev/null)
    if "$DEVKIT_RUN" --pregunta-abierta "$resultado"; then
      log "ALARMA: $name terminó con una pregunta abierta en vez de un estado observable"
    fi
  elif [ $rc -eq 3 ]; then
    # DEVKIT-93: review-prep.sh (dentro de `run_claude`) decidió que no había
    # nada que revisar antes de gastar un turno de Opus; no es un error, así
    # que no hay ALARMA. El motivo va en texto plano en $logf, no JSON.
    log "$name no lanzó: nada que revisar ($(tr '\n' ' ' < "$logf" 2>/dev/null | sed -E 's/[[:space:]]+$//'))"
  elif [ -n "$matada_min" ]; then
    # DEVKIT-185: `watch_long_running` ya dejó su propia ALARMA en el momento
    # del corte; esta repite el formato de la alarma 3 de 4 -mismo prefijo
    # que reconoce `estado_filas` en devkit-run.sh para el cierre de la fila-
    # con "tope de tiempo" para que la tabla de `--estado` distinga este
    # corte de un error cualquiera. `--skill-matada` es quien de verdad avisa
    # a la card (Notion), mismo patrón que `--presupuesto-corte`: sin
    # relanzo automático, ni por cuota ni por error transitorio (el texto de
    # este corte no calza con ninguno de los dos).
    log "ALARMA: $name terminó con error (rc=$rc): tope de tiempo, matada a los $matada_min min; ver $logf"
    "$DEVKIT_RUN" --skill-matada "$prompt" "$logf" "$matada_min" "$clave"
  else
    # Alarma 3 de 4: cualquier skill que termina con error.
    log "ALARMA: $name terminó con error (rc=$rc): $summary; ver $logf"
  fi
  # DEVKIT-94, H1 del informe sobre el PR #68: antes esto solo quedaba como
  # aviso dentro de `summary` ("excede el presupuesto..."); pr-review,
  # task-fix y task-document del ciclo automático corren por acá (`--sync`).
  # DEVKIT-105: el presupuesto de `presupuesto.<skill>` es una meta de
  # optimización, no un límite -exceder el presupuesto nunca bloquea la
  # card, en ningún camino (`--sync` ni `--worker`)-, así que
  # `--presupuesto-corte` solo avisa: ALARMA en watch.log y un comentario en
  # la card.
  turnos_reales=$(tail -1 "$logf" 2>/dev/null | jq -r '.num_turns // empty' 2>/dev/null)
  if [ -n "$presupuesto" ] && [ "$presupuesto" != - ] && [ -n "$turnos_reales" ] \
     && [ "$turnos_reales" -gt "$presupuesto" ] 2>/dev/null; then
    "$DEVKIT_RUN" --presupuesto-corte "$prompt" "$logf" "$presupuesto" "$turnos_reales" "$clave"
  fi
  work_state
  # `$attempt` es el mismo contador para `quota_pause` y `transient_retry`
  # (DEVKIT-124, H3): si una cuota agotada alterna con un 529 sobre el mismo
  # lanzamiento, ambos gastan del mismo presupuesto de reintentos en vez de
  # tener el suyo propio. Es un caso raro -las dos causas de corte son
  # distintas- y no vale la pena separar los contadores para eso.
  # DEVKIT-185: una skill matada por tope de tiempo nunca reintenta sola,
  # aunque su log truncado calzara por casualidad con el texto de cuota o de
  # un error transitorio -matar tarde es mejor que no matar, pero matar no
  # autoriza a insistir sin que alguien lo pida-.
  if [ $rc -ne 0 ] && [ $rc -ne 3 ] && [ -z "$matada_min" ]; then
    if quota_hit "$logf"; then
      quota_pause "$name" "$prompt" "$key" "$attempt" "$logf" "$forzado" "$clave"
    elif transient_hit "$logf"; then
      transient_retry "$name" "$prompt" "$key" "$attempt" "$logf" "$forzado" "$clave"
    fi
  fi
  return $rc
}

# Costo total del ciclo de un PR: suma "costo=" de todas sus líneas en
# watch.log (pr-review-<n>-*, task-fix-<n>-*, task-document-<n>-*, task-block-<n>,
# task-close-<n>), no solo el último task-close, porque el mismo PR pudo
# pasar por varias rondas de revisión y corrección. Se imprime al cerrar.
cycle_cost() {  # cycle_cost <num> [archivo de log, para la prueba]
  local num=$1 file=${2:-$WATCH_LOG_FILE}
  # `(-[0-9A-Za-z]+)*` en vez de `?`: task-fix-<n>-humano-<fecha> tiene dos
  # segmentos de sufijo, no uno.
  grep -E " (pr-review|task-fix|task-document|task-block|task-close)-$num(-[0-9A-Za-z]+)* (terminado|falló)" "$file" 2>/dev/null \
    | grep -oE 'costo=[0-9.]+' | cut -d= -f2 \
    | awk '{s+=$1} END{printf "%.4f", s+0}'
}

# Clave del título del PR, solo si es de este proyecto y no es la -0.
key_of() {  # key_of <título> <código>
  local key
  key=$(printf '%s' "$1" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  [ -n "$key" ] || return 1
  [ -z "$2" ] || [ "${key%%-*}" = "$2" ] || return 1
  [ "${key##*-}" != "0" ] || return 1
  printf '%s' "$key"
}

# Alarma 4 de 4 (DEVKIT-46): decisión pura, sin git ni gh, para que
# watch-test.sh la pruebe con datos sintéticos. `check_orphan_branch` reúne
# los tres datos (edad del último commit, si ya tiene PR, si una skill sigue
# viva) y llama a esta función.
orphan_branch_alarm() {  # orphan_branch_alarm <edad en segundos> <tiene PR: si|no> <skill viva: si|no>
  local age=$1 has_pr=$2 skill_alive=$3
  [ "$age" -ge "$ORPHAN_MAX_AGE" ] || return 1
  [ "$has_pr" = "no" ] || return 1
  [ "$skill_alive" = "no" ] || return 1
  return 0
}

# Sesión interactiva viva sobre este workspace (DEVKIT-46, H4 de la revisión):
# un humano trabajando a mano sobre una card `En progreso` (permitido por
# AGENTS.md) no toca `skill.lock` -ese candado es solo de `run_skill`-, así
# que sin esta señal la rama se ve huérfana aunque alguien la esté usando. Se
# reconoce por un `claude` sin `-p` (la TUI, no un `claude -p` headless) cuyo
# `cwd` es este mismo workspace: el host puede tener sesiones abiertas sobre
# otros proyectos, que no cuentan.
interactive_session_alive() {
  local pid cwd
  for pid in $(ps -eo pid=,comm= 2>/dev/null | awk '$2 == "claude" {print $1}'); do
    # `-ww`: sin ancho ilimitado, `ps` recorta la línea al COLUMNS del
    # entorno (una terminal integrada como la del editor lo exporta,
    # DEVKIT-79) y una sesión interactiva con argumentos largos se vería sin
    # `-p`, como si fuera headless.
    ps -p "$pid" -o args= -ww 2>/dev/null | grep -qE '(^| )-p( |$)' && continue
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || continue
    [ "$cwd" = "$WS" ] || continue
    return 0
  done
  return 1
}

# Rama en la que quedó el workspace, sin PR y sin ningún `claude -p` vivo hace
# más de ORPHAN_MAX_AGE segundos: la señal de que una ejecución se cortó a
# medias y nadie la está retomando. "Skill viva" se lee del candado de
# run_skill, no de la lista de procesos: si nadie tiene `skill.lock`, no hay
# un `claude -p` en curso sobre este workspace. Una sesión interactiva viva
# (ver interactive_session_alive) cuenta igual, aunque no toque el candado.
#
# La edad se mide desde la última señal de actividad, no solo desde el
# último commit: una rama recién creada por task-start hereda el timestamp
# del último commit de main (que puede ser viejo) y `exec >"$LOCK"` en
# run_skill actualiza el mtime del candado cada vez que una skill lo toma o
# lo suelta, así que sirve de proxy de "hace cuánto corrió algo aquí". Si la
# rama todavía no tiene commits propios sobre main, es demasiado pronto para
# medir: se sale sin evaluar la alarma (DEVKIT-46, H3 de la revisión).
check_orphan_branch() {
  local branch key committed lock_mtime last_activity now age has_pr skill_alive prs head_commit merge_base
  branch=$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null) || return
  case "$branch" in HEAD|main|"") return ;; esac
  head_commit=$(git -C "$WS" rev-parse HEAD 2>/dev/null) || return
  merge_base=$(git -C "$WS" merge-base HEAD main 2>/dev/null) || merge_base=""
  [ "$head_commit" != "$merge_base" ] || return
  committed=$(git -C "$WS" log -1 --format=%ct 2>/dev/null) || return
  last_activity=$committed
  if [ -f "$LOCK" ]; then
    lock_mtime=$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null) || lock_mtime=0
    [ "$lock_mtime" -le "$last_activity" ] || last_activity=$lock_mtime
  fi
  now=$(date +%s)
  age=$((now - last_activity))
  exec 8>"$LOCK"
  if flock -n 8; then skill_alive=no; flock -u 8; else skill_alive=si; fi
  exec 8>&-
  if [ "$skill_alive" = no ] && interactive_session_alive; then skill_alive=si; fi
  if prs=$(gh pr list --head "$branch" --state all --limit 1 --json number --jq 'length' 2>/dev/null); then
    { [ "${prs:-0}" -gt 0 ] 2>/dev/null && has_pr=si; } || has_pr=no
  else
    return  # gh no respondió: se reintenta en la vuelta siguiente
  fi
  key=$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  if orphan_branch_alarm "$age" "$has_pr" "$skill_alive"; then
    log "ALARMA: rama $branch (${key:-sin Clave}) sin PR y sin skill viva hace $((age / 60)) min"
  fi
}

# Comando que lista los agentes vivos con su Clave y su paso (DEVKIT-46,
# contenido de DEVKIT-19). Un agente vivo es un `devkit-run.sh --worker` o
# `--sync` en curso: su línea de proceso trae "--worker /<skill> <Clave> ..."
# o "--sync /<skill> ...". Hasta DEVKIT-57 solo miraba `--worker`, y no veía
# nada de lo que lanza el bucle. Solo ve procesos: un lanzamiento que todavía
# no tiene proceso lo muestra `devkit-run --estado`.
agentes_vivos() {
  local lineas
  # `-ww`: mismo motivo que en interactive_session_alive (DEVKIT-79); sin
  # ella, una ruta de log larga queda fuera de la línea y el agente parece
  # no tener `--worker`/`--sync`.
  lineas=$(ps -eo pid=,args= -ww 2>/dev/null | grep -E -- '--(worker|sync) /' | grep -v grep)
  if [ -z "$lineas" ]; then
    echo "sin agentes vivos"
    return 0
  fi
  printf '%s\n' "$lineas" | while IFS= read -r linea; do
    local pid args paso clave
    pid=$(printf '%s' "$linea" | awk '{print $1}')
    args=$(printf '%s' "$linea" | cut -d' ' -f2-)
    paso=$(printf '%s' "$args" | grep -oE -- '--(worker|sync)[[:space:]]+/[a-zA-Z-]+' | grep -oE '/[a-zA-Z-]+$' | tr -d '/')
    clave=$(printf '%s' "$args" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
    printf '%s\t%s\t%s\n' "$pid" "${clave:-?}" "${paso:-?}"
  done
  return 0
}

# Código del proyecto. Se relee en cada vuelta: en un proyecto nuevo,
# .devkit/devkit.toml arranca con `project = "PROJ"` y project-init lo corrige
# después, sin reiniciar el contenedor.
project_code() {
  [ -f "$WS/.devkit/devkit.toml" ] || return 0
  sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/.devkit/devkit.toml" | head -1
}

# Bloqueo por tres ciclos sin OK, en bash (DEVKIT-55). Primero el marcador en
# el PR: es lo que detiene al bucle aunque falle Notion. Luego la card.
#
# [motivo] (sexto argumento, opcional) reemplaza la causa por defecto, "tres
# ciclos sin OK": lo usa el bloqueo por task-fix vacío (DEVKIT-57).
block_pr() {  # block_pr <num> <Clave> <url> <head> <ciclos> [motivo]
  local num=$1 key=$2 url=$3 head=$4 ciclos=$5 motivo=${6:-} out rc estado
  if [ -n "$motivo" ]; then
    log "PR #$num ($key) $motivo: bloqueando con task-block.sh"
  else
    motivo="Tres ciclos de revisión y corrección sin veredicto OK"
    log "PR #$num ($key) $ciclos ciclos sin OK: bloqueando con task-block.sh"
  fi
  gh pr comment "$num" --body "<!-- devkit-block sha=$head -->
$motivo. La card pasa a Bloqueada y el bucle no toca este PR hasta que decidas.
Para retomar: mueve la card a Revisión automática y comenta aquí qué hacer. El bucle lanza task-fix con tu comentario y el conteo de ciclos vuelve a cero." >/dev/null 2>&1 \
    || log "PR #$num: no se pudo publicar el marcador devkit-block"
  out=$("$TASK_BLOCK" "$key" "$motivo en el PR $url; el bucle no lo toca hasta que decidas." 2>&1)
  rc=$?
  printf '%s\n' "$out" >"$RUN_DIR/task-block-$num.log"
  estado=terminado
  [ "$rc" -eq 0 ] || estado="falló (rc=$rc)"
  log "task-block-$num $estado: bash :: $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  [ "$rc" -eq 0 ] || log "ALARMA: task-block-$num terminó con error (rc=$rc); ver $RUN_DIR/task-block-$num.log"
}

# --- task-fix vacío con CAMBIOS vigente (DEVKIT-57) --------------------------
# Un task-fix que responde "nada que corregir" o "informe desactualizado"
# mientras el último informe sobre ese mismo head sigue siendo CAMBIOS no
# corrigió nada, y el ciclo queda quieto: no hay `devkit-fix` que dispare otra
# revisión, y `launched` impide relanzar el mismo fix. Pasó con un task-fix en
# Haiku (entrada de Documentación de DEVKIT-54). El bucle lo detecta, lo
# registra como ALARMA y relanza una vez con el siguiente modelo de
# `frontera`; si el segundo responde igual, bloquea la card.
FIX_VACIO_RE='nada que corregir|informe desactualizado'

# Decisión pura, para watch-test.sh: verdadero si <log> es un task-fix vacío
# y la decisión fresca del PR sigue siendo `fix` sobre el mismo <head>.
fix_vacio() {  # fix_vacio <log> <acción fresca> <head fresco> <head atendido>
  local resultado
  resultado=$(tail -1 "$1" 2>/dev/null | jq -r '.result // ""' 2>/dev/null)
  printf '%s' "$resultado" | grep -qiE "$FIX_VACIO_RE" || return 1
  [ "$2" = fix ] && [ "$3" = "$4" ]
}

frase_fix_vacio() {  # frase_fix_vacio <log>
  tail -1 "$1" 2>/dev/null | jq -r '.result // ""' 2>/dev/null | grep -oiE "$FIX_VACIO_RE" | head -1
}

# Acción y head frescos del PR, tras la skill: el informe pudo cambiar mientras
# corría.
decision_fresca() {  # decision_fresca <num>
  gh pr view "$1" --json headRefOid,reviews,comments 2>/dev/null | decide "$BOT" | cut -f1,2
}

# Caso `fix` del bucle: task-fix y, si respondió vacío, la alarma.
#
# [clave de launched] (sexto argumento, opcional) es la que ya marcó quien
# llama; por defecto "fix:$num:$ref", la forma anterior a DEVKIT-101, para no
# romper al hook `--fix` de watch-test.sh, que no la pasa. `caso_fix` sí la
# pasa siempre, con el informe incluido: sin ese mismo valor, una pausa por
# cuota (quota_pause) reescribiría una clave que no coincide con la que
# `caso_fix` marcó en `launched`, y la reanudación se perdería.
atender_fix() {  # atender_fix <num> <Clave> <url> <head> <ref> [clave de launched]
  local num=$1 key=$2 url=$3 head=$4 ref=$5 lkey=${6:-} name accion head_ahora siguiente rc
  [ -n "$lkey" ] || lkey="fix:$num:$ref"
  name="task-fix-$num-${head:0:7}"
  run_skill "$name" "/task-fix $key" "$lkey"
  rc=$?
  # rc=76 (DEVKIT-137, H6 de la revisión sobre el PR #103): modo alto, no
  # corrió nada. `run_skill` ya desmarcó `$lkey` para que la próxima pasada
  # en trabajo lo relance; seguir con `decision_fresca`/`fix_vacio` sobre un
  # log vacío gastaría un `gh pr view` en vano y, peor, podría relanzar
  # task-fix con otro modelo como si el primero hubiera respondido vacío.
  [ "$rc" -eq 76 ] && return 0
  IFS=$'\t' read -r accion head_ahora < <(decision_fresca "$num")
  fix_vacio "$RUN_DIR/$name.log" "${accion:-}" "${head_ahora:-}" "$head" || return 0
  siguiente=$("$DEVKIT_RUN" --siguiente-modelo "$ULTIMO_MODELO")
  log "ALARMA: $name terminó con \"$(frase_fix_vacio "$RUN_DIR/$name.log")\" con CAMBIOS vigente sobre ${head:0:7}; relanzo task-fix con ${siguiente:-el modelo del rol} (antes $ULTIMO_MODELO)"
  run_skill "$name-reintento" "/task-fix $key" "$lkey" 1 "$siguiente"
  IFS=$'\t' read -r accion head_ahora < <(decision_fresca "$num")
  fix_vacio "$RUN_DIR/$name-reintento.log" "${accion:-}" "${head_ahora:-}" "$head" || return 0
  log "ALARMA: $name-reintento también terminó con \"$(frase_fix_vacio "$RUN_DIR/$name-reintento.log")\" con CAMBIOS vigente sobre ${head:0:7}"
  block_pr "$num" "$key" "$url" "$head" "-" \
    "task-fix respondió sin corregir con dos modelos ($ULTIMO_MODELO el último) mientras el informe CAMBIOS sobre ${head:0:7} sigue vigente"
}

# Aviso de una sola vez cuando `decide` repite la misma acción ya lanzada
# para el mismo informe (DEVKIT-101): sin él, un lanzamiento que `launched`
# descarta queda mudo y el humano solo lo nota mirando `--estado` mucho
# después (pasó con el PR 68: quince minutos quieto sin que nadie avisara).
# La marca `aviso:<clave>` es aparte de la propia clave: existe solo para no
# repetir la línea en cada vuelta del bucle mientras siga sin haber un
# informe nuevo.
avisar_si_lanzada() {  # avisar_si_lanzada <num> <Clave> <acción> <clave de launched>
  local num=$1 key=$2 accion=$3 lkey=$4
  launched "$lkey" || return 1
  if ! launched "aviso:$lkey"; then
    mark "aviso:$lkey"
    log "PR #$num ($key) $accion ya lanzada para este informe; esperando"
  fi
  return 0
}

# Caso `fix`: la clave de `launched` incluye el informe (DEVKIT-101), así que
# un segundo CAMBIOS sobre el mismo head, tras una respuesta sin commits,
# vuelve a lanzar task-fix en vez de quedar atascado en la clave de la
# primera ronda.
caso_fix() {  # caso_fix <num> <Clave> <url> <head> <ref> <informe>
  local num=$1 key=$2 url=$3 head=$4 ref=$5 informe=$6 lkey
  lkey="fix:$num:$ref:$informe"
  avisar_si_lanzada "$num" "$key" fix "$lkey" && return
  mark "$lkey"
  log "PR #$num ($key) CAMBIOS en ${head:0:7}: lanzando task-fix"
  atender_fix "$num" "$key" "$url" "$head" "$ref" "$lkey"
}

# Caso `revisar`: misma guarda que `caso_fix`. El mensaje sigue distinguiendo
# "respuesta sin push" (ref == head, DEVKIT-22) de "sin informe" (head nuevo).
caso_revisar() {  # caso_revisar <num> <Clave> <head> <ref> <informe>
  local num=$1 key=$2 head=$3 ref=$4 informe=$5 lkey short
  short=${head:0:7}
  lkey="revisar:$num:$head:$ref:$informe"
  avisar_si_lanzada "$num" "$key" revisar "$lkey" && return
  mark "$lkey"
  if [ "$ref" = "$head" ]; then
    log "PR #$num ($key) head $short con respuesta sin push: lanzando pr-review otra vez"
  else
    log "PR #$num ($key) head $short sin informe: lanzando pr-review"
  fi
  run_skill "pr-review-$num-$short" "/pr-review $num" "$lkey" 1 "" "$key"
}

# Caso `fix-humano`: misma guarda que `caso_fix`/`caso_revisar` (DEVKIT-101
# H1). Antes marcaba `fix-humano:$num:$ref` directo y salía mudo si ya estaba
# lanzada: un task-fix que termina sin publicar nada para ese comentario
# (error, cuota) dejaba el comentario atascado para siempre, porque $ref no
# cambia hasta el próximo comentario humano. Con `avisar_si_lanzada`, al
# menos avisa una vez en vez de quedar en silencio.
caso_fix_humano() {  # caso_fix_humano <num> <Clave> <ref> <texto b64>
  local num=$1 key=$2 ref=$3 extra=$4 lkey text
  lkey="fix-humano:$num:$ref"
  avisar_si_lanzada "$num" "$key" fix-humano "$lkey" && return
  mark "$lkey"
  text=$(printf '%s' "$extra" | base64 -d 2>/dev/null)
  log "PR #$num ($key) comentario humano de $ref: lanzando task-fix"
  # La fecha del comentario en el nombre: un PR puede recibir varios
  # comentarios humanos y cada ejecución conserva su log.
  run_skill "task-fix-$num-humano-${ref//[^0-9A-Za-z]/}" "/task-fix $key $text" "$lkey"
}

# Arrastre de hijas de Backlog a Lista (DEVKIT-121): una Épica movida a
# Lista o En progreso no debería quedarse a medias porque una hija -creada a
# mano, o antes de aprobar la Épica- se quedó en Backlog y nadie la arranca.
# `epic-plan` ya crea sus hijas en Lista (paso 5 de su SKILL.md); esto cubre
# las que no pasaron por ahí. Cada pasada del bucle principal (más abajo)
# revisa las Épicas del proyecto en esos dos Estados, mueve a Lista sus
# hijas en Backlog y deja un comentario en la Épica con las Claves movidas.
# Una hija con Criterios de aceptación vacíos o "pendientes de definir"
# (misma regla de cierre de Épica que DEVKIT-44, en task-close.sh) no se
# mueve y se nombra igual en el comentario, para que no quede perdida en
# silencio.
#
# Sin script propio, a diferencia de `lanzar_cola`/`cola.sh`: no hay más
# lógica que una consulta a Notion y un `set` por hija, así que habla con
# `notion.sh` directo, igual que `devkit-run.sh` con `bloqueos`/`epicas`.
#
# Guardado en `launched`, con el conjunto de Claves movidas y pendientes de
# cada Épica: si nada cambió desde la última pasada, no repite el
# comentario. Una hija que ya se movió sale de la siguiente lectura de
# Backlog -ya no aparece-, así que la guarda solo hace falta para la hija
# que se queda pendiente pasada tras pasada.
join_coma() {  # join_coma <elemento>...
  local out="" x
  for x in "$@"; do
    if [ -z "$out" ]; then out="$x"; else out="$out, $x"; fi
  done
  printf '%s' "$out"
}

arrastrar_hijas() {  # arrastrar_hijas <n>
  local n=$1 codigo epicas epica_id epica_clave hijas backlog item hid clave criterios
  local movidas=() pendientes=() lkey comentario
  codigo=$(project_code)
  [ -n "$codigo" ] || return 0
  if ! epicas=$("$NOTION_BIN" epicas-abiertas "$codigo" 2>&1); then
    log "ALARMA: arrastre-$n no pudo leer Épicas abiertas: $(printf '%s' "$epicas" | tail -1 | cut -c1-160)"
    return
  fi
  while IFS=$'\t' read -r epica_id epica_clave; do
    [ -n "$epica_id" ] || continue
    if ! hijas=$("$NOTION_BIN" hijas "$epica_id" 2>&1); then
      log "ALARMA: arrastre-$n ($epica_clave) no pudo leer sus hijas: $(printf '%s' "$hijas" | tail -1 | cut -c1-160)"
      continue
    fi
    backlog=$(jq -c '[.[] | select(.nivel == "Tarea" and .estado == "Backlog")]' <<<"$hijas")
    [ "$(jq 'length' <<<"$backlog")" -gt 0 ] || continue
    movidas=() pendientes=()
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      hid=$(jq -r .id <<<"$item")
      clave=$(jq -r .clave <<<"$item")
      criterios=$("$NOTION_BIN" criterios "$hid" 2>&1) || criterios=""
      if [ -z "$criterios" ] || printf '%s' "$criterios" | grep -qiE 'pendientes? de definir'; then
        pendientes+=("$clave")
      elif "$NOTION_BIN" set "$hid" Estado=Lista >/dev/null 2>&1; then
        movidas+=("$clave")
      else
        log "ALARMA: arrastre-$n no pudo mover $clave (hija de $epica_clave) a Lista"
      fi
    done < <(jq -c '.[]' <<<"$backlog")
    [ "${#movidas[@]}" -gt 0 ] || [ "${#pendientes[@]}" -gt 0 ] || continue
    lkey="arrastre:$epica_clave:$(join_coma "${movidas[@]}")/$(join_coma "${pendientes[@]}")"
    launched "$lkey" && continue
    mark "$lkey"
    comentario=""
    [ "${#movidas[@]}" -eq 0 ] || comentario="Arrastradas de Backlog a Lista: $(join_coma "${movidas[@]}")."
    if [ "${#pendientes[@]}" -gt 0 ]; then
      [ -z "$comentario" ] || comentario="$comentario "
      comentario="${comentario}Con Criterios de aceptación pendientes de definir, sin mover: $(join_coma "${pendientes[@]}")."
    fi
    "$NOTION_BIN" comentar "$epica_id" "$comentario" >/dev/null 2>&1
    log "arrastre-$n ($epica_clave): $comentario"
  done < <(jq -r '.[] | [.id, .clave] | @tsv' <<<"$epicas")
}

# La siguiente card de la cola del proyecto, en bash (DEVKIT-120). Sustituye
# a chain_next/task-next.sh (DEVKIT-56): antes solo miraba las hermanas de
# una Épica, y solo se llamaba al OK del revisor y al merge. cola.sh mira el
# proyecto entero, y esta misma función también se llama en cada pasada del
# sondeo sin nada en curso (bucle principal, más abajo): así cualquier card
# libre en Lista arranca sola, no solo las hijas de una Épica en curso.
# `<n>` solo identifica la línea en watch.log: el número de PR que disparó
# la llamada, o la hora de la llamada del bucle principal, sin PR de por
# medio.
#
# Idempotente: `cola.sh` (sin argumento) no devuelve nada si ya hay una card
# `En progreso` o `Revisión automática` en el proyecto, o un `task-start`
# vivo para una card en `Lista` -la guarda vive en cola.sh, no aquí-, así
# que dos llamadas seguidas no lanzan dos veces.
#
# Persiste entre pasadas del bucle principal, que vive en este mismo proceso
# (DEVKIT-120, H1): guarda el último motivo por el que no se lanzó, para
# avisar una sola vez por motivo y no en cada pasada del sondeo.
LANZAR_COLA_ULTIMO_MOTIVO=""
lanzar_cola() {  # lanzar_cola <n>
  local n=$1 siguiente out rc estado sucio otros motivo
  siguiente=$("$COLA_BIN" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "ALARMA: cola-$n no pudo leer la cola (rc=$rc): $(printf '%s' "$siguiente" | tail -1 | cut -c1-160)"
    return
  fi
  [ -n "$siguiente" ] || return 0
  # Mismo chequeo que task-begin.sh antes de tocar el workspace (DEVKIT-120,
  # H1): sin él, un archivo sin commit o un `claude -p` ajeno hacía fallar
  # `task-start` en cada pasada, y `task_begin_fallo` bloqueaba la cola
  # entera card por card, minuto a minuto.
  sucio=$(git -C "$WS" status --porcelain --untracked-files=all 2>/dev/null)
  if [ -n "$sucio" ]; then
    motivo="workspace sucio: $(printf '%s' "$sucio" | tr '\n' ' ')"
  elif ! otros=$("$DEVKIT_RUN" --otros-agentes 2>&1); then
    motivo="otro agente: $(printf '%s' "$otros" | tr '\n' ' ')"
  fi
  if [ -n "${motivo:-}" ]; then
    if [ "$motivo" != "$LANZAR_COLA_ULTIMO_MOTIVO" ]; then
      log "cola-$n espera: $motivo"
      LANZAR_COLA_ULTIMO_MOTIVO=$motivo
    fi
    return 0
  fi
  LANZAR_COLA_ULTIMO_MOTIVO=""
  out=$(DEVKIT_ORIGEN=bucle "$DEVKIT_RUN" task-start "$siguiente" 2>&1)
  rc=$?
  printf '%s\n' "$out" >"$RUN_DIR/cola-$n.log"
  estado=terminado
  [ "$rc" -eq 0 ] || estado="falló (rc=$rc)"
  log "cola-$n $estado: bash, lanzada la siguiente card: task-start $siguiente :: $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  [ "$rc" -eq 0 ] || log "ALARMA: cola-$n terminó con error (rc=$rc); ver $RUN_DIR/cola-$n.log"
}

# Guarda de modo sobre `lanzar_cola` (DEVKIT-137): ni en pausa ni en alto se
# toma la siguiente card, ni desde el sondeo sin nada en curso ni desde el
# encadenamiento tras documentar -en alto, `pasada` ya no llega a este punto
# desde el sondeo de PRs (corta antes de consultar GitHub), pero el
# encadenamiento tras documentar sigue viniendo de un `procesar_pr` que
# arrancó en modo trabajo y todavía no notó el cambio, así que la guarda
# también hace falta aquí. El aviso de "no se toma la siguiente" no vive
# aquí -se repetiría en cada llamada, una por PR documentado y otra por
# pasada del sondeo- sino en `registrar_cambio_modo`, una sola vez por
# cambio de modo.
#
# Devuelve 75 (pausa) o 76 (alto) -códigos propios, sin relación con el de
# `lanzar_cola`- cuando se saltó: `procesar_pr` los usa para no marcar
# "encadenar" como intentado, así que al volver a trabajo la próxima pasada
# lo vuelve a intentar en vez de darlo por hecho para siempre (DEVKIT-137,
# H1 de la revisión).
intentar_lanzar_cola() {  # intentar_lanzar_cola <n>
  case "$(modo_actual)" in
    pausa) return 75 ;;
    alto) return 76 ;;
  esac
  lanzar_cola "$1"
  return 0
}

# ¿El cuerpo del PR trae la marca "Tipo: decisión" (DEVKIT-92)? La escribe el
# agente de `task-submit` cuando la card cambió una decisión de diseño, no
# solo la implementó; sin ella, la entrada de Documentación es mecánica.
es_decision() {  # es_decision <cuerpo del PR>
  printf '%s\n' "$1" | tr -d '\r' | grep -qx 'Tipo: decisión'
}

# OK del revisor sin documentar (DEVKIT-92): una entrada "decisión" todavía
# necesita al agente (razona el porqué, no lo copia de ningún lado); una
# entrada "cambio" la arma task-document.sh, en bash y sin modelo -por eso ya
# no hay ronda ni modelo que escalar en ella (DEVKIT-83), ni un segundo
# lanzamiento al cerrar (DEVKIT-84): el propio script decide si hay algo que
# escribir.
documentar_pr() {  # documentar_pr <num> <Clave> <head> <cuerpo del PR>
  local num=$1 key=$2 head=$3 cuerpo=$4 name out rc estado
  local short=${head:0:7}
  if es_decision "$cuerpo"; then
    log "PR #$num ($key) OK en $short, marcado Tipo: decisión: lanzando el agente task-document"
    run_skill "task-document-$num-$short" "/task-document $key $num" "documentar:$num:$head"
    return
  fi
  name="task-document-$num-$short"
  log "PR #$num ($key) OK en $short: task-document.sh"
  out=$("$TASK_DOCUMENT" "$key" "$num" 2>&1)
  rc=$?
  printf '%s\n' "$out" >"$RUN_DIR/$name.log"
  estado=terminado
  [ "$rc" -eq 0 ] || estado="falló (rc=$rc)"
  log "$name $estado: bash :: $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  [ "$rc" -eq 0 ] || log "ALARMA: $name terminó con error (rc=$rc); ver $RUN_DIR/$name.log"
}

# Reacción inmediata (DEVKIT-108): decide y actúa sobre un PR, y en cuanto
# termina vuelve a decidir sobre el mismo PR ahí mismo, sin esperar al
# siguiente tick de sleep_or_poke. `caso_revisar`/`caso_fix`/`caso_fix_humano`
# corren `run_skill` de forma síncrona (esperan a que el `claude -p` termine),
# así que apenas vuelven, el estado en GitHub ya cambió (nuevo informe,
# nuevo devkit-fix) y una nueva vuelta de `decide` lo ve. La cadena para
# sola en un estado terminal (nada, bloqueado, una acción sin reconocer) o
# cuando `decide` repite la misma tupla (acción, head, ref, informe) que la
# vuelta anterior: eso significa que `launched` ya la tenía marcada -el aviso
# de `avisar_si_lanzada` ya lo dijo una vez- y no hay nada nuevo que lanzar.
# `MAX_CHAIN_ITER` es solo una cota de seguridad, no la guarda real: esa
# sigue siendo `launched` y la guarda de tres ciclos, ya dentro de `decide` y
# de cada `caso_*`.
MAX_CHAIN_ITER=10

procesar_pr() {  # procesar_pr <num> <url> <title>
  local num=$1 url=$2 title=$3 key pr_full action head ref extra informe short cur prev="" intentos=0
  key=$(key_of "$title" "$CODE") || return 0
  if [ -z "$BOT" ]; then
    log "PR #$num: sin login de la cuenta máquina; se omite"
    return 0
  fi
  while [ "$intentos" -lt "$MAX_CHAIN_ITER" ]; do
    # Guarda de modo (DEVKIT-137, H3): un alto llegado a mitad de la cadena
    # (`run_skill` tarda minutos) corta antes del siguiente `caso_*` en vez
    # de seguir revisando, corrigiendo o documentando otros PRs.
    [ "$(modo_actual)" != alto ] || return 0
    intentos=$((intentos + 1))
    # `body` viaja en la misma consulta que decide() ya hacía (DEVKIT-92): es
    # lo único que necesita el caso `documentar` para saber si el PR trae la
    # marca "Tipo: decisión"; decide() la ignora, sin cambios.
    pr_full=$(gh pr view "$num" --json headRefOid,reviews,comments,body 2>/dev/null)
    IFS=$'\t' read -r action head ref extra informe < <(printf '%s' "$pr_full" | decide "$BOT")
    [ -n "${action:-}" ] || return 0
    short=${head:0:7}
    cur="$action|$head|$ref|$informe"
    case "$action" in
      revisar)
        # La clave incluye $ref y $informe (DEVKIT-101): ver el comentario
        # junto a caso_revisar.
        caso_revisar "$num" "$key" "$head" "$ref" "$informe"
        ;;
      fix)
        caso_fix "$num" "$key" "$url" "$head" "$ref" "$informe"
        ;;
      fix-humano)
        caso_fix_humano "$num" "$key" "$ref" "$extra"
        ;;
      documentar)
        if ! launched "documentar:$num:$head"; then
          mark "documentar:$num:$head"
          documentar_pr "$num" "$key" "$head" "$(jq -r '.body // ""' <<<"$pr_full")"
        fi
        # Después de documentar: la hija nueva hace `git switch` y espera el
        # candado, así que no le quita el turno a la entrada.
        if ! launched "encadenar:$num:$head" && intentar_lanzar_cola "$num"; then
          mark "encadenar:$num:$head"
        fi
        ;;
      nada)
        # OK ya documentado (por ejemplo, en una vida anterior del
        # contenedor): el encadenamiento se intenta igual una vez.
        if [ "$ref" = OK ] && ! launched "encadenar:$num:$head" && intentar_lanzar_cola "$num"; then
          mark "encadenar:$num:$head"
        fi
        return 0
        ;;
      bloquear)
        launched "bloquear:$num:$head" && return 0
        mark "bloquear:$num:$head"
        block_pr "$num" "$key" "$url" "$head" "$ref"
        return 0
        ;;
      bloqueado) return 0 ;;
      *) log "PR #$num: decisión desconocida '$action'"; return 0 ;;
    esac
    [ "$cur" != "$prev" ] || return 0
    prev="$cur"
  done
}

# Cierre de un PR mergeado, en bash (DEVKIT-55). La línea de resumen dice
# cuántos segundos pasaron desde el merge hasta que la card quedó cerrada:
# es la medida del criterio "menos de un minuto".
close_pr() {  # close_pr <num> <Clave> <url> <mergedAt>
  local num=$1 key=$2 url=$3 merged_at=$4 out rc estado desde
  log "PR #$num mergeado ($key): cerrando con task-close.sh"
  out=$("$TASK_CLOSE" "$key" "$url" 2>&1)
  rc=$?
  printf '%s\n' "$out" >"$RUN_DIR/task-close-$num.log"
  desde=$(( $(date +%s) - $(date -d "$merged_at" +%s 2>/dev/null || date +%s) ))
  estado=terminado
  [ "$rc" -eq 0 ] || estado="falló (rc=$rc)"
  log "task-close-$num $estado: bash, cerrado ${desde}s después del merge :: $(printf '%s' "$out" | tail -1 | cut -c1-160)"
  [ "$rc" -eq 0 ] || log "ALARMA: task-close-$num terminó con error (rc=$rc); ver $RUN_DIR/task-close-$num.log"
  log "PR #$num ($key) costo total del ciclo: \$$(cycle_cost "$num") USD"
}

# Una pasada sobre los PRs mergeados en las últimas 48 h.
#
# En alto no hace nada (DEVKIT-137, H4 de la revisión sobre el PR #103):
# cerrar un PR mergeado puede lanzar el agente task-document de una Épica o
# la siguiente card de la cola (cerrar_epica/lanzar_cola dentro de
# task-close.sh), y en alto no debe nacer ninguna skill nueva. No marca
# `cerrar:<n>`, así que el cierre se hace al reanudar, en la siguiente pasada
# de este mismo bucle.
check_merged_prs() {
  local code
  [ "$(modo_actual)" != alto ] || return 0
  code=$(project_code)
  # `-u 3`/`3< <(...)` (DEVKIT-102, H4), no `gh pr list | while ...`: con la
  # tubería, el `while` toma la entrada estándar del bucle entero, así que
  # cualquier hijo lanzado dentro del cuerpo (task-close.sh, y lo que este
  # lance a su vez) la hereda y se come la siguiente fila en vez de leer la
  # suya. Un descriptor propio dejo la entrada estándar real intacta.
  while IFS=$'\t' read -r -u 3 num url merged_at title; do
      key=$(key_of "$title" "$code") || continue
      launched "cerrar:$num" && continue
      IFS=$'\t' read -r action ref < <(
        gh pr view "$num" --json comments 2>/dev/null | decide_merged
      )
      # Sin decisión, gh no respondió: no se registra nada y se reintenta en
      # la vuelta siguiente. Registrarlo aquí perdería el cierre.
      [ -n "${action:-}" ] || continue
      if [ "$action" = "cerrada" ]; then
        # Se registra igual: evita una consulta a GitHub cada vuelta.
        mark "cerrar:$num"
        log "PR #$num mergeado ($key) ya cerrado en ${ref:0:7}: se omite"
        continue
      fi
      # Se registra antes de cerrar: si falla, el humano lo repite con
      # `devkit-run task-close <Clave>`; task-close.sh es idempotente.
      mark "cerrar:$num"
      close_pr "$num" "$key" "$url" "$merged_at"
  done 3< <(gh pr list --state merged --limit 30 --json number,title,url,mergedAt \
    --jq '[.[] | select(.mergedAt > (now - 172800 | todate))] | sort_by(.mergedAt)
           | .[] | "\(.number)\t\(.url)\t\(.mergedAt)\t\(.title)"' 2>/dev/null)
}

# ULTIMO_MODO_REGISTRADO recuerda el último modo que ya se anunció en
# watch.log, para avisar "no se toma la siguiente" una sola vez por cambio de
# modo (DEVKIT-137, criterio de aceptación 1), no en cada pasada ni en cada
# card que hubiera encadenado la cola.
ULTIMO_MODO_REGISTRADO=""
registrar_cambio_modo() {  # registrar_cambio_modo <modo>
  [ "$1" != "$ULTIMO_MODO_REGISTRADO" ] || return 0
  [ "$1" != pausa ] || log "modo pausa: no se toma la siguiente card de la cola hasta reanudar"
  ULTIMO_MODO_REGISTRADO=$1
}

# Una pasada del sondeo (DEVKIT-137). En pausa sigue atendiendo
# pr-review/task-fix/task-document/task-close de las cards ya en curso -por
# eso solo `intentar_lanzar_cola` se salta, no todo el bloque de GitHub-; en
# alto no consulta PRs ni lanza nada nuevo, el vigilante de modo alto
# (`vigilar_alto_once`, en un proceso aparte) es quien atiende lo que ya
# estaba corriendo. El bucle principal, al final del archivo, solo la llama
# en un `while true`; el hook `--pasada` la prueba suelta.
pasada() {
  local modo
  modo=$(modo_actual)
  registrar_cambio_modo "$modo"

  CODE=$(project_code)
  # Cada pasada, antes de drenar la cola: una Épica en Lista o En progreso
  # puede tener hijas nuevas en Backlog -DEVKIT-121- que arrastrar_hijas pasa
  # a Lista, así cola.sh ya las ve en esta misma vuelta.
  [ -z "$CODE" ] || arrastrar_hijas "$(date +%s)"
  # Cada pasada sin nada en curso, la cola drena sola (DEVKIT-120): no hace
  # falta comprobar aquí si hay una card activa, esa guarda ya vive dentro de
  # cola.sh. Antes de la consulta a GitHub: si el proyecto no tiene nada que
  # revisar en PRs abiertos, la card recién lanzada aparece igual en el
  # siguiente `--estado` sin esperar el resto del intervalo.
  [ -z "$CODE" ] || intentar_lanzar_cola "$(date +%s)"

  [ "$modo" != alto ] || return 0

  if [ -d .git ] && [ -n "${GH_TOKEN:-}" ]; then
    BOT="$(gh api user --jq .login 2>/dev/null)"
    log "consultando GitHub"
    check_orphan_branch

    # --- PRs abiertos: revisar, corregir, documentar o bloquear ------------
    # `-u 3`/`3< <(...)` (DEVKIT-102, H4): mismo motivo que check_merged_prs.
    # `procesar_pr` corre `run_skill` de forma síncrona, que a su vez corre
    # `claude -p` -el caso real del PR 68, donde ese `claude -p` se comió la
    # fila de otro PR de esta misma tubería- y también cola.sh,
    # task-document.sh y task-block.sh: con `cmd | while ...`, todos heredan
    # la tubería como entrada estándar.
    while IFS=$'\t' read -r -u 3 num url title; do
        # Guarda de modo (DEVKIT-137, H3): un alto llegado a mitad de esta
        # tubería (cada `procesar_pr` puede tardar minutos) corta antes del
        # siguiente PR en vez de lanzar pr-review/task-fix sobre los que
        # faltan por leer.
        [ "$(modo_actual)" != alto ] || break
        procesar_pr "$num" "$url" "$title"
    done 3< <(gh pr list --state open --limit 30 --json number,title,url \
      --jq '.[] | "\(.number)\t\(.url)\t\(.title)"' 2>/dev/null)
  fi
}

# Hooks de prueba, sin GitHub y sin gastar cuota:
#   --quota-hit             rc 0 si el texto por stdin es un aviso de límite
#   --quota-reset           imprime el epoch de reinicio que lee de ese texto
#   --sleep-or-poke <s>     milisegundos que duró sleep_or_poke <s>; prueba
#                           que tocar /run/devkit/poke la corta antes
#   --run-skill <n> <p> [clave de launched] [Clave]
#                           una ejecución de run_skill, esperando su
#                           relanzamiento; <Clave> es la de Notion, para el
#                           aviso por presupuesto excedido (DEVKIT-94,
#                           DEVKIT-105)
#   --cycle-cost <n> <log>  el costo total del ciclo de un PR, desde un log dado
#   --merged-once           una pasada del bucle de PRs mergeados
#   --block-pr <num> <Clave> <url> <head> <ciclos>
#                           el bloqueo por tres ciclos sin OK
#   --lanzar-cola <n>       la siguiente card de la cola del proyecto
#   --fix <num> <Clave> <url> <head> <ref>
#                           el caso `fix` completo: task-fix, alarma de
#                           task-fix vacío, relanzamiento y bloqueo
#   --documentar <num> <Clave> <head> <cuerpo>
#                           el caso `documentar`: task-document.sh, o el
#                           agente si el cuerpo trae "Tipo: decisión"
#   --caso-fix <num> <Clave> <url> <head> <ref> <informe>
#   --caso-revisar <num> <Clave> <head> <ref> <informe>
#                           la guarda de `launched` con el informe incluido
#                           (DEVKIT-101): si la clave ya está lanzada, avisa
#                           una sola vez y sale; si no, marca y lanza
#   --procesar-pr <num> <url> <título> [código]
#                           la cadena de reacción inmediata completa
#                           (DEVKIT-108): decide, actúa y vuelve a decidir
#                           sobre el mismo PR hasta un estado terminal o sin
#                           progreso; es lo que el bucle principal llama por
#                           cada fila de `gh pr list`
#   --modo-actual           el modo del interruptor de tres posiciones
#                           (DEVKIT-136/137), leído de MODO_FILE
#   --intentar-lanzar-cola <n>
#                           `lanzar_cola`, salvo en pausa o en alto: ahí no
#                           hace nada y sale con 75 (pausa) o 76 (alto)
#                           (DEVKIT-137)
#   --vigilar-alto-once     una pasada del vigilante de modo alto: si hay una
#                           skill en curso (EN_CURSO) y el modo es alto, la
#                           mata, libera skill.lock y bloquea su card
#   --pasada                una pasada completa del sondeo (arrastre, cola,
#                           PRs abiertos), la misma que corre el bucle
#                           principal en cada vuelta, obedeciendo el modo
#   --pasada-n <n>          <n> pasadas seguidas en el mismo proceso, para
#                           probar que el aviso de modo pausa sale una sola
#                           vez y no en cada una (DEVKIT-137)
# Los tres primeros se apoyan en DEVKIT_CLAUDE_BIN y DEVKIT_RUN_DIR; los
# siguientes, en un `gh` de mentira en PATH y DEVKIT_TASK_CLOSE_BIN,
# DEVKIT_TASK_BLOCK_BIN o dobles de notion.sh y devkit-run.sh; `--fix`, en
# ambos; `--caso-fix`/`--caso-revisar`/`--procesar-pr`, en los mismos que
# `--fix`/`--run-skill` y en DEVKIT_RUN_DIR para `launched`. Ver
# watch-test.sh.
case "${1:-}" in
  --quota-hit)
    QHIT_TMP=$(mktemp) && cat >"$QHIT_TMP"
    quota_hit "$QHIT_TMP"; QHIT_RC=$?
    rm -f "$QHIT_TMP"
    exit $QHIT_RC
    ;;
  --quota-reset)
    quota_reset_epoch
    exit 0
    ;;
  --sleep-or-poke)
    # --sleep-or-poke <segundos>: mide en milisegundos cuánto duró
    # sleep_or_poke (DEVKIT-108); la usa watch-test.sh para probar que tocar
    # /run/devkit/poke durante la espera la corta antes de los <segundos>
    # pedidos.
    ini=$(date +%s%N)
    sleep_or_poke "${2:-5}"
    fin=$(date +%s%N)
    echo $(( (fin - ini) / 1000000 ))
    exit 0
    ;;
  --run-skill)
    run_skill "${2:-prueba}" "${3:-/noop}" "${4:--}" 1 "" "${5:-}"
    wait
    exit 0
    ;;
  --cycle-cost)
    cycle_cost "${2:-}" "${3:-}"
    exit 0
    ;;
  --orphan-branch)
    if orphan_branch_alarm "${2:-0}" "${3:-no}" "${4:-si}"; then echo si; else echo no; fi
    exit 0
    ;;
  --agentes-vivos)
    agentes_vivos
    exit 0
    ;;
  --merged-once)
    check_merged_prs
    exit 0
    ;;
  --block-pr)
    block_pr "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    exit 0
    ;;
  --lanzar-cola)
    lanzar_cola "${2:-}"
    exit 0
    ;;
  --intentar-lanzar-cola)
    intentar_lanzar_cola "${2:-}"
    exit $?
    ;;
  --modo-actual)
    modo_actual
    exit 0
    ;;
  --vigilar-alto-once)
    vigilar_alto_once
    exit 0
    ;;
  --pasada)
    pasada
    exit 0
    ;;
  --pasada-n)
    # --pasada-n <n>: <n> pasadas seguidas en el mismo proceso, sin dormir
    # entre medio (DEVKIT-137): a diferencia de invocar `--pasada` <n> veces
    # por fuera, esto sí comparte ULTIMO_MODO_REGISTRADO entre pasadas -como
    # el bucle real, un solo proceso- y prueba que el aviso de modo pausa
    # sale una sola vez, no en cada una.
    for ((_pasada_n_i = 0; _pasada_n_i < ${2:-1}; _pasada_n_i++)); do pasada; done
    exit 0
    ;;
  --arrastrar-hijas)
    arrastrar_hijas "${2:-}"
    exit 0
    ;;
  --documentar)
    documentar_pr "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    exit 0
    ;;
  --fix)
    BOT="${DEVKIT_WATCH_BOT:-$(gh api user --jq .login 2>/dev/null)}"
    atender_fix "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    exit 0
    ;;
  --caso-fix)
    BOT="${DEVKIT_WATCH_BOT:-$(gh api user --jq .login 2>/dev/null)}"
    caso_fix "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
    exit 0
    ;;
  --caso-revisar)
    BOT="${DEVKIT_WATCH_BOT:-$(gh api user --jq .login 2>/dev/null)}"
    caso_revisar "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    exit 0
    ;;
  --caso-fix-humano)
    BOT="${DEVKIT_WATCH_BOT:-$(gh api user --jq .login 2>/dev/null)}"
    caso_fix_humano "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    exit 0
    ;;
  --procesar-pr)
    BOT="${DEVKIT_WATCH_BOT:-$(gh api user --jq .login 2>/dev/null)}"
    CODE="${5:-}"
    procesar_pr "${2:-}" "${3:-}" "${4:-}"
    exit 0
    ;;
esac

log "vigilancia iniciada (cada ${INTERVAL}s, guardia de ${MAX_CYCLES} ciclos; PRs mergeados cada ${MERGED_INTERVAL}s)"

# Bucle de PRs mergeados, aparte del principal (DEVKIT-55): el principal
# queda esperando mientras corre una skill (pr-review, task-fix), que puede
# tardar veinte minutos, y un merge en ese rato no se cerraría hasta que
# terminara. Este no toma `skill.lock`: task-close.sh solo toca Notion y
# GitHub, y su limpieza de git espera a tener el workspace libre.
if [ -d .git ] && [ -n "${GH_TOKEN:-}" ]; then
  ( while true; do check_merged_prs; sleep "$MERGED_INTERVAL"; done ) &
  MERGED_PID=$!
fi

# Vigilante de modo alto (DEVKIT-137), aparte del principal por el mismo
# motivo que el de PRs mergeados: el bucle principal está bloqueado en
# `wait` durante toda una skill síncrona (pr-review, task-fix, ...), así que
# nada dentro de él puede notar a tiempo que el modo cambió a alto. Corre
# siempre, con o sin GH_TOKEN: matar un proceso local no necesita GitHub.
( while true; do vigilar_alto_once; sleep "${DEVKIT_WATCH_ALTO_POLL:-3}"; done ) &
ALTO_PID=$!
trap 'kill "${MERGED_PID:-}" "$ALTO_PID" 2>/dev/null' EXIT

while true; do
  pasada
  sleep_or_poke "$INTERVAL"
done

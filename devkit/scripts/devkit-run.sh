#!/usr/bin/env bash
# Único punto de lanzamiento de una skill de Claude Code, en primer o segundo
# plano (DEVKIT-45, absorbe DEVKIT-18). Antes, un lanzamiento fuera del ciclo
# de `watch.sh` era un `nohup claude -p ...` escrito a mano desde /workspace;
# ahora es un solo comando, y aplica la misma tabla de modelo/esfuerzo por rol
# que usa el bucle.
#
# Uso normal, para un humano o para task-close al tomar la siguiente hija:
#   devkit-run <skill> <Clave> [texto extra...]
#     Arma el prompt "/<skill> <Clave> [texto extra]", lo lanza con `nohup
#     setsid` desde /workspace y vuelve en cuanto confirma que arrancó. Log
#     en /run/devkit/<skill>-<n>.log (n crece si ya hay uno); al terminar,
#     agrega el resumen de costo a watch.log, igual que una skill lanzada por
#     el bucle.
#     Antes de lanzar espera el marcador /run/devkit/ready del arranque del
#     contenedor. Después espera hasta 5 s: si el worker muere en ese rato
#     sin resumen "terminado", imprime las últimas líneas del log y sale con
#     70 (DEVKIT-57). Un `task-start` lanzado con el editor recién abierto
#     imprimió su PID y nunca corrió, y nadie lo supo hasta ir a mirar.
#   devkit-run --seguir <skill> <Clave> [texto extra...]
#     Lanza igual que el uso normal y, en vez de devolver el prompt, se queda
#     mostrando `--estado` hasta que ESTE lanzamiento termine o hasta Ctrl-C
#     (DEVKIT-82). Ctrl-C no mata al lanzamiento -corre con `setsid` desde
#     antes de este bucle, en su propia sesión, fuera del alcance de una
#     señal de la terminal-: solo cierra el monitor, y lo dice en una línea.
#     La última línea al terminar es el resumen de watch.log de ese
#     lanzamiento (`terminado [...]: modelo=... costo=...`).
#
# Qué hace cada agente, sin lanzar otro agente (DEVKIT-57):
#   devkit-run --estado [--seguir] [--todo]
#     Tabla de los últimos lanzamientos: skill (task-start en negrita, abre
#     una card; el resto la continúa, DEVKIT-134), card, el enlace completo
#     al PR de esa fila (DEVKIT-134: el owner/repo real de `gh repo view`,
#     cacheado; "-" sin PR todavía, el caso de task-start), quién lanzó, hace
#     cuánto, cuánto duró (DURÓ: `duracion=` de la línea terminado, o el
#     tiempo desde "lanzando" mientras sigue en curso, DEVKIT-107), estado (en
#     curso, terminó, error, bloqueada, no arrancó, no lanzó -un rc=3 de
#     review-prep.sh o task-begin.sh, "nada que revisar" no es un error-),
#     modelo/esfuerzo y turnos usados contra el presupuesto vigente de
#     roles.toml (TURNOS, con "!" si lo excede, misma cuenta que `--costos`).
#     DETALLE se recorta al ancho de la terminal, y la tabla a su alto -las
#     filas más recientes, con un resumen de cuántas quedaron afuera-; `--todo`
#     desactiva ese recorte de alto (DEVKIT-97). Debajo, un bloque `Consumo`
#     con el porcentaje de cuota del plan en vivo (sesión y semana), leído con
#     `claude -p "/usage"` (DEVKIT-62): es la misma cifra oficial de una
#     sesión interactiva, no una estimación desde watch.log. `--seguir`
#     refresca todo cada 3 s hasta Ctrl-C, con `bucle: ...` en la cabecera:
#     `vivo` (tick reciente), `esperando <skill>-<n>` (una skill de origen
#     bucle en curso explica la falta de tick, sin alarma), `SIN SEÑAL` (ni lo
#     uno ni lo otro) o `MUERTO` (watch.sh no está en `ps`).
#   devkit-run --tablero [--seguir]
#     Cards activas del proyecto (Lista, En progreso, Revisión automática,
#     Lista para merge, Bloqueada) en una tabla de consola: Clave, Estado,
#     Tipo, PR y "bloquea a" (columna de DEVKIT-63), agrupadas por Épica de
#     origen cuando hay más de una Épica En progreso (DEVKIT-80). Una sola
#     consulta a Notion por refresco (DEVKIT-82). `--seguir` la refresca
#     cada 30 s, no 3, para no gastar el límite de peticiones de Notion.
#   devkit-run --cola
#     Las primeras diez cards de la cola (DEVKIT-119): Clave, grupo (Épica de
#     origen o "(sin Épica)") y título, en el mismo orden que decide "la
#     siguiente card" (`cola.sh`). No acepta `--seguir`.
#   devkit-run --costos [<Clave>]
#     Costo por card, leído de /workspace/.devkit/costos.log (DEVKIT-89), que
#     sobrevive a `devkit recreate` a diferencia de watch.log. Con Clave: una
#     fila por lanzamiento (skill, fecha, modelo/esfuerzo/ronda, turnos,
#     costo, minutos) y una fila TOTAL. Sin Clave: una fila por card cerrada
#     en los últimos 30 días, más el promedio. Solo suma lo que ya está en el
#     log; nunca estima. "Card cerrada" se detecta solo por la línea
#     `task-close-N terminado` que deja el bucle (`watch.sh`): un
#     `devkit-run task-close` manual o un cierre resuelto por
#     `project-status` no la dejan, así que esas cards no aparecen en la
#     tabla sin Clave (H6 de pr-review en DEVKIT-89), aunque sí en
#     `--costos <Clave>`.
#
# Uso con anulación manual, para subir o bajar el rol de un lanzamiento
# concreto sin tocar roles.toml:
#   devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high|xhigh|max>] <skill> <Clave> [texto extra...]
#     La línea de resumen en watch.log marca "(anulación manual)".
#
# Modos que usa `watch.sh` (no para uso manual):
#   devkit-run --rol "<prompt>"                     imprime "modelo esfuerzo presupuesto ronda"
#   devkit-run --sync "<prompt>"                    corre en primer plano, JSON por stdout
#   devkit-run --resumen <log> <modelo> <esfuerzo> <presupuesto> [ronda]
#                                                    imprime la línea de costo/tokens/turnos
#   devkit-run --otros-agentes                      lista los `claude -p` ajenos
#                                                    sobre este workspace; sale 0
#                                                    si está libre, 1 si no
#   devkit-run --pregunta-abierta "<resultado>"     sale 0 si el resultado es una
#                                                    pregunta abierta, 1 si no
#   devkit-run --presupuesto-corte <prompt> <log>
#     <presupuesto> <turnos> [clave]                si <turnos> excede <presupuesto>,
#                                                    avisa: ALARMA en watch.log y un
#                                                    comentario en la card, sin
#                                                    bloquear (DEVKIT-105); <clave> es
#                                                    obligatoria para pr-review, que no
#                                                    la trae en el prompt
#   devkit-run --siguiente-modelo <alias>           imprime el modelo disponible
#                                                    que sigue a <alias> en
#                                                    `frontera` (vuelve al primero
#                                                    tras el último)
#   devkit-run --costos-totales <Clave>             "turnos costo minutos revisiones" de
#                                                    la card (DEVKIT-89); la usa
#                                                    task-close.sh para la línea
#                                                    "Costo: ..." del comentario de cierre
#   devkit-run --test                               autoprueba
#
# `--sync` usa DEVKIT_MODELO_FORZADO en vez del modelo del rol cuando viene no
# vacía: así relanza watch.sh un task-fix con otro modelo (DEVKIT-57). Usa
# DEVKIT_RONDA, si viene, en vez de volver a leer el PR (DEVKIT-61).
#
# La tabla rol -> modelo/esfuerzo/turnos vive en devkit/agents/roles.toml.
# Desde DEVKIT-54, el modelo no se elige por Tipo de la card sino por el papel
# de la skill en el flujo: `roles.toml` declara una lista `frontera` ordenada
# de alias de modelo y cada rol un `model_index` (posición 1-based desde la
# que empieza a buscar). El Tipo sigue eligiendo prefijo de rama, pero ya no
# modelo. Desde DEVKIT-61, `implementacion.rondas`
# cambia modelo y esfuerzo según cuántas veces se corrigió el PR (ver
# `model_effort_of`).
# Los permisos (qué puede correr una skill sin pedir permiso) siguen en
# `devkit/agents/settings.json`: este script no los toca ni los reemplaza.
# La entrada de Documentación "Arquitectura del devkit" (Notion), sección 8.2,
# documenta que la lista `allow` de ese archivo no restringe nada en modo
# `-p`/headless (se probó con `claude -p` real:
# comandos fuera de `allow` corren igual); lo que sí bloquea es la lista
# `deny` y el hook `pr-guard.sh`, que ya registra en
# `/run/devkit/denials.log` cada comando que rechaza, para ampliar sus
# reglas cuando bloquee algo legítimo. Ver la entrada de Documentación de
# DEVKIT-45 para la evidencia completa.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
RUN_DIR="${DEVKIT_RUN_DIR:-/run/devkit}"
CLAUDE_BIN="${DEVKIT_CLAUDE_BIN:-claude}"
# Transcripción de cada `claude -p` real, junto a su log (DEVKIT-102): sin
# ella, diagnosticar un caso como el del PR 68 -task-fix leyó una fila ajena
# colada en su propio prompt- exige rastrear a mano los .jsonl de sesión bajo
# `~/.claude/projects/`, que no llevan el nombre del lanzamiento y viven fuera
# de /run/devkit. Configurable para que la autoprueba no toque el directorio
# real.
CLAUDE_PROJECTS_DIR="${DEVKIT_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
ROLES_FILE="${DEVKIT_ROLES_FILE:-}"
if [ -z "$ROLES_FILE" ]; then
  if [ -f "$WS/.devkit/roles.toml" ]; then
    # Anulación por proyecto: $WS/.devkit/roles.toml sobrescribe la tabla del
    # template (DEVKIT-53, H5 de pr-review). Se prueba primero, así gana cuando
    # existe, incluso en modo dev donde también existe ../agents/roles.toml.
    ROLES_FILE="$WS/.devkit/roles.toml"
  elif [ -f "$HERE/../agents/roles.toml" ]; then
    ROLES_FILE="$HERE/../agents/roles.toml"
  else
    # $HERE es /opt/devkit/scripts cuando corre desde el alias de la imagen
    # (o SCRIPTS_DIR fuera de dev): el Dockerfile solo copia scripts/, así
    # que ../agents no existe ahí. TEMPLATE_DIR sí tiene agents/roles.toml
    # siempre: en dev es el symlink a $WS/devkit, y en un proyecto
    # instanciado es el clon del template que hace entrypoint.sh (DEVKIT-50,
    # hallazgo H1 de pr-review).
    ROLES_FILE="${DEVKIT_ROLES_FILE_FALLBACK:-/opt/devkit/template/agents/roles.toml}"
  fi
fi
WATCH_LOG="${DEVKIT_WATCH_LOG:-$RUN_DIR/watch.log}"
# Copia de las líneas `lanzando`/`terminado` de watch.log, fuera de tmpfs
# (DEVKIT-89): $RUN_DIR muere en cada `devkit recreate`, y sin esta copia no
# hay serie histórica de costo por card. $WS es un bind mount al host, así que
# sobrevive. watch.sh no se importa de este archivo, así que repite la misma
# variable y las mismas funciones (mismo patrón que INTERVALO_BUCLE, abajo).
COSTOS_LOG="${DEVKIT_COSTOS_LOG:-$WS/.devkit/costos.log}"
# Cache de disponibilidad de modelo, una vez por arranque: /run/devkit es
# tmpfs y nace vacío en cada `devkit recreate`, igual que /run/devkit/launched
# (DEVKIT-24), así que el resultado no sobrevive a un rebuild y se vuelve a
# comprobar entonces.
FRONTERA_CACHE_DIR="${DEVKIT_FRONTERA_CACHE_DIR:-$RUN_DIR/frontera}"
MODEL_CHECK_TIMEOUT="${DEVKIT_MODEL_CHECK_TIMEOUT:-30}"
# Segundos que vale un `no` en la caché antes de volver a sondear. Un `si` vale
# todo el arranque; un `no` no, porque la sonda no distingue un modelo que no
# existe de una cuota agotada o un corte de red, y la cuota vuelve (DEVKIT-27).
# Cachear el `no` para siempre dejaba `fable` y `opus` fuera hasta el próximo
# `devkit recreate` (DEVKIT-54, H1 de pr-review).
MODEL_RETRY="${DEVKIT_MODEL_RETRY:-600}"
# Mismo candado que `run_skill` en watch.sh: un solo `claude -p` a la vez
# sobre /workspace (DEVKIT-27), para que un `devkit-run` a mano no se pise
# con el bucle. `--sync` no lo toma: lo llama `run_skill`, que ya lo tiene.
LOCK="${DEVKIT_LOCK:-$RUN_DIR/skill.lock}"
# Mismas alarmas de DEVKIT-46 que `run_skill` en watch.sh, para que un
# lanzamiento por `--worker` (manual o desde task-close/epic-plan) avise
# igual que el bucle: skill lenta, con el mismo umbral y sondeo.
SKILL_TIMEOUT="${DEVKIT_WATCH_SKILL_TIMEOUT:-1200}"
SKILL_POLL="${DEVKIT_WATCH_SKILL_POLL:-5}"
# Scripts bash que reemplazan a las skills task-close y task-block (DEVKIT-55).
# Se pueden sustituir por un doble en la autoprueba, para no tocar Notion.
TASK_BLOCK_BIN="${DEVKIT_TASK_BLOCK_BIN:-$HERE/task-block.sh}"
TASK_CLOSE_BIN="${DEVKIT_TASK_CLOSE_BIN:-$HERE/task-close.sh}"
# Pasos mecánicos de task-start, en bash (DEVKIT-90). Sustituible por un doble
# en la autoprueba: las pruebas que no giran alrededor de él no necesitan un
# workspace git + Notion completos solo para que task-start arranque.
TASK_BEGIN_BIN="${DEVKIT_TASK_BEGIN_BIN:-$HERE/task-begin.sh}"
# Pasos 1 a 5 de pr-review y sus comprobaciones mecánicas, en bash (DEVKIT-93):
# `run_claude` lo corre antes de cualquier `claude -p` de pr-review, para que
# un PR sin nada nuevo que juzgar no gaste un lanzamiento en Opus. Sustituible
# por un doble en la autoprueba.
REVIEW_PREP_BIN="${DEVKIT_REVIEW_PREP_BIN:-$HERE/review-prep.sh}"
# Para leer la ronda de un lanzamiento (DEVKIT-61): la card en Notion trae la
# URL del PR, y gh cuenta sus comentarios devkit-fix. Sustituibles por dobles.
NOTION_BIN="${DEVKIT_NOTION_BIN:-$HERE/notion.sh}"
GH_BIN="${DEVKIT_GH_BIN:-gh}"
# La siguiente card por la estrategia fija de la cola (DEVKIT-119). Sustituible
# por un doble en la autoprueba, mismo motivo que NOTION_BIN.
COLA_BIN="${DEVKIT_COLA_BIN:-$HERE/cola.sh}"
# El worker (`nohup ... &`) nace en el mismo grupo de proceso que este script
# (comprobado: sin `set -m`, un `&` no crea grupo propio), así que una señal
# real de la terminal -Ctrl-C- lo alcanzaría igual que a este proceso, aunque
# `nohup` solo ignora SIGHUP. Antes eso no importaba: el script confirmaba el
# arranque y salía en segundos. `--seguir <skill> <Clave>` (DEVKIT-82) lo deja
# corriendo minutos, así que el worker nace con `setsid` en su propia sesión,
# fuera del grupo de la terminal, y una señal a este proceso ya no lo toca.
SETSID_BIN="${DEVKIT_SETSID_BIN:-setsid}"
# Arranque y estado de los lanzamientos (DEVKIT-57). READY lo escribe
# entrypoint.sh como último paso del arranque; `devkit shell` y `devkit code`
# ya lo esperan desde el host, y ahora también `devkit-run`.
READY_FILE="${DEVKIT_READY_FILE:-$RUN_DIR/ready}"
READY_TIMEOUT="${DEVKIT_READY_TIMEOUT:-120}"
# Segundos que espera tras lanzar para confirmar que el worker sigue vivo.
ARRANQUE_ESPERA="${DEVKIT_ARRANQUE_ESPERA:-5}"
# Un lanzamiento sin proceso visible ni resumen cuenta como `en curso` durante
# este margen, contado desde su línea "lanzando": entre esa línea y el
# `claude -p` pasan la sonda de modelos (hasta 30 s por modelo) y el `nohup`.
# El 2026-09-16, `watch.sh --agentes-vivos` dijo "sin agentes vivos" dos
# segundos después de "lanzando pr-review" por mirar solo los procesos.
ESTADO_GRACIA="${DEVKIT_ESTADO_GRACIA:-120}"
ESTADO_FILAS="${DEVKIT_ESTADO_FILAS:-20}"
ESTADO_INTERVALO="${DEVKIT_ESTADO_INTERVALO:-3}"
# Líneas reservadas al calcular cuánta tabla entra en la terminal (DEVKIT-97,
# corregido en H4): el banner + `bucle: ...` + línea en blanco de `--seguir`
# (3), la fila de títulos de la tabla (1), la línea "… N filas más antiguas"
# cuando la tabla se recorta (1) y el bloque `Consumo` que sigue a la tabla
# -en blanco, título, sesión y semana (`mostrar_consumo`): 4, no 1, con la
# cuota oficial legible; menos si falla o no hay lectura todavía, pero contar
# de menos desborda y de más solo achica un poco la tabla. `--estado` sin
# `--seguir` no imprime las primeras tres, pero reservarlas de más solo achica
# un poco la tabla, nunca la desborda -al revés de no reservar nada.
RESERVA_LINEAS_TABLA="${DEVKIT_RESERVA_LINEAS_TABLA:-9}"
# Intervalo del bucle de watch.sh, para juzgar si su último tick "consultando
# GitHub" está viejo (DEVKIT-81, señal de vida de `--estado --seguir`). Mismo
# valor por defecto y misma variable que INTERVAL en watch.sh: los dos
# scripts no se importan entre sí, así que el valor se repite a propósito.
INTERVALO_BUCLE="${DEVKIT_WATCH_INTERVAL:-120}"
# Refresco de `--tablero --seguir` (DEVKIT-82): 30 s, no los 3 s de `--estado
# --seguir`, para no gastar el límite de peticiones por minuto de la API de
# Notion -cada vuelta hace al menos una consulta real, a diferencia de
# `--estado`, que solo toca Notion para "bloquea a"/Épica, cacheado 30 s.
TABLERO_INTERVALO="${DEVKIT_TABLERO_INTERVALO:-30}"
# Margen de `seguir_lanzamiento` (H3, DEVKIT-82) entre que el worker deja de
# responder a `kill -0` y se da por muerto sin resumen: `watch.log` puede
# tardar un instante en terminar de escribirse, así que no basta con un solo
# chequeo fallido.
MARGEN_LANZAMIENTO_MUERTO="${DEVKIT_MARGEN_LANZAMIENTO_MUERTO:-10}"
# `-ww` en todo `ps` que lee argumentos (`args=`), acá y en watch.sh: sin
# ella, `ps` corta cada línea al ancho de COLUMNS/LINES del entorno aunque la
# salida vaya a una tubería, y una terminal integrada (la del editor) los
# exporta. El 2026-09-17 eso dejó la ruta del log fuera de la línea y
# `estado_filas` vio "no arrancó" con el agente vivo; el humano relanzó la
# misma card tres veces sin saberlo (DEVKIT-79). `-ww` (ancho ilimitado)
# ignora esas variables.
PS_BIN="${DEVKIT_PS_BIN:-ps}"
# Marcador de alarmas vistas (DEVKIT-63): `--estado` guarda ahí cuántas líneas
# de watch.log tenía al mostrarlas, y el segmento `!<k>` del prompt cuenta las
# `ALARMA:` posteriores a esa marca en vez de recorrer todo el log cada vez.
ALARMAS_VISTAS="${DEVKIT_ALARMAS_VISTAS:-$RUN_DIR/alarmas-vistas}"
# Timeout de `leer_cuota` (DEVKIT-62): `claude -p "/usage"` es un comando
# local que no llama al modelo (mide bajo 1.5 s aislado), pero un margen
# generoso evita que --estado se cuelgue si la CLI no responde.
CUOTA_TIMEOUT="${DEVKIT_CUOTA_TIMEOUT:-20}"
# La lectura en sí tarda ~1.3 s: --estado nunca la espera en línea (H1 de
# pr-review en DEVKIT-62). CUOTA_TTL es cuánto se muestra una lectura antes de
# refrescarla en segundo plano; CUOTA_CACHE guarda la última lectura con su
# hora, y CUOTA_LOCK evita que dos refrescos corran a la vez. 60 s no es un
# número arbitrario: es la cadencia real con la que el propio `claude -p
# "/usage"` renueva su snapshot, medida con `--debug-file` el 2026-09-19
# (`Usage read answered from a snapshot Ns old`, N subiendo de 0 a ~60 en
# cada lectura sucesiva) — refrescar más seguido no trae un dato más nuevo,
# solo gasta la llamada.
CUOTA_TTL="${DEVKIT_CUOTA_TTL:-60}"
# Espera propia para una lectura fallida (H1, pr-review DEVKIT-78): CUOTA_TTL
# mide la cadencia de una lectura buena, pero un fallo -el binario confirma
# que el de la card fue un 429- reintentado a esa misma cadencia golpea el
# endpoint con el ritmo del propio incidente. No se pudo medir a qué
# intervalo el endpoint vuelve a responder tras un 429 (el fallo no se
# reprodujo), así que se usa 1800 s: el extremo alto del rango 5/15/30 min
# que pedía medir el criterio de la card, el valor más conservador posible
# sin esa medición.
CUOTA_TTL_FALLO="${DEVKIT_CUOTA_TTL_FALLO:-1800}"
CUOTA_CACHE="${DEVKIT_CUOTA_CACHE:-$RUN_DIR/cuota.cache}"
CUOTA_LOCK="${DEVKIT_CUOTA_LOCK:-$RUN_DIR/cuota.lock}"
# Tope de refresco desatendido (DEVKIT-78): el incidente que abrió la card
# corrió `--estado --seguir` sin nadie mirando durante ~2 horas, refrescando
# la cuota cada 60 s (antes, cada 3 s con sesión persistente) cientos de
# veces seguidas. `seguir_estado` y `seguir_lanzamiento` dejan de disparar
# `refrescar_cuota_bg` -sin dejar de mostrar la última lectura buena- pasado
# este margen desde que arrancó el bucle; una `--estado` suelta (alguien
# mirando de verdad) siempre
# refresca si venció CUOTA_TTL, sin este tope.
CUOTA_DESATENDIDO="${DEVKIT_CUOTA_DESATENDIDO:-900}"
# Columna "bloquea a" de `--estado` (ampliación de DEVKIT-63): mismo patrón de
# caché que Consumo, una sola llamada a Notion por refresco. BLOQUEOS_TTL es
# más corto que CUOTA_TTL porque el Estado de una card cambia más seguido que
# la cuota del plan.
BLOQUEOS_TTL="${DEVKIT_BLOQUEOS_TTL:-30}"
BLOQUEOS_CACHE="${DEVKIT_BLOQUEOS_CACHE:-$RUN_DIR/bloqueos.cache}"
BLOQUEOS_LOCK="${DEVKIT_BLOQUEOS_LOCK:-$RUN_DIR/bloqueos.lock}"
# Agrupación por Épica de origen de `--estado` (DEVKIT-80, ampliación de
# DEVKIT-63 que quedó pendiente en el PR #53): mismo patrón de caché que
# Bloqueos, caché aparte porque `notion.sh epicas` trae todo el proyecto
# (Épicas y Tareas), no solo Lista/Lista para merge.
EPICAS_TTL="${DEVKIT_EPICAS_TTL:-30}"
EPICAS_CACHE="${DEVKIT_EPICAS_CACHE:-$RUN_DIR/epicas.cache}"
EPICAS_LOCK="${DEVKIT_EPICAS_LOCK:-$RUN_DIR/epicas.lock}"
# Owner/repo del remoto, para el enlace completo de la columna PR de
# `--estado` (DEVKIT-134). Sin TTL, a diferencia de Bloqueos/Épicas: el
# owner/repo de un proyecto no cambia en la vida de un contenedor, a
# diferencia del Estado de una card -mismo criterio de permanencia que
# CLAVE_DE_PR_CACHE-. Un archivo, no una variable: `estado_filas`/`url_de_pr`
# se llaman desde dentro de `$(...)` anidados (una fila, un `--seguir`), y una
# variable de shell no sobrevive a un subshell descartado -el mismo motivo
# por el que las demás cachés de este archivo son archivos, no variables.
REPO_NAME_WITH_OWNER_CACHE="${DEVKIT_REPO_NAME_WITH_OWNER_CACHE:-$RUN_DIR/repo-name-with-owner.cache}"
# DETALLE de la fila "(en espera)" (DEVKIT-133): mismo patrón de caché que
# Bloqueos/Épicas, sobre `notion.sh activas` -ya la usa `--tablero`- para no
# sumar una consulta nueva a Notion.sh. Aparte de BLOQUEOS_CACHE porque esa
# solo trae una card "Lista para merge" si además bloquea a alguna en Lista
# (columna "bloquea a"): una card "Lista para merge" que solo espera que el
# humano apruebe el PR, sin frenar a nadie, no aparecería ahí.
MERGE_TTL="${DEVKIT_MERGE_TTL:-30}"
MERGE_CACHE="${DEVKIT_MERGE_CACHE:-$RUN_DIR/merge.cache}"
MERGE_LOCK="${DEVKIT_MERGE_LOCK:-$RUN_DIR/merge.lock}"
# Antes de lanzar, `run_claude` comprueba con `claude mcp list` que Notion está
# conectado (DEVKIT-65): todas las skills la necesitan (AGENTS.md), y sin ella
# piden autorizar el conector y no avanzan. En 0 en la autoprueba, que corre
# contra dobles de `claude` sin `mcp list`; las pruebas de esta comprobación
# la reactivan a mano.
NOTION_CHECK="${DEVKIT_NOTION_CHECK:-1}"
# H4 de pr-review (DEVKIT-65): un `task-start` lanzado por `epic-plan` -que a
# su vez corre dentro de otro `claude -p`- terminó tres veces montando el
# conector de Notion con otro nombre de servidor y sin cobertura de
# `--allowedTools` (incidentes reales del 2026-09-16). La hipótesis de que la
# causa son las marcas de sesión anidada que el hijo hereda del padre
# (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, ...) no quedó confirmada: en este
# contenedor, `claude mcp list` con esas marcas puestas a mano y con la lista
# blanca de abajo dio el mismo resultado (comentario de la card, 2026-09-17
# 04:11; repetido en la revisión de pr-review sobre el commit ef9a3fe). Como
# medida defensiva de todas formas, `run_claude` copia al hijo solo las
# variables que de verdad hace falta -identidad de Notion/GitHub, red de
# salida (compose.yaml la fija a nivel de contenedor, ver AGENTS.md) y hora
# local- y descarta todo lo demás con esta lista blanca en vez de con una
# lista negra de marcas de sesión anidada: una CLI nueva puede sumar una
# marca que hoy no conocemos, y una lista negra la dejaría pasar igual.
# H2 de pr-review (DEVKIT-65): revisado el bloque `ENV` del Dockerfile y el
# `environment:` de `compose.yaml` completos. Suman `DISABLE_AUTOUPDATER=1`
# (Dockerfile: sin ella la CLI intenta actualizarse sola, sin salida a
# internet desde `dev`) y `MCP_OAUTH_CALLBACK_PORT=54545` (compose.yaml: el
# plugin de Notion vuelve a este puerto fijo tras el OAuth; sin la variable
# usa uno al azar que el proxy no espera). `TERM` y `UV_PYTHON_INSTALL_DIR`/
# `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` quedan fuera a propósito: `claude -p` no
# es interactivo y no consulta `TERM`, y los tres `UV_*` del Dockerfile ya
# apuntan a rutas bajo `$HOME`, que sí viaja en la lista; sin la variable,
# `uv` cae al mismo valor por defecto. `DEVKIT_PROJECT` y `DEVKIT_VERSION`
# (compose.yaml) también quedan fuera: ninguna skill ni este script las lee.
ENV_HEREDABLE="HOME PATH LANG LC_ALL TZ CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy DISABLE_AUTOUPDATER MCP_OAUTH_CALLBACK_PORT"
# En 0, `run_claude` vuelve al `claude -p` con el entorno completo heredado
# (el comportamiento previo a DEVKIT-65): lo usa la autoprueba de otro
# archivo (`watch-test.sh`) cuyos dobles de `claude` ya simulan estado propio
# con variables sueltas (contador de llamadas, `FIX_DIR`, ...) fuera de
# ENV_HEREDABLE, y no le corresponde conocer esta lista. La comprobación de
# la limpieza vive en la autoprueba de este archivo.
ENV_LIMPIO="${DEVKIT_ENV_LIMPIO:-1}"

# Última coincidencia de "<clave>.<campo> = valor" en roles.toml, sin
# comillas. La clave puede ser un rol (`revision`, `implementacion`) o el
# nombre de una skill puntual (`epic-plan`), para
# anular un campo del rol sin crear un rol nuevo. roles.toml usa claves
# punteadas (TOML válido) a propósito: este grep no necesita entender tablas
# ni tipos, solo esa forma fija.
role_field() {  # role_field <clave> <campo>
  grep -E "^${1}\.${2}[[:space:]]*=" "$ROLES_FILE" 2>/dev/null | tail -1 \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# Lista `frontera = ["a", "b", "c"]` de roles.toml, un alias de modelo por
# línea de salida, en el orden declarado. Es un array, no un escalar, así que
# no usa role_field.
frontera_list() {
  toml_lista frontera
}

# Cualquier lista `<clave> = ["a", "b"]` de roles.toml, un elemento por línea.
# La usan `frontera` y `<rol>.rondas` (DEVKIT-61).
toml_lista() {  # toml_lista <clave>
  local clave=${1//./\\.}
  grep -E "^${clave}[[:space:]]*=" "$ROLES_FILE" 2>/dev/null | tail -1 \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E "s/^${clave}[[:space:]]*=[[:space:]]*\[(.*)\][[:space:]]*\$/\1/" \
    | tr ',' '\n' | sed -E 's/^[[:space:]"]+//; s/[[:space:]"]+$//' | grep -v '^$'
}

# Rol de una skill a partir del primer token del prompt ("/pr-review 31" ->
# "pr-review"). Grupos del criterio de aceptación de DEVKIT-45/DEVKIT-54:
# revisión (pr-review, epic-plan: un mal desglose o una revisión floja cuestan
# más que cualquier card) e implementación (el resto: task-start, task-fix,
# task-submit, task-document). El rol `contabilidad` (task-close, task-block)
# se retiró en DEVKIT-55: esos dos pasos ya no son skills sino scripts bash
# (`task-close.sh`, `task-block.sh`) que no gastan modelo.
role_of() {  # role_of <prompt>
  local skill
  skill=$(printf '%s' "$1" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  case "$skill" in
    pr-review|epic-plan) printf 'revision' ;;
    *) printf 'implementacion' ;;
  esac
}

# Presupuesto de turnos vigente en roles.toml para un skill (DEVKIT-94):
# `presupuesto.<skill>`, o el `max_turns` de su rol si no hay anulación.
# Misma regla que resuelve `model_effort_of` para un lanzamiento nuevo, pero
# a partir del nombre del skill solo, para marcar filas ya cerradas en
# `--costos`. Definida acá, junto a `role_field`/`role_of` de los que depende,
# y no más abajo con el resto de `--costos` (DEVKIT-131 H3): ANCHO_TURNOS la
# llama al cargar el script, antes de que existan las funciones que van
# después en el archivo.
presupuesto_de_skill() {  # presupuesto_de_skill <skill>
  local skill=$1 valor
  valor=$(role_field presupuesto "$skill")
  [ -n "$valor" ] || valor=$(role_field "$(role_of "/$skill")" max_turns)
  printf '%s' "$valor"
}

# Si el modelo <alias> responde, con el resultado cacheado en
# FRONTERA_CACHE_DIR para no repetir la llamada en cada lanzamiento (DEVKIT-54:
# "una llamada mínima por modelo", "una vez por arranque"). Devuelve
# verdadero/falso por código de salida.
#
# "Mínima" hay que forzarlo: una sonda lanzada tal cual desde /workspace hereda
# todo el contexto del proyecto (AGENTS.md, las skills, los servidores MCP) y
# deja de ser una sonda. Medido en DEVKIT-54 con `fable`: 41 s y USD 0.95 para
# responder "ok", con 243k tokens de caché leídos. Como el timeout por defecto
# son 30 s, el primer modelo de la lista se marcaba caído en cada arranque y
# todo el flujo caía al segundo sin que nada lo avisara. Aislada —desde un
# directorio vacío, sin MCP y sin herramientas— la misma sonda tarda 2 s y
# cuesta centavos, que es lo que se quería.
modelo_disponible() {  # modelo_disponible <alias>
  local modelo_id=$1 cache
  cache="$FRONTERA_CACHE_DIR/$modelo_id"
  mkdir -p "$FRONTERA_CACHE_DIR" 2>/dev/null
  if [ -f "$cache" ]; then
    [ "$(cat "$cache" 2>/dev/null)" = "si" ] && return 0
    local edad
    edad=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    [ "$edad" -ge "$MODEL_RETRY" ] || return 1
  fi
  local resultado=no vacio rc err
  vacio=$(mktemp -d)
  # El stderr de la sonda queda junto a la caché para diagnosticar un fallo
  # sin repetir la llamada. Si el directorio no se puede escribir, se descarta:
  # la sonda no debe fallar por no poder guardar su diagnóstico.
  err="$FRONTERA_CACHE_DIR/$modelo_id.err"
  [ -w "$FRONTERA_CACHE_DIR" ] || err=/dev/null
  # `</dev/null` no es decorativo: `claude -p` lee stdin, y esta función se
  # llama desde el bucle de `resolver_modelo`. Sin esto, la primera sonda se
  # comía el resto de la lista de modelos y la resolución terminaba en el
  # último recurso en vez de en el siguiente modelo (DEVKIT-54).
  (cd "$vacio" && timeout "$MODEL_CHECK_TIMEOUT" "$CLAUDE_BIN" -p "ok" \
      --model "$modelo_id" --output-format json \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --disallowedTools "Bash" "Read" "Edit" "Write" "Grep" "Glob" "Skill" \
      </dev/null >/dev/null 2>"$err")
  rc=$?
  [ "$rc" -eq 0 ] && resultado=si
  rm -rf "$vacio"
  printf '%s' "$resultado" > "$cache" 2>/dev/null
  # Solo se registra la sonda que de verdad corrió, no las lecturas de caché:
  # así queda una línea por modelo y por arranque, y la caída al siguiente es
  # visible en watch.log sin tener que reproducirla (DEVKIT-54).
  if [ "$resultado" = "si" ]; then
    printf '%s devkit-run sonda de modelo: %s responde\n' \
      "$(date +%FT%T%:z)" "$modelo_id" >> "$WATCH_LOG" 2>/dev/null
  elif [ "$rc" -eq 124 ]; then
    # 124 es el código de `timeout`: el modelo no contestó a tiempo.
    printf '%s devkit-run sonda de modelo: %s no responde en %ss; cae al siguiente de la lista\n' \
      "$(date +%FT%T%:z)" "$modelo_id" "$MODEL_CHECK_TIMEOUT" >> "$WATCH_LOG" 2>/dev/null
  else
    # Cualquier otro código es un error de la CLI (alias desconocido, cuota,
    # red), casi siempre inmediato: decir "no responde en 30s" lo confundía
    # con un timeout (DEVKIT-54, H2 de pr-review).
    local detalle
    detalle=$(grep -m1 -v '^[[:space:]]*$' "$err" 2>/dev/null | cut -c1-160)
    printf '%s devkit-run sonda de modelo: %s falló (rc=%s): %s; cae al siguiente de la lista\n' \
      "$(date +%FT%T%:z)" "$modelo_id" "$rc" "${detalle:-sin detalle en stderr}" >> "$WATCH_LOG" 2>/dev/null
  fi
  [ "$resultado" = "si" ]
}

# Primer modelo disponible de `frontera`, buscando desde la posición
# <indice_inicial> (1-based) hacia el final de la lista. Si ninguno responde,
# devuelve el último de la lista completa como último recurso: lanzar con el
# modelo más débil vale más que no lanzar nada.
#
# La lista se carga entera en un array antes de sondear nada. Recorrerla con
# `while read` desde un heredoc parecía equivalente y no lo es: la sonda es un
# proceso que también lee stdin, así que se llevaba por delante los modelos que
# faltaban por probar.
resolver_modelo() {  # resolver_modelo <indice_inicial>
  local idx=${1:-1} modelo i=0
  local -a modelos=()
  while IFS= read -r modelo; do
    [ -n "$modelo" ] && modelos+=("$modelo")
  done < <(frontera_list)
  [ "${#modelos[@]}" -gt 0 ] || return 1
  [ -n "$idx" ] || idx=1
  for modelo in "${modelos[@]}"; do
    i=$((i + 1))
    [ "$i" -ge "$idx" ] || continue
    if modelo_disponible "$modelo"; then
      printf '%s' "$modelo"
      return 0
    fi
  done
  printf '%s' "${modelos[$(( ${#modelos[@]} - 1 ))]}"
}

# Modelo disponible que sigue a <alias> en `frontera` (DEVKIT-57). Lo usa
# watch.sh para relanzar un task-fix que respondió "nada que corregir" con un
# CAMBIOS vigente: otro modelo lee el mismo informe con otros ojos. Si <alias>
# es el último o no está en la lista, empieza por el primero; repetir el
# mismo modelo que ya falló no aporta otra lectura.
siguiente_modelo() {  # siguiente_modelo <alias>
  local actual=$1 modelo i=0 pos=0
  local -a modelos=()
  while IFS= read -r modelo; do
    [ -n "$modelo" ] && modelos+=("$modelo")
  done < <(frontera_list)
  [ "${#modelos[@]}" -gt 0 ] || return 1
  for modelo in "${modelos[@]}"; do
    i=$((i + 1))
    [ "$modelo" = "$actual" ] && pos=$i
  done
  [ "$pos" -lt "${#modelos[@]}" ] || pos=0
  resolver_modelo "$((pos + 1))"
}

# --- Escalera de modelos por ronda (DEVKIT-61) ------------------------------
# La ronda de un lanzamiento de implementación es cuántas veces se corrigió ya
# su PR, más uno: task-start y task-submit son siempre la 1 (todavía no hay
# PR); task-fix cuenta los comentarios `<!-- devkit-fix` del PR de la card.
# `implementacion.rondas` en roles.toml dice qué modelo y esfuerzo toca en
# cada ronda. Revisión no tiene ronda: imprime "-". task-document tampoco
# escala (DEVKIT-83, DEVKIT-92): siempre es la ronda 1, sin consultar el PR.

ronda_aviso() {  # ronda_aviso <prompt> <texto>
  printf '%s devkit-run ronda de "%s": %s\n' "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" "$2" \
    >> "$WATCH_LOG" 2>/dev/null
}

# PR de una card: la URL que guarda Notion; si falta, el PR de su rama. La
# rama sale de la card o, sin Notion, de las ramas locales y remotas cuyo
# nombre trae la Clave seguida de un guion (así DEVKIT-6 no toma DEVKIT-61).
pr_de_clave() {  # pr_de_clave <Clave>
  local clave=$1 card pr rama
  card=$("$NOTION_BIN" card "$clave" 2>/dev/null)
  pr=$(jq -r '.pr // empty' <<<"$card" 2>/dev/null)
  if [ -n "$pr" ]; then printf '%s' "$pr"; return 0; fi
  rama=$(jq -r '.rama // empty' <<<"$card" 2>/dev/null | sed -E 's#^.*/tree/##')
  [ -n "$rama" ] || rama=$(git -C "$WS" for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
    | sed -E 's#^origin/##' | grep -E "^[a-z]+/$clave-" | head -1)
  [ -n "$rama" ] || return 1
  pr=$("$GH_BIN" pr list --head "$rama" --state all --limit 1 --json number 2>/dev/null \
    | jq -r '.[0].number // empty' 2>/dev/null)
  [ -n "$pr" ] || return 1
  printf '%s' "$pr"
}

# ¿Terminó un `task-start` sin entregar ni bloquear? (DEVKIT-77). Un buen
# final deja la card en `Revisión automática` (task-submit corrió) o
# `Bloqueada` (task-block.sh corrió, por esta u otra barrera); cualquier otra
# cosa con `task-start` de por medio y la card todavía `En progreso` es el
# corte silencioso que dejó DEVKIT-63. Solo mira `task-start`: es la única
# skill de este grupo que puede terminar "bien" sin haber tocado el Estado.
task_start_sin_entregar() {  # task_start_sin_entregar <prompt> <clave>
  local prompt=$1 clave=$2 skill estado
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  [ "$skill" = task-start ] || return 1
  [ -n "$clave" ] || return 1
  estado=$(jq -r '.estado // empty' <<<"$("$NOTION_BIN" card "$clave" 2>/dev/null)" 2>/dev/null)
  [ "$estado" = "En progreso" ]
}

ronda_de() {  # ronda_de <prompt>
  local prompt=$1 skill clave pr n
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  case "$skill" in
    pr-review|epic-plan) printf -- '-'; return 0 ;;
    # task-document ya no escala (DEVKIT-83): el bucle solo la lanza como
    # agente para una entrada "decisión" o una Épica, ninguna de las dos es
    # una corrección que deba costar más caro en la ronda siguiente.
    task-fix) ;;
    *) printf '1'; return 0 ;;
  esac
  clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  if [ -z "$clave" ]; then
    ronda_aviso "$prompt" "sin Clave en el prompt; uso la ronda 1"
    printf '1'; return 0
  fi
  if ! pr=$(pr_de_clave "$clave"); then
    ronda_aviso "$prompt" "no encuentro el PR de $clave (ni en Notion ni por su rama); uso la ronda 1"
    printf '1'; return 0
  fi
  n=$("$GH_BIN" pr view "$pr" --json comments 2>/dev/null \
    | jq '[.comments[]? | select((.body // "") | contains("<!-- devkit-fix"))] | length' 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*)
      ronda_aviso "$prompt" "no pude leer los comentarios del PR $pr de $clave; uso la ronda 1"
      printf '1' ;;
    *) printf '%s' "$((n + 1))" ;;
  esac
}

# "<modelo> <esfuerzo> <presupuesto de turnos> <ronda>" para un prompt.
#
# Modelo y esfuerzo: si el rol declara `rondas`, el elemento de la ronda
# (`<alias>:<esfuerzo>`, el último si la ronda pasa del largo de la lista),
# con su alias por la misma sonda de `frontera`; si el alias no responde, el
# modelo de `model_index` y una línea en watch.log. Sin `rondas`,
# `model_index` y `effort` del rol, como antes de DEVKIT-61. `revision` no
# escala: su `rondas` se ignora con aviso. Tanto el modelo como el esfuerzo
# admiten además una anulación por skill (por ejemplo `epic-plan.model_index`
# o `epic-plan.effort`, DEVKIT-72), que manda sobre el valor del rol.
#
# [ronda] viene cuando quien llama ya la resolvió (watch.sh la pasa de `--rol`
# a `--sync` en DEVKIT_RONDA): no se vuelve a consultar el PR ni se repiten
# los avisos en watch.log.
#
# El presupuesto de turnos sigue la misma regla que el esfuerzo: el
# `max_turns` del rol, anulado por `presupuesto.<skill>` si roles.toml trae
# una entrada (DEVKIT-94). `--worker` lo usa para cortar y bloquear la card
# cuando el lanzamiento se pasa, no solo para avisar.
model_effort_of() {  # model_effort_of <prompt> [ronda]
  local role skill idx modelo esfuerzo turnos ronda avisar=1 elem alias esf i
  local -a rondas=()
  skill=$(printf '%s' "$1" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  role=$(role_of "$1")
  if [ -n "${2:-}" ]; then ronda=$2; avisar=""; else ronda=$(ronda_de "$1"); fi
  idx=$(role_field "$role" model_index)
  i=$(role_field "$skill" model_index)
  [ -z "$i" ] || idx=$i
  esfuerzo=$(role_field "$role" effort)
  while IFS= read -r elem; do rondas+=("$elem"); done < <(toml_lista "$role.rondas")
  if [ "$role" = revision ]; then
    if [ "${#rondas[@]}" -gt 0 ] && [ -n "$avisar" ]; then
      printf '%s devkit-run "%s": revision.rondas se ignora; el revisor no escala (DEVKIT-61)\n' \
        "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" >> "$WATCH_LOG" 2>/dev/null
    fi
    ronda="-"
    modelo=$(resolver_modelo "$idx")
  elif [ "${#rondas[@]}" -gt 0 ] && [[ "$ronda" =~ ^[0-9]+$ ]] && [ "$ronda" -ge 1 ]; then
    i=$ronda
    [ "$i" -le "${#rondas[@]}" ] || i=${#rondas[@]}
    elem=${rondas[$((i - 1))]}
    alias=${elem%%:*}
    esf=""
    case "$elem" in *:*) esf=${elem#*:} ;; esac
    [ -z "$esf" ] || esfuerzo=$esf
    if [ -n "$alias" ] && modelo_disponible "$alias"; then
      modelo=$alias
    else
      modelo=$(resolver_modelo "$idx")
      [ -z "$avisar" ] || ronda_aviso "$1" "ronda $ronda pide ${alias:-un alias vacío}, que no responde; uso $modelo (model_index del rol)"
    fi
  else
    modelo=$(resolver_modelo "$idx")
  fi
  esf=$(role_field "$skill" effort)
  [ -z "$esf" ] || esfuerzo=$esf
  turnos=$(role_field "$role" max_turns)
  i=$(role_field presupuesto "$skill")
  [ -z "$i" ] || turnos=$i
  # Campos vacíos como "-": `read` parte por espacios y se salta los campos
  # vacíos, así que un modelo vacío se leía como si fuera el esfuerzo
  # (DEVKIT-55).
  printf '%s %s %s %s' "${modelo:--}" "${esfuerzo:--}" "${turnos:--}" "${ronda:--}"
}

# Ejecuta la skill en primer plano; deja el JSON de `claude -p` en stdout.
#
# DEVKIT_SCRIPTS_DIR y DEVKIT_RUN_DIR se exportan al `claude -p` (DEVKIT-55).
# Las skills invocan scripts por ruta,
# `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/..."`, y la variable solo
# vivía en /run/devkit/env, que carga la shell del humano: ni watch.sh ni el
# agente la tenían. El respaldo /opt/devkit/scripts es la copia de la imagen,
# que en modo dev queda atrás del workspace; la del 2026-09-16 no entendía
# `frontera`, resolvió un modelo vacío y el `task-start DEVKIT-55` que lanzó
# `task-close` murió en el primer turno. El valor es $HERE y no lo que traiga
# el entorno: el script que resolvió este lanzamiento es el que deben usar
# los lanzamientos que salgan de él.
#
# DEVKIT_ORIGEN y DEVKIT_MODELO_FORZADO van vacías: describen este lanzamiento,
# no los que la skill haga después (DEVKIT-57). Un epic-plan que lanza
# task-start debe verse como origen `epic-plan`, no heredar el de su lanzador.
#
# DEVKIT_MODEL y DEVKIT_EFFORT son el modelo y el esfuerzo que recibe este
# `claude -p`, ya resueltos: rol, caída en `frontera`, `--modelo`/`--esfuerzo`
# o DEVKIT_MODELO_FORZADO (DEVKIT-58). Las skills los copian en la línea
# "<Verbo> con <modelo>, esfuerzo <x>" del PR, del informe de revisión y de
# la entrada de Documentación, para decidir con evidencia qué modelo alcanza
# para cada papel. Se leen de aquí y no de roles.toml porque solo este punto
# sabe qué se lanzó de verdad.
#
# DEVKIT_SKILL es el nombre de la skill de este lanzamiento, sin la barra
# (DEVKIT-91): `hook-stop.sh` lo lee para saber si corre dentro de un
# task-start o un task-fix -las dos skills que dejan la card a medio
# entregar si el agente termina de más- y quedarse fuera en cualquier otra.
# Vale lo mismo durante toda la sesión, aunque el agente invoque `task-submit`
# como sub-skill dentro de ella.
#
# Líneas "NOMBRE=valor" de ENV_HEREDABLE presentes en el entorno de quien
# llama, para copiarlas al `claude -p` hijo con `env -i` (DEVKIT-65). Función
# aparte para poder probarla sin lanzar nada de verdad.
entorno_hijo() {
  local nombre
  for nombre in $ENV_HEREDABLE; do
    [ -z "${!nombre:-}" ] || printf '%s=%s\n' "$nombre" "${!nombre}"
  done
}

# Aviso de DEVKIT-65: sin Notion conectado en el entorno del `claude -p`
# hijo, todas las skills piden autorizar el conector y no avanzan. Mejor
# avisarlo antes que dejarlo fallar a medias.
alarma_sin_notion() {  # alarma_sin_notion <prompt>
  printf 'devkit-run: el servidor de Notion no está conectado en el entorno del lanzamiento ("%s mcp list"); no se lanza "%s".\n' \
    "$CLAUDE_BIN" "$1" >&2
  printf '%s devkit-run "%s" ALARMA: sin Notion conectado (claude mcp list); no se lanza\n' \
    "$(date +%FT%T%:z)" "$1" >> "$WATCH_LOG" 2>/dev/null
}

# Perfil de herramientas por skill (DEVKIT-125). pr-review y task-document no
# tocan la rama: revisar y documentar es leer más los scripts mecánicos que
# ya hacen la escritura que necesitan (review-publish.sh mueve la card y
# publica la review, notion.sh escribe la entrada de Documentación), así que
# reciben Bash acotado a patrones concretos, sin Edit ni Write, y
# `--permission-mode default` en vez de `acceptEdits`. Así, un agente
# confundido que responda a un hallazgo de otro PR (DEVKIT-102) puede a lo
# sumo leer, no empujar un cambio. task-start, task-fix y epic-plan sí
# escriben la rama de la card: siguen con el perfil amplio de siempre.
#
# Los patrones de Bash van con la ruta real de $HERE, nunca con la sintaxis
# `"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/..."` que usan las skills de
# perfil amplio: Claude Code rechaza con "Contains expansion" cualquier
# comando que traiga una expansión de variable, antes de mirar la lista
# allow, así que un patrón con esa sintaxis nunca hace match (DEVKIT-125,
# revisión del PR 92, H1). `run_claude` inyecta la misma ruta real como texto
# plano en la primera línea del prompt para que la skill arme el comando sin
# `$` de por medio.
#
# Solo pr-review recibe además permiso para correr `--test` sobre los
# scripts que de verdad existen en el worktree que `review-prep.sh` ya dejó
# armado (DEVKIT-93): las comprobaciones mecánicas fijas de la rúbrica
# (`devkit-run.sh --test`, `watch-test.sh`) ya corrieron y están en
# `## Material`, pero un criterio de la card puede pedir el `--test` de otro
# script (p. ej. `pr-guard.sh`) que esa lista fija no cubre. Un patrón con un
# `*` a mitad de ruta (`.../*.sh`) tampoco hace match: la sintaxis `:*` de
# Claude Code es un prefijo literal seguido de comodín al final, no un glob de
# shell (H4), así que en vez de eso se expande la lista real de scripts del
# worktree aquí mismo, con el glob de bash, y se agrega un patrón literal por
# cada uno. Por el mismo motivo, la lectura de git queda acotada a ese
# worktree con `git -C <worktree>` en vez del `git diff`/`log`/`show` sin
# argumentos que solo sirve sobre /workspace (H7). `bash -n` también va con
# un patrón literal por script: `Bash(bash -n <worktree>:*)` no hacía match
# con `<worktree>/devkit/scripts/x.sh`, y un `Bash(bash -n:*)` genérico
# admitiría `bash -n +n x.sh`, que vuelve a activar la ejecución. `ruff
# check` y `pytest` no llevan patrón propio: ya los autoriza `settings.json`
# (`Bash(ruff:*)`, `Bash(pytest:*)`) sobre cualquier ruta.
#
# Imprime el modo de permiso en la primera línea y, una por línea, cada
# argumento de `--allowedTools`, para que `run_claude` los junte con
# `mapfile` sin depender de cómo separe espacios un array armado a mano.
perfil_de() {  # perfil_de <skill> [worktree de pr-review]
  local skill=$1 worktree=${2:-}
  case "$skill" in
    pr-review|task-document)
      printf '%s\n' default \
        Read Grep Glob Skill \
        mcp__plugin_Notion_notion mcp__claude_ai_Notion \
        'Bash(gh pr:*)' 'Bash(gh api:*)' \
        'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git show:*)' \
        "Bash($HERE/review-prep.sh:*)" \
        "Bash($HERE/review-publish.sh:*)" \
        "Bash($HERE/notion.sh:*)"
      if [ "$skill" = pr-review ] && [ -n "$worktree" ]; then
        local script
        for script in "$worktree"/devkit/scripts/*.sh; do
          [ -e "$script" ] || continue
          printf 'Bash(bash %s --test:*)\n' "$script"
        done
        printf 'Bash(git -C %s diff:*)\n' "$worktree"
        printf 'Bash(git -C %s log:*)\n' "$worktree"
        printf 'Bash(git -C %s show:*)\n' "$worktree"
        printf 'Bash(git -C %s grep:*)\n' "$worktree"
        for script in "$worktree"/*.sh "$worktree"/devkit/*.sh \
                      "$worktree"/devkit/*/*.sh; do
          [ -e "$script" ] || continue
          printf 'Bash(bash -n %s:*)\n' "$script"
        done
      fi
      ;;
    *)
      printf '%s\n' acceptEdits \
        Bash Read Edit Write Grep Glob Skill \
        mcp__plugin_Notion_notion mcp__claude_ai_Notion
      ;;
  esac
}

# Complemento de `perfil_de` (DEVKIT-125, revisión del PR 92, H5 y H9):
# `--allowedTools` solo se suma a la lista `allow` de
# `devkit/agents/settings.json`, que sigue autorizando `git add`, `git
# commit`, `git push` a las ramas de card, `gh pr merge --auto`, `uv`/`uvx`
# (ejecutan cualquier cosa, incluido un `git push` como subproceso que el
# motor de permisos no ve), `git checkout`/`switch`/`pull`/`worktree`
# (reescriben `/workspace`), `find` (con `-delete` o `-exec`), `gh pr edit`,
# `gh issue`, `git branch` (incluido `-D` sobre ramas de card) y `git fetch`
# para el perfil amplio (H10: el `fetch` que necesita pr-review ya lo hace
# `review-prep.sh` por dentro). Sin negarlos aparte, pr-review y
# task-document podrían usarlos igual pese a que el perfil restringido no los
# incluye en su lista allow. `--disallowedTools` sí gana sobre cualquier
# `allow`, sea de `--allowedTools` o de `settings.json`, así que aquí se
# niegan explícitos. Vacío para el perfil amplio: task-start, task-fix y
# epic-plan sí necesitan escribir la rama.
#
# Riesgo residual, sin cerrar aquí (H9): `gh api` sigue permitido para que
# pr-review y task-document lean la API de GitHub, pero admite también un
# `PUT /pulls/N/merge` u otra escritura. Queda para la entrada de
# Documentación de esta card.
perfil_disallow_de() {  # perfil_disallow_de <skill>
  case "$1" in
    pr-review|task-document)
      printf '%s\n' Edit Write NotebookEdit \
        'Bash(git add:*)' 'Bash(git commit:*)' 'Bash(git push:*)' \
        'Bash(gh pr merge:*)' \
        'Bash(uv:*)' 'Bash(uvx:*)' \
        'Bash(git checkout:*)' 'Bash(git switch:*)' 'Bash(git pull:*)' \
        'Bash(git worktree:*)' 'Bash(find:*)' \
        'Bash(gh pr edit:*)' 'Bash(gh issue:*)' \
        'Bash(git branch:*)' 'Bash(git fetch:*)'
      ;;
  esac
}

run_claude() {  # run_claude <prompt> <modelo> <esfuerzo>
  local skill prompt=$1
  skill=$(printf '%s' "$1" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  # Preparación mecánica de pr-review (DEVKIT-93): antes de gastar un solo
  # turno de Opus, `review-prep.sh` repite los pasos 1 a 5 de la skill y sus
  # comprobaciones de la rúbrica en bash. Salida 3: nada que revisar (PR
  # cerrado, sin card, o ya revisado sin respuesta del corrector, DEVKIT-74);
  # se corta aquí, sin `claude -p`, y el motivo queda en stdout para que quien
  # llama lo deje en watch.log sin ALARMA. Cualquier otra salida distinta de
  # cero es un fallo real (gh/Notion no respondieron) y se corta igual, con el
  # motivo en stderr.
  local worktree=""
  if [ "$skill" = pr-review ]; then
    local numero material prep_rc
    numero=$(printf '%s' "$1" | grep -oE '[0-9]+' | head -1)
    worktree="${DEVKIT_REVIEW_WORKTREE_DIR:-/tmp}/devkit-review-$numero"
    material=$("$REVIEW_PREP_BIN" "$numero" 2>&1)
    prep_rc=$?
    if [ "$prep_rc" -eq 3 ]; then
      printf '%s\n' "$material"
      return 3
    elif [ "$prep_rc" -ne 0 ]; then
      printf '%s\n' "$material" >&2
      return "$prep_rc"
    fi
    prompt="$1

## Material
$material"
  fi
  local -a extra=(
    "DEVKIT_ORIGEN=" "DEVKIT_MODELO_FORZADO=" "DEVKIT_RONDA="
    "DEVKIT_MODEL=$2" "DEVKIT_EFFORT=$3" "DEVKIT_SKILL=$skill"
    "DEVKIT_SCRIPTS_DIR=$HERE" "DEVKIT_RUN_DIR=$RUN_DIR"
  )
  [ -z "${DEVKIT_LOCK_HELD:-}" ] || extra+=("DEVKIT_LOCK_HELD=$DEVKIT_LOCK_HELD")
  [ -z "${DEVKIT_LANZADOR:-}" ] || extra+=("DEVKIT_LANZADOR=$DEVKIT_LANZADOR")

  local -a lanzador
  if [ "$ENV_LIMPIO" = 0 ]; then
    lanzador=(env "${extra[@]}")
  else
    local -a entorno
    mapfile -t entorno < <(entorno_hijo)
    entorno+=("${extra[@]}")
    lanzador=(env -i "${entorno[@]}")
  fi

  # La sonda usa el mismo entorno que el lanzamiento real: comprobar con el
  # entorno de quien llama (con marcas de sesión anidada de sobra) daría un
  # falso "no conectado" justo en el caso que la lista blanca de arriba
  # arregla.
  #
  # `</dev/null` en las dos llamadas de acá abajo no es decorativo, mismo
  # motivo que en `modelo_disponible` (DEVKIT-54): `claude` lee stdin. Sin
  # esto, un lanzamiento hecho desde dentro de un `while read` sobre una
  # tubería (watch.sh:1061, `gh pr list | while read -r num url title; do ...
  # run_skill ...; done`) hereda esa tubería como su entrada estándar y se
  # come la fila que le tocaba a la siguiente vuelta del bucle, que termina
  # pegada al final del prompt real. Pasó con task-fix sobre el PR 68
  # (DEVKIT-94): se tragó la fila de PR #67/DEVKIT-93 de `gh pr list` y la
  # leyó como si fuera "texto recibido como argumento" (paso 3 de la skill),
  # así que respondió un hallazgo `C1` inventado y nunca llegó a los cinco
  # hallazgos reales del informe (DEVKIT-102).
  if [ "$NOTION_CHECK" != 0 ] \
     && ! "${lanzador[@]}" "$CLAUDE_BIN" mcp list </dev/null 2>/dev/null | grep -qiE 'notion.*(connected|✔)'; then
    alarma_sin_notion "$1"
    return 67
  fi
  local -a perfil perfil_disallow
  mapfile -t perfil < <(perfil_de "$skill" "$worktree")
  mapfile -t perfil_disallow < <(perfil_disallow_de "$skill")

  # Cabecera de metadatos (DEVKIT-125, revisión del PR 92, H1, H3 y H8):
  # pr-review y task-document arman comandos con la ruta de los scripts y con
  # la marca "Revisado/Documentado con <modelo>, esfuerzo <x>". Antes lo
  # hacían con `${DEVKIT_SCRIPTS_DIR:-...}` y `echo "...${DEVKIT_MODEL:-?}..."`,
  # pero Claude Code rechaza con "Contains expansion" cualquier comando de
  # Bash que traiga una expansión de variable, sea o no el patrón allow
  # correcto (H1, H3). La variable sigue exportada (extra[], abajo) para las
  # skills de perfil amplio que ya la usan así sin problema bajo
  # `acceptEdits`; esta cabecera es solo para las que corren en `default` y
  # no pueden depender de que el shell expanda nada. Una sola línea de texto
  # plano, sin `$`: la skill copia el valor tal cual, no lo evalúa.
  #
  # Va como segunda línea del prompt, después de la línea `/skill ...`, no
  # antes (H8): Claude Code solo interpreta un slash command cuando es lo
  # primero que trae el mensaje, así que anteponer la cabecera dejaba el
  # prompt entero como texto plano y la skill solo se cargaba si el modelo
  # decidía invocarla por su cuenta. Limitado a pr-review/task-document: son
  # las únicas que la necesitan (H8); task-start, task-fix y epic-plan corren
  # con `acceptEdits` y ya usan `$DEVKIT_MODEL`/`$DEVKIT_EFFORT` sin problema.
  case "$skill" in
    pr-review|task-document)
      local cabecera="(DEVKIT_SCRIPTS_DIR=$HERE DEVKIT_MODEL=$2 DEVKIT_EFFORT=$3)"
      if [[ $prompt == *$'\n'* ]]; then
        prompt="${prompt%%$'\n'*}
$cabecera
${prompt#*$'\n'}"
      else
        prompt="$prompt
$cabecera"
      fi
      ;;
  esac
  local -a claude_args=(
    -p "$prompt"
    --model "$2" --effort "$3" --output-format json
    --permission-mode "${perfil[0]}"
    --allowedTools "${perfil[@]:1}"
  )
  [ "${#perfil_disallow[@]}" -eq 0 ] || claude_args+=(--disallowedTools "${perfil_disallow[@]}")
  # DEVKIT-125, revisión del PR 92, H7 reabierto: Claude Code solo deja leer
  # archivos con `git`/`bash -n`/`ruff`/`pytest` dentro de los directorios de
  # trabajo de la sesión, y por defecto esa lista trae únicamente `/workspace`.
  # Los patrones de `perfil_de` que apuntan al worktree de `review-prep.sh`
  # (DEVKIT-93) nunca hacían match sin esto: `git -C <worktree> diff/log/show`
  # salía con "was blocked ... only access files ... allowed working
  # directories: /workspace". `--add-dir` es justo la vía que Claude Code
  # documenta para sumar un directorio a esa lista.
  [ "$skill" = pr-review ] && [ -n "$worktree" ] && claude_args+=(--add-dir "$worktree")
  "${lanzador[@]}" "$CLAUDE_BIN" "${claude_args[@]}" </dev/null
}

# Copia recortada de la transcripción de un `claude -p` real, junto a su log
# (DEVKIT-102). `<logf>` ya trae el JSON de resultado en su última línea, con
# `session_id`: de ahí sale el nombre del `.jsonl` de sesión, bajo
# `$CLAUDE_PROJECTS_DIR/<cwd con / por ->/`, la misma regla que usa Claude
# Code para nombrar esa carpeta. Sin `session_id` (un log vacío o sin JSON,
# por ejemplo un rc=3 de "nada que revisar") no hay nada que copiar.
#
# Se queda solo con el primer turno de usuario -trae el argumento tal como
# llegó, `<command-args>` incluido: es lo que habría mostrado de inmediato que
# el PR 68 recibió una fila ajena de PR 67 en vez de su propio argumento- y el
# resultado ya presente en `<logf>`, no la sesión entera: una skill de quince
# turnos deja un archivo de un puñado de líneas, no un volcado completo.
#
# Vive aquí y no en watch.sh (mudanza de DEVKIT-102, H2): así también cubre
# `--worker` (task-start, task-close, epic-plan y `devkit-run <skill>
# <Clave>` manual), no solo el bucle. Watch.sh la llama con `--guardar-
# transcripcion` en vez de repetirla.
guardar_transcripcion() {  # guardar_transcripcion <logf> <destino>
  local logf=$1 destino=$2 session_id slug transcript primera
  session_id=$(tail -1 "$logf" 2>/dev/null | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$session_id" ] || return 0
  slug=$(printf '%s' "$WS" | tr '/' '-')
  transcript="$CLAUDE_PROJECTS_DIR/$slug/$session_id.jsonl"
  [ -f "$transcript" ] || return 0
  primera=$(jq -c 'select(.type == "user")' "$transcript" 2>/dev/null | head -1)
  [ -n "$primera" ] || return 0
  {
    printf '%s\n' "$primera"
    tail -1 "$logf"
  } > "$destino" 2>/dev/null
}

# Línea de costo/tokens/turnos/modelo/esfuerzo de un log ya terminado. La
# comparten `run_skill` (watch.sh) y el modo `--worker` de este script, para
# no repetir el `jq` en dos archivos. `ronda=` va justo después de `esfuerzo=`
# (DEVKIT-61): `cycle_cost` suma `costo=` y `--estado` lee el encabezado de la
# línea, así que ninguno de los dos depende de lo que hay entre medio.
resumen() {  # resumen <log> <modelo> <esfuerzo> <presupuesto> [ronda]
  local logf=$1 modelo=$2 esfuerzo=$3 presupuesto=$4 ronda=${5:--} linea turnos excedido=""
  # `duracion=` sale de `duration_ms` del propio JSON de `claude -p`, no del
  # reloj del monitor (DEVKIT-89, criterio 3): así un lanzamiento leído mucho
  # después de terminar (por ejemplo, al reconstruir costos.log) mide igual.
  linea=$(tail -1 "$logf" 2>/dev/null | jq -r '
    "costo=\(.total_cost_usd // "?") turnos=\(.num_turns // "?") duracion=\(if .duration_ms then ((.duration_ms / 1000 | floor) | tostring) else "?" end)s tokens: entrada=\(.usage.input_tokens // "?") cache=\(.usage.cache_read_input_tokens // "?") salida=\(.usage.output_tokens // "?") :: \((.result // "") | gsub("\n"; " ") | .[0:160])"' 2>/dev/null)
  [ -n "$linea" ] || linea="$(tail -1 "$logf" 2>/dev/null | cut -c1-160)"
  turnos=$(tail -1 "$logf" 2>/dev/null | jq -r '.num_turns // empty' 2>/dev/null)
  if [ -n "$presupuesto" ] && [ "$presupuesto" != "-" ] && [ -n "$turnos" ] \
     && [ "$turnos" -gt "$presupuesto" ] 2>/dev/null; then
    excedido=" (excede el presupuesto de $presupuesto turnos de roles.toml)"
  fi
  printf 'modelo=%s esfuerzo=%s ronda=%s %s%s' "$modelo" "$esfuerzo" "$ronda" "$linea" "$excedido"
}

# ¿La línea de watch.log (ya con fecha) es un lanzamiento o un cierre -exitoso
# o con error- de una de las seis skills que mide `--costos` (DEVKIT-89:
# task-start, pr-review, task-fix, task-document, task-close, epic-plan)? Un
# cierre con error también gastó turnos y costo, así que cuenta igual que uno
# exitoso (H2 de pr-review en DEVKIT-89): "ALARMA: <id> terminó con error" es
# el formato de `run_skill` en watch.sh, "falló (rc=" el de `devkit-run.sh` y
# el de `task-close-N` en bash. Sin este filtro, costos.log arrastraría
# también las líneas narrativas del bucle ("PR #31 ... lanzando pr-review")
# y las de task-block/cola, que no aportan costo/turnos y solo inflarían un
# archivo que vive fuera de tmpfs y no se rota nunca.
costos_log_candidata() {  # costos_log_candidata <línea con fecha>
  case "$1" in
    *" lanzando "*|*" terminado"*|*" terminó con error"*|*" falló (rc="*|*" no lanzó: "*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '[ \[](task-start|pr-review|task-fix|task-document|task-close|epic-plan)-'
}

# Copia a costos.log, si corresponde (DEVKIT-89). watch.sh tiene su propia
# copia de esta función: los dos scripts no se importan entre sí.
costos_log() {  # costos_log <línea completa, con fecha>
  costos_log_candidata "$1" || return 0
  mkdir -p "$(dirname "$COSTOS_LOG")" 2>/dev/null
  printf '%s\n' "$1" >> "$COSTOS_LOG" 2>/dev/null
}

# Cuota del plan, leída en vivo con `claude -p "/usage"` (DEVKIT-62). La
# compuerta de la card probó que sí existe una fuente oficial legible por
# script: la CLI responde con el mismo texto que `/usage` en una sesión
# interactiva, como comando local que no gasta turnos ni cuota
# (`duration_api_ms=0`, `total_cost_usd=0`). No hay campo numérico
# estructurado para el porcentaje, así que se extrae del texto con una
# expresión regular sobre sus dos líneas fijas. Aislada igual que
# `modelo_disponible` (directorio vacío, sin MCP): --estado no necesita
# heredar el contexto de /workspace para esta lectura.
leer_cuota() {  # leer_cuota -> "sesion_pct<TAB>sesion_reset<TAB>semana_pct<TAB>semana_reset"
  local vacio salida texto linea_sesion linea_semana sesion_pct sesion_reset semana_pct semana_reset
  vacio=$(mktemp -d)
  # --no-session-persistence (H2 de pr-review en DEVKIT-62): sin ella, cada
  # lectura deja una sesión de Claude Code en ~/.claude/projects/, que con
  # --estado --seguir son miles por hora y además inflan las cifras de
  # sesiones/requests que el propio /usage reporta.
  salida=$(cd "$vacio" && timeout "$CUOTA_TIMEOUT" "$CLAUDE_BIN" -p "/usage" --output-format json \
      --no-session-persistence \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' </dev/null 2>/dev/null)
  rm -rf "$vacio"
  texto=$(printf '%s' "$salida" | jq -r '.result // empty' 2>/dev/null)
  [ -n "$texto" ] || return 1
  linea_sesion=$(printf '%s\n' "$texto" | grep -E '^Current session: [0-9]+% used')
  linea_semana=$(printf '%s\n' "$texto" | grep -E '^Current week \(all models\): [0-9]+% used')
  [ -n "$linea_sesion" ] && [ -n "$linea_semana" ] || return 1
  sesion_pct=$(printf '%s' "$linea_sesion" | grep -oE '[0-9]+' | head -1)
  sesion_reset=$(printf '%s' "$linea_sesion" | sed -E 's/^Current session: [0-9]+% used · resets //')
  semana_pct=$(printf '%s' "$linea_semana" | grep -oE '[0-9]+' | head -1)
  semana_reset=$(printf '%s' "$linea_semana" | sed -E 's/^Current week \(all models\): [0-9]+% used · resets //')
  printf '%s\t%s\t%s\t%s' "$sesion_pct" "$sesion_reset" "$semana_pct" "$semana_reset"
}

# Refresca CUOTA_CACHE en segundo plano, sin bloquear a quien la llamó (H1 de
# pr-review en DEVKIT-62). El candado evita dos refrescos a la vez: si uno ya
# está en curso, este no espera ni relanza, simplemente no hace nada.
# La subshell cierra sus descriptores de entrada/salida (H3 de pr-review): si
# no, hereda los del llamador y quien lea `--estado` por pipe o `$(...)`
# queda atado a que termine el refresco, justo lo que H1 evitaba.
# Un fallo conserva la última lectura buena en vez de pisarla (DEVKIT-78,
# séptimo campo `ts_ok`): antes, una sola falla borraba el porcentaje que
# `mostrar_consumo` venía mostrando y lo cambiaba por "no se pudo leer", aun
# con una lectura buena de hace un minuto todavía útil.
refrescar_cuota_bg() {
  (
    mkdir -p "$(dirname "$CUOTA_CACHE")" 2>/dev/null
    exec 8>"$CUOTA_LOCK"
    flock -n 8 || exit 0
    # `local` sin asignar deja la variable sin definir, no vacía (gotcha de
    # bash): con `set -u`, "$prev_tsok" más abajo revienta la subshell entera
    # si nunca se llega al `read` (sin caché previa). Se inicializan vacías a
    # propósito.
    local cuota prev_ts='' prev_estado='' prev_sp='' prev_sr='' prev_wp='' prev_wr='' prev_tsok=''
    if [ -s "$CUOTA_CACHE" ]; then
      IFS=$'\t' read -r prev_ts prev_estado prev_sp prev_sr prev_wp prev_wr prev_tsok <"$CUOTA_CACHE"
      # Caché del formato viejo, de 6 campos sin `ts_ok` (H4, pr-review
      # DEVKIT-78): una lectura `ok` de ese formato es su propia lectura
      # buena. Sin esto, el primer fallo tras actualizar el devkit caía en la
      # rama sin `prev_tsok` de más abajo y borraba esa lectura, justo lo que
      # esta card quiere evitar.
      [ "$prev_estado" = ok ] && [ -z "$prev_tsok" ] && prev_tsok=$prev_ts
    fi
    if cuota=$(leer_cuota); then
      printf '%s\tok\t%s\t%s\n' "$(date +%s)" "$cuota" "$(date +%s)" >"$CUOTA_CACHE.tmp" && mv -f "$CUOTA_CACHE.tmp" "$CUOTA_CACHE"
    elif [ -n "$prev_tsok" ]; then
      printf '%s\tfail\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$prev_sp" "$prev_sr" "$prev_wp" "$prev_wr" "$prev_tsok" \
        >"$CUOTA_CACHE.tmp" && mv -f "$CUOTA_CACHE.tmp" "$CUOTA_CACHE"
    else
      printf '%s\tfail\n' "$(date +%s)" >"$CUOTA_CACHE.tmp" && mv -f "$CUOTA_CACHE.tmp" "$CUOTA_CACHE"
    fi
  ) </dev/null >/dev/null 2>&1 &
}

# Bloque `Consumo` de `--estado`: porcentaje de cuota en vivo, con la hora de
# la lectura (DEVKIT-62). `claude -p "/usage"` tarda ~1.3 s; en vez de
# esperarlo en línea, se muestra la última lectura de CUOTA_CACHE (si hay) y
# se refresca en segundo plano cuando vence CUOTA_TTL o cuando no hay ninguna
# todavía. Así `--estado` nunca queda atado a esa lectura (H1 de pr-review).
# <permitir_refresco> en 0 (DEVKIT-78, lo pasan `seguir_estado` y
# `seguir_lanzamiento` pasado CUOTA_DESATENDIDO) muestra la caché igual pero
# no dispara un refresco nuevo: por defecto en 1, así que una `--estado`
# suelta -sin `--seguir`- no cambia de comportamiento.
mostrar_consumo() {  # mostrar_consumo [permitir_refresco=1]
  local permitir_refresco=${1:-1}
  local ts estado sesion_pct sesion_reset semana_pct semana_reset ts_ok edad ttl_efectivo
  if [ -s "$CUOTA_CACHE" ]; then
    IFS=$'\t' read -r ts estado sesion_pct sesion_reset semana_pct semana_reset ts_ok <"$CUOTA_CACHE"
    edad=$(( $(date +%s) - ts ))
    if [ "$estado" = ok ]; then
      printf '\nConsumo (cuota oficial, leída %s)\n' "$(date -d "@$ts" +%T 2>/dev/null || date -r "$ts" +%T)"
      printf '  sesión: %s%% usada, reinicia %s\n' "$sesion_pct" "$sesion_reset"
      printf '  semana: %s%% usada, reinicia %s\n' "$semana_pct" "$semana_reset"
    elif [ -n "$ts_ok" ]; then
      # Fallo con una lectura buena previa (DEVKIT-78): se sigue mostrando esa
      # lectura -no "no se pudo leer"-. El segundo dato es la hora del último
      # intento fallido, no la de la última lectura buena (H2, pr-review): con
      # fallos repetidos esa hora avanza cada intento, y "sin refrescar desde"
      # decía algo falso.
      printf '\nConsumo (última cuota oficial leída %s, último intento fallido %s)\n' \
        "$(date -d "@$ts_ok" +%T 2>/dev/null || date -r "$ts_ok" +%T)" \
        "$(date -d "@$ts" +%T 2>/dev/null || date -r "$ts" +%T)"
      printf '  sesión: %s%% usada, reinicia %s\n' "$sesion_pct" "$sesion_reset"
      printf '  semana: %s%% usada, reinicia %s\n' "$semana_pct" "$semana_reset"
    else
      printf '\nConsumo: no se pudo leer la cuota oficial con `claude -p "/usage"` ahora\n'
    fi
    # Un fallo espera CUOTA_TTL_FALLO, no CUOTA_TTL, antes de reintentar (H1,
    # pr-review): contra un 429 activo, CUOTA_TTL repite la cadencia del
    # propio incidente.
    ttl_efectivo=$CUOTA_TTL
    [ "$estado" = ok ] || ttl_efectivo=$CUOTA_TTL_FALLO
    if [ "$edad" -ge "$ttl_efectivo" ] && [ "$permitir_refresco" = 1 ]; then
      refrescar_cuota_bg
    fi
  elif [ "$permitir_refresco" = 1 ]; then
    printf '\nConsumo: todavía no hay una lectura de la cuota oficial, refrescando en segundo plano\n'
    refrescar_cuota_bg
  else
    printf '\nConsumo: todavía no hay una lectura de la cuota oficial y --seguir lleva desatendido más de %s sin refrescar\n' \
      "$(hace "$CUOTA_DESATENDIDO")"
  fi
}

# Código del proyecto activo, para `notion.sh bloqueos <código>`. Se relee
# cada vez: un proyecto nuevo arranca con `project = "PROJ"` en
# `.devkit/devkit.toml` y `project-init` lo corrige después, sin que haya que
# reiniciar el contenedor (mismo criterio que `project_code` en watch.sh).
project_code() {
  [ -f "$WS/.devkit/devkit.toml" ] || return 0
  sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/.devkit/devkit.toml" | head -1
}

# Trae `notion.sh bloqueos` y escribe BLOQUEOS_CACHE; la comparten el
# refresco en segundo plano de `--estado` y el síncrono de `--tablero` (H1,
# DEVKIT-82) para no duplicar la llamada a Notion.
_bloqueos_fetch_y_guardar() {
  local codigo bloqueos
  codigo=$(project_code)
  [ -n "$codigo" ] || return 1
  bloqueos=$("$NOTION_BIN" bloqueos "$codigo" 2>/dev/null) || return 1
  printf '%s\t%s\n' "$(date +%s)" "$bloqueos" >"$BLOQUEOS_CACHE.tmp" && mv -f "$BLOQUEOS_CACHE.tmp" "$BLOQUEOS_CACHE"
}

# Refresca BLOQUEOS_CACHE en segundo plano, mismo patrón que
# `refrescar_cuota_bg`: `notion.sh bloqueos` es una llamada a la red, y
# `--estado` no la espera en línea.
refrescar_bloqueos_bg() {
  (
    mkdir -p "$(dirname "$BLOQUEOS_CACHE")" 2>/dev/null
    exec 8>"$BLOQUEOS_LOCK"
    flock -n 8 || exit 0
    _bloqueos_fetch_y_guardar
  ) </dev/null >/dev/null 2>&1 &
}

# Igual que `refrescar_bloqueos_bg`, pero en primer plano y bloqueante: la usa
# `mostrar_tablero`, que ya paga una consulta síncrona a Notion por vuelta y,
# a diferencia de `--estado` (refrescada cada 3 s, puede esperar a la vuelta
# siguiente), necesita "bloquea a" listo desde la primera llamada (H1,
# DEVKIT-82: con la caché vacía, `--tablero` salía plano y sin agrupar).
asegurar_bloqueos_cache() {
  if [ -s "$BLOQUEOS_CACHE" ]; then
    local ts edad
    IFS=$'\t' read -r ts _ <"$BLOQUEOS_CACHE"
    edad=$(( $(date +%s) - ts ))
    [ "$edad" -lt "$BLOQUEOS_TTL" ] && return 0
  fi
  mkdir -p "$(dirname "$BLOQUEOS_CACHE")" 2>/dev/null
  { flock 8; _bloqueos_fetch_y_guardar; } 8>"$BLOQUEOS_LOCK"
}

# "bloquea a: <Claves>" para una fila de `--estado` cuya Clave frena a otras
# (ampliación de DEVKIT-63): vacío si no hay caché todavía, si no frena a
# nadie, o si la Clave de la fila ni siquiera aparece (no está Lista para
# merge). El refresco en segundo plano corre una sola vez por TTL, no por
# fila: `mostrar_estado` llama esta función varias veces por vuelta y todas
# comparten la misma caché.
bloquea_a() {  # bloquea_a <Clave>
  local ts bloqueos edad lista
  [ -s "$BLOQUEOS_CACHE" ] || { refrescar_bloqueos_bg; return 0; }
  IFS=$'\t' read -r ts bloqueos <"$BLOQUEOS_CACHE"
  edad=$(( $(date +%s) - ts ))
  [ "$edad" -lt "$BLOQUEOS_TTL" ] || refrescar_bloqueos_bg
  lista=$(jq -r --arg c "$1" '.[] | select(.clave == $c) | .bloquea_a | join(", ")' <<<"$bloqueos" 2>/dev/null)
  [ -n "$lista" ] && printf 'bloquea a: %s' "$lista"
}

# Trae `notion.sh epicas` y escribe EPICAS_CACHE; misma razón que
# `_bloqueos_fetch_y_guardar` para compartirla entre el refresco en segundo
# plano y el síncrono (H1, DEVKIT-82).
_epicas_fetch_y_guardar() {
  local codigo epicas
  codigo=$(project_code)
  [ -n "$codigo" ] || return 1
  epicas=$("$NOTION_BIN" epicas "$codigo" 2>/dev/null) || return 1
  printf '%s\t%s\n' "$(date +%s)" "$epicas" >"$EPICAS_CACHE.tmp" && mv -f "$EPICAS_CACHE.tmp" "$EPICAS_CACHE"
}

# Refresca EPICAS_CACHE en segundo plano, mismo patrón que
# `refrescar_bloqueos_bg`.
refrescar_epicas_bg() {
  (
    mkdir -p "$(dirname "$EPICAS_CACHE")" 2>/dev/null
    exec 9>"$EPICAS_LOCK"
    flock -n 9 || exit 0
    _epicas_fetch_y_guardar
  ) </dev/null >/dev/null 2>&1 &
}

# Igual que `asegurar_bloqueos_cache`, para EPICAS_CACHE (H1, DEVKIT-82).
asegurar_epicas_cache() {
  if [ -s "$EPICAS_CACHE" ]; then
    local ts edad
    IFS=$'\t' read -r ts _ <"$EPICAS_CACHE"
    edad=$(( $(date +%s) - ts ))
    [ "$edad" -lt "$EPICAS_TTL" ] && return 0
  fi
  mkdir -p "$(dirname "$EPICAS_CACHE")" 2>/dev/null
  { flock 9; _epicas_fetch_y_guardar; } 9>"$EPICAS_LOCK"
}

# "Épica <Clave>: <Título>" para una fila de `--estado` cuya Clave tiene una
# Épica (Padre) `En progreso` (DEVKIT-80); vacío si no hay caché todavía, si
# la Clave no tiene Épica activa, o si no aparece en `notion.sh epicas`.
# `mostrar_estado` la usa para decidir si agrupa la tabla y bajo qué
# encabezado va cada fila.
epica_de() {  # epica_de <Clave>
  local ts epicas edad linea
  [ -s "$EPICAS_CACHE" ] || { refrescar_epicas_bg; return 0; }
  IFS=$'\t' read -r ts epicas <"$EPICAS_CACHE"
  edad=$(( $(date +%s) - ts ))
  [ "$edad" -lt "$EPICAS_TTL" ] || refrescar_epicas_bg
  linea=$(jq -r --arg c "$1" '.[] | select(.clave == $c) | "Épica \(.epica): \(.epica_titulo)"' <<<"$epicas" 2>/dev/null)
  printf '%s' "$linea"
}

# Trae `notion.sh activas` y escribe MERGE_CACHE; mismo patrón que
# `_bloqueos_fetch_y_guardar`/`_epicas_fetch_y_guardar`, aparte de las dos
# porque ninguna trae todas las cards "Lista para merge" del proyecto.
_merge_fetch_y_guardar() {
  local codigo activas
  codigo=$(project_code)
  [ -n "$codigo" ] || return 1
  activas=$("$NOTION_BIN" activas "$codigo" 2>/dev/null) || return 1
  printf '%s\t%s\n' "$(date +%s)" "$activas" >"$MERGE_CACHE.tmp" && mv -f "$MERGE_CACHE.tmp" "$MERGE_CACHE"
}

# Refresca MERGE_CACHE en segundo plano, mismo patrón que
# `refrescar_bloqueos_bg`/`refrescar_epicas_bg`.
refrescar_merge_bg() {
  (
    mkdir -p "$(dirname "$MERGE_CACHE")" 2>/dev/null
    exec 8>"$MERGE_LOCK"
    flock -n 8 || exit 0
    _merge_fetch_y_guardar
  ) </dev/null >/dev/null 2>&1 &
}

# Clave de la card "Lista para merge" más antigua del proyecto -la que el
# humano tiene pendiente aprobar hace más tiempo-, o vacío si no hay caché
# todavía o ninguna card está en ese Estado (DEVKIT-133, DETALLE de la fila
# "(en espera)"). Mismo criterio de refresco en segundo plano que
# `bloquea_a`/`epica_de`: nunca espera en línea a Notion.
esperando_aprobacion() {
  local ts activas edad
  [ -s "$MERGE_CACHE" ] || { refrescar_merge_bg; return 0; }
  IFS=$'\t' read -r ts activas <"$MERGE_CACHE"
  edad=$(( $(date +%s) - ts ))
  [ "$edad" -lt "$MERGE_TTL" ] || refrescar_merge_bg
  jq -r '[.[] | select(.estado == "Lista para merge")] | .[0].clave // empty' \
    <<<"$activas" 2>/dev/null
}

# Alarma de skill lenta (DEVKIT-46), igual que `watch_long_running` en
# watch.sh pero escribiendo directo a watch.log: `--worker` no comparte
# proceso con el bucle, así que no puede reusar su función.
watch_long_running() {  # watch_long_running <prompt> <pid>
  local prompt=$1 pid=$2 waited=0 alarmed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$SKILL_POLL"
    waited=$((waited + SKILL_POLL))
    if [ "$alarmed" -eq 0 ] && [ "$waited" -ge "$SKILL_TIMEOUT" ]; then
      printf '%s devkit-run "%s" ALARMA: lleva %s min corriendo (límite %ss)\n' \
        "$(date +%FT%T%:z)" "$prompt" "$((waited / 60))" "$SKILL_TIMEOUT" >> "$WATCH_LOG"
      alarmed=1
    fi
  done
}

# ¿El `result` de una skill es una pregunta abierta al humano, que nadie va a
# contestar en modo headless? La forma original (DEVKIT-50) solo miraba si el
# texto terminaba en "?". DEVKIT-77 mostró un cierre real que no la cumplía:
# "¿Cómo quieres que siga? Opciones: 1. [...] 2. [...] 3. [...] antes de
# decidir.", una pregunta con opciones que el agente cierra con una frase que
# no termina en "?". Puro, para poder probarlo con el texto real del
# incidente sin lanzar nada.
pregunta_abierta() {  # pregunta_abierta <resultado>
  local resultado=$1 parrafo
  # Regla original: el texto entero termina en pregunta.
  printf '%s' "$resultado" | grep -qE '\?[[:space:]]*$' && return 0
  # Último párrafo (el texto tras la última línea en blanco, o todo el
  # resultado si no hay ninguna): ahí es donde el agente suele dejar la
  # pregunta, aunque después la explique o la cierre sin "?".
  parrafo=$(printf '%s' "$resultado" | awk 'BEGIN{RS=""} {p=$0} END{print p}')
  [ -n "$parrafo" ] || parrafo=$resultado
  # Una línea que empieza por "¿" en ese párrafo.
  printf '%s\n' "$parrafo" | grep -qE '^¿' && return 0
  # Frases fijas del incidente, en cualquier parte del párrafo.
  printf '%s' "$parrafo" | grep -qiE '¿Cómo quieres que siga|¿Qué prefieres' && return 0
  # "Opciones:" seguida de líneas numeradas.
  printf '%s\n' "$parrafo" | grep -qE '^Opciones:' \
    && printf '%s\n' "$parrafo" | grep -qE '^[0-9]+\.' && return 0
  return 1
}

# Barrera mecánica de DEVKIT-50 sobre la regla de cierre de DEVKIT-44: un
# `result` que termina en pregunta es una card `En progreso` cortando en seco
# en vez de resolver en un estado observable (AGENTS.md), y DEVKIT-48 mostró
# que la regla escrita en las skills no basta. En vez de dejarla colgada, el
# lanzador mismo bloquea la card con un motivo forzado. Desde DEVKIT-55 el
# bloqueo es `task-block.sh`, bash contra la API de Notion: no gasta modelo
# y no puede, a su vez, terminar en pregunta, así que ya no hace falta
# excluir a nadie para evitar un bucle.
#
# DEVKIT-76: antes de bloquear, lee el Estado real de la card. Un
# relanzamiento por error sobre una card ya `Hecha` (DEVKIT-74: la card
# cerrada, mergeada y documentada, relanzada a mano) terminaba preguntando
# "¿tomo la siguiente card?" y esta barrera la mandaba a `Bloqueada` sin que
# hiciera falta: nadie iba a leer ese bloqueo, porque la card ya estaba
# resuelta. Deja la alarma en `watch.log` para que quede visible, pero no
# toca Notion ni corre `task-block.sh`. H4: esa alarma cita el motivo
# recibido en vez de asumir que siempre fue una pregunta, porque esta misma
# barrera también se dispara por falta de acceso a Notion (DEVKIT-65). H5:
# la alarma genérica del llamador se imprime aquí, después de saber si la
# card está Hecha, para no duplicarla con la de la card Hecha sobre el mismo
# evento.
# task-begin.sh no dejó la card lista: se registra el motivo y, si la card
# seguía tomable (Lista o En progreso: lo era antes de intentar, y si falló a
# mitad de camino sigue siéndolo, porque task-begin.sh solo pasa a Notion
# Estado=En progreso al final, con la rama ya creada y subida), se bloquea.
# Backlog/Hecha/Lista para merge/Revisión automática/Bloqueada no se tocan:
# ahí no hay nada que bloquear, y bloquear una card en pleno ciclo de
# revisión sería peor que no lanzar nada.
task_begin_fallo() {  # task_begin_fallo <prompt> <clave> <motivo>
  local prompt=$1 clave=$2 motivo=${3:-sin motivo} estado
  printf '%s devkit-run "%s" no lanza: %s\n' "$(date +%FT%T%:z)" "$prompt" "$motivo" >> "$WATCH_LOG" 2>/dev/null
  estado=$(jq -r '.estado // empty' <<<"$("$NOTION_BIN" card "$clave" 2>/dev/null)" 2>/dev/null)
  case "$estado" in
    Lista|"En progreso")
      printf '%s devkit-run "%s" bloquea la card con task-block.sh: %s\n' "$(date +%FT%T%:z)" "$prompt" "$clave" >> "$WATCH_LOG" 2>/dev/null
      "$TASK_BLOCK_BIN" "$clave" "devkit-run: task-begin.sh no la dejó lista: $motivo" >>"$WATCH_LOG" 2>&1
      ;;
  esac
}

forzar_task_block() {  # forzar_task_block <prompt> <logf> <motivo> <alarma> [clave]
  local prompt=$1 logf=$2 motivo=$3 alarma=$4 clave=${5:-} skill estado card_json pr
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  # `/pr-review <N>` no trae Clave en el prompt: quien la conoce (watch.sh,
  # por el título del PR) la pasa explícita en vez de que se pierda en el
  # regex de abajo (DEVKIT-94, H1 del informe sobre el PR #68).
  [ -n "$clave" ] || clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  if [ -z "$clave" ]; then
    printf '%s devkit-run "%s" %s\n' "$(date +%FT%T%:z)" "$prompt" "$alarma" >> "$WATCH_LOG"
    return 0
  fi
  card_json=$("$NOTION_BIN" card "$clave" 2>/dev/null)
  estado=$(jq -r '.estado // empty' <<<"$card_json" 2>/dev/null)
  if [ "$estado" = "Hecha" ]; then
    printf '%s devkit-run "%s" ALARMA: terminó sin estado observable sobre una card ya Hecha; no se bloquea (%s)\n' \
      "$(date +%FT%T%:z)" "$prompt" "$motivo" >> "$WATCH_LOG"
    return 1
  fi
  printf '%s devkit-run "%s" %s\n' "$(date +%FT%T%:z)" "$prompt" "$alarma" >> "$WATCH_LOG"
  # H5 del informe sobre el PR #68: un corte puede llegar después de que la
  # skill ya entregó (task-start dejó el PR abierto y la card en Revisión
  # automática antes de pasarse del presupuesto). Sin el Estado y el PR de
  # ese momento en el motivo, el humano tenía que abrir el log para saber si
  # había algo entregado antes de desbloquear.
  pr=$(jq -r '.pr // empty' <<<"$card_json" 2>/dev/null)
  motivo="devkit-run: $skill $motivo (Estado antes del bloqueo: ${estado:-desconocido}${pr:+, PR: $pr}); ver $logf"
  printf '%s devkit-run "%s" bloquea la card con task-block.sh: %s\n' "$(date +%FT%T%:z)" "$prompt" "$clave" >> "$WATCH_LOG"
  "$TASK_BLOCK_BIN" "$clave" "$motivo" >>"$WATCH_LOG" 2>&1
}

# DEVKIT-105: el presupuesto de turnos de roles.toml es una meta de
# optimización, no un límite. Antes (DEVKIT-94) exceder el presupuesto
# llamaba a `forzar_task_block` como cualquier otro corte, y una skill que ya
# había entregado (PR abierto, card en Revisión automática o Lista para
# merge) quedaba Bloqueada por un aviso: la revisión que el bucle lanzaba
# segundos después salía sin revisar y consumía su intento, y el humano tenía
# que devolver la card a mano. Pasó cuatro veces en un día (97, 99, 101 y
# 102). Ahora exceder el presupuesto nunca bloquea, haya entregado o no: deja
# la ALARMA en watch.log y, si hay Clave, un comentario en la card; el ciclo
# sigue su curso sin tocar el Estado.
avisar_presupuesto_excedido() {  # avisar_presupuesto_excedido <prompt> <logf> <presupuesto> <turnos> [clave]
  local prompt=$1 logf=$2 presupuesto=$3 turnos=$4 clave=${5:-} skill card_json id
  skill=$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')
  printf '%s devkit-run "%s" ALARMA: presupuesto excedido (%s turnos, presupuesto %s)\n' \
    "$(date +%FT%T%:z)" "$prompt" "$turnos" "$presupuesto" >> "$WATCH_LOG"
  [ -n "$clave" ] || clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  [ -n "$clave" ] || return 0
  card_json=$("$NOTION_BIN" card "$clave" 2>/dev/null)
  id=$(jq -r '.id // empty' <<<"$card_json" 2>/dev/null)
  [ -n "$id" ] || return 0
  "$NOTION_BIN" comentar "$id" \
    "Presupuesto excedido: $turnos turnos contra $presupuesto en $skill; el ciclo sigue" \
    >/dev/null 2>&1
}

# ¿El `claude -p` terminó sin acceso a Notion? (DEVKIT-65). Solo bloquea la
# card el campo estructurado `permission_denials` del evento `result`, cuando
# lista una herramienta de Notion que la CLI negó: es un hecho, no una frase.
notion_denegado() {  # notion_denegado <logf>
  tail -1 "$1" 2>/dev/null \
    | jq -e '[.permission_denials[]?.tool_name // ""] | map(test("mcp__.*notion"; "i")) | any' \
      >/dev/null 2>&1
}

# Respaldo por si la CLI no anota la negación: la frase del agente. Solo deja
# una ALARMA, no bloquea (H13 de pr-review): un `result` que resume este mismo
# mecanismo, como `task-fix-46-ce49aa6.log`, que terminó bien, dice las mismas
# frases, y esa clase de falso positivo no se agota sumando negativos.
# H14: sobre el `result` crudo, sin quitar comillas ni backticks, porque el
# agente suele escribir entre backticks el nombre del plugin o la herramienta.
result_sin_notion() {  # result_sin_notion <logf>
  tail -1 "$1" 2>/dev/null | jq -r '.result // ""' 2>/dev/null | tr '\n' ' ' | grep -qiE \
    'notion[^.]{0,80}(no tiene permiso|no tengo acceso|sin acceso|no (tengo|estoy|están?) autorizad[oa]s?)|(no tiene permiso|no tengo acceso|sin acceso)[^.]{0,40}notion|(autoriza[rd][a-z]*|autorizad[oa]s?)[^.]{0,20}mcp__[a-z_]*notion'
}

# Modelo vacío: la CLI rechaza `--model ""` con un 400 en el primer turno y el
# lanzamiento muere sin hacer nada (DEVKIT-55, `task-start-4.log`). Mejor no
# lanzar y decirlo: motivo por stderr, ALARMA en watch.log y código falso.
modelo_valido() {  # modelo_valido <modelo> <prompt>
  case "$1" in ''|-) ;; *) return 0 ;; esac
  printf 'devkit-run: no se pudo resolver un modelo para "%s" (roles.toml: %s); no se lanza. Revisa `frontera` y el rol.\n' \
    "$2" "$ROLES_FILE" >&2
  printf '%s devkit-run "%s" ALARMA: modelo vacío al resolver el rol (roles.toml: %s); no se lanza\n' \
    "$(date +%FT%T%:z)" "$2" "$ROLES_FILE" >> "$WATCH_LOG" 2>/dev/null
  return 1
}

# Procesos `claude -p` ajenos que ya están trabajando sobre este workspace.
#
# Existe por la Ampliación 2 de DEVKIT-54. Una skill que comprueba si hay otro
# agente corriendo con un `pgrep -f "<Clave>"` a secas se encuentra a sí misma
# cuatro veces: la Clave viaja en el argumento del lanzador, así que coinciden
# el `devkit-run.sh --worker`, el subshell que corre la skill, su vigilante y
# el propio `claude -p`. task-start leyó esos cuatro como "hay un segundo
# proceso sobre /workspace" y bloqueó la card sin motivo.
#
# La regla: descartar la ascendencia propia (que cubre el `claude -p` de uno
# mismo y su lanzador), descartar cualquier `devkit-run.sh` (lanzador y
# vigilante, que no son agentes) y quedarse solo con procesos `claude -p`.

# Cadena de PIDs desde el proceso actual hasta la raíz. La skill llama a este
# script desde su herramienta Bash, así que su propio `claude -p` es un
# ancestro, no el PID actual: filtrar solo por `$$` no alcanza.
ancestros_propios() {
  local pid=$$ padre
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    printf '%s ' "$pid"
    padre=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$padre" != "$pid" ] || break
    pid=$padre
  done
}

# Filtrado puro, separado de la consulta a `ps` para poder probarlo con una
# tabla fija en la autoprueba. Lee "<pid> <args>" por línea en stdin.
filtrar_agentes() {  # filtrar_agentes <lista de pids propios>
  local propios=" $1 " pid args
  while read -r pid args; do
    [ -n "$pid" ] || continue
    case "$propios" in *" $pid "*) continue ;; esac
    case "$args" in *devkit-run.sh*) continue ;; esac
    case "$args" in
      *claude*" -p "*|*claude*" -p") printf '%s %s\n' "$pid" "$args" ;;
    esac
  done
}

# El propio `claude -p` de quien llama, entre sus ancestros (DEVKIT-77):
# descarta `devkit-run.sh` y se queda con `claude ... -p <prompt> ...`, igual
# que la variante con banderas después del prompt de `filtrar_agentes` (no la
# variante sin espacio final, `*claude*" -p"`, porque `run_claude` siempre
# pasa el prompt después de `-p`), pero sobre la ascendencia propia en vez del
# `ps` completo, y devuelve el primero que encuentra en vez de filtrarlos
# todos. Puro, para probarlo con una tabla fija: recibe "<pid> <args>" por
# línea.
propio_de() {
  local pid args prompt
  while read -r pid args; do
    [ -n "$pid" ] || continue
    case "$args" in *devkit-run.sh*) continue ;; esac
    case "$args" in
      *claude*" -p "*)
        # Solo el argumento de `-p` (el prompt), sin las banderas que siguen
        # (`--model`, `--effort`, ...): así se lee de un vistazo.
        prompt=$(printf '%s' "$args" | sed -E 's/^.*-p ([^-].*)$/\1/; s/ --.*$//')
        printf '%s claude -p "%s"' "$pid" "$prompt"
        return 0 ;;
    esac
  done
  return 1
}

# Imprime un proceso ajeno por línea. Sale 0 si el workspace está libre y 1 si
# lo ocupa otro agente, para usarlo directo en un `if`. Antes de esa lista,
# si corre dentro de un agente, imprime `propio: <pid> claude -p "<prompt>"`
# (DEVKIT-77): así el agente ve su propio proceso ya identificado -el mismo
# que le hace desconfiar y correr su propio `ps`, como en DEVKIT-63- en vez
# de tener que buscarlo aparte.
otros_agentes() {
  local encontrados propio
  encontrados=$(ps -eo pid=,args= -ww 2>/dev/null | filtrar_agentes "$(ancestros_propios)")
  if propio=$(
    for pid in $(ancestros_propios); do
      printf '%s %s\n' "$pid" "$(ps -o args= -p "$pid" -ww 2>/dev/null)"
    done | propio_de
  ); then
    printf 'propio: %s\n' "$propio"
  fi
  [ -z "$encontrados" ] && return 0
  printf '%s\n' "$encontrados"
  return 1
}

# --- Quién lanzó, arranque y estado de los lanzamientos (DEVKIT-57) ---------
#
# Cada lanzamiento deja en watch.log una línea con forma fija:
#   <fecha> <id> lanzando (origen=<origen>) modelo=<alias> esfuerzo=<x> ronda=<n>: "<prompt>" log=<log>
# donde <id> es el nombre del log sin `.log` (`task-start-3`,
# `pr-review-41-4391e46`). La escriben este script, antes del `nohup`, y
# `run_skill` en watch.sh, antes de tomar el candado (ambos resuelven modelo y
# ronda antes de escribir la línea, DEVKIT-81). `--estado` parte de esas
# líneas y no de los procesos: un lanzamiento existe desde que se pidió, no
# desde que su `claude -p` aparece en `ps`. `lanzamientos()` también acepta el
# formato viejo sin esos tres campos (un `watch.sh` en memoria, sin
# `recreate`, todavía puede escribirlo).

# Origen de un lanzamiento: `humano`, `bucle`, `task-close` o la skill que lo
# pidió (`epic-plan`). Quien llama puede declararlo con DEVKIT_ORIGEN:
# watch.sh pone `bucle` y task-close.sh pone `task-close`. Si no viene, se
# busca entre los ancestros el primer `claude -p /<skill>`: epic-plan llama a
# devkit-run desde su herramienta Bash, así que su `claude -p` es ancestro.
# Sin ninguno de los dos, lo lanzó un humano desde la terminal.
#
# Filtrado puro, como filtrar_agentes: lee "<pid> <args>" de los ancestros,
# del más cercano al más lejano.
origen_de() {
  local pid args skill
  while read -r pid args; do
    case "$args" in *devkit-run.sh*) continue ;; *claude*) ;; *) continue ;; esac
    skill=$(printf '%s' "$args" | grep -oE '(^| )-p /[a-zA-Z-]+' | head -1 | sed -E 's#.*-p /##')
    if [ -n "$skill" ]; then
      printf '%s' "$skill"
      return 0
    fi
  done
  printf 'humano'
}

origen_lanzamiento() {
  if [ -n "${DEVKIT_ORIGEN:-}" ]; then
    printf '%s' "$DEVKIT_ORIGEN"
    return 0
  fi
  local pid
  for pid in $(ancestros_propios); do
    printf '%s %s\n' "$pid" "$(ps -o args= -p "$pid" -ww 2>/dev/null)"
  done | origen_de
}

# Antes de lanzar: ¿ya hay un worker o un `claude -p` de este mismo prompt
# vivo o esperando el candado? Sin esto, un falso "no arrancó" (ver el
# comentario junto a PS_BIN) llevó al humano a relanzar tres veces la misma
# card el 2026-09-17 sin saber que el lanzamiento anterior seguía vivo: la
# reanudación quedó esperando el candado detrás de la primera. Puro: lee
# "<pid> <args>" por línea de stdin, igual que filtrar_agentes.
lanzamiento_duplicado() {  # lanzamiento_duplicado <prompt>
  local prompt=$1 pid args
  while read -r pid args; do
    [ -n "$pid" ] || continue
    case "$args" in
      *"--worker $prompt "*) printf '%s\n' "$pid"; return 0 ;;
    esac
    case "$args" in *devkit-run.sh*) continue ;; esac
    case "$args" in
      *claude*"-p $prompt "*) printf '%s\n' "$pid"; return 0 ;;
    esac
  done
  return 1
}

# El prompt en una sola línea, sin comillas y corto: un task-fix con el
# comentario del humano trae saltos de línea que romperían la forma fija.
prompt_en_linea() {  # prompt_en_linea <prompt>
  local p
  p=$(printf '%s' "$1" | tr '\n"' '  ')
  printf '%s' "${p:0:120}"
}

# Identidad de un lanzamiento: la skill y su primer argumento (Clave o número
# de PR), sin el resto (DEVKIT-97). Desde DEVKIT-90, `--worker` arma
# `prompt_pleno` para task-start con el volcado de la card bajo "## Card" y
# eso -no el prompt corto- es lo que llega al `claude -p` real, así que
# aparece entero en `ps`; la línea "lanzando" en cambio solo guarda el
# prompt corto. Comparar por el texto completo (incluso recortado a 120
# caracteres por `prompt_en_linea`, que en un prompt de miles de caracteres
# solo alcanza a cubrir el volcado de la card, nunca el prompt corto que
# quedó al principio) daba una fila `sin registro` falsa para el propio
# `task-start` y un DETALLE con la card entera. `ps` aplana los saltos de
# línea de un argumento a espacios (confirmado: dos saltos seguidos quedan
# como dos espacios seguidos), así que ni siquiera hay un salto de línea real
# del que cortar; comparar por skill+primer argumento es la única forma
# estable de identificar el mismo lanzamiento en la línea del log y en `ps`.
identidad_prompt() {  # identidad_prompt <prompt>
  printf '%s' "$1" | awk '{print $1, $2}' | sed -E 's/[[:space:]]+$//'
}

linea_lanzando() {  # linea_lanzando <id> <origen> <prompt> <log> <modelo> <esfuerzo> <ronda>
  printf '%s %s lanzando (origen=%s) modelo=%s esfuerzo=%s ronda=%s: "%s" log=%s\n' \
    "$(date +%FT%T%:z)" "$1" "$2" "${5:--}" "${6:--}" "${7:--}" "$(prompt_en_linea "$3")" "$4"
}

# Espera el marcador de fin de arranque. Sin él, el contenedor todavía está
# leyendo secretos o clonando, y un `claude -p` lanzado en ese rato puede
# morir sin token ni rastro: el caso de origen de DEVKIT-57.
esperar_arranque() {  # esperar_arranque <prompt>
  [ -e "$READY_FILE" ] && return 0
  local t=0
  printf 'devkit-run: esperando a que termine el arranque del contenedor' >&2
  while [ ! -e "$READY_FILE" ] && [ "$t" -lt "$READY_TIMEOUT" ]; do
    sleep 1
    t=$((t + 1))
    printf '.' >&2
  done
  printf '\n' >&2
  [ -e "$READY_FILE" ] && return 0
  printf 'devkit-run: el arranque del contenedor no terminó en %ss (falta %s); no se lanza "%s".\n' \
    "$READY_TIMEOUT" "$READY_FILE" "$1" >&2
  printf 'Mira qué pasó con `devkit logs <proyecto>` desde el host y vuelve a lanzar cuando termine.\n' >&2
  printf '%s devkit-run "%s" ALARMA: arranque del contenedor sin terminar tras %ss; no se lanza\n' \
    "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" "$READY_TIMEOUT" >> "$WATCH_LOG" 2>/dev/null
  return 1
}

# Ampliación de DEVKIT-63: en modo dev, `devkit-run` lee `roles.toml` y este
# mismo archivo del workspace en el instante del lanzamiento, no de la imagen.
# Tras el merge de DEVKIT-61 (22:19 del 2026-09-16) el workspace seguía en el
# `main` que había clonado el `recreate` anterior -la Limpieza local de
# `task-close.sh` no lo actualizó, ver el comentario junto a `no_limpia` en
# task-close.sh-, y un lanzamiento manual a las 22:50 salió sin la escalera de
# modelos aunque `origin/main` ya la tenía. Este aviso no arregla eso: solo lo
# hace observable antes de resolver el modelo, cuando todavía se puede parar.
avisar_atras_de_origin() {  # avisar_atras_de_origin <prompt>
  local atras
  if ! timeout 5 git -C "$WS" fetch -q origin main 2>/dev/null; then
    printf 'devkit-run: no se pudo comprobar si el workspace está detrás de origin/main (git fetch falló).\n' >&2
    return 0
  fi
  atras=$(git -C "$WS" rev-list --count main..origin/main 2>/dev/null) || return 0
  case "$atras" in ''|0) return 0 ;; esac
  printf 'devkit-run: el workspace está %s commit(s) detrás de origin/main; puede estar lanzando con código viejo (git switch main && git pull --ff-only).\n' \
    "$atras" >&2
  printf '%s devkit-run "%s" ALARMA: workspace %s commit(s) detrás de origin/main; puede lanzar con código viejo\n' \
    "$(date +%FT%T%:z)" "$(prompt_en_linea "$1")" "$atras" >> "$WATCH_LOG" 2>/dev/null
}

# El `claude -p` del worker recién lanzado, entre sus descendientes: no el
# primer proceso del sistema cuyo prompt coincida (DEVKIT-79). Evidencia del
# 2026-09-17: con dos lanzamientos vivos del mismo prompt -uno esperando el
# candado, otro corriendo de verdad- `confirmar_arranque` tomaba el `claude
# -p` del lanzamiento anterior porque `ps` lo listaba primero, y reportaba
# como "arrancó" el proceso equivocado. Puro: lee "<pid> <ppid> <args>" por
# línea de stdin y recorre el árbol de procesos desde <raíz> en anchura.
claude_descendiente() {  # claude_descendiente <raíz> <prompt>
  local raiz=$1 prompt=$2
  local -A hijos_de args_de vistos
  local pid ppid args hijo
  while read -r pid ppid args; do
    [ -n "$pid" ] || continue
    hijos_de[$ppid]="${hijos_de[$ppid]:-} $pid"
    args_de[$pid]=$args
  done
  local -a cola=("$raiz")
  local i=0
  while [ "$i" -lt "${#cola[@]}" ]; do
    pid=${cola[$i]}
    i=$((i + 1))
    [ -z "${vistos[$pid]:-}" ] || continue
    vistos[$pid]=1
    args=${args_de[$pid]:-}
    case "$args" in
      *devkit-run.sh*) ;;
      *claude*"-p $prompt "*) printf '%s\n' "$pid"; return 0 ;;
    esac
    for hijo in ${hijos_de[$pid]:-}; do
      cola+=("$hijo")
    done
  done
  return 1
}

# Confirma que el lanzamiento en segundo plano arrancó. Espera hasta
# ARRANQUE_ESPERA segundos mirando al worker; si sigue vivo, arrancó (corre
# su `claude -p` o espera el candado). Si murió, solo vale como arranque si
# dejó su resumen "terminado" en watch.log: una skill muy corta. En otro
# caso imprime el final del log y las alarmas, y devuelve falso.
# Devuelve 0 si arrancó (o terminó de verdad), 2 si task-begin.sh la cortó
# antes de `claude -p` ("no lanzó", H8 del informe sobre el PR #64 de
# DEVKIT-90) y 1 en cualquier otro caso de no arranque.
confirmar_arranque() {  # confirmar_arranque <pid del worker> <prompt> <log>
  local pid=$1 prompt=$2 logf=$3 id t=0 pasos claude_pid alarmas cierre motivo_no_lanzo
  id=$(basename "$logf" .log)
  pasos=$((ARRANQUE_ESPERA * 5))
  while [ "$t" -lt "$pasos" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    t=$((t + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    claude_pid=$("$PS_BIN" -eo pid=,ppid=,args= -ww 2>/dev/null | claude_descendiente "$pid" "$prompt")
    if [ -n "$claude_pid" ]; then
      echo "arrancó: claude -p vivo (pid $claude_pid)"
    else
      echo "arrancó: el worker (pid $pid) espera el candado; síguelo con devkit-run --estado"
    fi
    return 0
  fi
  cierre=$(grep -F "terminado [$id]:" "$WATCH_LOG" 2>/dev/null | tail -1)
  if [ -n "$cierre" ]; then
    case "$cierre" in
      *"no lanzó: "*)
        motivo_no_lanzo=${cierre#*no lanzó: }
        printf 'devkit-run: "%s" no lanzó: %s\n' "$prompt" "$motivo_no_lanzo" >&2
        return 2
        ;;
    esac
    echo "arrancó y ya terminó; resumen en $WATCH_LOG"
    return 0
  fi
  {
    printf 'devkit-run: "%s" no arrancó: el worker murió en sus primeros %ss sin terminar.\n' "$prompt" "$ARRANQUE_ESPERA"
    printf 'Últimas líneas de %s:\n' "$logf"
    if [ -s "$logf" ]; then
      tail -n 20 "$logf" | sed 's/^/  /'
    else
      echo "  (log vacío: claude -p no llegó a escribir)"
    fi
    alarmas=$(grep -F "\"$(prompt_en_linea "$prompt")\"" "$WATCH_LOG" 2>/dev/null | grep 'ALARMA' | tail -3)
    if [ -n "$alarmas" ]; then
      echo "Alarmas en $WATCH_LOG:"
      printf '%s\n' "$alarmas" | sed 's/^/  /'
    fi
  } >&2
  # H5 de pr-review (DEVKIT-65): sin Notion conectada, `alarma_sin_notion` (en
  # `run_claude`) ya dejó la alarma específica del caso; sin este `if`, esto
  # sumaba una segunda "ALARMA: no arrancó" genérica y menos precisa por el
  # mismo evento (rc=67, candado ya liberado).
  if ! grep -qE "falló \(rc=67\) \[$id\]:" "$WATCH_LOG" 2>/dev/null; then
    printf '%s devkit-run "%s" ALARMA: no arrancó; el worker murió en %ss sin resumen [%s]\n' \
      "$(date +%FT%T%:z)" "$(prompt_en_linea "$prompt")" "$ARRANQUE_ESPERA" "$id" >> "$WATCH_LOG" 2>/dev/null
  fi
  return 1
}

# Lanzamientos registrados en watch.log, uno por línea "lanzando", en TSV:
# <n.º de línea> <fecha> <id> <origen> <prompt> <log> <modelo> <esfuerzo> <ronda>.
# `[[ =~ ]]` en vez de `sed -E` con grupos de captura: la línea nueva tiene
# más de 9 grupos y `sed` no los referencia todos (\1-\9 nada más), así que
# se recorre el archivo a mano con `BASH_REMATCH`, sin ese límite. El grupo
# modelo/esfuerzo/ronda es opcional: una línea vieja (DEVKIT-81) cae en las
# ramas `${BASH_REMATCH[n]:--}`.
# DEVKIT-81 H6: `grep -nF` filtra primero -recorre el archivo entero una sola
# vez, en C- y deja para el `while`/`BASH_REMATCH` (bash puro, mucho más
# lento por línea) solo las líneas "lanzando", casi siempre una fracción
# chica del log. Sin este filtro, `agentes_en_curso_rapido` -que llama a
# `lanzamientos` en cada prompt del shell, con el presupuesto de 50 ms de
# `prompt-status.sh`- tardaba cerca de 1 s con un watch.log de 20 000 líneas.
lanzamientos() {  # lanzamientos <watch.log>
  [ -f "$1" ] || return 0
  local ln resto
  local re='^([^ ]+) ([^ ]+) lanzando \(origen=([^)]*)\)( modelo=([^ ]+) esfuerzo=([^ ]+) ronda=([^:]+))?: "(.*)" log=([^ ]+)$'
  while IFS=: read -r ln resto; do
    [[ $resto =~ $re ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ln" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}" "${BASH_REMATCH[8]}" "${BASH_REMATCH[9]}" \
      "${BASH_REMATCH[5]:--}" "${BASH_REMATCH[6]:--}" "${BASH_REMATCH[7]:--}"
  done < <(grep -nF ' lanzando (origen=' "$1")
}

hace() {  # hace <segundos>
  local s=$1
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%sh%02dm' "$((s / 3600))" "$((s % 3600 / 60))"
  else printf '%sd' "$((s / 86400))"
  fi
}

# Una fila TSV por lanzamiento: skill, card, origen, hace cuánto, estado,
# detalle, modelo (DEVKIT-81, columna `modelo/esfuerzo rN`), duración y turnos
# (DEVKIT-107, al final para no correr la posición de los campos de arriba,
# que ya leen otras funciones por índice). Estados:
#   en curso    sin resumen, y su proceso vive, o se lanzó hace menos de
#               ESTADO_GRACIA segundos, o espera el candado; si ya pasó
#               SKILL_TIMEOUT sin resumen, el detalle suma "lento"
#   terminó     resumen "terminado"
#   error       resumen con rc distinto de cero, o log escrito sin resumen
#               y sin proceso (murió a medias)
#   bloqueada   terminó o falló, y task-block.sh bloqueó su card después de
#               lanzarlo; el detalle es el motivo
#   no arrancó  sin resumen, sin proceso y sin log pasado el margen, o
#               marcado así por confirmar_arranque
#   no lanzó    review-prep.sh (pr-review) o task-begin.sh (task-start) cortó
#               con rc=3 antes de cualquier `claude -p` real -"nada que
#               revisar" no es un error-; el detalle es el motivo, la única
#               línea de su log (DEVKIT-107)
#   sin registro  un `claude -p` vivo en `ps` sin ninguna línea "lanzando" que
#               lo explique (regla sin excepción de DEVKIT-81); ver
#               `filas_sin_registro`
# Lee `ps` de PS_BIN y la hora de <ahora>, para probarlo con datos fijos.
estado_filas() {  # estado_filas <watch.log> <ahora epoch>
  local wlog=$1 ahora=$2 procesos candado=libre
  procesos=$("$PS_BIN" -eo pid=,args= -ww 2>/dev/null)
  # Lectura, no escritura: abrir el candado con `>` le cambiaría el mtime,
  # que watch.sh usa como señal de actividad para la alarma de rama huérfana.
  if [ -e "$LOCK" ] && exec 7<"$LOCK"; then
    flock -n 7 || candado=ocupado
    exec 7<&-
  fi
  local ln ts id origen prompt logf modelo esfuerzo ronda skill arg clave t0 edad resto fin estado detalle bloqueo modelo_col resto_bloqueo fin_ln
  local duracion_col dur_seg turnos_usados turnos_col presupuesto pr
  local short_pr decision_ln decision
  # Todos los prompts lanzados alguna vez, no solo los ESTADO_FILAS visibles
  # en la tabla: un `claude -p` lanzado antes de esa cola, y todavía vivo, no
  # debe salir como `sin registro` (DEVKIT-81 H2). Una sola lectura de
  # `lanzamientos` para no duplicar el costo del recorrido de watch.log.
  local full_lanz
  full_lanz=$(lanzamientos "$wlog")
  local -a prompts_vistos=()
  # Solo los lanzamientos sin resumen final (DEVKIT-81 H11): uno que ya
  # terminó, falló o no arrancó no puede explicar un `claude -p` vivo, así
  # que compararlo daba un falso "registrado" cuando el prompt se repite en
  # un lanzamiento posterior (por ejemplo, el mismo PR revisado dos veces).
  while IFS=$'\t' read -r ln _ id _ p _ _ _ _; do
    [ -n "$p" ] || continue
    if ! tail -n +"$((ln + 1))" "$wlog" | grep -q -E \
        "^[^ ]+ ($id (terminado|no lanzó): |ALARMA: $id terminó con error \(rc=[0-9]+\)|devkit-run \".*\" (terminado|falló \(rc=[0-9]+\)) \[$id\]:|devkit-run \".*\" ALARMA: no arrancó.*\[$id\]\$)"; then
      prompts_vistos+=("$p")
    fi
  done <<<"$full_lanz"
  while IFS=$'\t' read -r ln ts id origen prompt logf modelo esfuerzo ronda <&3; do
    skill=${prompt%% *}
    skill=${skill#/}
    arg=$(printf '%s' "$prompt" | awk '{print $2}')
    clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
    # pr-review recibe el número de PR, no la Clave: se toma de la línea
    # "PR #<n> (<Clave>)" que el bucle escribe antes de lanzarlo.
    if [ -z "$clave" ] && [ -n "$arg" ]; then
      clave=$(head -n "$ln" "$wlog" | grep -oE "PR #$arg \([A-Z][A-Z0-9]+-[0-9]+\)" | tail -1 \
        | grep -oE '[A-Z][A-Z0-9]+-[0-9]+')
    fi
    # Columna PR (DEVKIT-134): el enlace completo, o "-" sin PR asociado.
    pr=$(url_de_pr "$(pr_de_lanzamiento "$skill" "$arg" "$id")")
    t0=$(date -d "$ts" +%s 2>/dev/null || echo "$ahora")
    edad=$((ahora - t0))
    resto=$(tail -n +"$((ln + 1))" "$wlog")
    fin=$(printf '%s\n' "$resto" | grep -m1 -E \
      "^[^ ]+ ($id (terminado|no lanzó): |ALARMA: $id terminó con error \(rc=[0-9]+\)|devkit-run \".*\" (terminado|falló \(rc=[0-9]+\)) \[$id\]:|devkit-run \".*\" ALARMA: no arrancó.*\[$id\]$)")
    estado="" detalle="" fin_ln=""
    if [ -n "$fin" ]; then
      case "$fin" in
        *"ALARMA: no arrancó"*) estado="no arrancó"; detalle="el worker murió al arrancar; ver $logf" ;;
        # DEVKIT-107: review-prep.sh (rc=3, "nada que revisar") corta antes de
        # cualquier `claude -p` real, en el bucle (`run_skill` en watch.sh,
        # "$id no lanzó: ...") y en `--worker` (task-begin.sh, "... terminado
        # [$id]: no lanzó: ..."). Ninguno de los dos casos es un error: el
        # motivo, la única línea de $logf, va tal cual al detalle.
        *" no lanzó: "*)
          estado="no lanzó"
          detalle=${fin#*no lanzó: }
          ;;
        *"terminó con error"*|*"falló (rc="*)
          estado=error
          detalle="$(printf '%s' "$fin" | grep -oE 'rc=[0-9]+' | head -1); ver $logf" ;;
        *) estado=terminó ;;
      esac
    elif grep -qF -- "$logf" <<<"$procesos" \
         || { [ "$origen" = bucle ] && grep -qF -- "--sync /$skill $arg" <<<"$procesos"; }; then
      estado="en curso"
      # Misma alarma que watch_long_running en watch.sh (SKILL_TIMEOUT):
      # visible en la tabla, no solo en watch.log.
      [ "$edad" -lt "$SKILL_TIMEOUT" ] || detalle="lento"
    elif [ "$edad" -lt "$ESTADO_GRACIA" ]; then
      estado="en curso"; detalle="arrancando"
    elif [ "$candado" = ocupado ] && printf '%s\n' "$resto" | grep -qE "^[^ ]+ $id espera: "; then
      estado="en curso"; detalle="espera el candado"
    elif [ -s "$logf" ]; then
      estado=error; detalle="murió sin resumen; ver $logf"
    else
      estado="no arrancó"; detalle="sin proceso, log ni resumen tras $(hace "$edad")"
    fi
    # Bloqueo de la card después del lanzamiento y antes de que otro
    # lanzamiento de la misma card tome el relevo. La Clave va seguida de un
    # espacio o de la comilla final del prompt: así DEVKIT-57 no pasa por
    # DEVKIT-5.
    if [ -n "$clave" ] && [ "$estado" != "en curso" ]; then
      # El bloqueo solo puede ser de ESTE lanzamiento si ocurrió antes de su
      # propia línea de resolución ($fin, DEVKIT-97 ampliación del 19:07):
      # ESTADO describe solo el lanzamiento, y un bloqueo posterior a su
      # cierre es de otra corrida de la misma card (un task-fix bloqueado por
      # una pregunta abierta mucho después de que un pr-review ya había
      # terminado bien, por ejemplo), no de esta fila -aunque nada más vuelva
      # a mencionar la Clave entre medio para activar el corte de más abajo.
      resto_bloqueo=$resto
      fin_ln=""
      if [ -n "$fin" ]; then
        fin_ln=$(printf '%s\n' "$resto" | grep -nF -m1 -- "$fin" | cut -d: -f1)
        [ -n "$fin_ln" ] && resto_bloqueo=$(printf '%s\n' "$resto" | head -n "$((fin_ln - 1))")
      fi
      bloqueo=$(printf '%s\n' "$resto_bloqueo" | awk -v c="$clave" '
        / lanzando \(origen=/ && index($0, "\"/") && (index($0, " " c " ") || index($0, " " c "\"")) { exit }
        index($0, " task-block.sh " c " Bloqueada") { print; exit }')
      # DEVKIT-97 H3: block_pr en watch.sh (tres ciclos sin OK, task-fix vacío
      # dos veces) siempre bloquea DESPUÉS del `terminado` del lanzamiento que
      # cortó -el corte de arriba, pensado para un task-block.sh corrido a
      # mano mucho más tarde sobre la misma card, también se comía este caso
      # legítimo. Se distingue por su propia línea "PR #N (Clave) ...:
      # bloqueando con task-block.sh", que precede a la de "Bloqueada" sin
      # nada más entre medio (un `gh pr comment` no escribe en watch.log): si
      # aparece después de $fin y antes de cualquier lanzamiento nuevo de esta
      # Clave, el bloqueo es de esta fila.
      if [ -z "$bloqueo" ] && [ -n "${fin_ln:-}" ]; then
        bloqueo=$(printf '%s\n' "$resto" | tail -n "+$((fin_ln + 1))" | awk -v c="$clave" '
          / lanzando \(origen=/ && index($0, "\"/") && (index($0, " " c " ") || index($0, " " c "\"")) { exit }
          /: bloqueando con task-block\.sh$/ && index($0, "(" c ")") { marcado=1; next }
          marcado && index($0, " task-block.sh " c " Bloqueada") { print; exit }')
      fi
      if [ -n "$bloqueo" ]; then
        estado=bloqueada
        detalle=$(printf '%s' "$bloqueo" | sed -E 's/^.* task-block\.sh [^ ]+ Bloqueada desde [^:]*: //')
        detalle=${detalle:0:100}
      fi
    fi
    # Respaldo de DEVKIT-77: un `task-start` que "terminó" bien según la
    # línea de resumen, pero dejó su card `En progreso` sin PR y sin
    # bloquear, no es un avance real (DEVKIT-63). Mismo corte por el
    # siguiente lanzamiento de la misma Clave que usa `bloqueo`, para no
    # confundir esta alarma con la de un lanzamiento posterior.
    if [ "$skill" = task-start ] && [ "$estado" = terminó ] && [ -n "$clave" ] \
       && printf '%s\n' "$resto" | awk -v c="$clave" '
            / lanzando \(origen=/ && index($0, "\"/") && (index($0, " " c " ") || index($0, " " c "\"")) { found=0; exit }
            index($0, "ALARMA: terminó sin entregar ni bloquear (" c "):") { found=1; exit }
            END { exit (found ? 0 : 1) }'; then
      estado=error
      detalle="terminó sin entregar ni bloquear; card $clave sigue En progreso"
    fi
    # DEVKIT-132: ESTADO de una fila pr-review terminada muestra el veredicto
    # del bucle -Lista para merge, CAMBIOS o Bloqueada- en vez del genérico
    # "terminó", para no tener que abrir GitHub a ver qué decidió el
    # revisor. Se lee de la primera línea "PR #<num> (<Clave>) ..." que
    # watch.sh escribe después de $fin: por la reacción inmediata de
    # `procesar_pr` (DEVKIT-108), es siempre la decisión que salió de ESTE
    # informe, no de uno posterior (ver el comentario de `procesar_pr` en
    # watch.sh). Sin esa línea todavía -el bucle no volvió a decidir, o
    # decidió `fix-humano`/`nada`, que no dejan una línea con este prefijo-
    # sigue "terminó". También corre cuando el bloqueo de arriba (DEVKIT-97
    # H3) ya dejó estado=bloqueada: si esa misma línea de decisión es
    # "bloqueando con task-block.sh", el bloqueo es el veredicto de ESTE
    # informe y pasa a "Bloqueada" (negrita), conservando el detalle con el
    # motivo que el bloque de arriba ya extrajo; si no matchea ninguna
    # decisión, el bloqueo era ajeno y sigue "bloqueada" (sin negrita).
    if [ "$skill" = pr-review ] && { [ "$estado" = terminó ] || [ "$estado" = bloqueada ]; } \
       && [ -n "$arg" ]; then
      short_pr=${id#pr-review-"$arg"-}
      decision_ln=${fin_ln:-}
      [ -n "$decision_ln" ] || decision_ln=$(printf '%s\n' "$resto" | grep -nF -m1 -- "$fin" | cut -d: -f1)
      if [ -n "$decision_ln" ]; then
        decision=$(printf '%s\n' "$resto" | tail -n "+$((decision_ln + 1))" | grep -m1 -E "^[^ ]+ PR #$arg \(")
        case "$decision" in
          *" OK en $short_pr"*) estado="Lista para merge" ;;
          *" CAMBIOS en $short_pr: lanzando task-fix") estado=CAMBIOS ;;
          *"bloqueando con task-block.sh") estado=Bloqueada ;;
        esac
      fi
    fi
    if [ "$modelo" = - ] || [ -z "$modelo" ]; then
      modelo_col=-
    elif [ "$ronda" = - ] || [ -z "$ronda" ]; then
      modelo_col="$modelo/$esfuerzo"
    else
      modelo_col="$modelo/$esfuerzo r$ronda"
    fi
    # DEVKIT-107: DURÓ y TURNOS, tomados de la misma línea de cierre ($fin) que
    # ya resolvió ESTADO/DETALLE arriba. "en curso" no tiene línea de cierre
    # todavía: su duración es el tiempo transcurrido desde "lanzando" (el mismo
    # $edad de HACE, creciendo en cada refresco) y sus turnos, desconocidos,
    # quedan en "-" contra el presupuesto. `presupuesto_de_skill` es la misma
    # función que usa `--costos` para marcar un exceso con "!".
    presupuesto=$(presupuesto_de_skill "$skill")
    if [ "$estado" = "en curso" ]; then
      duracion_col=$(hace "$edad")
      turnos_col="-/${presupuesto:--}"
    else
      dur_seg=$(printf '%s' "$fin" | grep -oE 'duracion=[0-9]+' | head -1 | cut -d= -f2)
      if [ -n "$dur_seg" ]; then duracion_col=$(hace "$dur_seg"); else duracion_col=-; fi
      turnos_usados=$(printf '%s' "$fin" | grep -oE 'turnos=[0-9]+' | head -1 | cut -d= -f2)
      if [ -n "$turnos_usados" ]; then
        if [ -n "$presupuesto" ] && [ "$turnos_usados" -gt "$presupuesto" ] 2>/dev/null; then
          turnos_col="${turnos_usados}/${presupuesto}!"
        else
          turnos_col="${turnos_usados}/${presupuesto:--}"
        fi
      else
        turnos_col="-/${presupuesto:--}"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$skill" "${clave:--}" "$origen" "$(hace "$edad")" "$estado" "${detalle:--}" "$modelo_col" "$duracion_col" "$turnos_col" "$pr"
  done 3< <(if [ -n "$full_lanz" ]; then printf '%s\n' "$full_lanz"; fi | tail -n "$ESTADO_FILAS")
  filas_sin_registro "$procesos" "${prompts_vistos[@]}"
}

# Filas `sin registro` (DEVKIT-81, regla sin excepción): un `claude -p` vivo
# en `ps` cuyo prompt no aparece en ninguna línea "lanzando" reciente. Cubre
# un lanzamiento que devkit-run no vio -un bug, algo lanzado a mano por fuera
# de devkit-run/watch.sh-, para que ningún `claude -p` del contenedor quede
# invisible en `--estado`. La sonda de modelo (`claude -p "ok"`, en
# `modelo_disponible`) y la lectura de cuota (`claude -p "/usage"`, en
# `leer_cuota`) no son skills: se excluyen por su prompt exacto, no porque
# tengan línea "lanzando" -no la tienen, y nunca la tendrán.
filas_sin_registro() {  # filas_sin_registro <procesos ps -eo pid=,args=> [prompt activo]...
  local procesos=$1
  shift
  local -a activos=("$@")
  local -a activos_id=()
  local pid resto prompt prompt_id encontrado a
  for a in "${activos[@]}"; do
    activos_id+=("$(identidad_prompt "$a")")
  done
  while read -r pid resto; do
    [ -n "$pid" ] || continue
    case "$resto" in *claude*" -p "*) ;; *) continue ;; esac
    prompt=${resto#*" -p "}
    # `run_claude` siempre pone `--model` justo después del prompt (:585):
    # cortar ahí, no en el primer " --", evita partir un comentario humano
    # que trae sus propias banderas (DEVKIT-81 H10). La sonda de modelo y la
    # de cuota no pasan por `run_claude`; la de cuota no lleva `--model`, así
    # que se cae al corte por el primer " --" de siempre.
    case "$prompt" in
      *" --model "*) prompt=${prompt% --model *} ;;
      *) prompt=${prompt%% --*} ;;
    esac
    case "$prompt" in ok|/usage) continue ;; esac
    # Comparar por identidad (skill + primer argumento, DEVKIT-97), no por el
    # texto completo: la línea "lanzando" solo guarda el prompt corto, pero
    # `ps` trae el volcado de la card que `--worker` le agrega a task-start
    # (ver `identidad_prompt`). Un `prompt_norm` recortado a 120 caracteres
    # del texto completo no comparte prefijo útil con el prompt corto cuando
    # ese volcado es más largo que eso.
    prompt_id=$(identidad_prompt "$prompt")
    encontrado=0
    for a in "${activos_id[@]}"; do
      [ "$prompt_id" = "$a" ] && { encontrado=1; break; }
    done
    [ "$encontrado" = 1 ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' - - - - "sin registro" "claude -p vivo (pid $pid) sin línea lanzando: $(prompt_en_linea "$prompt")" - - - -
  done <<<"$procesos"
}

# Conteo rápido de "en curso" para el segmento `agentes:<a>` del prompt
# (DEVKIT-63): mismo criterio que `estado_filas`, en una sola pasada del log
# y con bash builtins en vez de un `grep`/`date`/`tail` por fila -con unos 15
# lanzamientos, `estado_filas` completo mide sobre 90 ms (`starship timings`),
# muy por encima del presupuesto de 50 ms por módulo del prompt. La única
# diferencia a propósito: un `--sync` anidado del bucle (un `claude -p`
# lanzado dentro de otro, caso raro) cuenta como "en curso" recién cuando
# aparece en `ps` con la ruta de su log, no antes; `estado_filas` también lo
# detecta por su patrón `--sync /<skill> <arg>` en la lista de procesos. Ver
# la entrada de Documentación "Arquitectura del devkit" (Notion), sección 4.4.
agentes_en_curso_rapido() {  # agentes_en_curso_rapido <watch.log> <ahora epoch>
  local wlog=$1 ahora=$2 procesos lanz ids candado=libre en_curso=0
  local -A done_ids
  procesos=$("$PS_BIN" -eo args= -ww 2>/dev/null)
  lanz=$(lanzamientos "$wlog" | tail -n "$ESTADO_FILAS")
  [ -n "$lanz" ] || { echo 0; return 0; }
  ids=$(printf '%s\n' "$lanz" | cut -f3 | paste -sd'|' -)
  if [ -n "$ids" ]; then
    while IFS= read -r d; do [ -n "$d" ] && done_ids[$d]=1; done < <(
      grep -oE "($ids) (terminado|no lanzó): |ALARMA: ($ids) terminó con error \(rc=[0-9]+\)|devkit-run \".*\" (terminado|falló \(rc=[0-9]+\)) \[($ids)\]:|devkit-run \".*\" ALARMA: no arrancó.*\[($ids)\]\$" \
        "$wlog" 2>/dev/null | grep -oE -- "$ids")
  fi
  if [ -e "$LOCK" ] && exec 7<"$LOCK"; then
    flock -n 7 || candado=ocupado
    exec 7<&-
  fi
  local ln ts id origen prompt logf modelo esfuerzo ronda t0 edad
  while IFS=$'\t' read -r ln ts id origen prompt logf modelo esfuerzo ronda; do
    [ -n "${done_ids[$id]:-}" ] && continue
    if [[ $procesos == *"$logf"* ]]; then
      en_curso=$((en_curso + 1)); continue
    fi
    t0=$(date -d "$ts" +%s 2>/dev/null || echo "$ahora")
    edad=$((ahora - t0))
    if [ "$edad" -lt "$ESTADO_GRACIA" ]; then
      en_curso=$((en_curso + 1)); continue
    fi
    if [ "$candado" = ocupado ] && grep -qE "^[^ ]+ $id espera: " "$wlog" 2>/dev/null; then
      en_curso=$((en_curso + 1))
    fi
  done <<<"$lanz"
  echo "$en_curso"
}

# Rellena a <n> caracteres. `printf %-Ns` cuenta bytes, y "terminó" o
# "no arrancó" desalinearían la tabla.
rellenar() {  # rellenar <texto> <ancho>
  local s=$1 n=$2
  printf '%s%*s' "$s" "$(( n > ${#s} ? n - ${#s} : 0 ))" ''
}

# Tamaño de la terminal para recortar la tabla (DEVKIT-97, H1): solo
# `$COLUMNS`/`$LINES` -así la autoprueba fija un tamaño sin una tty real, y
# `seguir_estado`/`seguir_lanzamiento`/`seguir_tablero`/la rama `--estado` sin
# `--seguir` los exportan con `tput` (y solo con tty real, `[ -t 1 ]`) antes de
# armar el cuadro, porque adentro de un `$(...)` -que es como arman ese
# cuadro- `tput` ya no ve la tty real (mismo problema que `color` en
# `senal_bucle`). Sin ninguna de las dos (una tubería, `cron`, un lanzamiento
# de watch.sh, esta autoprueba, todos sin tty pero a veces con `$TERM`
# heredado): un tamaño grande a propósito, no uno chico. Un `tput` de respaldo
# acá adentro devolvía 80/24 con `$TERM` definido pero sin tty -el caso más
# común fuera de una terminal interactiva-, y esta tabla ya usa
# `$ANCHO_COLUMNAS_FIJAS` columnas fijas antes de DETALLE (DEVKIT-131: se
# calculan, no se fijan a mano; no repetir la cifra acá, que queda vieja en
# cuanto un valor posible cambia): a 80 quedaban pocos caracteres para
# DETALLE, mucho peor que no recortar nada cuando no hay certeza real del
# tamaño.
ancho_terminal() {
  local c=${COLUMNS:-}
  [ "$c" -gt 0 ] 2>/dev/null || c=200
  printf '%s' "$c"
}

alto_terminal() {
  local l=${LINES:-}
  [ "$l" -gt 0 ] 2>/dev/null || l=1000
  printf '%s' "$l"
}

# Owner/repo del remoto actual (DEVKIT-134, columna PR de `--estado`), con
# REPO_NAME_WITH_OWNER_CACHE (arriba, junto a Bloqueos/Épicas): una sola
# llamada a `gh repo view` mientras esa caché exista, no una por fila ni una
# por refresco de `--seguir`. Antes de `ancho_de`/`ANCHO_PR`, que la necesitan
# al arrancar el script para medir la columna: definida aquí arriba, no junto
# a `clave_de_pr` más abajo, para que ese cálculo top-level la encuentre ya
# declarada. "-" si `gh` no responde: sin owner/repo no hay enlace que armar,
# y esa fila cae al mismo "-" que una fila sin PR. Ese "-" no se persiste
# (DEVKIT-134 H1): si se guardara, un solo fallo de `gh` -sin red, sin auth,
# o un `--test` corrido sin `gh`- dejaría la columna en "-" para siempre
# mientras viva /run/devkit, aunque `gh` ya responda en la siguiente llamada.
repo_name_with_owner() {
  local repo
  if [ -s "$REPO_NAME_WITH_OWNER_CACHE" ]; then
    cat "$REPO_NAME_WITH_OWNER_CACHE"
    return 0
  fi
  repo=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
  case "$repo" in
    ?*/?*)
      mkdir -p "$(dirname "$REPO_NAME_WITH_OWNER_CACHE")" 2>/dev/null
      printf '%s' "$repo" >"$REPO_NAME_WITH_OWNER_CACHE" 2>/dev/null
      printf '%s' "$repo"
      ;;
    *)
      printf -- '-'
      ;;
  esac
}

# Número de PR de un lanzamiento (DEVKIT-134): "-" si no tiene uno todavía
# -task-start crea la card sin PR-. pr-review lo recibe como su propio
# argumento ("/pr-review 41": <arg> ya lo trae, la misma resolución que usa
# la Clave un poco más arriba en `estado_filas`, sin volver a leer el log).
# task-fix, task-document, task-close y task-block lo llevan en el propio
# <id> que arma watch.sh (`task-fix-<n>-<sha>`, `task-document-<n>-<sha>`,
# `task-close-<n>`, `task-block-<n>`), mismo patrón de <id> que ya usa
# `clave_de_lanzamiento` (más abajo) para pr-review/task-close.
pr_de_lanzamiento() {  # pr_de_lanzamiento <skill> <arg> <id>
  local skill=$1 arg=$2 id=$3 num
  if [ "$skill" = pr-review ]; then
    case "$arg" in ''|*[!0-9]*) : ;; *) printf '%s' "$arg"; return 0 ;; esac
  fi
  num=$(printf '%s' "$id" | grep -oE '^(pr-review|task-fix|task-document|task-close|task-block)-[0-9]+' | grep -oE '[0-9]+$')
  printf '%s' "${num:--}"
}

# Enlace completo del PR de una fila de `--estado` (DEVKIT-134): "-" sin
# número o sin owner/repo, nunca un enlace roto a medias.
url_de_pr() {  # url_de_pr <número de PR o "-">
  local num=$1 repo
  if [ "$num" = - ]; then
    printf -- '-'
    return 0
  fi
  repo=$(repo_name_with_owner)
  if [ "$repo" = - ]; then
    printf -- '-'
    return 0
  fi
  printf 'https://github.com/%s/pull/%s' "$repo" "$num"
}

# Ancho de una columna fija: la longitud del valor posible más largo, más un
# espacio de separación con la siguiente (DEVKIT-131). `rellenar` no agrega
# ese espacio cuando el texto ya llena el ancho (DEVKIT-107 H4), así que tiene
# que venir incluido acá. Sin este cálculo cada ANCHO_* se fijaba a mano
# contra una foto de los valores del momento, y un valor nuevo la desbordaba
# en silencio corriendo el resto de la fila -caso real: ANCHO_LANZO=8 no
# alcanzaba para "task-close" (10).
ancho_de() {  # ancho_de <valor>...
  local max=0 v
  for v in "$@"; do
    [ "${#v}" -gt "$max" ] && max=${#v}
  done
  printf '%s' "$((max + 1))"
}

# SKILL: cualquier skill real que `devkit-run <skill> <arg>` pueda lanzar deja
# línea "lanzando" en watch.log (autoprueba de /task-submit, línea ~6852);
# task-close y task-block son bash, DEVKIT-55, y no aparecen aquí. Se leen los
# directorios de skills instalados -$WS/.claude/skills, el símlink al
# template (AGENTS.md)-, con $HERE/../agents/skills como alternativa en modo
# dev (este mismo repo, antes de reinstalar la imagen); si ninguno de los dos
# tiene skills, cae al listado fijo de siempre (DEVKIT-131 H1: una lista a
# mano de cinco se quedó corta contra las 11 reales -template-propagate, la
# más larga, desbordaba ANCHO_SKILL-). LANZÓ: quién pidió el lanzamiento
# -"humano" es el respaldo de origen_de sin ancestro reconocido, "bucle" lo
# pone run_skill de watch.sh, "task-close" lo exporta task-close.sh
# (DEVKIT_ORIGEN) y también es el origen fijo que costos_filas asigna al
# cierre bash del PR- o cualquiera de esas mismas skills como ancestro
# (origen_de: un `claude -p /epic-plan` lanzando `task-start`, por ejemplo,
# deja origen=epic-plan).
skills_lanzables() {
  local base dir encontrados=()
  for base in "$WS/.claude/skills" "$HERE/../agents/skills"; do
    encontrados=()
    for dir in "$base"/*/; do
      [ -f "${dir}SKILL.md" ] || continue
      encontrados+=("$(basename "$dir")")
    done
    if [ "${#encontrados[@]}" -gt 0 ]; then
      printf '%s\n' "${encontrados[@]}" | sort
      return 0
    fi
  done
  printf '%s\n' task-start pr-review task-fix task-document epic-plan
}
mapfile -t SKILLS_CON_LANZAMIENTO < <(skills_lanzables)
ORIGENES_LANZAMIENTO=(humano bucle task-close "${SKILLS_CON_LANZAMIENTO[@]}")

# ESTADO: cada estado que arma estado_filas (comentario de esa función,
# arriba: en curso, terminó, error, bloqueada, no arrancó, no lanzó, y "sin
# registro" como único valor del caso por defecto) con su glifo -el de UTF-8
# y el de respaldo ASCII (utf8_disponible), porque sin locale UTF-8 el
# respaldo puede medir más que el icono real ("!! bloqueada" son 12, dos más
# que "⊘ bloqueada"-. "Lista para merge" y "Bloqueada" (DEVKIT-132: el
# veredicto de un pr-review terminado, no un paso del ciclo) entran acá
# también, porque son los valores más anchos que de verdad puede mostrar
# ESTADO -sin ellos, `ancho_de` los calcularía cortos y la fila desbordaría
# en silencio en cuanto el bucle deje ese veredicto-.
ESTADOS_CON_GLIFO=(
  "⠿ en curso" "* en curso"
  "✔ terminó" "ok terminó"
  "✔ Lista para merge" "ok Lista para merge"
  "✖ error" "x error"
  "⊘ bloqueada" "!! bloqueada"
  "⊘ Bloqueada" "!! Bloqueada"
  "○ no arrancó" "o no arrancó"
  "○ no lanzó" "o no lanzó"
  "○ en espera" "o en espera"
  "⚠ sin registro" "! sin registro"
)

# MODELO: "<alias>/<esfuerzo>[ r<ronda>]", con <alias> de `frontera` (roles.toml,
# DEVKIT-131: el alias, no un número a mano) y también de `implementacion.rondas`/
# `revision.rondas` -alias:esfuerzo por elemento, DEVKIT-61-, porque esos dos
# también son alias reales de roles.toml y `frontera` no los repite (DEVKIT-131
# H3: MODELO solo tomaba los de `frontera` y un alias más largo en `.rondas`
# desbordaba la columna sin que nada lo notara). El resto en su forma más larga
# real -"/medium r9": "medium" es el esfuerzo más largo que acepta `--esfuerzo`
# (línea de uso, arriba) y una ronda de un dígito es la que se ve en la
# práctica-.
mapfile -t ALIAS_FRONTERA < <(frontera_list)
[ "${#ALIAS_FRONTERA[@]}" -gt 0 ] || ALIAS_FRONTERA=(fable opus sonnet)
mapfile -t ALIAS_RONDAS < <({ toml_lista implementacion.rondas; toml_lista revision.rondas; } | sed -E 's/:.*$//')
MODELOS_CON_ESFUERZO=()
for _alias_frontera in "${ALIAS_FRONTERA[@]}" "${ALIAS_RONDAS[@]}"; do
  MODELOS_CON_ESFUERZO+=("$_alias_frontera/medium r9")
done
unset _alias_frontera

ANCHO_SKILL=$(ancho_de "${SKILLS_CON_LANZAMIENTO[@]}")
ANCHO_CARD=12  # sin cambios (DEVKIT-107 H4): DEVKIT-9999 mide 11, más el espacio de separación.
# PR (DEVKIT-134): la URL completa, con el owner/repo real -`repo_name_with_
# owner` cachea esa consulta a `gh`, una sola vez por ejecución- y cinco
# dígitos de PR (99999), un margen amplio contra el volumen real de este
# proyecto, mismo criterio que ANCHO_CARD con DEVKIT-9999. El humano acepta
# que en terminales angostas esto le come más espacio a DETALLE (pedido del
# 2026-09-21).
ANCHO_PR=$(ancho_de "https://github.com/$(repo_name_with_owner)/pull/99999")
ANCHO_LANZO=$(ancho_de "${ORIGENES_LANZAMIENTO[@]}")
# HACE/DURÓ: la forma más larga que devuelve `hace()` es "23h59m" (6);
# "59m59s" no ocurre, `hace()` no combina minutos y segundos.
ANCHO_HACE=$(ancho_de "23h59m")
ANCHO_DURO=$ANCHO_HACE
ANCHO_ESTADO=$(ancho_de "${ESTADOS_CON_GLIFO[@]}")
ANCHO_MODELO=$(ancho_de "${MODELOS_CON_ESFUERZO[@]}")
# TURNOS: "<turnos_usados>/<presupuesto>[!]", con <presupuesto> el mayor
# `presupuesto_de_skill` entre las skills reales -`presupuesto.<skill>` de
# roles.toml, o el `max_turns` de su rol si esa skill no lo anula- (DEVKIT-131
# H3: antes era el literal "125/120!", y un roles.toml de proyecto con un
# presupuesto de más dígitos desbordaba la columna sin que nada lo detectara).
# <turnos_usados> puede llevar un dígito más que <presupuesto> por un exceso
# real; de ahí el "9" de más en PRESUPUESTO_MAX_MAS_UNO.
PRESUPUESTO_MAX=0
for _skill_presupuesto in "${SKILLS_CON_LANZAMIENTO[@]}"; do
  _v_presupuesto=$(presupuesto_de_skill "$_skill_presupuesto")
  case "$_v_presupuesto" in '' | *[!0-9]*) continue ;; esac
  [ "$_v_presupuesto" -gt "$PRESUPUESTO_MAX" ] && PRESUPUESTO_MAX=$_v_presupuesto
done
unset _skill_presupuesto _v_presupuesto
PRESUPUESTO_MAX_MAS_UNO=$(printf '9%.0s' $(seq 1 $((${#PRESUPUESTO_MAX} + 1))))
ANCHO_TURNOS=$(ancho_de "${PRESUPUESTO_MAX_MAS_UNO}/${PRESUPUESTO_MAX}!")
ANCHO_COLUMNAS_FIJAS=$((ANCHO_SKILL + ANCHO_CARD + ANCHO_PR + ANCHO_LANZO + ANCHO_HACE + ANCHO_DURO + ANCHO_ESTADO + ANCHO_MODELO + ANCHO_TURNOS))

# Recorta <texto> a <ancho> con "…" al final si no entra entero. <ancho>
# menor a 1 corta a 1 -nunca a 0 ni negativo, `${s:0:n}` con `n` negativo
# cuenta desde el final y mostraría lo último, no lo primero.
recortar() {  # recortar <texto> <ancho>
  local s=$1 n=$2
  [ "$n" -ge 1 ] 2>/dev/null || n=1
  [ "${#s}" -gt "$n" ] || { printf '%s' "$s"; return 0; }
  printf '%s…' "${s:0:$((n - 1))}"
}

# Envuelve en color ANSI los caracteres de <fila> en [<inicio>, <inicio>+
# <largo>) -recortado a lo que <fila> realmente tenga, para cuando el recorte
# de la fila entera al ancho de la terminal (DEVKIT-107 H1) se llevó parte o
# toda esa columna. Se aplica siempre DESPUÉS de recortar la fila entera,
# nunca antes: `recortar`/`${#fila}` cuentan caracteres visibles, y una
# secuencia ANSI de por medio correría el corte (mismo motivo por el que
# DEVKIT-106 H3 ya pintaba cada columna después de recortar DETALLE, no
# antes).
pintar_rango() {  # pintar_rango <fila> <inicio> <largo> <color>
  local fila=$1 inicio=$2 largo=$3 color=$4 visible
  [ "$inicio" -lt "${#fila}" ] || { printf '%s' "$fila"; return 0; }
  visible=$(( inicio + largo > ${#fila} ? ${#fila} - inicio : largo ))
  printf '%s%s%s' "${fila:0:inicio}" "$(colorear "$color" "${fila:inicio:visible}" 1)" "${fila:$((inicio + visible))}"
}

# Iconos y color de `--estado`/`--tablero` (DEVKIT-106): un vistazo sin leer
# texto. Sin UTF-8 declarada en LANG/LC_ALL caen a un respaldo ASCII de un
# carácter -bash cuenta bytes, no caracteres, fuera de una locale UTF-8, y un
# icono multibyte desalinearía `rellenar` igual que "terminó" antes de
# DEVKIT-81 H7-. Misma precedencia que la libc para decidir cómo bash cuenta
# caracteres (DEVKIT-106 H8): LC_ALL, luego LC_CTYPE, luego LANG.
utf8_disponible() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;;
    *) return 1 ;;
  esac
}

# Girador de "en curso" (DEVKIT-106): el de npm/ora, un punto braille por
# refresco de `--seguir`; fijo en ⠿ en una sola foto de `--estado`.
GIRO_BRAILLE='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# Aplica el color ANSI de <color> ("verde"/"ambar"/"rojo"/"gris"/"negrita"/
# vacío, cada uno de los primeros cuatro con un sufijo "-negrita" opcional
# -DEVKIT-132, para "Lista para merge" y "Bloqueada" en
# `color_de_estado_fila`-) a <texto> si <habilitado> es 1 -mismo patrón que
# <color> en `senal_bucle`: quien arma el cuadro dentro de un `$(...)` no
# puede decidirlo ahí adentro con `[ -t 1 ]` y lo resuelve antes, afuera.
# "negrita" sola es un atributo, no un color (DEVKIT-134: SKILL en negrita
# para task-start, distinguir de un vistazo la fila que abre una card de la
# que la continúa, sin competir con los colores de ESTADO). Sin color que
# aplicar (vacío o <habilitado> distinto de 1), <texto> vuelve intacto.
colorear() {  # colorear <color> <texto> <habilitado>
  local color=$1 texto=$2 habilitado=$3 code='' negrita='' num=''
  case "$color" in
    *-negrita) negrita=1; color=${color%-negrita} ;;
  esac
  if [ "$habilitado" = 1 ]; then
    case "$color" in
      verde) num=32 ;;
      ambar) num=33 ;;
      rojo) num=31 ;;
      gris) num=90 ;;
      negrita) code=$'\033[1m' ;;
    esac
    if [ -n "$num" ]; then
      if [ -n "$negrita" ]; then code=$'\033[1;'"$num"m; else code=$'\033['"$num"m; fi
    fi
  fi
  if [ -n "$code" ]; then printf '%s%s\033[0m' "$code" "$texto"; else printf '%s' "$texto"; fi
}

# Glifo sin color de una fila de `estado_filas` (skill/tarea). "en curso" gira
# en braille, una posición por refresco (<idx>), fijo en ⠿ con <fijo>=1 (una
# sola foto de `--estado` sin `--seguir`); terminó ✔ -mismo icono para "Lista
# para merge" (DEVKIT-132): el veredicto OK de un pr-review terminado, no un
# paso distinto-; error -mismo icono para
# "falló", el texto que trae la línea cruda de watch.log antes de que
# `estado_filas` lo normalice a "error"- ✖; bloqueada ⊘ -mismo icono para
# "Bloqueada" (DEVKIT-132), el veredicto de bloqueo de un pr-review terminado-
# -no ⛔: ese glifo es
# East Asian Wide y mide dos celdas, mientras que `rellenar` cuenta caracteres
# (DEVKIT-106 H1)-; no arrancó (la card
# nunca llegó a lanzar; "no lanzó" es el mismo caso con otro nombre) ○;
# cualquier otro valor -"sin registro", un `claude -p` vivo que `devkit-run`
# no reconoce, y también "CAMBIOS" (DEVKIT-132): el veredicto de corrección de
# un pr-review terminado- ⚠, la misma alarma que "lento": es una anomalía o
# algo que necesita atención, no un paso resuelto del ciclo. Separado de
# `color_de_estado_fila` para que
# `formatear_fila` rellene la columna con el texto plano -sin las secuencias
# ANSI, que `rellenar` contaría como caracteres visibles y correría el resto
# de la tabla- y recién después pinte el glifo ya alineado.
glifo_estado_fila() {  # glifo_estado_fila <estado> <idx> <fijo:0|1> <utf:0|1>
  local estado=$1 idx=$2 fijo=$3 utf=$4
  case "$estado" in
    "en curso")
      if [ "$fijo" = 1 ]; then
        [ "$utf" = 1 ] && printf '⠿' || printf '*'
      elif [ "$utf" = 1 ]; then
        printf '%s' "${GIRO_BRAILLE:$((idx % 10)):1}"
      else
        printf '*'
      fi
      ;;
    terminó|"Lista para merge") [ "$utf" = 1 ] && printf '✔' || printf 'ok' ;;
    error|falló|"falló ("*) [ "$utf" = 1 ] && printf '✖' || printf 'x' ;;
    bloqueada|Bloqueada) [ "$utf" = 1 ] && printf '⊘' || printf '!!' ;;
    "no arrancó"|"no lanzó"|"en espera") [ "$utf" = 1 ] && printf '○' || printf 'o' ;;
    *) [ "$utf" = 1 ] && printf '⚠' || printf '!' ;;
  esac
}

# Color del glifo de `glifo_estado_fila` para el mismo <estado>. "en curso"
# vuelve vacío -el girador no lleva color, ya se distingue por moverse-.
# "Lista para merge" y "Bloqueada" (DEVKIT-132) son los mismos verde/rojo de
# "terminó"/"bloqueada", pero en negrita -el atributo ANSI que suma
# `colorear`-: son un veredicto ya tomado por el revisor, no el genérico "el
# lanzamiento terminó" o "la card quedó bloqueada por otro motivo". "CAMBIOS"
# (DEVKIT-132, el tercer veredicto) no tiene caso propio: cae en el `ambar`
# por defecto, igual que cualquier estado que esta función no reconoce.
color_de_estado_fila() {  # color_de_estado_fila <estado>
  case "$1" in
    "en curso") printf '' ;;
    terminó) printf verde ;;
    "Lista para merge") printf verde-negrita ;;
    error|falló|"falló ("*|bloqueada) printf rojo ;;
    Bloqueada) printf rojo-negrita ;;
    "no arrancó"|"no lanzó") printf gris ;;
    "en espera") printf ambar ;;
    *) printf ambar ;;
  esac
}

# Mismo set de iconos que `glifo_estado_fila`/`color_de_estado_fila`, sobre el
# Estado de Notion de una fila de `--tablero` (DEVKIT-106): "En progreso" y
# "Revisión automática" son trabajo activo -mismo braille que "en curso"-;
# "Lista para merge" ya terminó el trabajo del agente; "Lista" es la cola,
# todavía sin lanzar -mismo icono que "no arrancó"-; "Bloqueada" es la misma
# palabra que en `estado_filas`.
glifo_estado_tablero() {  # glifo_estado_tablero <estado card> <idx> <fijo:0|1> <utf:0|1>
  case "$1" in
    "En progreso"|"Revisión automática") glifo_estado_fila "en curso" "$2" "$3" "$4" ;;
    "Lista para merge") glifo_estado_fila terminó 0 1 "$4" ;;
    Bloqueada) glifo_estado_fila bloqueada 0 1 "$4" ;;
    Lista) glifo_estado_fila "no arrancó" 0 1 "$4" ;;
    *) glifo_estado_fila desconocido 0 1 "$4" ;;
  esac
}

color_de_estado_tablero() {  # color_de_estado_tablero <estado card>
  case "$1" in
    "En progreso"|"Revisión automática") printf '' ;;
    "Lista para merge") printf verde ;;
    Bloqueada) printf rojo ;;
    Lista) printf gris ;;
    *) printf ambar ;;
  esac
}

# Punto de la cabecera de `--estado`/`--tablero --seguir` (DEVKIT-106): verde
# "ejecutando" con al menos una fila "en curso" en <filas> (la salida de
# `estado_filas`); si no hay ninguna, ámbar "en espera" con el bucle vivo o
# esperando una skill, rojo "parado" con el bucle MUERTO o SIN SEÑAL -las
# mismas ramas que ya distingue el texto de <bucle> (`senal_bucle`), leídas de
# ahí para no duplicar esa lógica-. <fijo>=1 (una sola foto de `--estado`, sin
# `--seguir`) deja el punto sin parpadeo; en `--seguir` alterna ● lleno/○
# hueco con <idx>, la señal de vida del propio monitor (DEVKIT-81): si dos
# refrescos seguidos muestran el mismo símbolo, el monitor está congelado.
punto_estado() {  # punto_estado <filas de estado_filas> <bucle de senal_bucle> <idx> <fijo:0|1> <utf:0|1> <color_habilitado>
  local filas=$1 bucle=$2 idx=$3 fijo=$4 utf=$5 habilitado=$6 color palabra relleno
  if printf '%s\n' "$filas" | awk -F'\t' '$5=="en curso"{f=1} END{exit !f}'; then
    color=verde; palabra=ejecutando
  else
    case "$bucle" in
      *MUERTO*|*'SIN SEÑAL'*) color=rojo; palabra=parado ;;
      *) color=ambar; palabra="en espera" ;;
    esac
  fi
  if [ "$fijo" = 1 ] || [ "$((idx % 2))" -eq 0 ]; then
    relleno=$([ "$utf" = 1 ] && printf '●' || printf '*')
  else
    relleno=$([ "$utf" = 1 ] && printf '○' || printf 'o')
  fi
  printf '%s %s' "$(colorear "$color" "$relleno" "$habilitado")" "$(colorear "$color" "$palabra" "$habilitado")"
}

encabezado_tabla() {
  # Cada ANCHO_* sale de `ancho_de` contra los valores posibles reales de su
  # columna (DEVKIT-131), no de una cifra fijada a mano: no repetir números
  # acá, que quedan viejos en cuanto un valor posible cambia (caso real:
  # "⚠ sin registro" ensanchó ESTADO en DEVKIT-106 H2, después de que
  # DEVKIT-81 H7 ya la había ensanchado una vez). Las constantes `ANCHO_*`
  # están junto a `ANCHO_COLUMNAS_FIJAS`, arriba.
  printf '%s%s%s%s%s%s%s%s%s%s\n' "$(rellenar SKILL "$ANCHO_SKILL")" "$(rellenar CARD "$ANCHO_CARD")" \
    "$(rellenar PR "$ANCHO_PR")" "$(rellenar LANZÓ "$ANCHO_LANZO")" "$(rellenar HACE "$ANCHO_HACE")" "$(rellenar DURÓ "$ANCHO_DURO")" \
    "$(rellenar ESTADO "$ANCHO_ESTADO")" "$(rellenar MODELO "$ANCHO_MODELO")" \
    "$(rellenar TURNOS "$ANCHO_TURNOS")" DETALLE
}

# Una fila formateada de `--estado`, con "bloquea a: ..." sumado al detalle
# si corresponde. Aparte de `mostrar_estado` para que agrupar por Épica
# (DEVKIT-80) no duplique el formato de columnas. DETALLE se recorta al
# ancho disponible de la terminal (DEVKIT-97): sin esto, una card completa
# colgada de un `sin registro` (o cualquier motivo largo) desbordaba una
# sola fila a veinte líneas de pantalla, y el redibujo en el sitio de
# `--seguir` (`\033[H`) apilaba cuadros en vez de refrescar uno solo.
# <idx>/<fijo>/<color> (DEVKIT-106) van a `glifo_estado_fila`/`colorear` para
# el icono de ESTADO; por defecto una sola foto sin color, así las llamadas
# directas de la autoprueba (sin esos tres argumentos) no cambian. ANCHO_ESTADO
# sale de `ancho_de` sobre los estados posibles (DEVKIT-131): "⚠ sin registro"
# fue el que la ensanchó (DEVKIT-106 H2), sin margen quedaba pegado a MODELO.
# <duracion> y <turnos> (DEVKIT-107), y <pr> (DEVKIT-134, el enlace completo o
# "-" sin PR) ya llegan formateados desde `estado_filas` (o de la autoprueba,
# directo): esta función solo alinea y colorea, no vuelve a calcularlos.
#
# La fila se arma entera en texto plano (sin ANSI) y solo al final, si no
# entra en el ancho de la terminal, se recorta completa con `recortar` -no
# solo DETALLE- y recién ahí se pintan los colores con `pintar_rango`
# (DEVKIT-107 H1): angostar `ANCHO_COLUMNAS_FIJAS` (calculado, DEVKIT-131) no
# alcanza en una terminal más angosta que eso, y ahí hace falta comerse parte
# de las columnas fijas de la derecha (TURNOS, MODELO), no solo DETALLE. Pintar
# antes de ese recorte final correría el corte, como ya cuidaba DEVKIT-106 H3
# para DETALLE por separado.
formatear_fila() {  # formatear_fila <skill> <clave> <pr> <origen> <edad> <duracion> <estado> <modelo> <turnos> <detalle> [idx=0] [fijo=1] [color=]
  local skill=$1 clave=$2 pr=$3 origen=$4 edad=$5 duracion=$6 estado=$7 modelo=$8 turnos=$9 detalle=${10} \
        idx=${11:-0} fijo=${12:-1} color_habilitado=${13:-} frena="" utf glifo color icono_len \
        glifo_lento glifo_lento_len ancho fila off_estado off_turnos off_detalle
  [ "$clave" = - ] || frena=$(bloquea_a "$clave")
  if [ -n "$frena" ]; then
    [ "$detalle" = - ] && detalle=$frena || detalle="$detalle; $frena"
  fi
  utf8_disponible && utf=1 || utf=0
  # "lento" (el detalle que deja `estado_filas` cuando un "en curso" supera
  # SKILL_TIMEOUT) suma su propio icono ámbar delante, aparte del girador de
  # ESTADO: son dos alarmas distintas, sigue en curso pero además va lento.
  glifo_lento_len=0
  case "$detalle" in
    lento|"lento;"*)
      glifo_lento=$([ "$utf" = 1 ] && printf '⚠' || printf '!')
      glifo_lento_len=${#glifo_lento}
      detalle="$glifo_lento $detalle"
      ;;
  esac
  ancho=$(ancho_terminal)
  detalle=$(recortar "$detalle" "$((ancho - ANCHO_COLUMNAS_FIJAS))")
  glifo=$(glifo_estado_fila "$estado" "$idx" "$fijo" "$utf")
  color=$(color_de_estado_fila "$estado")
  icono_len=${#glifo}
  off_estado=$((ANCHO_SKILL + ANCHO_CARD + ANCHO_PR + ANCHO_LANZO + ANCHO_HACE + ANCHO_DURO))
  off_turnos=$((off_estado + ANCHO_ESTADO + ANCHO_MODELO))
  off_detalle=$((off_turnos + ANCHO_TURNOS))
  fila="$(rellenar "$skill" "$ANCHO_SKILL")$(rellenar "$clave" "$ANCHO_CARD")$(rellenar "$pr" "$ANCHO_PR")$(rellenar "$origen" "$ANCHO_LANZO")"
  fila+="$(rellenar "$edad" "$ANCHO_HACE")$(rellenar "$duracion" "$ANCHO_DURO")$(rellenar "$glifo $estado" "$ANCHO_ESTADO")"
  fila+="$(rellenar "$modelo" "$ANCHO_MODELO")$(rellenar "$turnos" "$ANCHO_TURNOS")$detalle"
  [ "${#fila}" -le "$ancho" ] || fila=$(recortar "$fila" "$ancho")
  if [ "$color_habilitado" = 1 ]; then
    [ "$glifo_lento_len" -eq 0 ] || fila=$(pintar_rango "$fila" "$off_detalle" "$glifo_lento_len" ambar)
    # TURNOS excedido ("67/60!", DEVKIT-107).
    case "$turnos" in *'!') fila=$(pintar_rango "$fila" "$off_turnos" "$ANCHO_TURNOS" rojo) ;; esac
    [ -z "$color" ] || fila=$(pintar_rango "$fila" "$off_estado" "$icono_len" "$color")
    # SKILL en negrita para task-start (DEVKIT-134): distingue de un vistazo
    # la fila que abre una card de la que la continúa.
    [ "$skill" != task-start ] || fila=$(pintar_rango "$fila" 0 "$ANCHO_SKILL" negrita)
  fi
  printf '%s\n' "$fila"
}

# Última vez que algún lanzamiento terminó, de cualquier skill (DEVKIT-133,
# ancla de la fila "(en espera)"): la línea de cierre -éxito o error- más
# reciente de watch.log, tanto de un lanzamiento directo de `run_skill`
# (`$id terminado: `/`ALARMA: $id terminó con error (rc=N)`) como de uno
# lanzado por `--worker` (`devkit-run "..." terminado [$id]:`/`devkit-run
# "..." falló (rc=N) [$id]:`). "no lanzó"/"no arrancó" no cuentan: ninguno de
# los dos deja trabajo real terminado, así que no deberían reiniciar el
# tiempo ocioso. Vacío si watch.log no existe o no tiene ninguna.
ultima_actividad_ts() {  # ultima_actividad_ts <watch.log>
  local wlog=$1 linea
  [ -f "$wlog" ] || return 1
  linea=$(grep -E ' (terminado: |terminó con error \(rc=[0-9]+\)|terminado \[[^]]+\]:|falló \(rc=[0-9]+\) \[[^]]+\]:)' \
    "$wlog" | tail -1)
  [ -n "$linea" ] || return 1
  date -d "$(awk '{print $1}' <<<"$linea")" +%s 2>/dev/null
}

# Arranque del bucle (DEVKIT-133): respaldo de `ultima_actividad_ts` cuando
# watch.log todavía no tiene ningún cierre -un contenedor recién levantado-,
# sobre la línea que `watch.sh` deja al arrancar ("vigilancia iniciada").
arranque_bucle_ts() {  # arranque_bucle_ts <watch.log>
  local wlog=$1 linea
  [ -f "$wlog" ] || return 1
  linea=$(grep -E ' vigilancia iniciada ' "$wlog" | tail -1)
  [ -n "$linea" ] || return 1
  date -d "$(awk '{print $1}' <<<"$linea")" +%s 2>/dev/null
}

# Fila sintética "(en espera)" (DEVKIT-133): cuando ninguna fila de
# `estado_filas` está en curso, mide desde que terminó el último lanzamiento
# del proyecto -o desde que arrancó el bucle si todavía no hay ninguno- y
# explica qué espera. Devuelve vacío (rc=1) si no hay ningún punto de partida
# -watch.log inexistente o sin ninguna línea reconocible, el caso que ya
# cubre "sin lanzamientos registrados"- para no inventar una duración desde
# `ahora`. Mismo formato de columnas que `estado_filas`, así fluye por el
# mismo `formatear_fila` que el resto de la tabla.
# <bucle_texto> (DEVKIT-133 H2) es la salida de `senal_bucle`: con el bucle
# MUERTO o SIN SEÑAL nadie va a tomar la cola, así que DETALLE dice "bucle
# parado" en vez de "cola vacía"/"esperando aprobación de ...", que daría a
# entender que el sistema sigue esperando trabajo.
fila_en_espera() {  # fila_en_espera <watch.log> <ahora epoch> [bucle_texto]
  local wlog=$1 ahora=$2 bucle_texto=${3:-} t0 edad detalle clave_merge
  t0=$(ultima_actividad_ts "$wlog") || t0=$(arranque_bucle_ts "$wlog") || return 1
  [ -n "$t0" ] || return 1
  edad=$((ahora - t0))
  if grep -qE 'MUERTO|SIN SEÑAL' <<<"$bucle_texto"; then
    detalle="bucle parado"
  else
    clave_merge=$(esperando_aprobacion)
    if [ -n "$clave_merge" ]; then
      detalle="esperando aprobación de $clave_merge"
    else
      detalle="cola vacía"
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "(en espera)" - bucle "$(hace "$edad")" "en espera" "$detalle" - "$(hace "$edad")" - -
}

# Imprime filas ya formateadas, recortadas al alto de la terminal (DEVKIT-97)
# con las más recientes -las últimas del arreglo, porque `estado_filas` las
# entrega en el orden del log, más viejas primero- y un resumen de cuántas
# quedaron afuera. Sin esto, muchos lanzamientos desbordan `--seguir` y el
# redibujo en el sitio (`\033[H` en `cuadro_sin_parpadeo`) apila cuadros en
# vez de refrescar uno solo. `devkit-run --estado --todo` (`DEVKIT_ESTADO_TODO`)
# lo desactiva para verlas todas.
imprimir_tabla() {  # imprimir_tabla <fila formateada>...
  local total=$# max inicio
  if [ -n "${DEVKIT_ESTADO_TODO:-}" ] || [ "$total" -eq 0 ]; then
    [ "$total" -eq 0 ] || printf '%s\n' "$@"
    return 0
  fi
  max=$(( $(alto_terminal) - RESERVA_LINEAS_TABLA ))
  [ "$max" -ge 1 ] 2>/dev/null || max=1
  if [ "$total" -le "$max" ]; then
    printf '%s\n' "$@"
    return 0
  fi
  inicio=$(( total - max + 1 ))
  printf '%s\n' "${@:inicio}"
  printf '… %s filas más antiguas (devkit-run --estado --todo para verlas)\n' "$((total - max))"
}

mostrar_estado() {  # mostrar_estado [permitir_refresco_cuota=1] [idx=0] [fijo=1] [color=] [filas=] [bucle_texto=]
  local permitir_refresco_cuota=${1:-1} idx=${2:-0} fijo=${3:-1} color_habilitado=${4:-}
  local filas skill clave origen edad estado detalle modelo duracion turnos pr
  # <filas> (DEVKIT-106 H5): quien ya llamó a `estado_filas` esta misma vuelta
  # -para el punto de la cabecera, en `seguir_estado`/`seguir_lanzamiento`/
  # `--estado` sin `--seguir`- se las pasa acá para no leer watch.log/ps dos
  # veces por refresco y arriesgar que el punto y la tabla salgan de fotos
  # distintas. `$#` -ge 5, no el valor: una llamada sin filas activas de
  # verdad pasa una cadena vacía a propósito.
  local ahora_estado=${DEVKIT_AHORA:-$(date +%s)}
  if [ $# -ge 5 ]; then
    filas=$5
  else
    filas=$(estado_filas "$WATCH_LOG" "$ahora_estado")
  fi
  # <bucle_texto> (DEVKIT-133 H2), sexto argumento: mismo <bucle> que ya
  # calculó quien llama para la cabecera (`senal_bucle`), pasado tal cual a
  # `fila_en_espera` para que DETALLE no diga "cola vacía" con el bucle
  # parado.
  local bucle_texto=${6:-}
  # Fila "(en espera)" (DEVKIT-133): sin ninguna en curso, se agrega al final
  # para medir el tiempo ocioso, con lo que el sistema espera en DETALLE.
  # `fila_en_espera` sale vacía (rc=1) sin ningún cierre ni arranque de bucle
  # que anclarla -watch.log inexistente o recién creado-, y la tabla queda
  # igual que antes de esta card.
  if ! printf '%s\n' "$filas" | awk -F'\t' '$5=="en curso"{f=1} END{exit !f}'; then
    local fila_espera
    if fila_espera=$(fila_en_espera "$WATCH_LOG" "$ahora_estado" "$bucle_texto"); then
      if [ -n "$filas" ]; then filas="$filas"$'\n'"$fila_espera"; else filas=$fila_espera; fi
    fi
  fi
  if [ -z "$filas" ]; then
    echo "sin lanzamientos registrados en $WATCH_LOG"
  else
    # Épica de origen por Clave (DEVKIT-80): una consulta a la caché por
    # Clave distinta, no por fila. Agrupa la tabla solo si hay más de una
    # Épica `En progreso` entre las filas; con una sola, o ninguna, la tabla
    # queda plana como antes de esta card.
    local -A epica_de_clave
    local -a orden_epicas=()
    local clave_vista=""
    while IFS=$'\t' read -r skill clave origen edad estado detalle modelo duracion turnos pr; do
      [ "$clave" = - ] && continue
      case " $clave_vista " in *" $clave "*) continue ;; esac
      clave_vista="$clave_vista $clave"
      epica_de_clave[$clave]=$(epica_de "$clave")
      if [ -n "${epica_de_clave[$clave]}" ]; then
        local encontrada=0 e
        for e in "${orden_epicas[@]}"; do [ "$e" = "${epica_de_clave[$clave]}" ] && { encontrada=1; break; }; done
        [ "$encontrada" = 1 ] || orden_epicas+=("${epica_de_clave[$clave]}")
      fi
    done <<<"$filas"

    # DEVKIT-97 H5: la tabla agrupada por Épica (dos o más Épicas `En
    # progreso` entre las filas) no pasa por `imprimir_tabla` y no se recorta
    # al alto de la terminal -a diferencia de la tabla plana, más abajo.
    # Excepción a propósito, no un olvido: `ESTADO_FILAS` (20 por defecto) ya
    # acota cuántos lanzamientos del log llegan hasta acá, agrupar por Épica
    # es el caso menos frecuente (una sola card `En progreso` por Épica a la
    # vez, AGENTS.md), y recortar por grupo sin perder la cabecera de cada
    # Épica es harina de otro costal. Si esto empieza a desbordar `--seguir`
    # en la práctica, se resuelve aparte.
    if [ "${#orden_epicas[@]}" -ge 2 ]; then
      local primero=1
      for e in "${orden_epicas[@]}"; do
        [ "$primero" = 1 ] || echo
        primero=0
        printf '%s\n' "$e"
        encabezado_tabla
        while IFS=$'\t' read -r skill clave origen edad estado detalle modelo duracion turnos pr; do
          [ "${epica_de_clave[$clave]:-}" = "$e" ] && formatear_fila "$skill" "$clave" "$pr" "$origen" "$edad" "$duracion" "$estado" "$modelo" "$turnos" "$detalle" "$idx" "$fijo" "$color_habilitado"
        done <<<"$filas"
      done
      # Filas sin Épica activa (sin Padre En progreso, o sin Clave): quedan
      # en un bloque aparte al final, no se pierden.
      local hay_sin=0
      while IFS=$'\t' read -r skill clave origen edad estado detalle modelo duracion turnos pr; do
        [ "$clave" != - ] && [ -n "${epica_de_clave[$clave]:-}" ] && continue
        if [ "$hay_sin" = 0 ]; then
          echo
          echo "(sin Épica)"
          encabezado_tabla
          hay_sin=1
        fi
        formatear_fila "$skill" "$clave" "$pr" "$origen" "$edad" "$duracion" "$estado" "$modelo" "$turnos" "$detalle" "$idx" "$fijo" "$color_habilitado"
      done <<<"$filas"
    else
      encabezado_tabla
      local -a filas_fmt=()
      while IFS=$'\t' read -r skill clave origen edad estado detalle modelo duracion turnos pr; do
        filas_fmt+=("$(formatear_fila "$skill" "$clave" "$pr" "$origen" "$edad" "$duracion" "$estado" "$modelo" "$turnos" "$detalle" "$idx" "$fijo" "$color_habilitado")")
      done <<<"$filas"
      imprimir_tabla "${filas_fmt[@]}"
    fi
  fi
  mostrar_consumo "$permitir_refresco_cuota"
  mkdir -p "$(dirname "$ALARMAS_VISTAS")" 2>/dev/null
  wc -l <"$WATCH_LOG" 2>/dev/null >"$ALARMAS_VISTAS.tmp" && mv -f "$ALARMAS_VISTAS.tmp" "$ALARMAS_VISTAS" \
    || echo 0 >"$ALARMAS_VISTAS"
}

# Señal de vida del bucle para la cabecera de `--estado --seguir` (DEVKIT-81,
# reordenada por DEVKIT-97 con un caso nuevo). El indicador antiguo medía un
# solo tick con un umbral fijo (el doble de INTERVALO_BUCLE) sin importar qué
# corría en ese momento: `watch.sh` lanza pr-review/task-fix de forma
# síncrona -`run_skill` espera a que termine antes de seguir con el próximo
# PR- así que el tick "consultando GitHub" no puede llegar mientras esa skill
# sigue corriendo, y una corrección larga (13 min con DEVKIT-87) disparaba
# `SIN SEÑAL` con el bucle vivo. Orden de las cuatro ramas, cada una excluye
# a las de abajo:
#   1. `watch.sh` no está en `ps`: `MUERTO`, no hay bucle que espere nada.
#   2. Una fila `en curso` de origen `bucle`, salvo `task-start` (DEVKIT-97
#      H2), explica la falta de tick: el bucle está esperando a esa skill, no
#      muerto. Sin alarma -si esa fila ya superó SKILL_TIMEOUT, la marca
#      "lento" vive en su propia fila de la tabla (`estado_filas`); esta línea
#      no la duplica ni la reemplaza. `task-start` con origen `bucle` viene de
#      `lanzar_cola` -> `cola.sh` -> `devkit-run.sh task-start`, que lanza
#      un worker con `nohup setsid` y vuelve enseguida (ver la cabecera de
#      este archivo): no bloquea a `watch.sh` como sí lo hace `run_skill` con
#      pr-review/task-fix/task-close/task-document (`--sync`, con `wait`).
#      Contarlo aquí taparía un SIN SEÑAL real de `watch.sh` mientras ese
#      worker, ajeno al tick, sigue corriendo.
#   3. Sin skill que lo explique, el último tick (o su ausencia total) más
#      viejo que el doble de INTERVALO_BUCLE: `SIN SEÑAL` de verdad.
#   4. Cualquier otro caso: vivo, con la edad del último tick.
# Por `ps` de PS_BIN y `estado_filas` sobre el mismo `wlog`, como el resto de
# este archivo, para poder fijarlo en la autoprueba.
# <color> no vacío pinta la rama `SIN SEÑAL`/`MUERTO` en rojo (DEVKIT-81 H4,
# mismo patrón que ROJO/RESET en prompt-status.sh). senal_bucle no puede
# decidirlo por su cuenta con `[ -t 1 ]`: seguir_estado la llama siempre
# dentro de `$(...)`, donde el descriptor 1 nunca es una terminal aunque la
# de verdad sí lo sea. El caso 2 nunca lleva color: no es una alarma del
# bucle.
senal_bucle() {  # senal_bucle <watch.log> <ahora epoch> [color]
  local wlog=$1 ahora=$2 color=${3:-} procesos tick t0 edad rojo='' reset=''
  local skill clave origen edad_fila estado detalle modelo n
  if [ -n "$color" ]; then rojo=$'\033[31m'; reset=$'\033[0m'; fi
  procesos=$("$PS_BIN" -eo args= -ww 2>/dev/null)
  if ! grep -qF 'watch.sh' <<<"$procesos"; then
    printf '%sbucle: MUERTO, no encuentro watch.sh en ps%s\n' "$rojo" "$reset"
    return 0
  fi
  while IFS=$'\t' read -r skill clave origen edad_fila estado detalle modelo; do
    if [ "$origen" = bucle ] && [ "$estado" = "en curso" ] && [ "$skill" != task-start ]; then
      if [ "$clave" = - ]; then
        printf 'bucle: esperando %s hace %s\n' "$skill" "$edad_fila"
      else
        n=${clave##*-}
        printf 'bucle: esperando %s-%s hace %s\n' "$skill" "$n" "$edad_fila"
      fi
      return 0
    fi
  done < <(estado_filas "$wlog" "$ahora")
  tick=$(grep -E '^[^ ]+ consultando GitHub$' "$wlog" 2>/dev/null | tail -1 | awk '{print $1}')
  if [ -z "$tick" ]; then
    printf '%sbucle: SIN SEÑAL, watch.sh vive pero sin ningún tick "consultando GitHub" todavía%s\n' "$rojo" "$reset"
    return 0
  fi
  t0=$(date -d "$tick" +%s 2>/dev/null || echo "$ahora")
  edad=$((ahora - t0))
  if [ "$edad" -gt "$((2 * INTERVALO_BUCLE))" ]; then
    printf '%sbucle: SIN SEÑAL hace %s%s\n' "$rojo" "$(hace "$edad")" "$reset"
  else
    printf 'bucle: vivo, último tick hace %s\n' "$(hace "$edad")"
  fi
}

# `--seguir` sin parpadeo (DEVKIT-81): arma el cuadro completo en memoria y
# recién entonces lo imprime, con el cursor de vuelta al origen (`\033[H`) y
# `\033[J` (borra desde el cursor hasta el final) solo al terminar, para
# limpiar el resto de un cuadro anterior más largo sin borrar y volver a
# dibujar todo -que es lo que parpadea. Cada renglón lleva `\033[K` al final
# (DEVKIT-81 H3): sin eso, si ese mismo renglón viene más corto que en el
# cuadro anterior, queda el resto del texto viejo pegado a la derecha; `\033[J`
# solo limpia lo que queda debajo del último renglón, no a la derecha de uno
# más corto. El cursor se oculta con `tput civis` mientras refresca y se
# restaura con `tput cnorm` al salir, Ctrl-C incluido.
cuadro_sin_parpadeo() {  # cuadro_sin_parpadeo <cuadro>
  printf '\033[H%s\033[K\n\033[J' "${1//$'\n'/$'\033[K\n'}"
}

# Si un bucle sin nadie mirando puede seguir refrescando la cuota (H3,
# pr-review DEVKIT-78): pasado CUOTA_DESATENDIDO desde que arrancó <desde>, ya
# no. Compartida por seguir_estado y seguir_lanzamiento -- antes solo la
# aplicaba el primero, y el segundo (`--seguir <skill> <Clave>`) podía correr
# igual de desatendido durante un task-fix o pr-review largo.
calcular_permitir_refresco_cuota() {  # calcular_permitir_refresco_cuota <desde> <ahora>
  [ "$(( $2 - $1 ))" -lt "$CUOTA_DESATENDIDO" ] && printf 1 || printf 0
}

seguir_estado() {
  local i=0 frame ahora color_tty='' desde utf filas bucle punto
  desde=${DEVKIT_AHORA:-$(date +%s)}
  utf8_disponible && utf=1 || utf=0
  if [ -t 1 ]; then
    tput civis 2>/dev/null
    trap 'tput cnorm 2>/dev/null' EXIT
    trap 'tput cnorm 2>/dev/null; exit 130' INT TERM
    color_tty=1
  fi
  while true; do
    ahora=${DEVKIT_AHORA:-$(date +%s)}
    # `COLUMNS`/`LINES` de verdad, tomados acá afuera (DEVKIT-97): adentro del
    # `$(...)` de más abajo `tput` ya no ve la tty real -mismo problema que
    # `color` en `senal_bucle`-, y se toman de nuevo en cada vuelta por si el
    # humano cambió el tamaño de la ventana mientras `--seguir` corría.
    if [ -t 1 ]; then export COLUMNS=$(tput cols 2>/dev/null) LINES=$(tput lines 2>/dev/null); fi
    # El punto de la cabecera (DEVKIT-106) lee las mismas <filas> y el mismo
    # <bucle> que ya arma esta vuelta para `mostrar_estado`/`senal_bucle`, y
    # se las pasa a `mostrar_estado` como quinto argumento (DEVKIT-106 H5):
    # sin esto, `mostrar_estado` volvía a leer watch.log/ps por su cuenta y el
    # punto y la tabla podían salir de fotos distintas.
    filas=$(estado_filas "$WATCH_LOG" "$ahora")
    bucle=$(senal_bucle "$WATCH_LOG" "$ahora" "$color_tty")
    punto=$(punto_estado "$filas" "$bucle" "$i" 0 "$utf" "$color_tty")
    # `frame=$(...)` recorta *todos* los saltos de línea finales de lo que
    # captura, no uno solo (DEVKIT-97/DEVKIT-85): con "...\n\n" al final del
    # `printf`, la sustitución se comía las dos líneas en blanco antes de que
    # `frame+=` pegara la tabla, y la fila de títulos quedaba pegada a la
    # cabecera. El separador se agrega aparte, después de la sustitución.
    frame=$(printf 'devkit-run --estado  %s %s  (cada %ss; Ctrl-C para salir)\n%s' \
      "$(date +%T)" "$punto" "$ESTADO_INTERVALO" "$bucle")
    frame+=$'\n\n'
    frame+=$(mostrar_estado "$(calcular_permitir_refresco_cuota "$desde" "$ahora")" "$i" 0 "$color_tty" "$filas" "$bucle")
    i=$((i + 1))
    if [ -t 1 ]; then
      cuadro_sin_parpadeo "$frame"
    else
      printf '%s\n' "$frame"
    fi
    sleep "$ESTADO_INTERVALO"
  done
}

# `--seguir <skill> <Clave>` (DEVKIT-82): en vez de devolver el prompt tras
# lanzar, se queda mostrando `--estado` -mismo redibujo sin parpadeo que
# `seguir_estado`- hasta que ESTE lanzamiento (identificado por <id>, el
# nombre del log sin ".log") deje su línea de cierre en watch.log, y esa
# línea es la última que imprime. El trap de Ctrl-C corre siempre, no solo
# con terminal: un doble sin tty en la autoprueba también necesita el aviso.
# No mata al worker -nada en este trap lo toca-: ya nació en su propia sesión
# con `setsid`, así que una señal real de la terminal no lo alcanza.
# <pid> (H3, DEVKIT-82) es el PID del worker que lanzó `$!`: si `kill -0`
# falla (murió por SIGKILL, OOM u otra causa que no deja resumen) y sigue
# fallando pasado `MARGEN_LANZAMIENTO_MUERTO`, el monitor no espera para
# siempre -antes se quedaba corriendo hasta que algo externo lo cortara-, lo
# dice y sale con un código distinto de cero.
# Pasado CUOTA_DESATENDIDO desde que arrancó (H3, pr-review DEVKIT-78), deja
# de refrescar la cuota sola -mismo tope que seguir_estado, vía
# calcular_permitir_refresco_cuota-: un task-fix o pr-review largo también
# corre desatendido.
seguir_lanzamiento() {  # seguir_lanzamiento <id> <pid del worker>
  local id=$1 pid=$2 i=0 frame ahora color_tty='' resumen_final muerto_desde=0 desde utf filas bucle punto
  desde=${DEVKIT_AHORA:-$(date +%s)}
  utf8_disponible && utf=1 || utf=0
  if [ -t 1 ]; then tput civis 2>/dev/null; color_tty=1; fi
  trap '
    [ -t 1 ] && tput cnorm 2>/dev/null
    printf "devkit-run: Ctrl-C cierra el monitor; el lanzamiento \"%s\" sigue en curso (síguelo con devkit-run --estado)\n" "$id"
    exit 130
  ' INT TERM
  while true; do
    ahora=${DEVKIT_AHORA:-$(date +%s)}
    # COLUMNS/LINES de verdad, tomados acá afuera: mismo motivo que en
    # seguir_estado (DEVKIT-97).
    if [ -t 1 ]; then export COLUMNS=$(tput cols 2>/dev/null) LINES=$(tput lines 2>/dev/null); fi
    # Punto de cabecera (DEVKIT-106): mismas <filas>/<bucle> de esta vuelta,
    # ver el comentario de seguir_estado.
    filas=$(estado_filas "$WATCH_LOG" "$ahora")
    bucle=$(senal_bucle "$WATCH_LOG" "$ahora" "$color_tty")
    punto=$(punto_estado "$filas" "$bucle" "$i" 0 "$utf" "$color_tty")
    # Mismo recorte de "$(...)" que en seguir_estado (DEVKIT-97/DEVKIT-85):
    # el separador va aparte de la sustitución que trae senal_bucle.
    frame=$(printf 'devkit-run --seguir %s  %s %s  (cada %ss; Ctrl-C solo cierra el monitor)\n%s' \
      "$id" "$(date +%T)" "$punto" "$ESTADO_INTERVALO" "$bucle")
    frame+=$'\n\n'
    frame+=$(mostrar_estado "$(calcular_permitir_refresco_cuota "$desde" "$ahora")" "$i" 0 "$color_tty" "$filas" "$bucle")
    i=$((i + 1))
    if [ -t 1 ]; then
      cuadro_sin_parpadeo "$frame"
    else
      printf '%s\n' "$frame"
    fi
    resumen_final=$(grep -E "devkit-run \".*\" (terminado|falló \(rc=[0-9]+\)) \[$id\]:" "$WATCH_LOG" 2>/dev/null | tail -1)
    if [ -n "$resumen_final" ]; then
      [ -t 1 ] && tput cnorm 2>/dev/null
      printf '%s\n' "$resumen_final"
      return 0
    fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      if [ "$muerto_desde" -eq 0 ]; then
        muerto_desde=$ahora
      elif [ "$((ahora - muerto_desde))" -ge "$MARGEN_LANZAMIENTO_MUERTO" ]; then
        [ -t 1 ] && tput cnorm 2>/dev/null
        printf 'devkit-run: el lanzamiento "%s" murió sin dejar resumen en %s\n' "$id" "$WATCH_LOG"
        return 71
      fi
    else
      muerto_desde=0
    fi
    sleep "$ESTADO_INTERVALO"
  done
}

# Tabla de `--tablero` (DEVKIT-82): Clave, Estado, Tipo y PR.
encabezado_tablero() {
  printf '%s%s%s%s%s\n' "$(rellenar CLAVE 12)" "$(rellenar ESTADO 22)" "$(rellenar TIPO 10)" \
    "$(rellenar PR 40)" 'BLOQUEA A'
}

# <idx>/<fijo>/<color> (DEVKIT-106): mismos iconos y mismo punto de cabecera
# que `--estado`, ver `glifo_estado_tablero`. La columna ESTADO tampoco crece:
# "Revisión automática" mide 19 y el icono+espacio ocupan 2 de los 3 que le
# sobran a la columna de 22.
formatear_fila_tablero() {  # formatear_fila_tablero <clave> <estado> <tipo> <pr> [idx=0] [fijo=1] [color=]
  local clave=$1 estado=$2 tipo=$3 pr=$4 idx=${5:-0} fijo=${6:-1} color_habilitado=${7:-} \
        frena utf glifo color estado_col icono_len
  frena=$(bloquea_a "$clave")
  utf8_disponible && utf=1 || utf=0
  glifo=$(glifo_estado_tablero "$estado" "$idx" "$fijo" "$utf")
  color=$(color_de_estado_tablero "$estado")
  estado_col=$(rellenar "$glifo $estado" 22)
  if [ -n "$color" ] && [ "$color_habilitado" = 1 ]; then
    icono_len=${#glifo}
    estado_col="$(colorear "$color" "${estado_col:0:icono_len}" 1)${estado_col:icono_len}"
  fi
  printf '%s%s%s%s%s\n' "$(rellenar "$clave" 12)" "$estado_col" "$(rellenar "$tipo" 10)" \
    "$(rellenar "$pr" 40)" "${frena#bloquea a: }"
}

# Cards activas del proyecto (DEVKIT-82): una consulta a Notion (`notion.sh
# activas`), agrupadas por Épica de origen cuando hay más de una Épica `En
# progreso` -mismo patrón que `mostrar_estado` (DEVKIT-80)-, y "bloquea a" con
# la misma caché que `--estado` (`bloquea_a`, DEVKIT-63). A diferencia de
# `--estado`, que solo dispara el refresco de esas cachés en segundo plano
# porque de todos modos hay algo que mostrar mientras llegan (los procesos, el
# log), `--tablero` las asegura en primer plano (`asegurar_bloqueos_cache`,
# `asegurar_epicas_cache`) antes de agrupar: con la caché fría, la primera
# vuelta paga hasta tres consultas -activas, bloqueos y epicas-, no una sola
# (H1 de pr-review en DEVKIT-82: antes salía plano y sin "bloquea a" la
# primera vez, porque esas dos cachés recién arrancaban a llenarse detrás).
mostrar_tablero() {  # mostrar_tablero [idx=0] [fijo=1] [color=]
  local idx=${1:-0} fijo=${2:-1} color_habilitado=${3:-}
  local codigo filas
  codigo=$(project_code)
  if [ -z "$codigo" ]; then
    echo "devkit-run --tablero: no encuentro \"project\" en $WS/.devkit/devkit.toml"
    return 1
  fi
  if ! filas=$("$NOTION_BIN" activas "$codigo" 2>&1); then
    printf 'devkit-run --tablero: no se pudo leer Notion: %s\n' "$filas" >&2
    return 1
  fi
  if [ "$(jq 'length' <<<"$filas" 2>/dev/null)" = 0 ]; then
    echo "sin cards activas en el proyecto $codigo"
    return 0
  fi
  asegurar_bloqueos_cache
  asegurar_epicas_cache
  local clave estado tipo pr
  local -A epica_de_clave
  local -a orden_epicas=()
  while IFS= read -r clave; do
    [ -n "$clave" ] || continue
    epica_de_clave[$clave]=$(epica_de "$clave")
    if [ -n "${epica_de_clave[$clave]}" ]; then
      local encontrada=0 e
      for e in "${orden_epicas[@]}"; do [ "$e" = "${epica_de_clave[$clave]}" ] && { encontrada=1; break; }; done
      [ "$encontrada" = 1 ] || orden_epicas+=("${epica_de_clave[$clave]}")
    fi
  done < <(jq -r '.[].clave' <<<"$filas")

  if [ "${#orden_epicas[@]}" -ge 2 ]; then
    local primero=1
    for e in "${orden_epicas[@]}"; do
      [ "$primero" = 1 ] || echo
      primero=0
      printf '%s\n' "$e"
      encabezado_tablero
      while IFS=$'\t' read -r clave estado tipo pr; do
        [ "${epica_de_clave[$clave]:-}" = "$e" ] && formatear_fila_tablero "$clave" "$estado" "$tipo" "$pr" "$idx" "$fijo" "$color_habilitado"
      done < <(jq -r '.[] | [.clave, .estado, (.tipo // "" | if . == "" then "-" else . end), (.pr // "" | if . == "" then "-" else . end)] | @tsv' <<<"$filas")
    done
    local hay_sin=0
    while IFS=$'\t' read -r clave estado tipo pr; do
      [ -n "${epica_de_clave[$clave]:-}" ] && continue
      if [ "$hay_sin" = 0 ]; then
        echo
        echo "(sin Épica)"
        encabezado_tablero
        hay_sin=1
      fi
      formatear_fila_tablero "$clave" "$estado" "$tipo" "$pr" "$idx" "$fijo" "$color_habilitado"
    done < <(jq -r '.[] | [.clave, .estado, (.tipo // "" | if . == "" then "-" else . end), (.pr // "" | if . == "" then "-" else . end)] | @tsv' <<<"$filas")
  else
    encabezado_tablero
    while IFS=$'\t' read -r clave estado tipo pr; do
      formatear_fila_tablero "$clave" "$estado" "$tipo" "$pr" "$idx" "$fijo" "$color_habilitado"
    done < <(jq -r '.[] | [.clave, .estado, (.tipo // "" | if . == "" then "-" else . end), (.pr // "" | if . == "" then "-" else . end)] | @tsv' <<<"$filas")
  fi
}

# `--tablero --seguir` (DEVKIT-82): mismo redibujo sin parpadeo y cursor
# oculto que `seguir_estado`, pero cada `TABLERO_INTERVALO` (30 s, no 3: cada
# vuelta paga una consulta real a Notion, sin la caché de 30 s que sí
# protege a `--estado`).
seguir_tablero() {
  local i=0 frame ahora color_tty='' utf filas bucle punto
  utf8_disponible && utf=1 || utf=0
  if [ -t 1 ]; then
    tput civis 2>/dev/null
    trap 'tput cnorm 2>/dev/null' EXIT
    trap 'tput cnorm 2>/dev/null; exit 130' INT TERM
    color_tty=1
  fi
  while true; do
    ahora=${DEVKIT_AHORA:-$(date +%s)}
    # Punto de cabecera (DEVKIT-106): el mismo que `--estado`, calculado
    # sobre `estado_filas`/`senal_bucle` de WATCH_LOG -es la misma realidad
    # (¿hay algo lanzado ahora mismo? ¿el bucle vive?), sin importar cuál
    # tabla la esté mostrando.
    filas=$(estado_filas "$WATCH_LOG" "$ahora")
    bucle=$(senal_bucle "$WATCH_LOG" "$ahora" "$color_tty")
    punto=$(punto_estado "$filas" "$bucle" "$i" 0 "$utf" "$color_tty")
    # Mismo recorte de "$(...)" que en seguir_estado (DEVKIT-97/DEVKIT-85):
    # el separador va aparte de la sustitución que trae senal_bucle.
    frame=$(printf 'devkit-run --tablero  %s %s  (cada %ss; Ctrl-C para salir)\n%s' \
      "$(date +%T)" "$punto" "$TABLERO_INTERVALO" "$bucle")
    frame+=$'\n\n'
    frame+=$(mostrar_tablero "$i" 0 "$color_tty")
    i=$((i + 1))
    if [ -t 1 ]; then
      cuadro_sin_parpadeo "$frame"
    else
      printf '%s\n' "$frame"
    fi
    sleep "$TABLERO_INTERVALO"
  done
}

# --- devkit-run --costos [<Clave>] (DEVKIT-89) ------------------------------
# Mide el costo por card desde costos.log, que sobrevive a `devkit recreate`.
# Solo suma cifras que ya están en el log (costo=, turnos=, duracion=);
# prohibido estimar (misma regla que DEVKIT-62). `--costos <Clave>` marca con
# "!" pegado al número de turnos las filas que superaron el presupuesto
# vigente en roles.toml para ese skill (DEVKIT-94); el resumen de proyecto
# (sin Clave) agrega turnos de varios skills por card y no tiene un único
# presupuesto contra el que comparar, así que no lleva marca.

# Precarga `CLAVE_DE_PR_CACHE` con una sola llamada a `gh pr list`, en vez de
# una `gh pr view` por cada PR distinto del log (H3 de pr-review en
# DEVKIT-89, segunda vuelta): `costos_filas` resuelve la Clave de *todas* las
# líneas de pr-review/task-close antes de filtrar por la Clave pedida, así
# que sin esto un solo `--costos-totales <Clave>` paga un `gh pr view` por
# cada PR distinto que haya pasado por el proyecto. `--limit` acota el costo
# de esta llamada; un PR más viejo que el límite no queda en la caché y cae
# al `gh pr view` individual de `clave_de_pr`, que sigue siendo correcto,
# solo más lento para ese caso puntual.
poblar_cache_pr() {  # poblar_cache_pr <archivo de caché>
  local cache=$1
  "$GH_BIN" pr list --state all --limit 500 --json number,title 2>/dev/null \
    | jq -r '.[] | .title as $t | (if ($t | test("^[A-Z][A-Z0-9]+-[0-9]+")) then ($t | capture("(?<c>^[A-Z][A-Z0-9]+-[0-9]+)").c) else "-" end) as $c | [(.number|tostring), $c] | @tsv' \
    2>/dev/null >>"$cache"
}

# Clave de un PR, por su título (mismo patrón que `key_of` en watch.sh). "-"
# si `gh` no responde o el título no trae Clave: nunca se inventa.
# `CLAVE_DE_PR_CACHE`, si está seteada, apunta a un archivo "num<TAB>clave"
# que evita repetir `gh pr view` por cada línea de pr-review/task-close que
# comparte PR (H3 de pr-review en DEVKIT-89): `costos_filas` y
# `costos_resumen_proyecto` llaman a esta función una vez por card y por
# fila dentro de un `< <(...)`, así que un array en memoria no sobrevive
# entre esas invocaciones; un archivo sí, sin importar el subshell. La
# arman `mostrar_costos` y `--costos-totales`, dueños de la corrida
# completa, con `poblar_cache_pr` antes de la primera lectura.
clave_de_pr() {  # clave_de_pr <número de PR>
  local num=$1 titulo clave hit
  if [ -n "${CLAVE_DE_PR_CACHE:-}" ] && [ -f "$CLAVE_DE_PR_CACHE" ]; then
    hit=$(grep -m1 -E "^$num	" "$CLAVE_DE_PR_CACHE" 2>/dev/null | cut -f2)
    if [ -n "$hit" ]; then
      [ "$hit" = - ] && return 0
      printf '%s' "$hit"
      return 0
    fi
  fi
  titulo=$("$GH_BIN" pr view "$num" --json title --jq .title 2>/dev/null)
  clave=$(printf '%s' "$titulo" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  if [ -n "${CLAVE_DE_PR_CACHE:-}" ]; then
    printf '%s\t%s\n' "$num" "${clave:--}" >> "$CLAVE_DE_PR_CACHE" 2>/dev/null
  fi
  printf '%s' "$clave"
}

# Clave de un lanzamiento. task-start/task-fix/task-document/epic-plan la
# traen en el propio prompt; pr-review y el cierre de task-close solo traen
# el número de PR (mismo caso especial que `estado_filas` con pr-review), así
# que se resuelve con `clave_de_pr`. "-" si no hay ninguna.
clave_de_lanzamiento() {  # clave_de_lanzamiento <prompt> <id>
  local prompt=$1 id=$2 clave num
  clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  if [ -z "$clave" ]; then
    num=$(printf '%s' "$id" | grep -oE '^(pr-review|task-close)-[0-9]+' | grep -oE '[0-9]+$')
    [ -z "$num" ] || clave=$(clave_de_pr "$num")
  fi
  printf '%s' "${clave:--}"
}

# Línea de cierre ("terminado"/"falló") de un <id>, la primera tras su línea
# "lanzando" en <línea> (mismo emparejamiento que `estado_filas` en watch.sh,
# sin las ramas de "en curso"/"no arrancó": aquí solo interesa lo que ya
# cerró). Un cierre con error cuenta igual que uno exitoso (H2 de pr-review en
# DEVKIT-89), así que se empareja también "$id falló (rc=" (task-close-N,
# cola-N) y "ALARMA: $id terminó con error" (`run_skill` en watch.sh, que
# no deja línea "$id terminado:" cuando falla). "$id no lanzó: " también
# cierra (DEVKIT-107 H2): sin esto, un pr-review que no lanzó (por ejemplo
# "ya revisado en <sha>") y que luego se relanza con el mismo id -mismo head,
# tras un devkit-fix sin push- deja sin emparejar su propio cierre; la
# búsqueda salta hasta el "terminado" del relanzamiento y `costos_filas`
# cuenta ese costo dos veces, una por cada "lanzando". Los IDs no son únicos
# para siempre -se reinician en cada `devkit recreate`, igual que en
# watch.log-, así que se empareja con el cierre más cercano, no con uno
# global.
costos_cierre_de() {  # costos_cierre_de <archivo> <línea de "lanzando"> <id>
  local file=$1 desde=$2 id=$3
  tail -n +"$((desde + 1))" "$file" 2>/dev/null | grep -m1 -E \
    "^[^ ]+ ($id (terminado|falló \(rc=[0-9]+\)|no lanzó): |ALARMA: $id terminó con error \(rc=[0-9]+\): |devkit-run \".*\" (terminado|falló \(rc=[0-9]+\)) \[$id\]:)"
}

# Un campo "campo=N" de una línea de cierre, vacío si no está (bash no gasta
# modelo: task-close no deja costo= ni turnos=).
costos_campo() {  # costos_campo <línea> <campo>
  printf '%s' "$1" | grep -oE "$2=[0-9.]+" | head -1 | cut -d= -f2
}

# Una fila TSV por lanzamiento cerrado, filtrando por Clave si se da:
# fecha, clave, skill, id, modelo/esfuerzo/ronda, turnos, costo, duracion(s).
# Cubre las cinco skills con línea "lanzando" (task-start, pr-review,
# task-fix, task-document, epic-plan) más el cierre de task-close por el
# bucle (DEVKIT-55), que no tiene "lanzando" propia: se busca aparte, por su
# id `task-close-<num>`, sin duplicar los que ya salieron por la vía normal
# (un `devkit-run task-close` manual no pasa por aquí: DEVKIT-55 lo resuelve
# como `exec` directo a task-close.sh, sin línea "lanzando").
costos_filas() {  # costos_filas <archivo> [Clave]
  local file=$1 filtro=${2:-} ln ts id origen prompt logf modelo esfuerzo ronda
  local -A vistos=()
  local skill clave cierre c t d
  while IFS=$'\t' read -r ln ts id origen prompt logf modelo esfuerzo ronda; do
    [ -n "$id" ] || continue
    vistos[$id]=1
    clave=$(clave_de_lanzamiento "$prompt" "$id")
    [ -z "$filtro" ] || [ "$clave" = "$filtro" ] || continue
    skill=${prompt#/}; skill=${skill%% *}
    cierre=$(costos_cierre_de "$file" "$ln" "$id")
    # Un cierre "no lanzó" (DEVKIT-107 H2) no tiene costo ni turnos: no es un
    # lanzamiento real de claude -p, sino review-prep.sh/task-begin.sh
    # cortando antes. Se descarta en vez de imprimir una fila en blanco.
    case "$cierre" in *" no lanzó: "*) continue ;; esac
    c=$(costos_campo "${cierre:-}" costo); t=$(costos_campo "${cierre:-}" turnos); d=$(costos_campo "${cierre:-}" duracion)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$clave" "$skill" "$id" "$modelo" "$esfuerzo" "$ronda" "${t:--}" "${c:--}" "${d:--}"
  done < <(lanzamientos "$file")
  while IFS=: read -r ln resto; do
    [[ $resto =~ ^([^ ]+)\ task-close-([0-9]+)\ (terminado|falló) ]] || continue
    id="task-close-${BASH_REMATCH[2]}"
    [ -n "${vistos[$id]:-}" ] && continue
    ts=${BASH_REMATCH[1]}
    clave=$(clave_de_pr "${BASH_REMATCH[2]}")
    [ -z "$filtro" ] || [ "$clave" = "$filtro" ] || continue
    printf '%s\t%s\ttask-close\t%s\t-\t-\t-\t-\t-\t-\n' "$ts" "${clave:--}" "$id"
  done < <(grep -nE ' task-close-[0-9]+ (terminado|falló)' "$file" 2>/dev/null)
}

# Turnos, costo, minutos y revisiones (lanzamientos de pr-review) de una
# card, sumando solo lo presente en costos.log. La usan la fila TOTAL de
# `--costos <Clave>` y task-close.sh, para la línea "Costo: ..." del
# comentario de cierre (misma función, DEVKIT-89 criterio 4). Sin filas para
# la Clave, no imprime nada: un "0 turnos, 0 USD" sería una medición
# inventada, no una lectura de costos.log (H5 de pr-review en DEVKIT-89).
costos_totales_card() {  # costos_totales_card <Clave>
  local clave=$1 turnos_tot=0 costo_tot=0 dur_tot=0 revisiones=0 filas=0
  local ts c_clave skill id modelo esfuerzo ronda t c d
  while IFS=$'\t' read -r ts c_clave skill id modelo esfuerzo ronda t c d; do
    [ -n "$skill" ] || continue
    filas=1
    [ "$skill" != pr-review ] || revisiones=$((revisiones + 1))
    [ "$t" = - ] || turnos_tot=$((turnos_tot + t))
    [ "$c" = - ] || costo_tot=$(awk -v a="$costo_tot" -v b="$c" 'BEGIN{printf "%.4f", a+b}')
    [ "$d" = - ] || dur_tot=$((dur_tot + d))
  done < <(costos_filas "${COSTOS_LOG:-/dev/null}" "$clave")
  [ "$filas" = 1 ] || return 1
  printf '%s\t%s\t%s\t%s' "$turnos_tot" "$costo_tot" "$((dur_tot / 60))" "$revisiones"
}

# Tabla de una card: una fila por lanzamiento y una fila TOTAL.
costos_tabla_card() {
  local clave=$1 ts c_clave skill id modelo esfuerzo ronda t c d modelo_col min filas=0 presupuesto t_col
  # FECHA mide 27, no 21 (H7 de pr-review en DEVKIT-89): el timestamp con
  # zona (`2026-09-18T10:05:00-05:00`) mide 25, y `rellenar` no trunca.
  printf '%s%s%s%s%s%s\n' "$(rellenar SKILL 16)" "$(rellenar FECHA 27)" "$(rellenar MODELO/ESFUERZO/RONDA 28)" \
    "$(rellenar TURNOS 8)" "$(rellenar COSTO 10)" MIN
  while IFS=$'\t' read -r ts c_clave skill id modelo esfuerzo ronda t c d; do
    [ -n "$skill" ] || continue
    filas=1
    if [ "$modelo" = - ] || [ -z "$modelo" ]; then modelo_col=-
    elif [ "$ronda" = - ] || [ -z "$ronda" ]; then modelo_col="$modelo/$esfuerzo"
    else modelo_col="$modelo/$esfuerzo r$ronda"; fi
    min=-
    [ "$d" = - ] || min=$((d / 60))
    t_col=$t
    if [ "$t" != - ] && [ -n "$t" ]; then
      presupuesto=$(presupuesto_de_skill "$skill")
      if [ -n "$presupuesto" ] && [ "$t" -gt "$presupuesto" ] 2>/dev/null; then
        t_col="${t}!"
      fi
    fi
    printf '%s%s%s%s%s%s\n' "$(rellenar "$skill" 16)" "$(rellenar "$ts" 27)" "$(rellenar "$modelo_col" 28)" \
      "$(rellenar "$t_col" 8)" "$(rellenar "$c" 10)" "$min"
  done < <(costos_filas "$COSTOS_LOG" "$clave")
  if [ "$filas" = 0 ]; then
    echo "Sin lanzamientos de $clave en $COSTOS_LOG."
    return 0
  fi
  local turnos_tot costo_tot min_tot revisiones
  IFS=$'\t' read -r turnos_tot costo_tot min_tot revisiones < <(costos_totales_card "$clave")
  printf '%s%s%s%s%s%s\n' "$(rellenar TOTAL 16)" "$(rellenar - 27)" "$(rellenar - 28)" \
    "$(rellenar "$turnos_tot" 8)" "$(rellenar "$costo_tot" 10)" "$min_tot ($revisiones revisiones)"
}

# Sin argumento: una fila por card con al menos un cierre exitoso de
# task-close en los últimos 30 días, con la suma de todos sus lanzamientos,
# más el promedio. Es la serie histórica del criterio de aceptación: mide si
# las hijas 4 a 8 de la Épica DEVKIT-86 bajan el costo, sin estimar nada. Un
# `task-close-N falló` no cierra la card -queda para el siguiente ciclo del
# bucle-, así que no cuenta aquí (H2 de pr-review en DEVKIT-89); sí aparece
# como fila en `costos_filas`/`costos_tabla_card`, porque ese lanzamiento
# igual costó turnos.
costos_resumen_proyecto() {
  local corte hoy_epoch
  hoy_epoch=$(date +%s)
  corte=$((hoy_epoch - 30 * 86400))
  local -a cerradas=()
  local ts c_clave skill id resto
  while IFS=: read -r ln resto; do
    [[ $resto =~ ^([^ ]+)\ task-close-([0-9]+)\ terminado ]] || continue
    ts=${BASH_REMATCH[1]}
    [ "$(date -d "$ts" +%s 2>/dev/null || echo 0)" -ge "$corte" ] || continue
    c_clave=$(clave_de_pr "${BASH_REMATCH[2]}")
    [ "$c_clave" != - ] && [ -n "$c_clave" ] || continue
    case " ${cerradas[*]:-} " in *" $c_clave "*) continue ;; esac
    cerradas+=("$c_clave")
  done < <(grep -nE ' task-close-[0-9]+ terminado' "$COSTOS_LOG" 2>/dev/null)
  if [ "${#cerradas[@]}" -eq 0 ]; then
    echo "Sin cards cerradas en los últimos 30 días en $COSTOS_LOG."
    return 0
  fi
  printf '%s%s%s%s%s\n' "$(rellenar CARD 14)" "$(rellenar TURNOS 8)" "$(rellenar COSTO 10)" \
    "$(rellenar MIN 6)" REVISIONES
  local turnos costo min revisiones suma_turnos=0 suma_costo=0 suma_min=0 suma_rev=0 n=0
  for c_clave in "${cerradas[@]}"; do
    IFS=$'\t' read -r turnos costo min revisiones < <(costos_totales_card "$c_clave")
    printf '%s%s%s%s%s\n' "$(rellenar "$c_clave" 14)" "$(rellenar "$turnos" 8)" "$(rellenar "$costo" 10)" \
      "$(rellenar "$min" 6)" "$revisiones"
    suma_turnos=$((suma_turnos + turnos))
    suma_costo=$(awk -v a="$suma_costo" -v b="$costo" 'BEGIN{printf "%.4f", a+b}')
    suma_min=$((suma_min + min))
    suma_rev=$((suma_rev + revisiones))
    n=$((n + 1))
  done
  printf '%s%s%s%s%s\n' "$(rellenar PROMEDIO 14)" "$(rellenar "$((suma_turnos / n))" 8)" \
    "$(rellenar "$(awk -v a="$suma_costo" -v n="$n" 'BEGIN{printf "%.4f", a/n}')" 10)" \
    "$(rellenar "$((suma_min / n))" 6)" "$(awk -v a="$suma_rev" -v n="$n" 'BEGIN{printf "%.1f", a/n}')"
}

mostrar_costos() {  # mostrar_costos [Clave]
  if [ ! -f "$COSTOS_LOG" ]; then
    echo "Sin costos.log todavía: ningún lanzamiento se registró desde que existe DEVKIT-89."
    return 0
  fi
  if [ -n "${1:-}" ]; then costos_tabla_card "$1"; else costos_resumen_proyecto; fi
}

run_tests() {
  local fail=0 tmp
  check() {
    local name=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
      printf 'ok   %-58s %s\n' "$name" "$got"
    else
      printf 'FAIL %-58s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
      fail=1
    fi
  }

  # Los dobles de `claude` de esta autoprueba no entienden `mcp list`
  # (DEVKIT-65): sin apagar la comprobación aquí, cada lanzamiento de abajo
  # la vería como "sin Notion" y no llegaría a correr. Los casos que sí
  # prueban la comprobación la reactivan a mano con DEVKIT_NOTION_CHECK=1.
  export DEVKIT_NOTION_CHECK=0

  # Ancho/alto amplios por defecto (DEVKIT-97 H1): sin esto, un COLUMNS/LINES
  # heredado de quien corre `--test` (una terminal angosta, un `COLUMNS=80` de
  # otra invocación) angostaba los checks que no fijan su propio tamaño. Los
  # que sí necesitan un tamaño puntual lo fijan aparte con
  # `COLUMNS=... LINES=... <comando>`, que pisa esta exportación solo para esa
  # invocación.
  export COLUMNS=200 LINES=1000

  check "rol de pr-review" revision "$(role_of '/pr-review 31')"
  check "rol de epic-plan" revision "$(role_of '/epic-plan DEVKIT-1')"
  # DEVKIT-55: task-close y task-block son bash; el rol que los agrupaba ya no
  # existe en la tabla del template. Fuera de dev no hay ../agents: se busca
  # la tabla como ROLES_FILE, y un archivo ausente cuenta 0.
  local tabla_template="$HERE/../agents/roles.toml"
  [ -f "$tabla_template" ] || tabla_template="${DEVKIT_ROLES_FILE_FALLBACK:-/opt/devkit/template/agents/roles.toml}"
  check "roles.toml del template sin rol contabilidad" 0 \
    "$(cat "$tabla_template" 2>/dev/null | grep -c '^contabilidad\.')"
  check "rol de task-start" implementacion "$(role_of '/task-start')"
  check "rol de task-fix" implementacion "$(role_of '/task-fix DEVKIT-44')"
  check "rol de task-submit" implementacion "$(role_of '/task-submit DEVKIT-44')"
  check "rol de task-document" implementacion "$(role_of '/task-document DEVKIT-44')"

  # Comprobación de concurrencia (DEVKIT-54, Ampliación 2). La tabla imita lo
  # que devolvió `ps` el 2026-09-16: tres procesos propios del lanzador más el
  # `claude -p` propio, que es de donde salió el falso positivo. Solo el
  # `claude -p` ajeno debe aparecer.
  local tabla propios
  propios="37786 37792 37794"
  tabla='37786 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-54 /run/devkit/task-start-3.log opus high 40
37792 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-54 /run/devkit/task-start-3.log opus high 40
37793 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-54 /run/devkit/task-start-3.log opus high 40
37794 claude -p /task-start DEVKIT-54 --model opus --effort high --output-format json
40001 claude -p /pr-review 38 --model fable --effort high --output-format json'
  check "concurrencia: solo cuenta el claude -p ajeno" \
    "40001 claude -p /pr-review 38 --model fable --effort high --output-format json" \
    "$(printf '%s\n' "$tabla" | filtrar_agentes "$propios")"
  # El vigilante (37793) no está en la lista de propios y aun así se descarta,
  # porque sus argumentos son los de devkit-run.sh: sin esa regla, un
  # lanzamiento se vería a sí mismo como agente ajeno.
  check "concurrencia: sin ajenos, el workspace está libre" "" \
    "$(printf '%s\n' "$tabla" | grep -v '^40001 ' | filtrar_agentes "$propios")"
  # DEVKIT-77: `--otros-agentes` identifica su propio `claude -p` entre los
  # ancestros (37794), no el vigilante (37793, argumentos de devkit-run.sh) ni
  # el `claude -p` ajeno (40001, ni siquiera está en la lista de ancestros).
  check "concurrencia: identifica el propio claude -p entre los ancestros" \
    '37794 claude -p "/task-start DEVKIT-54"' \
    "$(printf '%s\n' "$tabla" | grep -E '^(37786|37792|37793|37794) ' | propio_de)"
  local propio_rc=0 propio_sin
  propio_sin=$(printf '%s\n' "$tabla" | grep -E '^(37786|37792|37793) ' | propio_de) || propio_rc=$?
  check "concurrencia: sin un claude -p propio entre los ancestros, no hay salida" "" "$propio_sin"
  check "concurrencia: sin un claude -p propio entre los ancestros, sale con error" 1 "$propio_rc"

  # DEVKIT-79: lanzamiento_duplicado encuentra el worker vivo del mismo
  # prompt, sin confundirse con un `claude -p` de otra card.
  local tabla_dup
  tabla_dup='50001 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-9 /run/devkit/task-start-1.log opus high 40
50002 claude -p /task-fix DEVKIT-9 --model opus --effort high --output-format json'
  check "lanzamiento_duplicado: encuentra el worker vivo del mismo prompt" 50001 \
    "$(printf '%s\n' "$tabla_dup" | lanzamiento_duplicado '/task-start DEVKIT-9')"
  check "lanzamiento_duplicado: sin coincidencia, no hay salida" "" \
    "$(printf '%s\n' "$tabla_dup" | lanzamiento_duplicado '/task-start DEVKIT-99')"
  local tabla_dup2
  tabla_dup2='50003 claude -p /task-start DEVKIT-9 --model opus --effort high --output-format json'
  check "lanzamiento_duplicado: encuentra el claude -p vivo del mismo prompt" 50003 \
    "$(printf '%s\n' "$tabla_dup2" | lanzamiento_duplicado '/task-start DEVKIT-9')"
  # H1 de pr-review en el PR #56: una Clave que es prefijo de otra no debe
  # dar falso positivo.
  local tabla_dup3
  tabla_dup3='50004 claude -p /task-start DEVKIT-79 --model opus --effort high --output-format json'
  check "lanzamiento_duplicado: Clave prefijo de otra no da falso positivo" "" \
    "$(printf '%s\n' "$tabla_dup3" | lanzamiento_duplicado '/task-start DEVKIT-7')"
  # DEVKIT-97: el rechazo de lanzamiento duplicado sigue viendo el `claude -p`
  # vivo aunque su prompt real lleve el volcado de la card entera detrás
  # (DEVKIT-90) -el prompt que se compara (`/task-start DEVKIT-94`) es un
  # prefijo del que trae `ps`, con un espacio del "\n\n" aplanado justo
  # después, así que el patrón de siempre ya lo encuentra.
  local tabla_dup4
  tabla_dup4="50005 claude -p /task-start DEVKIT-94  ## Card - Clave: DEVKIT-94 $(printf 'relleno %.0s' $(seq 1 100)) --model opus --effort high --output-format json"
  check "lanzamiento_duplicado: encuentra el claude -p vivo aunque el prompt real lleve la card entera" 50005 \
    "$(printf '%s\n' "$tabla_dup4" | lanzamiento_duplicado '/task-start DEVKIT-94')"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Dobles de notion.sh y gh para la ronda (DEVKIT-61). Responden desde
  # $RONDA_DIR: `card-<Clave>.json`, `pr-view.json` (comentarios del PR) y
  # `pr-list.json`; sin archivo, fallan como un servicio caído. Se exportan
  # para que ningún lanzamiento de esta prueba (task-fix, task-document)
  # consulte la card real en Notion ni el PR real en GitHub.
  export RONDA_DIR="$tmp/ronda"
  mkdir -p "$RONDA_DIR"
  # Repo aislado para pr_de_clave: sin card ni PR en los dobles, cae a buscar
  # una rama `<tipo>/<Clave>-` en el workspace. Sin este repo vacío usaría el
  # workspace real (WS por defecto) y una rama real que calzara con la Clave
  # de prueba (DEVKIT-99) volvería flaky el caso "sin PR ni rama" (DEVKIT-104).
  git init -q "$tmp/ronda-ws"
  cat >"$tmp/notion-doble" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) cat "$RONDA_DIR/card-$2.json" 2>/dev/null ;;
  comentar) printf '%s\t%s\n' "$2" "$3" >>"$RONDA_DIR/comentarios" ;;
esac
FIN
  cat >"$tmp/gh-doble" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RONDA_DIR/gh-llamadas"
case "$1 $2" in
  "pr view") cat "$RONDA_DIR/pr-view.json" 2>/dev/null ;;
  "pr list") cat "$RONDA_DIR/pr-list.json" 2>/dev/null ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$tmp/notion-doble" "$tmp/gh-doble"
  export DEVKIT_NOTION_BIN="$tmp/notion-doble" DEVKIT_GH_BIN="$tmp/gh-doble"
  NOTION_BIN="$tmp/notion-doble" GH_BIN="$tmp/gh-doble"

  # Doble de task-begin.sh (DEVKIT-90), exportado para el resto de la
  # autoprueba: las pruebas de más abajo que lanzan task-start no giran
  # alrededor de sus pasos mecánicos (workspace, rama, Notion) y no necesitan
  # un repositorio git completo solo para que el agente arranque. Las pruebas
  # que sí prueban task-begin.sh de verdad anulan esta variable con el
  # binario real, por invocación.
  cat >"$tmp/task-begin-doble" <<'FIN'
#!/usr/bin/env bash
echo "- Clave: $1"
echo "- Título: card de prueba"
FIN
  chmod +x "$tmp/task-begin-doble"
  export DEVKIT_TASK_BEGIN_BIN="$tmp/task-begin-doble"

  # Doble de review-prep.sh (DEVKIT-93), exportado igual que el de
  # task-begin.sh: dice que siempre hay algo que revisar, sin tocar gh ni
  # Notion, para que las pruebas de más abajo que lanzan "/pr-review ..." sin
  # probar la preparación en sí no dependan del PR 9 de verdad. Las pruebas
  # que sí prueban la preparación anulan esta variable por invocación.
  cat >"$tmp/review-prep-doble" <<'FIN'
#!/usr/bin/env bash
echo "## Card
material de prueba"
FIN
  chmod +x "$tmp/review-prep-doble"
  export DEVKIT_REVIEW_PREP_BIN="$tmp/review-prep-doble"

  # Un doble de `claude` que no gasta cuota: responde bien a cualquier
  # `--model`, así sirve tanto para las comprobaciones de disponibilidad como
  # para los lanzamientos de punta a punta de más abajo.
  local doble
  doble="$tmp/claude"
  cat >"$doble" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$doble"

  cat >"$tmp/roles.toml" <<'FIN'
frontera = ["modelo-barato", "modelo-medio", "modelo-fuerte"]
implementacion.model_index = 1
implementacion.effort = "low"
implementacion.max_turns = 15
revision.model_index = 3
revision.effort = "high"
revision.max_turns = 50
epic-plan.effort = "max"
FIN

  check "campo model_index de implementación" "1" \
    "$(ROLES_FILE="$tmp/roles.toml" role_field implementacion model_index)"
  check "campo model_index de revisión" "3" \
    "$(ROLES_FILE="$tmp/roles.toml" role_field revision model_index)"
  check "anulación de esfuerzo por skill (epic-plan)" "max" \
    "$(ROLES_FILE="$tmp/roles.toml" role_field epic-plan effort)"
  check "lista de frontera, una por línea" "modelo-barato
modelo-medio
modelo-fuerte" "$(ROLES_FILE="$tmp/roles.toml" frontera_list)"
  # Un comentario al final de la línea es TOML válido y `.devkit/roles.toml`
  # se edita a mano: no puede colarse en el valor (DEVKIT-54, H3).
  cat >"$tmp/roles-comentarios.toml" <<'FIN'
frontera = ["a", "b"]  # del más fuerte al más barato
revision.model_index = 1 # primero de la lista
revision.effort = "high"  # "max" solo en epic-plan
FIN
  check "frontera_list ignora un comentario en línea" "a
b" "$(ROLES_FILE="$tmp/roles-comentarios.toml" frontera_list)"
  check "role_field ignora un comentario en línea (número)" "1" \
    "$(ROLES_FILE="$tmp/roles-comentarios.toml" role_field revision model_index)"
  check "role_field ignora un comentario en línea (cadena)" "high" \
    "$(ROLES_FILE="$tmp/roles-comentarios.toml" role_field revision effort)"

  # Sin DEVKIT_ROLES_FILE y sin hermano ../agents (la forma en que corre
  # desde /opt/devkit/scripts en la imagen), el valor por defecto debe caer
  # al respaldo en vez de a un archivo que no existe (DEVKIT-50, H1).
  mkdir -p "$tmp/nested/scripts"
  cp "$HERE/devkit-run.sh" "$tmp/nested/scripts/devkit-run.sh"
  check "ROLES_FILE por defecto cae al respaldo sin ../agents" "modelo-fuerte high 50 -" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_ROLES_FILE_FALLBACK="$tmp/roles.toml" DEVKIT_WS="$tmp" \
       DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-fallback" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" \
       bash "$tmp/nested/scripts/devkit-run.sh" --rol '/pr-review 9')"

  # Resolución normal de la lista (DEVKIT-54): con todos los modelos
  # disponibles, resolver_modelo devuelve el que toca por model_index, sin
  # caer al siguiente.
  check "resolución normal: primer modelo de la lista" "modelo-barato" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-normal-1" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 1)"
  check "resolución normal: tercer modelo de la lista" "modelo-fuerte" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-normal-3" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 3)"

  # Caída al siguiente modelo (DEVKIT-54): un doble que rechaza un alias
  # puntual simula un modelo que no existe o no responde; resolver_modelo
  # debe caer al siguiente de la lista, y quedar cacheado que el primero no
  # sirve.
  local caido
  caido="$tmp/claude-caido"
  cat >"$caido" <<'FIN'
#!/usr/bin/env bash
modelo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) modelo=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$modelo" = "modelo-inexistente" ]; then
  echo "error: modelo desconocido" >&2
  exit 1
fi
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":1}\n'
FIN
  chmod +x "$caido"
  # Tres modelos a propósito, no dos: con dos, "el siguiente de la lista" y
  # "el último recurso" son el mismo valor y la prueba pasa aunque la
  # resolución esté rota. Así se escapó que la sonda se comía el stdin del
  # bucle y cortaba la lista tras el primer modelo (DEVKIT-54).
  cat >"$tmp/roles-caida.toml" <<'FIN'
frontera = ["modelo-inexistente", "modelo-bueno", "modelo-ultimo"]
implementacion.model_index = 1
implementacion.effort = "high"
implementacion.max_turns = 10
FIN
  check "caída al siguiente modelo cuando el primero no responde" "modelo-bueno" \
    "$(CLAUDE_BIN="$caido" ROLES_FILE="$tmp/roles-caida.toml" FRONTERA_CACHE_DIR="$tmp/frontera-caida" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 1)"
  check "el modelo caído queda cacheado como no disponible" "no" \
    "$(cat "$tmp/frontera-caida/modelo-inexistente" 2>/dev/null)"
  check "el modelo elegido tras la caída queda cacheado como disponible" "si" \
    "$(cat "$tmp/frontera-caida/modelo-bueno" 2>/dev/null)"
  # Una sonda que lee stdin no debe truncar la lista: con un doble que se
  # come la entrada, la resolución tiene que seguir llegando al segundo
  # modelo y no saltar al último.
  local traga
  traga="$tmp/claude-traga"
  cat >"$traga" <<'FIN'
#!/usr/bin/env bash
modelo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) modelo=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null            # se come todo el stdin, como hace claude -p
[ "$modelo" != "modelo-inexistente" ] || exit 1
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":1}\n'
FIN
  chmod +x "$traga"
  check "una sonda que lee stdin no trunca la lista de frontera" "modelo-bueno" \
    "$(CLAUDE_BIN="$traga" ROLES_FILE="$tmp/roles-caida.toml" FRONTERA_CACHE_DIR="$tmp/frontera-traga" WATCH_LOG="$tmp/sonda-watch.log" resolver_modelo 1)"
  # La caída tiene que quedar en watch.log: es la forma de verla sin
  # reproducirla a mano (criterio de aceptación de DEVKIT-54).
  : >"$tmp/sonda-watch.log"
  CLAUDE_BIN="$caido" ROLES_FILE="$tmp/roles-caida.toml" \
    FRONTERA_CACHE_DIR="$tmp/frontera-log" WATCH_LOG="$tmp/sonda-watch.log" \
    resolver_modelo 1 >/dev/null
  # Un error inmediato de la CLI se registra como fallo con su stderr, no como
  # timeout, y el stderr queda junto a la caché.
  check "la caída al siguiente modelo queda registrada en watch.log" \
    'sonda de modelo: modelo-inexistente falló (rc=1): error: modelo desconocido' \
    "$(grep -oE 'sonda de modelo: modelo-inexistente falló \(rc=1\): error: modelo desconocido' "$tmp/sonda-watch.log" | head -1)"
  check "el stderr de la sonda queda en <alias>.err" "error: modelo desconocido" \
    "$(cat "$tmp/frontera-log/modelo-inexistente.err" 2>/dev/null)"
  # Solo el rc 124 de `timeout` se registra como "no responde en Ns".
  local lento
  lento="$tmp/claude-lento"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$lento"
  chmod +x "$lento"
  CLAUDE_BIN="$lento" FRONTERA_CACHE_DIR="$tmp/frontera-lento" WATCH_LOG="$tmp/sonda-watch.log" \
    MODEL_CHECK_TIMEOUT=1 modelo_disponible modelo-lento
  check "un timeout de la sonda se registra como no responde" \
    'sonda de modelo: modelo-lento no responde en 1s' \
    "$(grep -oE 'sonda de modelo: modelo-lento no responde en 1s' "$tmp/sonda-watch.log" | head -1)"
  check "el modelo que sí responde también deja su línea" \
    'sonda de modelo: modelo-bueno responde' \
    "$(grep -oE 'sonda de modelo: modelo-bueno responde' "$tmp/sonda-watch.log" | head -1)"
  # Una segunda resolución con la caché ya escrita no vuelve a sondear ni a
  # registrar: "una vez por arranque".
  : >"$tmp/sonda-watch.log"
  CLAUDE_BIN="$caido" ROLES_FILE="$tmp/roles-caida.toml" \
    FRONTERA_CACHE_DIR="$tmp/frontera-log" WATCH_LOG="$tmp/sonda-watch.log" \
    resolver_modelo 1 >/dev/null
  check "con la caché escrita no vuelve a sondear" "0" \
    "$(grep -c 'sonda de modelo' "$tmp/sonda-watch.log" | tr -d ' ')"
  # Un `no` caduca: un fallo transitorio (cuota, red) no puede dejar el modelo
  # fuera todo el arranque. Dentro del plazo se respeta sin sondear; con
  # MODEL_RETRY=0 ya venció, la sonda vuelve a correr y el modelo queda en `si`.
  mkdir -p "$tmp/frontera-transitorio"
  printf 'no' >"$tmp/frontera-transitorio/modelo-bueno"
  check "un no dentro del plazo no vuelve a sondear" "no" \
    "$(CLAUDE_BIN="$doble" FRONTERA_CACHE_DIR="$tmp/frontera-transitorio" WATCH_LOG="$tmp/sonda-watch.log" MODEL_RETRY=600 modelo_disponible modelo-bueno; cat "$tmp/frontera-transitorio/modelo-bueno")"
  check "un fallo transitorio no persiste tras el plazo" "si" \
    "$(CLAUDE_BIN="$doble" FRONTERA_CACHE_DIR="$tmp/frontera-transitorio" WATCH_LOG="$tmp/sonda-watch.log" MODEL_RETRY=0 modelo_disponible modelo-bueno; cat "$tmp/frontera-transitorio/modelo-bueno")"

  check "modelo/esfuerzo de pr-review" "modelo-fuerte high 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-pr" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/pr-review 9')"
  check "modelo/esfuerzo de epic-plan (esfuerzo máximo por skill)" "modelo-fuerte max 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-epic" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/epic-plan DEVKIT-1')"
  check "modelo/esfuerzo de task-fix (rol implementación)" "modelo-barato low 15 1" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-fix" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/task-fix DEVKIT-2')"

  # --- Presupuesto de turnos por skill (DEVKIT-94) ---------------------------
  # `presupuesto.task-fix` anula `implementacion.max_turns` (15 en
  # $tmp/roles.toml), igual que ya hacían `model_index`/`effort` por skill.
  cat >"$tmp/roles-presupuesto.toml" <<'FIN'
frontera = ["modelo-barato"]
implementacion.model_index = 1
implementacion.effort = "low"
implementacion.max_turns = 40
revision.model_index = 1
revision.effort = "high"
revision.max_turns = 50
presupuesto.task-fix = 7
FIN
  check "model_effort_of usa presupuesto.task-fix, no implementacion.max_turns" "modelo-barato low 7 1" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-presupuesto.toml" FRONTERA_CACHE_DIR="$tmp/frontera-presupuesto" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/task-fix DEVKIT-2')"
  check "sin presupuesto.pr-review, sigue el max_turns del rol" "modelo-barato high 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-presupuesto.toml" FRONTERA_CACHE_DIR="$tmp/frontera-presupuesto" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/pr-review 9')"

  # De punta a punta: un lanzamiento que se pasa del presupuesto nunca
  # bloquea la card (DEVKIT-105): el presupuesto de roles.toml es una meta de
  # optimización, no un límite, así que solo avisa -ALARMA en watch.log y un
  # comentario en la card-, sin llamar a task-block.sh y sin tocar el Estado.
  # $tmp/roles.toml no trae `presupuesto.task-fix`, así que el tope es
  # `implementacion.max_turns` (15); el doble de `claude` responde con 99
  # turnos, muy por encima.
  local gastador bloqueo_presupuesto espera
  gastador="$tmp/claude-gastador"
  cat >"$gastador" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"Completé DEVKIT-3: listo.","total_cost_usd":0.5,"num_turns":99}\n'
FIN
  chmod +x "$gastador"
  bloqueo_presupuesto="$tmp/task-block-doble-presupuesto"
  printf '#!/usr/bin/env bash\nprintf "%%s|" "$@" >"%s/bloqueo.args"\n' "$tmp" >"$bloqueo_presupuesto"
  chmod +x "$bloqueo_presupuesto"
  mkdir -p "$tmp/run"
  : >"$tmp/run/ready"  # sin esto, esperar_arranque espera 120s de verdad
  printf '{"id":"card-3","estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-3.json"
  rm -f "$tmp/bloqueo.args" "$RONDA_DIR/comentarios"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$gastador" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo_presupuesto" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -s "$RONDA_DIR/comentarios" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "presupuesto excedido no bloquea la card con task-block.sh" 0 \
    "$([ -e "$tmp/bloqueo.args" ] && echo 1 || echo 0)"
  check "watch.log deja la ALARMA de presupuesto excedido" \
    'ALARMA: presupuesto excedido (99 turnos, presupuesto 15)' \
    "$(grep -oE 'ALARMA: presupuesto excedido \(99 turnos, presupuesto 15\)' "$tmp/run/watch.log" | head -1)"
  check "el comentario en la card nombra el presupuesto excedido" \
    'Presupuesto excedido: 99 turnos contra 15 en task-fix; el ciclo sigue' \
    "$(grep -oE 'Presupuesto excedido: 99 turnos contra 15 en task-fix; el ciclo sigue' "$RONDA_DIR/comentarios" | head -1)"

  # Mismo resultado con la card ya entregada (PR abierto, Revisión
  # automática): antes de DEVKIT-105 esto la dejaba Bloqueada y la revisión
  # que el bucle lanzaba segundos después salía sin revisar (pasó cuatro
  # veces en un día: 97, 99, 101 y 102). Ahora tampoco bloquea ni cambia el
  # Estado; solo avisa igual que arriba.
  printf '{"id":"card-3","estado":"Revisión automática","pr":"https://github.com/o/r/pull/61"}\n' \
    >"$RONDA_DIR/card-DEVKIT-3.json"
  rm -f "$tmp/bloqueo.args" "$RONDA_DIR/comentarios"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$gastador" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo_presupuesto" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -s "$RONDA_DIR/comentarios" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "presupuesto excedido con card ya entregada tampoco bloquea" 0 \
    "$([ -e "$tmp/bloqueo.args" ] && echo 1 || echo 0)"
  check "presupuesto excedido con card ya entregada también comenta" \
    'Presupuesto excedido: 99 turnos contra 15 en task-fix; el ciclo sigue' \
    "$(grep -oE 'Presupuesto excedido: 99 turnos contra 15 en task-fix; el ciclo sigue' "$RONDA_DIR/comentarios" | head -1)"
  rm -f "$RONDA_DIR/card-DEVKIT-3.json" "$RONDA_DIR/comentarios"

  # --- Anulación de `model_index` por skill (DEVKIT-72) ---------------------
  # `epic-plan.model_index` anula `revision.model_index`, igual que ya hacía
  # `epic-plan.effort`: con la tabla real del template, pr-review sube al
  # segundo modelo de frontera (opus) y epic-plan se queda en el primero
  # (fable).
  cat >"$tmp/roles-anulacion-modelo.toml" <<'FIN'
frontera = ["fable", "opus", "sonnet"]
revision.model_index = 2
revision.effort = "high"
revision.max_turns = 50
epic-plan.model_index = 1
epic-plan.effort = "max"
FIN
  check "pr-review sube al segundo modelo de frontera (revision.model_index)" "opus high 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-anulacion-modelo.toml" FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/pr-review 9')"
  check "epic-plan anula model_index a 1: primer modelo de frontera" "fable max 50 -" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-anulacion-modelo.toml" FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/epic-plan DEVKIT-1')"
  # De punta a punta, no solo en `model_effort_of` aislado: el doble de
  # `claude` recibe de verdad `--model opus` para pr-review y `--model fable`
  # para epic-plan. La ruta del log queda fija en el script del doble, no en
  # una variable de entorno: `run_claude` lanza con `env -i` y una lista
  # blanca que no incluye variables de esta prueba.
  local registra
  registra="$tmp/claude-registra"
  cat >"$registra" <<FIN
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/claude-llamadas"
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$registra"
  : >"$tmp/claude-llamadas"
  DEVKIT_CLAUDE_BIN="$registra" DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" \
    DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --sync '/pr-review 9' >/dev/null 2>&1
  check "el claude -p de pr-review recibe --model opus" 1 \
    "$(grep -c -- '--model opus' "$tmp/claude-llamadas")"
  : >"$tmp/claude-llamadas"
  DEVKIT_CLAUDE_BIN="$registra" DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" \
    DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --sync '/epic-plan DEVKIT-1' >/dev/null 2>&1
  check "el claude -p de epic-plan recibe --model fable" 1 \
    "$(grep -c -- '--model fable' "$tmp/claude-llamadas")"

  # --- review-prep.sh antes de pr-review (DEVKIT-93) ------------------------
  # `run_claude` corre `review-prep.sh` antes de cualquier `claude -p` de
  # pr-review: con un PR simulado docs y uno código (la clasificación la
  # decide el propio `review-prep.sh`, acá solo importa que su salida llegue
  # al prompt bajo `## Material`) y, por separado, el caso que paga esta card:
  # "nada que revisar" no debe gastar ningún turno de Opus.
  cat >"$tmp/review-prep-docs" <<'FIN'
#!/usr/bin/env bash
echo "## Card
PR simulado de documentación.
## Comprobaciones mecánicas
PR de documentación: sin worktree, sin comprobaciones mecánicas."
FIN
  cat >"$tmp/review-prep-codigo" <<'FIN'
#!/usr/bin/env bash
echo "## Card
PR simulado de código.
## Comprobaciones mecánicas
Comprobaciones mecánicas (2 Verificado, 0 Falla):
- **bash -n foo.sh**: Verificado"
FIN
  cat >"$tmp/review-prep-nada" <<'FIN'
#!/usr/bin/env bash
echo "ya revisado en abc123"
exit 3
FIN
  chmod +x "$tmp/review-prep-docs" "$tmp/review-prep-codigo" "$tmp/review-prep-nada"

  : >"$tmp/claude-llamadas"
  DEVKIT_CLAUDE_BIN="$registra" DEVKIT_REVIEW_PREP_BIN="$tmp/review-prep-docs" \
    DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" \
    DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --sync '/pr-review 20' >/dev/null 2>&1
  check "PR docs simulado: el material de review-prep.sh entra en el prompt" 1 \
    "$(grep -c 'PR de documentación: sin worktree' "$tmp/claude-llamadas")"
  check "PR docs simulado: el prompt trae el encabezado ## Material" 1 \
    "$(grep -c '## Material' "$tmp/claude-llamadas")"

  : >"$tmp/claude-llamadas"
  DEVKIT_CLAUDE_BIN="$registra" DEVKIT_REVIEW_PREP_BIN="$tmp/review-prep-codigo" \
    DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" \
    DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --sync '/pr-review 21' >/dev/null 2>&1
  check "PR código simulado: el material de review-prep.sh entra en el prompt" 1 \
    "$(grep -c 'bash -n foo.sh' "$tmp/claude-llamadas")"

  : >"$tmp/claude-llamadas"
  salida_nada=$(DEVKIT_CLAUDE_BIN="$registra" DEVKIT_REVIEW_PREP_BIN="$tmp/review-prep-nada" \
    DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" \
    DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --sync '/pr-review 22' 2>&1)
  salida_nada_rc=$?
  check "nada que revisar: devkit-run --sync sale con 3" 3 "$salida_nada_rc"
  check "nada que revisar: el motivo llega a stdout/stderr" 1 \
    "$(grep -c 'ya revisado en abc123' <<<"$salida_nada")"
  check "nada que revisar: no llama a claude -p (cero turnos de Opus)" 0 \
    "$(wc -l <"$tmp/claude-llamadas" | tr -d ' ')"

  # --- Perfil de herramientas por skill (DEVKIT-125) --------------------------
  # pr-review y task-document no tocan la rama: reciben Read/Grep/Glob/Skill,
  # Notion, y Bash acotado a patrones concretos, sin Edit ni Write y con
  # `--permission-mode default`. task-start, task-fix y epic-plan siguen con
  # el perfil amplio de siempre. `perfil_de` aislada primero, y después de
  # punta a punta con el doble de `claude` (la línea real que recibiría).
  check "perfil_de: pr-review sin worktree, sin el --test acotado" \
    "default
Read
Grep
Glob
Skill
mcp__plugin_Notion_notion
mcp__claude_ai_Notion
Bash(gh pr:*)
Bash(gh api:*)
Bash(git diff:*)
Bash(git log:*)
Bash(git show:*)
Bash($HERE/review-prep.sh:*)
Bash($HERE/review-publish.sh:*)
Bash($HERE/notion.sh:*)" \
    "$(perfil_de pr-review)"
  check "perfil_de: task-document recibe el mismo perfil restringido que pr-review, sin el --test" \
    "$(perfil_de pr-review)" "$(perfil_de task-document)"
  check "perfil_de: task-document ignora un worktree, nunca agrega el --test" 0 \
    "$(perfil_de task-document /tmp/devkit-review-42 | grep -c -F -- '--test')"
  check "perfil_de: pr-review y task-document no traen Edit ni Write" 0 \
    "$(perfil_de pr-review | grep -xc -E 'Edit|Write')"
  # H1 y H3 de la revisión del PR 92: ningún patrón puede traer una
  # expansión de variable (`$` o backtick), porque Claude Code la rechaza con
  # "Contains expansion" antes de mirar la lista allow. Cubre también el
  # perfil amplio, aunque ahí nunca importó (acceptEdits no consulta la
  # lista), para que nadie vuelva a colar `${DEVKIT_SCRIPTS_DIR:-...}` ahí.
  for skill_chequeo in pr-review task-document task-start task-fix epic-plan; do
    check "perfil_de: $skill_chequeo sin expansión de variables en ningún patrón" 0 \
      "$(perfil_de "$skill_chequeo" /tmp/devkit-review-42 | grep -c '[$`]')"
  done
  for skill_amplio in task-start task-fix epic-plan; do
    check "perfil_de: $skill_amplio conserva el perfil amplio de siempre" \
      'acceptEdits
Bash
Read
Edit
Write
Grep
Glob
Skill
mcp__plugin_Notion_notion
mcp__claude_ai_Notion' \
      "$(perfil_de "$skill_amplio")"
  done

  # H4 y H7 de la revisión del PR 92: el `--test` del worktree ya no depende
  # de un `*` a mitad de patrón (esa sintaxis no existe para Claude Code, que
  # solo entiende un prefijo literal más `:*` al final): `perfil_de` expande
  # el glob de bash sobre los scripts que de verdad están en el worktree y
  # agrega un patrón literal por cada uno, más la lectura de git y las
  # comprobaciones mecánicas acotadas a esa misma ruta.
  local worktree_perfil="$tmp/worktree-perfil-h4"
  mkdir -p "$worktree_perfil/devkit/scripts"
  : >"$worktree_perfil/devkit/scripts/devkit-run.sh"
  : >"$worktree_perfil/devkit/scripts/pr-guard.sh"
  : >"$worktree_perfil/devkit/entrypoint.sh"
  : >"$worktree_perfil/new-project.sh"
  check "perfil_de: --test del worktree, un patrón literal por script real" \
    "Bash(bash $worktree_perfil/devkit/scripts/devkit-run.sh --test:*)
Bash(bash $worktree_perfil/devkit/scripts/pr-guard.sh --test:*)
Bash(git -C $worktree_perfil diff:*)
Bash(git -C $worktree_perfil log:*)
Bash(git -C $worktree_perfil show:*)
Bash(git -C $worktree_perfil grep:*)
Bash(bash -n $worktree_perfil/new-project.sh:*)
Bash(bash -n $worktree_perfil/devkit/entrypoint.sh:*)
Bash(bash -n $worktree_perfil/devkit/scripts/devkit-run.sh:*)
Bash(bash -n $worktree_perfil/devkit/scripts/pr-guard.sh:*)" \
    "$(perfil_de pr-review "$worktree_perfil" | tail -10)"
  check "perfil_de: sin scripts en el worktree, ningún --test ni bash -n, pero sí la lectura acotada" \
    "Bash(git -C /tmp/devkit-review-vacio diff:*)
Bash(git -C /tmp/devkit-review-vacio log:*)
Bash(git -C /tmp/devkit-review-vacio show:*)
Bash(git -C /tmp/devkit-review-vacio grep:*)" \
    "$(perfil_de pr-review /tmp/devkit-review-vacio | tail -4)"
  check "perfil_de: sin patrón bash -n, ruff check ni pytest sobre la raíz del worktree" \
    0 "$(perfil_de pr-review "$worktree_perfil" \
      | grep -cE "^Bash\((bash -n|ruff check|pytest) $worktree_perfil:")"

  # H5 de la revisión del PR 92: `--allowedTools` solo se suma a la lista
  # `allow` de `settings.json`, que sigue autorizando `git add/commit/push` y
  # `gh pr merge --auto` para el perfil amplio. `perfil_disallow_de` niega
  # eso aparte para pr-review/task-document -`--disallowedTools` sí gana
  # sobre cualquier `allow`- y va vacía para el perfil amplio.
  check "perfil_disallow_de: pr-review niega escritura y push/merge" \
    'Edit
Write
NotebookEdit
Bash(git add:*)
Bash(git commit:*)
Bash(git push:*)
Bash(gh pr merge:*)
Bash(uv:*)
Bash(uvx:*)
Bash(git checkout:*)
Bash(git switch:*)
Bash(git pull:*)
Bash(git worktree:*)
Bash(find:*)
Bash(gh pr edit:*)
Bash(gh issue:*)
Bash(git branch:*)
Bash(git fetch:*)' \
    "$(perfil_disallow_de pr-review)"
  check "perfil_disallow_de: task-document recibe la misma lista de negados" \
    "$(perfil_disallow_de pr-review)" "$(perfil_disallow_de task-document)"
  for skill_amplio in task-start task-fix epic-plan; do
    check "perfil_disallow_de: $skill_amplio no niega nada" "" \
      "$(perfil_disallow_de "$skill_amplio")"
  done

  # H1, H3 y H6 de la revisión del PR 92: comprobación estática de que
  # ningún bloque ```sh``` de estas dos skills -los comandos que de verdad
  # se ejecutan, a diferencia de la prosa que explica el respaldo para una
  # sesión interactiva- trae la sintaxis `${VAR:-...}` que Claude Code
  # rechaza con "Contains expansion". Una referencia simple como `"$cuerpo"`
  # (una variable local que la misma skill arma en el paso anterior, sin
  # respaldo de shell) no es el problema que encontró la revisión: solo
  # `${...}` lo es. Es la clase de comprobación que el "ciclo real" de más
  # abajo no puede hacer, porque su doble de `claude` no pasa por el motor de
  # permisos real (H6).
  local bloques_sh_sin_expansion
  bloques_sh_sin_expansion() {  # bloques_sh_sin_expansion <SKILL.md>
    awk '/^   ```sh$/{f=1;next} /^   ```$/{f=0} f' "$1" | grep -c '\${'
  }
  check "pr-review/SKILL.md: los bloques sh no traen expansión de variables" 0 \
    "$(bloques_sh_sin_expansion "$HERE/../agents/skills/pr-review/SKILL.md")"
  check "task-document/SKILL.md: los bloques sh no traen expansión de variables" 0 \
    "$(bloques_sh_sin_expansion "$HERE/../agents/skills/task-document/SKILL.md")"

  # De punta a punta: la línea que de verdad recibe el doble de `claude`,
  # reconstruida con `perfil_de`/`perfil_disallow_de` para no repetir la
  # lista a mano y quedar desincronizada si cambia (la integración con
  # `run_claude` -el slice `perfil[@]:1`, sobre todo- es lo que esto prueba;
  # la lista en sí ya quedó cubierta arriba). También comprueba que el
  # argumento de `-p` siga empezando por el slash command (H8: Claude Code
  # solo lo interpreta si es lo primero del mensaje) y que la cabecera de
  # metadatos (`DEVKIT_SCRIPTS_DIR=... DEVKIT_MODEL=... DEVKIT_EFFORT=...`)
  # llegue como segunda línea, solo para pr-review/task-document.
  local perfil_prompt perfil_skill perfil_extra
  for perfil_prompt in '/pr-review 30' '/task-document DEVKIT-1 5' \
      '/task-start DEVKIT-1' '/task-fix DEVKIT-1' '/epic-plan DEVKIT-1'; do
    perfil_skill=${perfil_prompt#/}; perfil_skill=${perfil_skill%% *}
    perfil_extra=""
    [ "$perfil_skill" = pr-review ] && perfil_extra="$tmp/worktrees-perfil/devkit-review-30"
    local -a perfil_esperado perfil_disallow_esperado
    mapfile -t perfil_esperado < <(perfil_de "$perfil_skill" "$perfil_extra")
    mapfile -t perfil_disallow_esperado < <(perfil_disallow_de "$perfil_skill")
    local linea_esperada="--permission-mode ${perfil_esperado[0]} --allowedTools ${perfil_esperado[*]:1}"
    [ "${#perfil_disallow_esperado[@]}" -eq 0 ] \
      || linea_esperada="$linea_esperada --disallowedTools ${perfil_disallow_esperado[*]}"
    : >"$tmp/claude-llamadas"
    DEVKIT_CLAUDE_BIN="$registra" DEVKIT_REVIEW_PREP_BIN="$tmp/review-prep-codigo" \
      DEVKIT_REVIEW_WORKTREE_DIR="$tmp/worktrees-perfil" \
      DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" \
      DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
      bash "$HERE/devkit-run.sh" --sync "$perfil_prompt" >/dev/null 2>&1
    check "el claude -p de $perfil_skill recibe exactamente su perfil" 1 \
      "$(grep -c -F -- "$linea_esperada" "$tmp/claude-llamadas")"
    check "el claude -p de $perfil_skill empieza por el slash command" 1 \
      "$(grep -c -F -- "-p $perfil_prompt" "$tmp/claude-llamadas")"
    case "$perfil_skill" in
      pr-review|task-document)
        check "el claude -p de $perfil_skill recibe la cabecera de metadatos" 1 \
          "$(grep -c -F -- "DEVKIT_SCRIPTS_DIR=$HERE" "$tmp/claude-llamadas")"
        ;;
      *)
        check "el claude -p de $perfil_skill no recibe la cabecera de metadatos (H8)" 0 \
          "$(grep -c -F -- "DEVKIT_SCRIPTS_DIR=$HERE" "$tmp/claude-llamadas")"
        ;;
    esac
    # H7 reabierto de la revisión del PR 92: sin `--add-dir`, `git -C
    # <worktree>` queda fuera de los directorios de trabajo permitidos y la
    # lectura del worktree de pr-review se bloquea entera.
    if [ "$perfil_skill" = pr-review ]; then
      check "el claude -p de pr-review recibe --add-dir con el worktree" 1 \
        "$(grep -c -F -- "--add-dir $perfil_extra" "$tmp/claude-llamadas")"
    else
      check "el claude -p de $perfil_skill no recibe --add-dir" 0 \
        "$(grep -c -F -- '--add-dir' "$tmp/claude-llamadas")"
    fi
  done

  # --- Ciclo real de pr-review con el perfil restringido (DEVKIT-125, AC2) ---
  # Con los dobles de DEVKIT-93 (notion-doble, gh-doble), de punta a punta:
  # `review-prep.sh` prepara el material, `run_claude` lanza el doble de
  # `claude` con el perfil restringido, y el doble hace lo único que ese
  # perfil permite escribir de verdad -el informe y la llamada a
  # `review-publish.sh`, los dos cubiertos por los patrones nuevos-. Con
  # veredicto OK, la card debe terminar igual que con el perfil de antes: en
  # "Lista para merge", informe publicado y sin residuo en el árbol.
  local ciclo2_dir
  ciclo2_dir=$(mktemp -d "$tmp/ciclo2.XXXXXX")
  mkdir -p "$ciclo2_dir/ws/.devkit" "$ciclo2_dir/run"
  cat >"$ciclo2_dir/notion-doble" <<FIN
#!/usr/bin/env bash
case "\$1" in
  card) printf '{"id":"card-9401","url":"https://notion.so/card9401","estado":"Revisión automática","titulo":"Probar ciclo con perfil restringido"}' ;;
  set) shift; printf '%s\n' "\$*" >>"$ciclo2_dir/set-llamadas" ;;
esac
FIN
  chmod +x "$ciclo2_dir/notion-doble"
  cat >"$ciclo2_dir/gh-doble" <<'FIN'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo '{"title":"DEVKIT-9401: probar ciclo con perfil restringido","body":"## Qué cambia\nProbar el perfil restringido.","state":"OPEN","headRefOid":"abc9401","headRefName":"feat/DEVKIT-9401","reviews":[],"comments":[]}' ;;
  "pr review") cat >/dev/null; exit 0 ;;
  "pr edit") cat >/dev/null; exit 0 ;;
  "pr comment") cat >/dev/null; exit 0 ;;
  "api "*) echo '{"login":"devkit-bot","owner":{"type":"User","login":"byroncz"}}' ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$ciclo2_dir/gh-doble"
  cat >"$ciclo2_dir/review-prep-codigo" <<'FIN'
#!/usr/bin/env bash
echo "## Card
PR simulado de código, perfil restringido.
## Comprobaciones mecánicas
Comprobaciones mecánicas (1 Verificado, 0 Falla):
- **bash -n foo.sh**: Verificado"
FIN
  chmod +x "$ciclo2_dir/review-prep-codigo"
  cat >"$ciclo2_dir/agente-doble" <<FIN
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ciclo2_dir/claude-llamadas"
cat >"$ciclo2_dir/ws/.devkit/review-9401.md" <<'INFORME'
<!-- devkit-review sha=abc9401 verdict=OK -->
Revisado con fable, esfuerzo high
## Revisión independiente (commit abc9401)

### Criterios de aceptación
| Criterio | Estado | Cómo se comprobó |
|---|---|---|
| Todo | Verificado | bash -n foo.sh |

### Lectura adversarial
- Nada que objetar.

### Veredicto
**OK** todo bien.
INFORME
env DEVKIT_WS="$ciclo2_dir/ws" DEVKIT_GH_BIN="$ciclo2_dir/gh-doble" DEVKIT_NOTION_BIN="$ciclo2_dir/notion-doble" \
  DEVKIT_REVIEW_WORKTREE_DIR="$ciclo2_dir/worktrees" DEVKIT_RUN_DIR="$ciclo2_dir/run" \
  bash "$HERE/review-publish.sh" 9401 "$ciclo2_dir/ws/.devkit/review-9401.md" >/dev/null 2>&1
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$ciclo2_dir/agente-doble"
  DEVKIT_CLAUDE_BIN="$ciclo2_dir/agente-doble" DEVKIT_REVIEW_PREP_BIN="$ciclo2_dir/review-prep-codigo" \
    DEVKIT_ROLES_FILE="$tmp/roles-anulacion-modelo.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion" \
    DEVKIT_RUN_DIR="$ciclo2_dir/run" DEVKIT_WS="$ciclo2_dir/ws" \
    bash "$HERE/devkit-run.sh" --sync '/pr-review 9401' >/dev/null 2>&1
  check "ciclo real con perfil restringido: el doble recibe --permission-mode default" 1 \
    "$(grep -c -- '--permission-mode default' "$ciclo2_dir/claude-llamadas")"
  check "ciclo real con perfil restringido: --allowedTools no trae Edit ni Write" 0 \
    "$(sed -E 's/--disallowedTools.*//' "$ciclo2_dir/claude-llamadas" | grep -c -E '(^| )(Edit|Write)( |$)')"
  check "ciclo real con perfil restringido: --disallowedTools sí niega Edit y Write (H5)" 1 \
    "$(grep -c -E -- '--disallowedTools.*( |^)Edit( |$)' "$ciclo2_dir/claude-llamadas")"
  check "ciclo real con perfil restringido: veredicto OK mueve la card a Lista para merge" 1 \
    "$(grep -c 'card-9401 Estado=Lista para merge' "$ciclo2_dir/set-llamadas" 2>/dev/null)"
  check "ciclo real con perfil restringido: el informe publicado no deja residuo" 1 \
    "$([ -e "$ciclo2_dir/ws/.devkit/review-9401.md" ] && echo 0 || echo 1)"
  check "ciclo real con perfil restringido: toca /run/devkit/poke" 1 \
    "$([ -e "$ciclo2_dir/run/poke" ] && echo 1 || echo 0)"

  # --- run_claude no hereda la tubería de quien lo lanza (DEVKIT-102) --------
  # `watch.sh:1061` recorre los PRs abiertos con `gh pr list | while read -r
  # num url title; do ... done`; dentro de ese `while`, `run_skill` lanza
  # `devkit-run.sh --sync` en segundo plano sin tocar su entrada estándar
  # (watch.sh:530). Sin `</dev/null` en el `claude -p` real de `run_claude`,
  # ese lanzamiento hereda la tubería y se come la fila que le tocaba a la
  # siguiente vuelta del bucle -pasó con la fila de PR #67/DEVKIT-93 mientras
  # se corregía el PR 68/DEVKIT-94-, y esa fila termina pegada al final del
  # prompt real. El doble de abajo copia a un archivo lo que de verdad llega
  # a su entrada estándar: con la tubería reproducida tal cual, ese archivo
  # debe quedar vacío.
  local traga_stdin
  traga_stdin="$tmp/claude-traga-stdin"
  cat >"$traga_stdin" <<FIN
#!/usr/bin/env bash
cat >"$tmp/stdin-recibido" 2>/dev/null
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":1}\n'
FIN
  chmod +x "$traga_stdin"
  : >"$tmp/stdin-recibido"
  printf 'fila-actual\tsim\tsim\nfila-de-otro-pr\thttps://example.com/pull/67\tDEVKIT-93 otro PR\n' | {
    IFS=$'\t' read -r _sim_num _sim_url _sim_title
    DEVKIT_CLAUDE_BIN="$traga_stdin" DEVKIT_ROLES_FILE="$tmp/roles.toml" \
      DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-102" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
      bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-3' >/dev/null 2>&1 &
    wait
  }
  check "el claude -p real no se come la fila que le tocaba al bucle (DEVKIT-102)" "" \
    "$(cat "$tmp/stdin-recibido" 2>/dev/null)"

  # --- review-prep.sh de verdad: worktree y entorno heredado (DEVKIT-93, H1 y
  # H2 de la revisión del PR 67) ---------------------------------------------
  # Los dobles de más arriba nunca tocan gh, Notion ni crean un worktree de
  # verdad: acá se invoca el binario real sobre un PR simulado con un origin
  # local, dos veces seguidas, para probar que un worktree que sobrevive a un
  # ciclo interrumpido no deja el PR sin revisión para siempre (H1); y una
  # tercera vez con las variables que `watch.sh:495` exporta al `--sync`,
  # para probar que no se filtran a las comprobaciones mecánicas (H2).
  local rp_dir rp_head
  rp_dir=$(mktemp -d "$tmp/rp.XXXXXX")
  git init -q --bare "$rp_dir/origin.git"
  git init -q "$rp_dir/ws"
  git -C "$rp_dir/ws" config user.email test@example.com
  git -C "$rp_dir/ws" config user.name test
  git -C "$rp_dir/ws" remote add origin "$rp_dir/origin.git"
  mkdir -p "$rp_dir/ws/.devkit" "$rp_dir/ws/devkit/scripts"
  cat >"$rp_dir/ws/.devkit/devkit.toml" <<'FIN'
project = "DEVKIT"
FIN
  echo "echo real" >"$rp_dir/ws/devkit/scripts/devkit-run.sh"
  git -C "$rp_dir/ws" add -A
  git -C "$rp_dir/ws" commit -q -m init --no-gpg-sign
  git -C "$rp_dir/ws" branch -q -m main
  git -C "$rp_dir/ws" push -q -u origin main
  git -C "$rp_dir/ws" switch -q -c feat/DEVKIT-9302-probar-review-prep
  # Un devkit-run.sh de mentira: falla si `DEVKIT_RONDA` sigue exportada
  # cuando la comprobación mecánica "devkit-run.sh --test" lo corre (para que
  # H2 delate si review-prep.sh no anuló el entorno heredado), o si SIGINT le
  # llega ignorado (para que H8 delate si review-prep.sh no lo restauró antes
  # de encadenar la autoprueba).
  cat >"$rp_dir/ws/devkit/scripts/devkit-run.sh" <<'FIN'
#!/usr/bin/env bash
if [ "${DEVKIT_RONDA:-}" = "-" ]; then
  echo "DEVKIT_RONDA se filtró a la comprobación mecánica" >&2
  exit 1
fi
sigign=$(awk '/^SigIgn:/ {print $2}' /proc/self/status 2>/dev/null)
if [ -n "$sigign" ] && [ $(( 0x$sigign & 2 )) -ne 0 ]; then
  echo "SIGINT llegó ignorado a la comprobación mecánica" >&2
  exit 1
fi
exit 0
FIN
  git -C "$rp_dir/ws" add -A
  git -C "$rp_dir/ws" commit -q -m 'feat(DEVKIT-9302): probar review-prep.sh' --no-gpg-sign
  git -C "$rp_dir/ws" push -q -u origin feat/DEVKIT-9302-probar-review-prep
  rp_head=$(git -C "$rp_dir/ws" rev-parse HEAD)
  git -C "$rp_dir/origin.git" update-ref "refs/pull/9302/head" "$rp_head"
  mkdir -p "$rp_dir/run"
  cat >"$rp_dir/notion-doble" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) printf '{"id":"card-9302","estado":"Revisión automática"}' ;;
  contenido) echo "## Objetivo
Probar review-prep.sh de verdad." ;;
esac
FIN
  chmod +x "$rp_dir/notion-doble"
  cat >"$rp_dir/gh-doble" <<FIN
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view") printf '{"state":"OPEN","title":"DEVKIT-9302: probar review-prep.sh","body":"cuerpo","headRefOid":"$rp_head","headRefName":"feat/DEVKIT-9302-probar-review-prep","reviews":[],"comments":[]}' ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$rp_dir/gh-doble"
  local rp_env=(DEVKIT_WS="$rp_dir/ws" DEVKIT_NOTION_BIN="$rp_dir/notion-doble" DEVKIT_GH_BIN="$rp_dir/gh-doble" \
    DEVKIT_REVIEW_WORKTREE_DIR="$rp_dir/worktrees")

  env "${rp_env[@]}" bash "$HERE/review-prep.sh" 9302 >/dev/null 2>"$rp_dir/salida-1.err"
  check "review-prep.sh de verdad: primera corrida sale con 0" 0 "$?"
  # Sin `review-publish.sh` de por medio (nadie llamó a `git worktree
  # remove`), el worktree queda atascado: el ciclo siguiente vuelve a correr
  # review-prep.sh contra el mismo número de PR, tal como haría `devkit-run`
  # en el siguiente tick.
  env "${rp_env[@]}" bash "$HERE/review-prep.sh" 9302 >"$rp_dir/salida-2.out" 2>"$rp_dir/salida-2.err"
  check "review-prep.sh de verdad: un worktree atascado no bloquea el ciclo siguiente (H1)" 0 "$?"

  env "${rp_env[@]}" DEVKIT_RONDA=- DEVKIT_MODELO_FORZADO=modelo-x DEVKIT_LOCK_HELD=1 DEVKIT_LANZADOR=watch \
    bash "$HERE/review-prep.sh" 9302 >"$rp_dir/salida-3.out" 2>"$rp_dir/salida-3.err"
  check "review-prep.sh de verdad: DEVKIT_RONDA=- no se filtra a devkit-run.sh --test (H2)" 1 \
    "$(grep -c '\*\*devkit-run.sh --test\*\*: Verificado' "$rp_dir/salida-3.out")"

  # `watch.sh:496` lanza su `--sync` con `&` desde un shell no interactivo:
  # SIGINT le llega ignorado a ese job y a todo lo que corre debajo. `trap ''
  # INT` reproduce esa herencia para esta corrida.
  ( trap '' INT
    env "${rp_env[@]}" bash "$HERE/review-prep.sh" 9302 >"$rp_dir/salida-4.out" 2>"$rp_dir/salida-4.err"
  )
  check "review-prep.sh de verdad: SIGINT heredado ignorado no filtra Falla falsos (H8)" 1 \
    "$(grep -c '\*\*devkit-run.sh --test\*\*: Verificado' "$rp_dir/salida-4.out")"

  # --- review-publish.sh de verdad: no confunde un informe distinto con un
  # reintento del mismo (H7 de la revisión del PR 67) -------------------------
  # Caso de DEVKIT-22: el head no cambió y el veredicto se repite (CAMBIOS),
  # pero un informe nuevo trae hallazgos distintos al último publicado -por
  # ejemplo, porque task-fix respondió después de ese informe-. El marcador
  # (sha+verdict) es idéntico al de arriba; solo el cuerpo cambia.
  local rpub_dir
  rpub_dir=$(mktemp -d "$tmp/rpub.XXXXXX")
  cat >"$rpub_dir/informe-nuevo.md" <<'FIN'
<!-- devkit-review sha=abc123 verdict=CAMBIOS -->
Informe nuevo, con hallazgos distintos al anterior.
FIN
  cat >"$rpub_dir/gh-doble" <<'FIN'
#!/usr/bin/env bash
echo "$1 $2" >>"$(dirname "$0")/llamadas"
case "$1 $2" in
  "pr view")
    printf '<!-- devkit-review sha=abc123 verdict=CAMBIOS -->\nInforme anterior, con otros hallazgos.'
    ;;
  *) exit 0 ;;
esac
FIN
  chmod +x "$rpub_dir/gh-doble"
  DEVKIT_WS="$rpub_dir" DEVKIT_GH_BIN="$rpub_dir/gh-doble" \
    bash "$HERE/review-publish.sh" 9303 "$rpub_dir/informe-nuevo.md" >"$rpub_dir/salida.out" 2>"$rpub_dir/salida.err"
  check "review-publish.sh de verdad: publica un informe distinto aunque el marcador se repita (H7)" 1 \
    "$(grep -c '^pr review$' "$rpub_dir/llamadas" 2>/dev/null)"

  # --- review-publish.sh de verdad: `-` lee el informe por stdin, sin que la
  # skill tenga que escribirlo antes (DEVKIT-125, revisión del PR 92, H2) ----
  # El perfil restringido de pr-review no trae `Write`; el heredoc que la
  # skill manda por `stdin` debe llegar igual a `gh pr review` y, con
  # `--conservar`, dejar una copia en `.devkit/review-<N>.md` para depurar.
  local rpub_stdin_dir
  rpub_stdin_dir=$(mktemp -d "$tmp/rpub-stdin.XXXXXX")
  mkdir -p "$rpub_stdin_dir/.devkit" "$rpub_stdin_dir/tmpdir"
  cat >"$rpub_stdin_dir/gh-doble" <<'FIN'
#!/usr/bin/env bash
echo "$1 $2" >>"$(dirname "$0")/llamadas"
case "$1 $2" in
  "pr view") printf '' ;;
  "pr review")
    shift 2
    while [ $# -gt 0 ]; do
      if [ "$1" = --body-file ]; then
        cat "$2" >"$(dirname "$0")/cuerpo-publicado"
        shift
      fi
      shift
    done
    ;;
  *) exit 0 ;;
esac
FIN
  chmod +x "$rpub_stdin_dir/gh-doble"
  DEVKIT_WS="$rpub_stdin_dir" DEVKIT_GH_BIN="$rpub_stdin_dir/gh-doble" TMPDIR="$rpub_stdin_dir/tmpdir" \
    bash "$HERE/review-publish.sh" 9307 - <<'FIN' >"$rpub_stdin_dir/salida.out" 2>"$rpub_stdin_dir/salida.err"
<!-- devkit-review sha=def456 verdict=CAMBIOS -->
Informe recibido por stdin.
FIN
  check "review-publish.sh de verdad: '-' publica el informe recibido por stdin" 1 \
    "$(grep -c 'Informe recibido por stdin' "$rpub_stdin_dir/cuerpo-publicado" 2>/dev/null)"
  check "review-publish.sh de verdad: '-' no deja ningún temporal sin '--conservar'" 0 \
    "$(find "$rpub_stdin_dir/tmpdir" -type f 2>/dev/null | wc -l | tr -d ' ')"
  DEVKIT_WS="$rpub_stdin_dir" DEVKIT_GH_BIN="$rpub_stdin_dir/gh-doble" TMPDIR="$rpub_stdin_dir/tmpdir" \
    bash "$HERE/review-publish.sh" --conservar 9307 - <<'FIN' >/dev/null 2>&1
<!-- devkit-review sha=def456 verdict=CAMBIOS -->
Informe recibido por stdin, con --conservar.
FIN
  check "review-publish.sh de verdad: '-' con --conservar deja una copia en .devkit/review-<N>.md" 1 \
    "$(grep -c 'con --conservar' "$rpub_stdin_dir/.devkit/review-9307.md" 2>/dev/null)"

  # --- review-publish.sh de verdad: "Qué hace" trae el primer párrafo
  # completo de "## Qué cambia", no dos líneas físicas (DEVKIT-115) ----------
  # task-submit.sh envuelve el cuerpo del PR a unos 75 caracteres: un párrafo
  # real ocupa varias líneas físicas. El `head -2` original cortaba a media
  # frase (evidencia del PR 81, comentario del 2026-09-21).
  local rpub2_dir
  rpub2_dir=$(mktemp -d "$tmp/rpub2.XXXXXX")
  mkdir -p "$rpub2_dir/ws/.devkit"
  cat >"$rpub2_dir/informe.md" <<'FIN'
<!-- devkit-review sha=def456 verdict=OK -->
Informe de prueba, todos los criterios verificados.
FIN
  printf '## Qué cambia\nEl caso "sin PR ni rama" del bloque de devkit-run.sh --test aislado\nusaba el workspace real (WS por defecto) para el git for-each-ref de\nramas, en vez de un workspace de prueba propio.\n\n## Cómo probarlo\nN/A\n' \
    >"$rpub2_dir/cuerpo.md"
  jq -Rs --arg titulo "DEVKIT-9305: probar review-publish.sh" '{title: $titulo, body: .}' \
    "$rpub2_dir/cuerpo.md" >"$rpub2_dir/pr-view.json"
  cat >"$rpub2_dir/notion-doble" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) printf '{"id":"card-9305"}' ;;
  set) exit 0 ;;
esac
FIN
  chmod +x "$rpub2_dir/notion-doble"
  cat >"$rpub2_dir/gh-doble" <<FIN
#!/usr/bin/env bash
[ "\$1" = api ] && exit 1
if [ "\$1 \$2" = "pr view" ]; then
  if printf '%s' "\$*" | grep -q reviews; then
    printf '{"reviews":[]}'
  else
    cat "$rpub2_dir/pr-view.json"
  fi
  exit 0
fi
case "\$1 \$2" in
  "pr review") exit 0 ;;
  "pr edit") cat >/dev/null; exit 0 ;;
  "pr comment") cat >"$rpub2_dir/comentario.md"; exit 0 ;;
  *) exit 0 ;;
esac
FIN
  chmod +x "$rpub2_dir/gh-doble"
  DEVKIT_WS="$rpub2_dir/ws" DEVKIT_GH_BIN="$rpub2_dir/gh-doble" DEVKIT_NOTION_BIN="$rpub2_dir/notion-doble" \
    DEVKIT_REVIEW_WORKTREE_DIR="$rpub2_dir/worktrees" DEVKIT_RUN_DIR="$rpub2_dir/run" \
    bash "$HERE/review-publish.sh" 9305 "$rpub2_dir/informe.md" >"$rpub2_dir/salida.out" 2>"$rpub2_dir/salida.err"
  check "review-publish.sh de verdad: \"Qué hace\" trae el párrafo completo de un cuerpo envuelto a 75 columnas (DEVKIT-115)" 1 \
    "$(grep -c 'ramas, en vez de un workspace de prueba propio\.' "$rpub2_dir/comentario.md" 2>/dev/null)"

  # --- review-publish.sh de verdad: párrafo de más de 400 caracteres corta en
  # el último punto seguido, no en el punto de un nombre de archivo (DEVKIT-115,
  # H1) ------------------------------------------------------------------------
  # Antes de esta card, `corte="${limite%.*}"` cortaba en el último punto de
  # cualquier clase. Un párrafo con un nombre de archivo (con su propio punto,
  # sin espacio detrás) después del último punto seguido reproducía el corte a
  # media frase: "...review-publish. (…)". El párrafo de abajo pone ese punto de
  # nombre de archivo dentro de los primeros 400 caracteres, después del único
  # punto seguido real.
  local rpub3_dir
  rpub3_dir=$(mktemp -d "$tmp/rpub3.XXXXXX")
  mkdir -p "$rpub3_dir/ws/.devkit"
  local rpub3_sent1 rpub3_filler1 rpub3_filler2 rpub3_parrafo
  rpub3_sent1="Esta oracion termina aqui de verdad. "
  rpub3_filler1=$(printf 'x%.0s' $(seq 1 300))
  rpub3_filler2=$(printf 'x%.0s' $(seq 1 80))
  rpub3_parrafo="${rpub3_sent1}${rpub3_filler1} review-publish.sh ${rpub3_filler2}"
  printf '## Qué cambia\n%s\n\n## Cómo probarlo\nN/A\n' "$rpub3_parrafo" >"$rpub3_dir/cuerpo.md"
  jq -Rs --arg titulo "DEVKIT-9306: probar el corte de review-publish.sh" '{title: $titulo, body: .}' \
    "$rpub3_dir/cuerpo.md" >"$rpub3_dir/pr-view.json"
  cat >"$rpub3_dir/informe.md" <<'FIN'
<!-- devkit-review sha=cafe123 verdict=OK -->
Informe de prueba, todos los criterios verificados.
FIN
  cat >"$rpub3_dir/notion-doble" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) printf '{"id":"card-9306"}' ;;
  set) exit 0 ;;
esac
FIN
  chmod +x "$rpub3_dir/notion-doble"
  cat >"$rpub3_dir/gh-doble" <<FIN
#!/usr/bin/env bash
[ "\$1" = api ] && exit 1
if [ "\$1 \$2" = "pr view" ]; then
  if printf '%s' "\$*" | grep -q reviews; then
    printf '{"reviews":[]}'
  else
    cat "$rpub3_dir/pr-view.json"
  fi
  exit 0
fi
case "\$1 \$2" in
  "pr review") exit 0 ;;
  "pr edit") cat >/dev/null; exit 0 ;;
  "pr comment") cat >"$rpub3_dir/comentario.md"; exit 0 ;;
  *) exit 0 ;;
esac
FIN
  chmod +x "$rpub3_dir/gh-doble"
  DEVKIT_WS="$rpub3_dir/ws" DEVKIT_GH_BIN="$rpub3_dir/gh-doble" DEVKIT_NOTION_BIN="$rpub3_dir/notion-doble" \
    DEVKIT_REVIEW_WORKTREE_DIR="$rpub3_dir/worktrees" DEVKIT_RUN_DIR="$rpub3_dir/run" \
    bash "$HERE/review-publish.sh" 9306 "$rpub3_dir/informe.md" >"$rpub3_dir/salida.out" 2>"$rpub3_dir/salida.err"
  check "review-publish.sh de verdad: el corte de más de 400 caracteres cae en el último punto seguido (DEVKIT-115, H1)" 1 \
    "$(grep -c 'Esta oracion termina aqui de verdad\. (…)' "$rpub3_dir/comentario.md" 2>/dev/null)"
  check "review-publish.sh de verdad: el corte no cae a mitad del nombre de archivo (DEVKIT-115, H1)" 0 \
    "$(grep -c 'publish\. (…)' "$rpub3_dir/comentario.md" 2>/dev/null)"

  # --- Ciclo limpio: review-publish.sh + task-submit.sh no dejan residuos
  # (DEVKIT-99, H3) -----------------------------------------------------------
  # Un informe de pr-review sin publicar (o publicado y sin borrar) y un
  # `.devkit/pr-body.md` a medio consumir son justo los dos residuos que
  # bloquean la siguiente card en `task-begin.sh`. Reproduce ambos scripts,
  # de verdad y en el mismo workspace, para comprobar que el árbol queda
  # limpio al final del ciclo.
  local ciclo_dir
  ciclo_dir=$(mktemp -d "$tmp/ciclo.XXXXXX")
  git init -q --bare "$ciclo_dir/origin.git"
  git init -q "$ciclo_dir/ws"
  git -C "$ciclo_dir/ws" config user.email test@example.com
  git -C "$ciclo_dir/ws" config user.name test
  git -C "$ciclo_dir/ws" remote add origin "$ciclo_dir/origin.git"
  git -C "$ciclo_dir/ws" commit -q --allow-empty -m init --no-gpg-sign
  git -C "$ciclo_dir/ws" branch -q -m main
  git -C "$ciclo_dir/ws" push -q -u origin main
  git -C "$ciclo_dir/ws" switch -q -c feat/DEVKIT-9304-probar-ciclo-limpio
  git -C "$ciclo_dir/ws" push -q -u origin feat/DEVKIT-9304-probar-ciclo-limpio
  mkdir -p "$ciclo_dir/run" "$ciclo_dir/ws/.devkit"
  cat >"$ciclo_dir/notion-doble" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) printf '{"id":"card-9304","url":"https://notion.so/card9304","estado":"En progreso","titulo":"Probar ciclo limpio"}' ;;
  set) shift; printf '%s\n' "$*" >>"$FAKE_DIR/set-llamadas" ;;
  comentar) shift; printf '%s\n' "$*" >>"$FAKE_DIR/comentar-llamadas" ;;
esac
FIN
  chmod +x "$ciclo_dir/notion-doble"
  cat >"$ciclo_dir/gh-doble" <<'FIN'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") exit 1 ;;
  "pr review") exit 0 ;;
  "pr create")
    cat >/dev/null
    echo "https://github.com/o/r/pull/9304"
    exit 0 ;;
  "pr edit") cat >/dev/null; exit 0 ;;
  "pr merge") exit 0 ;;
  "pr comment") cat >/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$ciclo_dir/gh-doble"
  cat >"$ciclo_dir/ws/.devkit/review-9304.md" <<'FIN'
<!-- devkit-review sha=abc999 verdict=CAMBIOS -->
Informe de prueba, sin hallazgos reales.
FIN
  env DEVKIT_WS="$ciclo_dir/ws" DEVKIT_GH_BIN="$ciclo_dir/gh-doble" \
    DEVKIT_REVIEW_WORKTREE_DIR="$ciclo_dir/worktrees" DEVKIT_RUN_DIR="$ciclo_dir/run" \
    bash "$HERE/review-publish.sh" 9304 "$ciclo_dir/ws/.devkit/review-9304.md" >/dev/null 2>&1
  check "ciclo limpio: review-publish.sh borra el informe" 1 \
    "$([ -e "$ciclo_dir/ws/.devkit/review-9304.md" ] && echo 0 || echo 1)"
  # DEVKIT-108: último paso, como en task-submit.sh, para que watch.sh no
  # espere el resto del intervalo cuando un humano corre pr-review a mano.
  check "ciclo limpio: review-publish.sh toca /run/devkit/poke" 1 \
    "$([ -e "$ciclo_dir/run/poke" ] && echo 1 || echo 0)"

  cat >"$ciclo_dir/ws/.devkit/pr-body.md" <<'FIN'
## Qué cambia
Probar que el ciclo no deja residuos.

## Cómo probarlo
N/A

## Cambios requeridos
Ninguno.
FIN
  echo "cambio de prueba" >"$ciclo_dir/ws/archivo.txt"
  env FAKE_DIR="$ciclo_dir" DEVKIT_WS="$ciclo_dir/ws" DEVKIT_RUN_DIR="$ciclo_dir/run" \
    DEVKIT_NOTION_BIN="$ciclo_dir/notion-doble" DEVKIT_GH_BIN="$ciclo_dir/gh-doble" \
    bash "$HERE/task-submit.sh" --mensaje "feat(DEVKIT-9304): probar ciclo limpio" >/dev/null 2>&1
  check "ciclo limpio: task-submit.sh sale con 0" 0 "$?"
  check "ciclo limpio: git status --porcelain queda vacío tras el ciclo completo" "" \
    "$(git -C "$ciclo_dir/ws" status --porcelain)"

  # --- fix-publish.sh: guarda mecánica del paso 8 de task-fix (DEVKIT-102) ---
  # Compara cada id de la respuesta contra los `H<n>` del informe CAMBIOS que
  # declara atender (`review=` del propio marcador). El caso real del PR 68
  # (DEVKIT-94): la respuesta solo traía "C1", que no está entre los
  # hallazgos del informe -debía abortar en vez de publicarse.
  local fp_dir
  fp_dir=$(mktemp -d "$tmp/fp.XXXXXX")
  cat >"$fp_dir/gh-doble" <<'FIN'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/llamadas"
campo="" prev="" con_jq=0
for a in "$@"; do
  [ "$a" = --jq ] && con_jq=1
  [ "$prev" = --json ] && campo=$a
  prev=$a
done
case "$1 $2" in
  "pr view")
    case "$campo" in
      reviews)
        printf '{"reviews":[{"submittedAt":"2026-01-01T00:00:00Z","body":"<!-- devkit-review sha=abc123 verdict=CAMBIOS -->\\nInforme.\\n<!-- devkit-findings -->\\nH1 | alta | a.sh:1 | falla algo | arreglarlo\\nH2 | media | b.sh:2 | falla otra cosa | arreglarla\\n<!-- /devkit-findings -->"}]}'
        ;;
      comments) [ "$con_jq" = 1 ] && echo "" || echo '{"comments":[]}' ;;
      title) [ "$con_jq" = 1 ] && echo "DEVKIT-9305: probar fix-publish" || echo '{"title":"DEVKIT-9305: probar fix-publish"}' ;;
      *) exit 1 ;;
    esac
    ;;
  "pr comment") cat >/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$fp_dir/gh-doble"
  cat >"$fp_dir/notion-doble" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) printf '{"id":"card-9305"}' ;;
  comentar) shift 2; printf '%s\n' "$*" >>"$(dirname "$0")/comentario" ;;
esac
FIN
  chmod +x "$fp_dir/notion-doble"
  local fp_env=(DEVKIT_GH_BIN="$fp_dir/gh-doble" DEVKIT_NOTION_BIN="$fp_dir/notion-doble" \
    DEVKIT_RUN_DIR="$fp_dir/run" DEVKIT_WATCH_LOG="$fp_dir/run/watch.log")
  mkdir -p "$fp_dir/run"

  cat >"$fp_dir/respuesta-c1.md" <<'FIN'
<!-- devkit-fix sha=def456 review=abc123 -->
<!-- devkit-fixes -->
C1 | descartado | hace referencia al PR #67, no a este PR
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir/llamadas"
  env "${fp_env[@]}" bash "$HERE/fix-publish.sh" 9305 "$fp_dir/respuesta-c1.md" >"$fp_dir/salida-c1.out" 2>"$fp_dir/salida-c1.err"
  check "fix-publish.sh: un id ausente del informe aborta (rc)" 1 "$?"
  check "fix-publish.sh: un id ausente no llega a comentar en el PR" 0 \
    "$(grep -c '^pr comment' "$fp_dir/llamadas")"
  check "fix-publish.sh: el motivo nombra el id y el sha del informe" 1 \
    "$(cat "$fp_dir/salida-c1.out" "$fp_dir/salida-c1.err" | grep -c 'C1.*no está entre los hallazgos.*abc123')"
  check "fix-publish.sh: el motivo queda en watch.log como ALARMA" 1 \
    "$(grep -c 'ALARMA: fix-publish PR #9305 aborta' "$fp_dir/run/watch.log")"
  check "fix-publish.sh: el motivo queda comentado en la card" 1 \
    "$(grep -c 'fix-publish: la respuesta trae' "$fp_dir/comentario" 2>/dev/null)"
  check "fix-publish.sh: borra el archivo de respuesta aunque aborte (mismo criterio que DEVKIT-99)" 1 \
    "$([ -e "$fp_dir/respuesta-c1.md" ] && echo 0 || echo 1)"

  cat >"$fp_dir/respuesta-h.md" <<'FIN'
<!-- devkit-fix sha=def789 review=abc123 -->
<!-- devkit-fixes -->
H1 | atendido | def789
H2 | descartado | fuera de alcance
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir/llamadas"
  env "${fp_env[@]}" bash "$HERE/fix-publish.sh" 9305 "$fp_dir/respuesta-h.md" >"$fp_dir/salida-h.out" 2>"$fp_dir/salida-h.err"
  check "fix-publish.sh: todos los ids en el informe, publica (rc)" 0 "$?"
  check "fix-publish.sh: todos los ids en el informe, llama a pr comment" 1 \
    "$(grep -c '^pr comment' "$fp_dir/llamadas")"

  # Respuesta a un comentario humano: `review=` es el headRefOid leído en el
  # paso 2, no el sha de un informe CAMBIOS. Sin informe que coincida, no hay
  # `devkit-findings` que cumplir y un C<n> se publica sin más (paso 3,
  # tercera viñeta de task-fix/SKILL.md).
  cat >"$fp_dir/respuesta-humano.md" <<'FIN'
<!-- devkit-fix sha=def999 review=cafe00 manual=1 -->
<!-- devkit-fixes -->
C1 | atendido | def999
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir/llamadas"
  env "${fp_env[@]}" bash "$HERE/fix-publish.sh" 9305 "$fp_dir/respuesta-humano.md" >"$fp_dir/salida-humano.out" 2>"$fp_dir/salida-humano.err"
  check "fix-publish.sh: respuesta a comentario humano, sin informe que comparar, publica (rc)" 0 "$?"
  check "fix-publish.sh: respuesta a comentario humano, llama a pr comment" 1 \
    "$(grep -c '^pr comment' "$fp_dir/llamadas")"

  # `review=` con un sha corto (prefijo de abc123): no cuela, aunque el id sea
  # válido. La comparación es carácter a carácter, sin aceptar prefijos.
  cat >"$fp_dir/respuesta-sha-corto.md" <<'FIN'
<!-- devkit-fix sha=defaaa review=abc12 -->
<!-- devkit-fixes -->
H1 | atendido | defaaa
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir/llamadas"
  env "${fp_env[@]}" bash "$HERE/fix-publish.sh" 9305 "$fp_dir/respuesta-sha-corto.md" >"$fp_dir/salida-sha-corto.out" 2>"$fp_dir/salida-sha-corto.err"
  check "fix-publish.sh: sha corto en review= aborta (rc)" 1 "$?"
  check "fix-publish.sh: sha corto en review= no llega a comentar en el PR" 0 \
    "$(grep -c '^pr comment' "$fp_dir/llamadas")"

  # `review=` con el sha del head nuevo (el que declara `sha=`), no el del
  # último informe: tampoco cuela.
  cat >"$fp_dir/respuesta-head-nuevo.md" <<'FIN'
<!-- devkit-fix sha=def456 review=def456 -->
<!-- devkit-fixes -->
H1 | atendido | def456
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir/llamadas"
  env "${fp_env[@]}" bash "$HERE/fix-publish.sh" 9305 "$fp_dir/respuesta-head-nuevo.md" >"$fp_dir/salida-head-nuevo.out" 2>"$fp_dir/salida-head-nuevo.err"
  check "fix-publish.sh: review=head nuevo aborta (rc)" 1 "$?"
  check "fix-publish.sh: review=head nuevo no llega a comentar en el PR" 0 \
    "$(grep -c '^pr comment' "$fp_dir/llamadas")"

  # Sin bloque devkit-fixes: nada que publicar, aborta en vez de comentar un
  # cuerpo vacío.
  cat >"$fp_dir/respuesta-sin-bloque.md" <<'FIN'
<!-- devkit-fix sha=defbbb review=abc123 -->
Sin hallazgos que reportar.
FIN
  : >"$fp_dir/llamadas"
  env "${fp_env[@]}" bash "$HERE/fix-publish.sh" 9305 "$fp_dir/respuesta-sin-bloque.md" >"$fp_dir/salida-sin-bloque.out" 2>"$fp_dir/salida-sin-bloque.err"
  check "fix-publish.sh: sin bloque devkit-fixes aborta (rc)" 1 "$?"
  check "fix-publish.sh: sin bloque devkit-fixes no llega a comentar en el PR" 0 \
    "$(grep -c '^pr comment' "$fp_dir/llamadas")"

  # Un informe CAMBIOS seguido de un OK sobre el mismo sha (respuesta sin
  # push, DEVKIT-22): el último marcador es el OK, así que una respuesta a un
  # comentario humano sobre ese mismo sha publica sin comparar contra el
  # CAMBIOS viejo (antes era un falso positivo: DEVKIT-102, H3).
  local fp_dir2
  fp_dir2=$(mktemp -d "$tmp/fp2.XXXXXX")
  cat >"$fp_dir2/gh-doble" <<'FIN'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/llamadas"
campo="" prev="" con_jq=0
for a in "$@"; do
  [ "$a" = --jq ] && con_jq=1
  [ "$prev" = --json ] && campo=$a
  prev=$a
done
case "$1 $2" in
  "pr view")
    case "$campo" in
      reviews)
        printf '{"reviews":[{"submittedAt":"2026-01-01T00:00:00Z","body":"<!-- devkit-review sha=abc123 verdict=CAMBIOS -->\\nInforme.\\n<!-- devkit-findings -->\\nH1 | alta | a.sh:1 | falla algo | arreglarlo\\n<!-- /devkit-findings -->"},{"submittedAt":"2026-01-01T00:05:00Z","body":"<!-- devkit-review sha=abc123 verdict=OK -->\\nRevisado tras una respuesta sin push."}]}'
        ;;
      comments) [ "$con_jq" = 1 ] && echo "" || echo '{"comments":[]}' ;;
      title) [ "$con_jq" = 1 ] && echo "DEVKIT-9306: probar fix-publish CAMBIOS+OK" || echo '{"title":"DEVKIT-9306: probar fix-publish CAMBIOS+OK"}' ;;
      *) exit 1 ;;
    esac
    ;;
  "pr comment") cat >/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$fp_dir2/gh-doble"
  local fp_env2=(DEVKIT_GH_BIN="$fp_dir2/gh-doble" DEVKIT_NOTION_BIN="$fp_dir/notion-doble" \
    DEVKIT_RUN_DIR="$fp_dir2/run" DEVKIT_WATCH_LOG="$fp_dir2/run/watch.log")
  mkdir -p "$fp_dir2/run"
  cat >"$fp_dir2/respuesta-cambios-ok.md" <<'FIN'
<!-- devkit-fix sha=def777 review=abc123 manual=1 -->
<!-- devkit-fixes -->
C1 | atendido | def777
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir2/llamadas"
  env "${fp_env2[@]}" bash "$HERE/fix-publish.sh" 9306 "$fp_dir2/respuesta-cambios-ok.md" >"$fp_dir2/salida.out" 2>"$fp_dir2/salida.err"
  check "fix-publish.sh: último informe OK tras un CAMBIOS en el mismo sha, publica (rc)" 0 "$?"
  check "fix-publish.sh: último informe OK tras un CAMBIOS en el mismo sha, llama a pr comment" 1 \
    "$(grep -c '^pr comment' "$fp_dir2/llamadas")"

  # `fix-humano` (watch.sh) lanza task-fix sin `manual=1` cuando el último
  # informe sigue en CAMBIOS: una respuesta que solo trae `C<n>` no tiene
  # `devkit-findings` que cumplir si responde a un comentario humano genuino
  # posterior al corte (mismo criterio que `$human` en `decide`), aunque no
  # lleve `manual=1` (DEVKIT-102, H5). Sin ese comentario -el caso del PR
  # 68- sigue abortando.
  local fp_dir3
  fp_dir3=$(mktemp -d "$tmp/fp3.XXXXXX")
  cat >"$fp_dir3/gh-doble" <<'FIN'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/llamadas"
campo="" prev="" con_jq=0
for a in "$@"; do
  [ "$a" = --jq ] && con_jq=1
  [ "$prev" = --json ] && campo=$a
  prev=$a
done
case "$1 $2" in
  "api user") [ "$con_jq" = 1 ] && echo "bot-ci" || echo '{"login":"bot-ci"}' ;;
  "pr view")
    case "$campo" in
      reviews)
        printf '{"reviews":[{"submittedAt":"2026-01-01T00:00:00Z","state":"COMMENTED","author":{"login":"bot-ci"},"body":"<!-- devkit-review sha=abc123 verdict=CAMBIOS -->\\nInforme.\\n<!-- devkit-findings -->\\nH1 | alta | a.sh:1 | falla algo | arreglarlo\\n<!-- /devkit-findings -->"}]}'
        ;;
      comments)
        if [ -e "$(dirname "$0")/con-humano" ]; then
          if [ "$con_jq" = 1 ]; then
            echo ""
          else
            printf '{"comments":[{"createdAt":"2026-01-01T01:00:00Z","author":{"login":"humano-x"},"body":"Por favor revisen esto de nuevo."}]}'
          fi
        else
          [ "$con_jq" = 1 ] && echo "" || echo '{"comments":[]}'
        fi
        ;;
      title) [ "$con_jq" = 1 ] && echo "DEVKIT-9307: probar fix-publish comentario humano" || echo '{"title":"DEVKIT-9307: probar fix-publish comentario humano"}' ;;
      *) exit 1 ;;
    esac
    ;;
  "pr comment") cat >/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$fp_dir3/gh-doble"
  local fp_env3=(DEVKIT_GH_BIN="$fp_dir3/gh-doble" DEVKIT_NOTION_BIN="$fp_dir/notion-doble" \
    DEVKIT_RUN_DIR="$fp_dir3/run" DEVKIT_WATCH_LOG="$fp_dir3/run/watch.log")
  mkdir -p "$fp_dir3/run"

  cat >"$fp_dir3/respuesta-humano-sin-manual.md" <<'FIN'
<!-- devkit-fix sha=defccc review=abc123 -->
<!-- devkit-fixes -->
C1 | atendido | defccc
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir3/llamadas"
  env "${fp_env3[@]}" bash "$HERE/fix-publish.sh" 9307 "$fp_dir3/respuesta-humano-sin-manual.md" \
    >"$fp_dir3/salida-sin-humano.out" 2>"$fp_dir3/salida-sin-humano.err"
  check "fix-publish.sh: C1 sin manual=1 y sin comentario humano, aborta (rc)" 1 "$?"
  check "fix-publish.sh: C1 sin manual=1 y sin comentario humano, no llega a comentar en el PR" 0 \
    "$(grep -c '^pr comment' "$fp_dir3/llamadas")"

  touch "$fp_dir3/con-humano"
  cat >"$fp_dir3/respuesta-humano-sin-manual.md" <<'FIN'
<!-- devkit-fix sha=defccc review=abc123 -->
<!-- devkit-fixes -->
C1 | atendido | defccc
<!-- /devkit-fixes -->
FIN
  : >"$fp_dir3/llamadas"
  env "${fp_env3[@]}" bash "$HERE/fix-publish.sh" 9307 "$fp_dir3/respuesta-humano-sin-manual.md" \
    >"$fp_dir3/salida-con-humano.out" 2>"$fp_dir3/salida-con-humano.err"
  check "fix-publish.sh: C1 sin manual=1 pero con comentario humano posterior, publica (rc)" 0 "$?"
  check "fix-publish.sh: C1 sin manual=1 pero con comentario humano posterior, llama a pr comment" 1 \
    "$(grep -c '^pr comment' "$fp_dir3/llamadas")"

  # --- Escalera de modelos por ronda (DEVKIT-61) ----------------------------
  # Tres rondas con modelo y esfuerzo distintos, para que cada ronda se vea en
  # la salida. La ronda de task-fix es 1 más los comentarios devkit-fix del PR.
  cat >"$tmp/roles-rondas.toml" <<'FIN'
frontera = ["modelo-fuerte", "modelo-medio", "modelo-barato"]
implementacion.model_index = 2
implementacion.effort = "low"
implementacion.max_turns = 40
implementacion.rondas = ["modelo-barato:low", "modelo-medio:medium", "modelo-fuerte:high"]  # experimento
revision.model_index = 1
revision.effort = "high"
revision.max_turns = 50
revision.rondas = ["modelo-barato:low"]
FIN
  # prs_con <n>: el PR de la card trae n comentarios devkit-fix y uno ajeno.
  prs_con() {
    local i c='{"body":"<!-- devkit-review sha=a1 verdict=CAMBIOS -->"}'
    for ((i = 0; i < $1; i++)); do c="$c,{\"body\":\"<!-- devkit-fix sha=b$i review=a$i -->\\nH1 | atendido\"}"; done
    printf '{"comments":[%s]}' "$c" >"$RONDA_DIR/pr-view.json"
  }
  ronda_env() {  # ronda_env <función> <args...>, con la tabla de rondas
    CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-rondas.toml" FRONTERA_CACHE_DIR="$tmp/frontera-rondas" \
      WATCH_LOG="$tmp/rondas-watch.log" WS="$tmp/ronda-ws" "$@"
  }
  printf '{"pr":"https://github.com/o/r/pull/7","rama":"https://github.com/o/r/tree/feat/DEVKIT-7-algo"}' \
    >"$RONDA_DIR/card-DEVKIT-7.json"
  : >"$tmp/rondas-watch.log"
  prs_con 0
  check "ronda 1: task-fix sin devkit-fix previos" "modelo-barato low 40 1" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  prs_con 1
  check "ronda 2: un devkit-fix previo" "modelo-medio medium 40 2" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  prs_con 2
  check "ronda 3: dos devkit-fix previos" "modelo-fuerte high 40 3" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  prs_con 3
  check "ronda 4 repite el último elemento de la lista" "modelo-fuerte high 40 4" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  # task-document ya no escala por ronda (DEVKIT-83, DEVKIT-92): siempre es
  # la ronda 1, así que siempre le toca el primer elemento de la lista, sin
  # importar cuántos devkit-fix tenga el PR.
  check "task-document no escala: siempre ronda 1" "modelo-barato low 40 1" \
    "$(ronda_env model_effort_of '/task-document DEVKIT-7 7')"
  : >"$RONDA_DIR/gh-llamadas"
  check "task-start es ronda 1 sin consultar el PR" "modelo-barato low 40 1 0" \
    "$(ronda_env model_effort_of '/task-start DEVKIT-7') $(wc -l <"$RONDA_DIR/gh-llamadas" | tr -d ' ')"
  check "task-submit es ronda 1" "modelo-barato low 40 1" \
    "$(ronda_env model_effort_of '/task-submit DEVKIT-7')"
  check "ronda ya resuelta: no consulta el PR" "modelo-medio medium 40 2 0" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7' 2) $(wc -l <"$RONDA_DIR/gh-llamadas" | tr -d ' ')"
  # Sin URL del PR en Notion: gh pr list --head <rama de la card>.
  printf '{"pr":null,"rama":"https://github.com/o/r/tree/feat/DEVKIT-8-otra"}' >"$RONDA_DIR/card-DEVKIT-8.json"
  printf '[{"number":8}]' >"$RONDA_DIR/pr-list.json"
  prs_con 1
  check "sin PR en Notion lo busca por la rama" "modelo-medio medium 40 2" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-8')"
  check "gh pr list recibe la rama de la card" "pr list --head feat/DEVKIT-8-otra --state all --limit 1 --json number" \
    "$(grep '^pr list' "$RONDA_DIR/gh-llamadas" | tail -1)"
  # PR ilegible: ronda 1 y la línea en watch.log.
  rm -f "$RONDA_DIR/pr-view.json"
  check "PR ilegible: ronda 1" "modelo-barato low 40 1" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-7')"
  check "PR ilegible: lo dice en watch.log" "no pude leer los comentarios del PR https://github.com/o/r/pull/7 de DEVKIT-7; uso la ronda 1" \
    "$(grep -oE 'no pude leer los comentarios del PR .*' "$tmp/rondas-watch.log" | tail -1)"
  check "card sin PR ni rama: ronda 1 con aviso" "modelo-barato low 40 1 1" \
    "$(ronda_env model_effort_of '/task-fix DEVKIT-99') $(grep -c 'no encuentro el PR de DEVKIT-99' "$tmp/rondas-watch.log")"
  # El alias de la ronda pasa por la sonda: si no responde, model_index.
  mkdir -p "$tmp/frontera-rondas-caida"
  printf 'si' >"$tmp/frontera-rondas-caida/modelo-medio"
  printf 'no' >"$tmp/frontera-rondas-caida/modelo-fuerte"
  prs_con 2
  check "alias de la ronda caído: usa el de model_index" "modelo-medio high 40 3" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles-rondas.toml" FRONTERA_CACHE_DIR="$tmp/frontera-rondas-caida" \
       WATCH_LOG="$tmp/rondas-watch.log" MODEL_RETRY=600 model_effort_of '/task-fix DEVKIT-7')"
  check "alias de la ronda caído: lo dice en watch.log" "ronda 3 pide modelo-fuerte, que no responde; uso modelo-medio (model_index del rol)" \
    "$(grep -oE 'ronda 3 pide modelo-fuerte.*' "$tmp/rondas-watch.log" | tail -1)"
  # El revisor no escala: revision.rondas se ignora con una línea.
  : >"$tmp/rondas-watch.log"
  check "revisión ignora sus rondas" "modelo-fuerte high 50 -" \
    "$(ronda_env model_effort_of '/pr-review 7')"
  printf 'epic-plan.effort = "max"\n' >>"$tmp/roles-rondas.toml"
  check "epic-plan ignora las rondas y sube a max" "modelo-fuerte max 50 -" \
    "$(ronda_env model_effort_of '/epic-plan DEVKIT-1')"
  check "revision.rondas ignorada queda en watch.log" 2 \
    "$(grep -c 'revision.rondas se ignora; el revisor no escala' "$tmp/rondas-watch.log")"
  # Sin rondas, model_index y effort del rol, como antes (tabla de arriba),
  # aunque el PR vaya por la ronda 3: la ronda solo queda anotada.
  check "sin rondas manda model_index" "modelo-barato low 15 3" \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-fix" WATCH_LOG="$tmp/sonda-watch.log" model_effort_of '/task-fix DEVKIT-7')"
  printf '{"result":"x","total_cost_usd":0.5,"num_turns":1}\n' >"$tmp/resumen-ronda.log"
  check "la línea de resumen lleva ronda= junto a modelo= y esfuerzo=" "modelo=modelo-fuerte esfuerzo=high ronda=3 costo=0.5" \
    "$(resumen "$tmp/resumen-ronda.log" modelo-fuerte high 99 3 | grep -oE '^modelo=[^ ]+ esfuerzo=[^ ]+ ronda=[^ ]+ costo=[0-9.]+')"
  check "--resumen por línea de comandos pasa la ronda (lo usa watch.sh)" "modelo=m esfuerzo=e ronda=2" \
    "$(bash "$HERE/devkit-run.sh" --resumen "$tmp/resumen-ronda.log" m e 99 2 | grep -oE '^modelo=[^ ]+ esfuerzo=[^ ]+ ronda=[^ ]+')"
  check "resumen sin ronda (watch.sh viejo) escribe ronda=-" "modelo=m esfuerzo=e ronda=-" \
    "$(resumen "$tmp/resumen-ronda.log" m e 99 | grep -oE '^modelo=[^ ]+ esfuerzo=[^ ]+ ronda=[^ ]+')"
  # --modelo y --esfuerzo mandan sobre la ronda, de punta a punta.
  mkdir -p "$tmp/run-rondas"
  : >"$tmp/run-rondas/ready"
  DEVKIT_ARRANQUE_ESPERA=1 DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run-rondas" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles-rondas.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-rondas" \
    bash "$HERE/devkit-run.sh" --modelo modelo-a-mano --esfuerzo max task-fix DEVKIT-7 >/dev/null 2>&1
  espera_linea() {  # espera_linea <archivo> <patrón>
    local e=0
    while ! grep -qE "$2" "$1" 2>/dev/null && [ "$e" -lt 50 ]; do sleep 0.1; e=$((e + 1)); done
  }
  espera_linea "$tmp/run-rondas/watch.log" 'terminado \['
  check "--modelo/--esfuerzo mandan sobre la ronda" "modelo=modelo-a-mano esfuerzo=max ronda=3" \
    "$(grep -oE 'modelo=modelo-a-mano esfuerzo=max ronda=[0-9-]+' "$tmp/run-rondas/watch.log" | head -1)"
  # DEVKIT_MODELO_FORZADO pisa el modelo de la ronda; el esfuerzo de la ronda
  # se mantiene.
  cat >"$tmp/claude-espejo-ronda" <<'FIN'
#!/usr/bin/env bash
case "$*" in *"-p ok"*) printf '{"result":"ok"}\n'; exit 0 ;; esac
printf '{"result":"%s %s","total_cost_usd":0,"num_turns":1}\n' "$DEVKIT_MODEL" "$DEVKIT_EFFORT"
FIN
  chmod +x "$tmp/claude-espejo-ronda"
  check "DEVKIT_MODELO_FORZADO manda sobre la ronda" '{"result":"modelo-forzado high","total_cost_usd":0,"num_turns":1}' \
    "$(DEVKIT_MODELO_FORZADO=modelo-forzado DEVKIT_CLAUDE_BIN="$tmp/claude-espejo-ronda" DEVKIT_RUN_DIR="$tmp/run-rondas" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles-rondas.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-rondas" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-7' 2>/dev/null | tail -1)"

  # --worker de punta a punta, con el mismo doble de arriba.
  mkdir -p "$tmp/run"
  # Arranque terminado y confirmación corta (DEVKIT-57): sin el marcador, cada
  # lanzamiento de abajo esperaría 120 s; con 5 s de confirmación, la cadena
  # epic-plan -> task-start no cabe en su tope de espera.
  : >"$tmp/run/ready"
  export DEVKIT_ARRANQUE_ESPERA=1
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" --worker '/task-document DEVKIT-2' "$tmp/run/task-document-1.log" \
      modelo-barato low 15 >/dev/null 2>&1
  check "worker deja el log de claude" 'listo' \
    "$(jq -r .result "$tmp/run/task-document-1.log" 2>/dev/null)"
  check "worker agrega el resumen a watch.log" 'modelo=modelo-barato esfuerzo=low' \
    "$(grep -oE 'modelo=modelo-barato esfuerzo=low' "$tmp/run/watch.log" 2>/dev/null | head -1)"

  # Lanzamiento en segundo plano: vuelve enseguida y numera el log si ya
  # existe uno para la misma skill.
  : >"$tmp/run/pr-review-1.log"
  local antes despues rc espera=0
  antes=$(date +%s%N)
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" pr-review DEVKIT-2 >/dev/null 2>&1
  rc=$?
  despues=$(date +%s%N)
  check "el lanzamiento en segundo plano no espera al claude de mentira" 0 "$rc"
  if [ $(( (despues - antes) / 1000000 )) -lt 2000 ]; then
    printf 'ok   %-58s %s\n' "vuelve enseguida (< 2s)" "sí"
  else
    printf 'FAIL %-58s tardó %sms\n' "vuelve enseguida (< 2s)" "$(( (despues - antes) / 1000000 ))"
    fail=1
  fi
  # El worker corre en segundo plano (nohup): se espera a que aparezca el
  # log, con tope, en vez de comprobar justo después de volver.
  while [ ! -e "$tmp/run/pr-review-2.log" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "numera el log siguiente en vez de pisar el existente" 1 \
    "$([ -e "$tmp/run/pr-review-2.log" ] && echo 1 || echo 0)"

  # El candado: con skill.lock tomado, --worker espera y avisa en vez de
  # correr en paralelo con lo que sea que lo tiene (DEVKIT-27: dos agentes
  # sobre el mismo workspace se pisarían la rama).
  (
    exec 9>"$tmp/run/skill.lock"
    flock 9
    sleep 0.6
  ) &
  local tenedor=$!
  sleep 0.1  # deja que el subshell de arriba tome el candado primero
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" --worker '/task-document DEVKIT-2' "$tmp/run/candado.log" \
      modelo-barato low 15 >/dev/null 2>&1
  wait "$tenedor" 2>/dev/null
  check "espera el candado en vez de correr en paralelo" \
    "espera: otra skill ocupa el workspace" \
    "$(grep -oE 'espera: otra skill ocupa el workspace' "$tmp/run/watch.log" | head -1)"

  # El resumen avisa cuando se pasa del presupuesto de turnos.
  printf '{"result":"listo","total_cost_usd":0.5,"num_turns":99}\n' >"$tmp/exceso.log"
  check "avisa cuando se excede el presupuesto de turnos" 'excede el presupuesto de 15 turnos' \
    "$(resumen "$tmp/exceso.log" modelo-x low 15 | grep -oE 'excede el presupuesto de 15 turnos')"

  # Cadena epic-plan -> task-start (DEVKIT-50): el doble de claude, al ver un
  # prompt de epic-plan, lanza a su vez devkit-run task-start con el mismo
  # entorno de prueba, imitando lo que hace la skill al arrancar la primera
  # hija. Debe quedar en watch.log un resumen por cada rol (revisión para
  # epic-plan, implementación para task-start). Hasta DEVKIT-55 la cadena
  # salía de task-close, que ahora es bash y se prueba en watch-test.sh.
  git -C "$tmp" init -q
  git -C "$tmp" commit -q --allow-empty -m init --no-gpg-sign
  git -C "$tmp" checkout -q -b feat/DEVKIT-3-algo
  local cadena
  cadena="$tmp/claude-cadena"
  cat >"$cadena" <<FIN
#!/usr/bin/env bash
case "\$2" in
  */epic-plan*)
    DEVKIT_CLAUDE_BIN="$cadena" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \\
      DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \\
      DEVKIT_TASK_BEGIN_BIN="$tmp/task-begin-doble" \\
      bash "$HERE/devkit-run.sh" task-start DEVKIT-3 >/dev/null 2>&1
    ;;
esac
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$cadena"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$cadena" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" epic-plan DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ "$(grep -cE 'devkit-run "/(epic-plan|task-start)' "$tmp/run/watch.log" 2>/dev/null)" -lt 2 ] \
        && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "cadena epic-plan -> task-start: dos resúmenes con roles distintos" 2 \
    "$(grep -oE 'modelo=(modelo-barato|modelo-fuerte)' "$tmp/run/watch.log" | sort -u | wc -l | tr -d ' ')"

  # Anulación manual: --modelo/--esfuerzo pisan el rol resuelto y la línea de
  # resumen lo marca, sin comparar contra el presupuesto de roles.toml.
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" --modelo modelo-a-mano --esfuerzo high task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/run/task-fix-1.log" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "anulación manual usa el modelo y esfuerzo pedidos" 'modelo=modelo-a-mano esfuerzo=high' \
    "$(grep -oE 'modelo=modelo-a-mano esfuerzo=high' "$tmp/run/watch.log" | head -1)"
  check "anulación manual queda marcada en el resumen" 'anulación manual' \
    "$(grep -oE 'anulación manual' "$tmp/run/watch.log" | head -1)"

  # DEVKIT-77: `pregunta_abierta` reconoce más formas que "termina en ?". El
  # incidente real de DEVKIT-63 cerraba con "antes de decidir.", sin "?" al
  # final, y la regla original de DEVKIT-50 no lo veía.
  check "pregunta_abierta: regla original, termina en ?" si \
    "$(pregunta_abierta '¿qué credencial uso?' && echo si || echo no)"
  check "pregunta_abierta: un cierre normal no dispara la barrera" no \
    "$(pregunta_abierta 'Completé DEVKIT-40: cambios en el Dockerfile y las notas de la versión. PR #25 abierto y en Revisión automática.' && echo si || echo no)"
  local resultado_linea resultado_frase resultado_opciones
  resultado_linea=$'Reuní el contexto necesario.\n\n¿Prefieres que continúe con el plan A o el plan B?\nDime cuál y sigo enseguida.'
  check "pregunta_abierta: línea que empieza por ¿ en el último párrafo, sin terminar en ?" si \
    "$(pregunta_abierta "$resultado_linea" && echo si || echo no)"
  resultado_frase="Terminé de revisar el conflicto. ¿Cómo quieres que siga? Antes de tocar nada, prefiero confirmarlo contigo."
  check "pregunta_abierta: frase fija ¿Cómo quieres que siga, sin terminar en ?" si \
    "$(pregunta_abierta "$resultado_frase" && echo si || echo no)"
  resultado_opciones=$'Quedan tres caminos posibles antes de seguir.\nOpciones:\n1. Seguir de todas formas\n2. Esperar al humano\n3. Bloquear la card\nAvísame antes de decidir.'
  check "pregunta_abierta: Opciones: con líneas numeradas, sin terminar en ?" si \
    "$(pregunta_abierta "$resultado_opciones" && echo si || echo no)"

  # Barrera mecánica DEVKIT-50/DEVKIT-44: un result que termina en pregunta
  # bloquea la card con task-block.sh (DEVKIT-55). Un doble del script anota
  # los argumentos que recibe, así la prueba no toca Notion.
  local pregunton bloqueo
  pregunton="$tmp/claude-pregunton"
  cat >"$pregunton" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"¿qué credencial uso?","total_cost_usd":0.01,"num_turns":2}\n'
FIN
  chmod +x "$pregunton"
  bloqueo="$tmp/task-block-doble"
  printf '#!/usr/bin/env bash\nprintf "%%s|" "$@" >"%s/bloqueo.args"\n' "$tmp" >"$bloqueo"
  chmod +x "$bloqueo"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$pregunton" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/bloqueo.args" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "pregunta abierta bloquea la card con task-block.sh" 'bloquea la card con task-block.sh: DEVKIT-3' \
    "$(grep -oE 'bloquea la card con task-block.sh: DEVKIT-3' "$tmp/run/watch.log" | head -1)"
  check "task-block.sh recibe la Clave como primer argumento" 'DEVKIT-3' \
    "$(cut -d'|' -f1 "$tmp/bloqueo.args" 2>/dev/null)"
  check "el motivo de la pregunta abierta la nombra" 'pregunta abierta' \
    "$(cut -d'|' -f2 "$tmp/bloqueo.args" 2>/dev/null | grep -oE 'pregunta abierta|sin acceso a Notion' | head -1)"

  # DEVKIT-77, extremo a extremo: el texto real del incidente de DEVKIT-63
  # ("¿Cómo quieres que siga? Opciones: 1. [...] 2. [...] 3. [...] antes de
  # decidir.") no termina en "?", y antes de esta card no bloqueaba la card.
  local pregunton_opciones
  pregunton_opciones="$tmp/claude-pregunton-opciones"
  cat >"$pregunton_opciones" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"Encontré un conflicto real de concurrencia con DEVKIT-63; el chequeo dio libre dos veces.\\n¿Cómo quieres que siga?\\nOpciones:\\n1. Seguir de todas formas\\n2. Esperar al humano\\n3. Bloquear la card\\nAvísame antes de decidir.","total_cost_usd":0.01,"num_turns":2}\n'
FIN
  chmod +x "$pregunton_opciones"
  rm -f "$tmp/bloqueo.args"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$pregunton_opciones" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-3 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/bloqueo.args" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "pregunta abierta sin '?' final (texto real de DEVKIT-63) también bloquea" \
    'bloquea la card con task-block.sh: DEVKIT-3' \
    "$(grep -oE 'bloquea la card con task-block.sh: DEVKIT-3' "$tmp/run/watch.log" | head -1)"

  # DEVKIT-76: `forzar_task_block` lee el Estado real antes de bloquear. Una
  # card ya Hecha que preguntó de más no se mueve a Bloqueada: solo queda la
  # alarma en watch.log y task-block.sh no se llama.
  printf '{"estado":"Hecha"}\n' >"$RONDA_DIR/card-DEVKIT-76.json"
  rm -f "$tmp/bloqueo.args"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$pregunton" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-76 >/dev/null 2>&1
  espera=0
  while ! grep -q 'ALARMA: terminó sin estado observable sobre una card ya Hecha; no se bloquea' \
      "$tmp/run/watch.log" 2>/dev/null && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "card Hecha: no llama a task-block.sh" 1 \
    "$([ -e "$tmp/bloqueo.args" ] && echo 0 || echo 1)"
  check "card Hecha: deja la alarma sin bloquear, con el motivo real (H4)" \
    'ALARMA: terminó sin estado observable sobre una card ya Hecha; no se bloquea (terminó con una pregunta abierta' \
    "$(grep -oE 'ALARMA: terminó sin estado observable sobre una card ya Hecha; no se bloquea \(terminó con una pregunta abierta' "$tmp/run/watch.log" | head -1)"
  check "card Hecha: una sola ALARMA, no la genérica y la de Hecha (H5)" 1 \
    "$(grep -c 'ALARMA' "$tmp/run/watch.log")"

  # Card En progreso: sigue bloqueando, es el comportamiento anterior a esta
  # card y la barrera de DEVKIT-50/DEVKIT-44 sigue siendo correcta ahí.
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-76.json"
  rm -f "$tmp/bloqueo.args"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$pregunton" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" task-fix DEVKIT-76 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/bloqueo.args" ] && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "card En progreso: sigue bloqueando (comportamiento actual)" \
    'bloquea la card con task-block.sh: DEVKIT-76' \
    "$(grep -oE 'bloquea la card con task-block.sh: DEVKIT-76' "$tmp/run/watch.log" | head -1)"
  rm -f "$RONDA_DIR/card-DEVKIT-76.json"

  # DEVKIT-77: `task_start_sin_entregar` usa el mismo doble de notion.sh
  # (`card <Clave>`) para decidir si un task-start dejó la card sin resolver.
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  check "task_start_sin_entregar: card sigue En progreso" si \
    "$(task_start_sin_entregar '/task-start DEVKIT-63' DEVKIT-63 && echo si || echo no)"
  printf '{"estado":"Revisión automática"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  check "task_start_sin_entregar: card ya en Revisión automática, no hay corte" no \
    "$(task_start_sin_entregar '/task-start DEVKIT-63' DEVKIT-63 && echo si || echo no)"
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  check "task_start_sin_entregar: solo aplica a task-start, no a task-fix" no \
    "$(task_start_sin_entregar '/task-fix DEVKIT-63' DEVKIT-63 && echo si || echo no)"

  # Extremo a extremo: un task-start "limpio" (sin pregunta abierta, con el
  # doble genérico "listo") que deja la card En progreso sin PR ni bloqueo
  # también deja su propia ALARMA en watch.log (DEVKIT-77).
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-63.json"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-63 >/dev/null 2>&1
  espera=0
  while ! grep -q 'ALARMA: terminó sin entregar ni bloquear (DEVKIT-63):' "$tmp/run/watch.log" 2>/dev/null \
        && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "task-start limpio pero sin entregar deja su propia ALARMA" \
    'ALARMA: terminó sin entregar ni bloquear (DEVKIT-63): card sigue En progreso, sin PR ni bloqueo' \
    "$(grep -oE 'ALARMA: terminó sin entregar ni bloquear \(DEVKIT-63\): card sigue En progreso, sin PR ni bloqueo' "$tmp/run/watch.log" | head -1)"

  # H2 del informe sobre el PR #64 (esta card): un comentario de la card que
  # empieza con "/" (como "/pr-review 64 dio OK") viaja en el volcado bajo
  # `## Card`, pero ese volcado solo llega a `run_claude` (`prompt_pleno`):
  # todo lo demás en `--worker` -la línea "lanzando", `forzar_task_block`,
  # `task_start_sin_entregar`- sigue usando el prompt corto, así que esa
  # línea nunca se confunde con el principio del prompt real. Antes de
  # DEVKIT-90 esto no aplicaba (task-start no llevaba volcado); el riesgo es
  # que un futuro cambio vuelva a mezclar los dos prompts.
  local tb_slash
  tb_slash="$tmp/task-begin-doble-slash"
  cat >"$tb_slash" <<'FIN'
#!/usr/bin/env bash
echo "- Clave: $1"
echo "- Título: card de prueba"
echo ""
echo "## Comentarios"
echo "/pr-review 64 dio OK, dijo el humano"
FIN
  chmod +x "$tb_slash"
  printf '{"estado":"En progreso"}\n' >"$RONDA_DIR/card-DEVKIT-9096.json"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_TASK_BEGIN_BIN="$tb_slash" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-9096 >/dev/null 2>&1
  espera=0
  while ! grep -q 'ALARMA: terminó sin entregar ni bloquear (DEVKIT-9096):' "$tmp/run/watch.log" 2>/dev/null \
        && [ "$espera" -lt 40 ]; do
    sleep 0.1
    espera=$((espera + 1))
  done
  check "H2: una línea de la card que empieza con / no rompe la alarma de DEVKIT-77" \
    'ALARMA: terminó sin entregar ni bloquear (DEVKIT-9096): card sigue En progreso, sin PR ni bloqueo' \
    "$(grep -oE 'ALARMA: terminó sin entregar ni bloquear \(DEVKIT-9096\): card sigue En progreso, sin PR ni bloqueo' "$tmp/run/watch.log" | head -1)"
  check "H2: la línea \"lanzando\" queda en una sola línea de watch.log" 1 \
    "$(grep -c 'lanzando (origen=' "$tmp/run/watch.log")"

  # DEVKIT-76 + DEVKIT-90: un task-start sobre una card que ya no es tomable
  # (Hecha, Bloqueada, Revisión automática) ya ni siquiera llega a lanzar un
  # agente: task-begin.sh la detecta por Notion, antes de cualquier
  # `claude -p`, y devkit-run deja "no lanza" con su motivo, sin ALARMA y sin
  # bloquear (nada que bloquear en esos Estados). Antes de DEVKIT-90 el
  # agente llegaba a correr y respondía él mismo este mismo texto (de ahí
  # `DEVKIT_CLAUDE_BIN=/bin/false`: si el hook fallara y la llamada llegara
  # a intentar lanzar un agente, la prueba lo notaría por el fallo, no por un
  # falso positivo).
  no_lanza_terminal() {  # no_lanza_terminal <nombre> <Clave> <card JSON> <motivo esperado, con el prefijo de task-begin.sh>
    local nombre=$1 clave=$2 card_json=$3 motivo=$4
    printf '%s\n' "$card_json" >"$RONDA_DIR/card-$clave.json"
    : >"$tmp/run/watch.log"
    rm -f "$tmp/bloqueo.args"
    DEVKIT_CLAUDE_BIN=/bin/false DEVKIT_TASK_BEGIN_BIN="$HERE/task-begin.sh" DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
      DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" DEVKIT_ROLES_FILE="$tmp/roles.toml" \
      DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
      bash "$HERE/devkit-run.sh" task-start "$clave" >/dev/null 2>&1
    check "$nombre: no lanza, con el motivo de task-begin.sh" "no lanza: $motivo" \
      "$(grep -oE 'no lanza: .*' "$tmp/run/watch.log" | head -1)"
    check "$nombre: sin ALARMA de ningún tipo" 0 "$(grep -c 'ALARMA' "$tmp/run/watch.log")"
    check "$nombre: no bloquea (nada que bloquear en ese Estado)" 1 \
      "$([ -e "$tmp/bloqueo.args" ] && echo 0 || echo 1)"
    rm -f "$RONDA_DIR/card-$clave.json"
  }
  # Claves de cuatro cifras a propósito, fuera del rango de una Clave real de
  # este proyecto: `lanzamiento_duplicado` mira `ps` de verdad (no un doble),
  # y una Clave de dos cifras coincidió una vez con la propia card que esta
  # autoprueba corría en ese momento (un `task-start DEVKIT-90` real y vivo
  # en `ps` durante la corrida de la card DEVKIT-90), lo que hizo que la
  # prueba se topara con su propio lanzamiento en curso y saliera por el
  # camino de "ya hay un lanzamiento" en vez de probar task-begin.sh.
  no_lanza_terminal "relanzamiento sobre Hecha" DEVKIT-9090 \
    '{"estado":"Hecha","pr":"https://github.com/o/r/pull/9"}' \
    'task-begin: DEVKIT-9090 ya está en Hecha (PR https://github.com/o/r/pull/9); no hay nada que hacer.'
  no_lanza_terminal "relanzamiento sobre Bloqueada" DEVKIT-9091 \
    '{"estado":"Bloqueada"}' \
    'task-begin: DEVKIT-9091 está bloqueada; el humano debe moverla a En progreso antes de relanzar.'
  no_lanza_terminal "relanzamiento sobre Revisión automática" DEVKIT-9092 \
    '{"estado":"Revisión automática","pr":"https://github.com/o/r/pull/12"}' \
    'task-begin: DEVKIT-9092 ya está en Revisión automática (PR https://github.com/o/r/pull/12); no hay nada que hacer.'
  no_lanza_terminal "relanzamiento sobre Por refinar" DEVKIT-9093 \
    '{"estado":"Por refinar"}' \
    'task-begin: DEVKIT-9093 está Por refinar; el humano debe moverla a Lista o Backlog.'

  # H7 del informe sobre el PR #64 (esta card): --test solo probaba que los
  # Estados terminales de arriba no bloqueaban; la rama real de bloqueo
  # (card tomable, pero el workspace no está listo) no tenía un caso propio.
  # Workspace con cambios sin commit sobre una card Lista: task-begin.sh
  # falla por el motivo real (no por un doble) y devkit-run bloquea la card.
  printf '{"estado":"Lista","tipo":"feature","titulo":"Probar bloqueo real"}\n' \
    >"$RONDA_DIR/card-DEVKIT-9098.json"
  echo sucio >"$tmp/sucio.txt"
  rm -f "$tmp/bloqueo.args"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN=/bin/false DEVKIT_TASK_BEGIN_BIN="$HERE/task-begin.sh" DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-9098 >/dev/null 2>&1
  espera=0
  while [ ! -e "$tmp/bloqueo.args" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "H7: workspace sucio sobre una card Lista bloquea la card de verdad" \
    'bloquea la card con task-block.sh: DEVKIT-9098' \
    "$(grep -oE 'bloquea la card con task-block.sh: DEVKIT-9098' "$tmp/run/watch.log" | head -1)"
  check "H7: task-block.sh recibe el motivo real de task-begin.sh (workspace sucio)" \
    'cambios sin commit' \
    "$(cut -d'|' -f2 "$tmp/bloqueo.args" 2>/dev/null | grep -oE 'cambios sin commit')"
  rm -f "$tmp/sucio.txt" "$RONDA_DIR/card-DEVKIT-9098.json"

  # H8 del informe sobre el PR #64 (esta card): dos lanzamientos seguidos que
  # fallan en task-begin.sh no deben reutilizar el mismo id de log -si no se
  # reserva el número, el "lanzando" huérfano del primero se empareja con el
  # cierre del segundo y --costos duplica el costo del siguiente task-start
  # real (DEVKIT-89 H2 del mismo tipo, ahora sobre este camino de fallo)-.
  local h8_run="$tmp/run-h8" h8_costos="$tmp/costos-h8.log"
  mkdir -p "$h8_run"
  : >"$h8_run/ready"
  printf '{"estado":"Hecha","pr":"https://github.com/o/r/pull/9"}\n' \
    >"$RONDA_DIR/card-DEVKIT-9099.json"
  : >"$h8_run/watch.log"
  for _ in 1 2; do
    DEVKIT_CLAUDE_BIN=/bin/false DEVKIT_TASK_BEGIN_BIN="$HERE/task-begin.sh" DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
      DEVKIT_RUN_DIR="$h8_run" DEVKIT_WS="$tmp" DEVKIT_ROLES_FILE="$tmp/roles.toml" \
      DEVKIT_FRONTERA_CACHE_DIR="$h8_run/frontera" DEVKIT_COSTOS_LOG="$h8_costos" \
      bash "$HERE/devkit-run.sh" task-start DEVKIT-9099 >/dev/null 2>&1
  done
  check "H8: dos fallos seguidos de task-begin.sh reservan dos ids de log distintos" 2 \
    "$(ls "$h8_run"/task-start-*.log 2>/dev/null | wc -l | tr -d ' ')"
  check "H8: costos.log no duplica el cierre del primer id" 1 \
    "$(grep -c 'terminado \[task-start-1\]' "$h8_costos" 2>/dev/null)"
  check "H8: el segundo fallo también queda en costos.log, con su propio id" 1 \
    "$(grep -c 'terminado \[task-start-2\]' "$h8_costos" 2>/dev/null)"
  rm -f "$RONDA_DIR/card-DEVKIT-9099.json"

  # --- task-begin.sh de verdad (no el doble), con notion.sh simulado -------
  # Lista y En progreso con Rama: los dos casos que sí tocan git y Notion,
  # de punta a punta, a través del propio `devkit-run.sh task-start` (no
  # aislado). Workspace propio, con un origin local de verdad (`git push`
  # necesita un remoto al que empujar) para no interferir con `$tmp`, que
  # usan decenas de pruebas más y no vive en la rama `main`.
  local tb_dir
  tb_dir=$(mktemp -d)
  git init -q --bare "$tb_dir/origin.git"
  git init -q "$tb_dir/ws"
  git -C "$tb_dir/ws" config user.email test@example.com
  git -C "$tb_dir/ws" config user.name test
  git -C "$tb_dir/ws" remote add origin "$tb_dir/origin.git"
  git -C "$tb_dir/ws" commit -q --allow-empty -m init --no-gpg-sign
  git -C "$tb_dir/ws" branch -q -m main
  git -C "$tb_dir/ws" push -q -u origin main
  mkdir -p "$tb_dir/run" "$tb_dir/ronda"
  : >"$tb_dir/run/ready"
  # `--otros-agentes` de verdad mira `ps`: aislado con un doble que siempre
  # dice "libre", para que estas dos pruebas no dependan de qué más corre en
  # este contenedor en el momento de la corrida (esa comprobación ya tiene su
  # propia batería de pruebas más arriba, con `filtrar_agentes`/`propio_de`).
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tb_dir/otros-agentes-libre"
  chmod +x "$tb_dir/otros-agentes-libre"
  cat >"$tb_dir/notion-doble" <<FIN
#!/usr/bin/env bash
case "\$1" in
  card) cat "$tb_dir/ronda/card-\$2.json" 2>/dev/null ;;
  pagina) cat "$tb_dir/ronda/pagina-\$2.json" 2>/dev/null ;;
  set) id2=\$2; shift 2; printf '%s %s\n' "\$id2" "\$*" >>"$tb_dir/ronda/set-llamadas" ;;
  comentar) printf '%s %s\n' "\$2" "\$3" >>"$tb_dir/ronda/comentar-llamadas" ;;
  contenido) printf '## Objetivo\ncard de prueba\n' ;;
  comentarios) printf 'un comentario de prueba\n' ;;
esac
FIN
  chmod +x "$tb_dir/notion-doble"
  # DEVKIT_COSTOS_LOG fuera de `ws` a propósito: en un proyecto real
  # `.devkit/costos.log` está en `.gitignore` (DEVKIT-89), pero este
  # workspace de prueba no trae ese `.gitignore`, y sin la variable
  # `costos_log()` lo crea dentro de `ws` y ensucia el árbol para el segundo
  # lanzamiento (el de reanudación, que si ve cambios sin commit no debería).
  local tb_env=(DEVKIT_WS="$tb_dir/ws" DEVKIT_RUN_DIR="$tb_dir/run" DEVKIT_NOTION_BIN="$tb_dir/notion-doble" \
    DEVKIT_TASK_BEGIN_BIN="$HERE/task-begin.sh" DEVKIT_RUN_BIN="$tb_dir/otros-agentes-libre" \
    DEVKIT_TASK_BLOCK_BIN="$bloqueo" DEVKIT_CLAUDE_BIN="$doble" DEVKIT_ROLES_FILE="$tmp/roles.toml" \
    DEVKIT_FRONTERA_CACHE_DIR="$tb_dir/frontera" DEVKIT_ARRANQUE_ESPERA=1 \
    DEVKIT_COSTOS_LOG="$tb_dir/costos.log")

  # Lista: crea la rama desde main, la sube y deja la card En progreso con
  # Agente=claude y Rama, antes de que el agente llegue a arrancar.
  printf '{"id":"pagina-9093","estado":"Lista","tipo":"feature","titulo":"Probar rama nueva"}' \
    >"$tb_dir/ronda/card-DEVKIT-9093.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9093 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-1.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "task-begin de verdad (Lista): crea y sube la rama feat/DEVKIT-9093-..." 1 \
    "$(git -C "$tb_dir/ws" ls-remote --heads origin 2>/dev/null | grep -c 'feat/DEVKIT-9093-probar-rama-nueva')"
  check "task-begin de verdad (Lista): deja la card En progreso, Agente=claude y Rama en Notion" 1 \
    "$(grep -c 'Estado=En progreso Agente=claude Rama=' "$tb_dir/ronda/set-llamadas" 2>/dev/null)"
  check "task-begin de verdad (Lista): el agente sí llega a arrancar (con la card ya lista)" 1 \
    "$([ -s "$tb_dir/run/task-start-1.log" ] && echo 1 || echo 0)"

  # En progreso con Rama: reanudación, cambia a la rama que ya existe en vez
  # de crear una nueva ni tocar Notion otra vez.
  git -C "$tb_dir/ws" switch -q main
  git -C "$tb_dir/ws" push -q origin main:refs/heads/feat/DEVKIT-9094-otra
  printf '{"id":"pagina-9094","estado":"En progreso","rama":"https://github.com/o/r/tree/feat/DEVKIT-9094-otra"}' \
    >"$tb_dir/ronda/card-DEVKIT-9094.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9094 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-2.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "task-begin de verdad (En progreso con Rama): cambia a la rama existente (reanudación)" \
    "feat/DEVKIT-9094-otra" "$(git -C "$tb_dir/ws" rev-parse --abbrev-ref HEAD)"
  check "task-begin de verdad (En progreso con Rama): no crea una rama nueva ni vuelve a tocar Notion" 1 \
    "$(grep -c 'Estado=En progreso Agente=claude Rama=' "$tb_dir/ronda/set-llamadas" 2>/dev/null)"

  # H1 del informe sobre el PR #64 (esta card): un `claude -p` ajeno de
  # verdad -no un doble de otra skill que ya haya terminado, sino uno vivo
  # mientras dura el candado- no debe hacer que este task-start bloquee una
  # card Lista válida. Antes de este fix, task-begin.sh (con su
  # `--otros-agentes`) corría en el lanzador, sin candado: veía ese proceso
  # ajeno antes de que le tocara el turno y lo confundía con un conflicto de
  # verdad, en vez de simplemente esperar. Aquí `--otros-agentes` corre de
  # verdad (`ps`), no el doble "siempre libre" de los dos casos de arriba.
  printf '{"id":"pagina-9095","estado":"Lista","tipo":"feature","titulo":"Probar candado real"}' \
    >"$tb_dir/ronda/card-DEVKIT-9095.json"
  cp "$doble" "$tb_dir/claude-otro"
  (
    exec 9>"$tb_dir/run/skill.lock"
    flock 9
    "$tb_dir/claude-otro" -p '/pr-review 99' --model modelo-x &
    otro_pid=$!
    sleep 0.6
    kill "$otro_pid" 2>/dev/null
  ) &
  h1_tenedor=$!
  sleep 0.1  # deja que el subshell tome el candado y arranque su claude -p ajeno
  rm -f "$tmp/bloqueo.args"
  env "${tb_env[@]}" DEVKIT_RUN_BIN="$HERE/devkit-run.sh" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-9095 >/dev/null 2>&1
  wait "$h1_tenedor" 2>/dev/null
  espera=0
  while [ ! -s "$tb_dir/run/task-start-3.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "H1: candado tomado por un claude -p ajeno de verdad: espera en vez de bloquear" 1 \
    "$([ -s "$tb_dir/run/task-start-3.log" ] && echo 1 || echo 0)"
  check "H1: no llama a task-block.sh" 1 \
    "$([ -e "$tmp/bloqueo.args" ] && echo 0 || echo 1)"

  # H6 del informe sobre el PR #64 (esta card): la rama ya existe -local y en
  # origin- porque un intento anterior la creó y subió, pero el `set` de
  # Notion falló a mitad de camino y la card se quedó Lista, sin Rama. Antes,
  # `switch -c` fallaba con "¿ya existe?" y la card quedaba trabada hasta que
  # el humano borrara la rama a mano; ahora la reutiliza.
  git -C "$tb_dir/ws" switch -q main
  git -C "$tb_dir/ws" switch -q -c feat/DEVKIT-9097-probar-rama-existente
  git -C "$tb_dir/ws" push -q -u origin feat/DEVKIT-9097-probar-rama-existente
  git -C "$tb_dir/ws" switch -q main
  printf '{"id":"pagina-9097","estado":"Lista","tipo":"feature","titulo":"Probar rama existente"}' \
    >"$tb_dir/ronda/card-DEVKIT-9097.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9097 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-4.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "H6: una rama que ya existe (intento anterior) se reutiliza en vez de fallar" \
    "feat/DEVKIT-9097-probar-rama-existente" "$(git -C "$tb_dir/ws" rev-parse --abbrev-ref HEAD)"
  # Tercera vez que este `tb_dir` deja una card lista por este camino (la
  # primera fue DEVKIT-9093, la segunda DEVKIT-9095 en el caso de H1): la
  # cuenta es acumulada sobre el mismo `set-llamadas`, no específica de esta
  # card.
  check "H6: termina de dejar la card En progreso, con Agente y Rama en Notion" 3 \
    "$(grep -c 'Estado=En progreso Agente=claude Rama=' "$tb_dir/ronda/set-llamadas" 2>/dev/null)"
  check "H6: el agente sí llega a arrancar" 1 \
    "$([ -s "$tb_dir/run/task-start-4.log" ] && echo 1 || echo 0)"

  # DEVKIT-100: el slug de la rama era el título entero (170 caracteres en el
  # caso real que motivó esta card). Con un título largo, la rama solo lleva
  # las primeras cinco palabras -sin "al", una contracción de
  # artículo+preposición- recortadas a 40 caracteres.
  printf '{"id":"pagina-9098","estado":"Lista","tipo":"feature","titulo":"PR review proporcional al diff preparación y comprobaciones mecánicas por script informe publicado desde un archivo sin worktree para PRs de solo documentación"}' \
    >"$tb_dir/ronda/card-DEVKIT-9098.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9098 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-5.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "DEVKIT-100: título largo -> rama corta feat/DEVKIT-9098-pr-review-proporcional-diff" 1 \
    "$(git -C "$tb_dir/ws" ls-remote --heads origin 2>/dev/null | grep -c 'feat/DEVKIT-9098-pr-review-proporcional-diff$')"

  # DEVKIT-100: título con acentos, sin partir palabras al recortar.
  git -C "$tb_dir/ws" switch -q main
  printf '{"id":"pagina-9099","estado":"Lista","tipo":"bug","titulo":"Depuración rápida según el pipeline de ingestión"}' \
    >"$tb_dir/ronda/card-DEVKIT-9099.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9099 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-6.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "DEVKIT-100: título con acentos -> rama fix/DEVKIT-9099-depuracion-rapida-segun-pipeline" 1 \
    "$(git -C "$tb_dir/ws" ls-remote --heads origin 2>/dev/null | grep -c 'fix/DEVKIT-9099-depuracion-rapida-segun-pipeline$')"

  # DEVKIT-109: al arrancar la primera hija de una Épica en Lista, la Épica
  # pasa a En progreso con un comentario de una línea; si ya estaba En
  # progreso, o la hija no tiene Padre, no la toca.
  printf '{"id":"pagina-epica-1","estado":"Lista"}' >"$tb_dir/ronda/pagina-epica-1.json"
  printf '{"id":"pagina-9200","estado":"Lista","tipo":"feature","titulo":"Hija con épica en Lista","padre":["epica-1"]}' \
    >"$tb_dir/ronda/card-DEVKIT-9200.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9200 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-7.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "DEVKIT-109: hija con Padre en Lista deja la Épica En progreso" 1 \
    "$(grep -c '^epica-1 Estado=En progreso$' "$tb_dir/ronda/set-llamadas" 2>/dev/null)"
  check "DEVKIT-109: hija con Padre en Lista comenta en la Épica" 1 \
    "$(grep -c '^epica-1 Arrancó su primera hija (DEVKIT-9200)' "$tb_dir/ronda/comentar-llamadas" 2>/dev/null)"

  git -C "$tb_dir/ws" switch -q main
  printf '{"id":"pagina-epica-2","estado":"En progreso"}' >"$tb_dir/ronda/pagina-epica-2.json"
  printf '{"id":"pagina-9201","estado":"Lista","tipo":"feature","titulo":"Hija con épica ya en progreso","padre":["epica-2"]}' \
    >"$tb_dir/ronda/card-DEVKIT-9201.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9201 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-8.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "DEVKIT-109: hija con Padre ya En progreso no la toca" 0 \
    "$(grep -c 'epica-2' "$tb_dir/ronda/set-llamadas" "$tb_dir/ronda/comentar-llamadas" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"

  comentarios_antes=$(wc -l <"$tb_dir/ronda/comentar-llamadas" 2>/dev/null || echo 0)
  git -C "$tb_dir/ws" switch -q main
  printf '{"id":"pagina-9202","estado":"Lista","tipo":"feature","titulo":"Hija sin épica"}' \
    >"$tb_dir/ronda/card-DEVKIT-9202.json"
  env "${tb_env[@]}" bash "$HERE/devkit-run.sh" task-start DEVKIT-9202 >/dev/null 2>&1
  espera=0
  while [ ! -s "$tb_dir/run/task-start-9.log" ] && [ "$espera" -lt 40 ]; do sleep 0.1; espera=$((espera + 1)); done
  check "DEVKIT-109: hija sin Padre no comenta en ninguna Épica" "$comentarios_antes" \
    "$(wc -l <"$tb_dir/ronda/comentar-llamadas" 2>/dev/null || echo 0)"

  rm -rf "$tb_dir"

  # `devkit-run task-block` y `devkit-run task-close` delegan en el script
  # bash, en primer plano y con los argumentos tal cual (DEVKIT-55).
  rm -f "$tmp/bloqueo.args"
  DEVKIT_TASK_BLOCK_BIN="$bloqueo" bash "$HERE/devkit-run.sh" task-block DEVKIT-3 falta el token >/dev/null 2>&1
  check "devkit-run task-block delega en el script bash" 'DEVKIT-3|falta|el|token|' \
    "$(cat "$tmp/bloqueo.args" 2>/dev/null)"
  # Un watch.sh viejo pide las skills retiradas por --sync: van a los scripts
  # y no llegan a `claude`.
  rm -f "$tmp/bloqueo.args"
  DEVKIT_CLAUDE_BIN=/bin/false DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" --sync '/task-block DEVKIT-3 tres ciclos sin OK' >/dev/null 2>&1
  check "--sync /task-block (watch.sh viejo) va al script" 'DEVKIT-3|tres ciclos sin OK|' \
    "$(cat "$tmp/bloqueo.args" 2>/dev/null)"
  rm -f "$tmp/bloqueo.args"
  DEVKIT_CLAUDE_BIN=/bin/false DEVKIT_TASK_CLOSE_BIN="$bloqueo" \
    bash "$HERE/devkit-run.sh" --sync '/task-close DEVKIT-3 https://github.com/o/r/pull/9' >/dev/null 2>&1
  check "--sync /task-close (watch.sh viejo) va al script" 'DEVKIT-3|https://github.com/o/r/pull/9|' \
    "$(cat "$tmp/bloqueo.args" 2>/dev/null)"

  # Modelo vacío (DEVKIT-55): con una lista `frontera` vacía no hay modelo que
  # resolver. Antes se lanzaba `claude --model ""` y moría con un 400; ahora no
  # se lanza, sale con 65 y deja la alarma.
  printf 'frontera = []\nimplementacion.model_index = 1\nimplementacion.effort = "high"\n' >"$tmp/roles-vacio.toml"
  : >"$tmp/run/watch.log"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles-vacio.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-vacio" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-3 >/dev/null 2>&1; rc=$?
  check "modelo vacío: no lanza y sale con 65" 65 "$rc"
  check "modelo vacío: deja la alarma en watch.log" 'ALARMA: modelo vacío' \
    "$(grep -oE 'ALARMA: modelo vacío' "$tmp/run/watch.log" | head -1)"
  DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/vacio.log" "" high 40 >/dev/null 2>&1; rc=$?
  check "modelo vacío en --worker: tampoco lanza" "65 no" \
    "$rc $([ -s "$tmp/run/vacio.log" ] && echo si || echo no)"

  # El `claude -p` recibe DEVKIT_SCRIPTS_DIR y DEVKIT_RUN_DIR del lanzador
  # (Ampliación de DEVKIT-55): sin la variable en el entorno, o con la copia
  # vieja de la imagen, una skill que invoca otro script por ruta debe llegar
  # al de este mismo directorio (el del workspace, en modo dev).
  local espejo
  espejo="$tmp/claude-espejo"
  cat >"$espejo" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"%s %s","total_cost_usd":0,"num_turns":1}\n' "$DEVKIT_SCRIPTS_DIR" "$DEVKIT_RUN_DIR"
FIN
  chmod +x "$espejo"
  env -u DEVKIT_SCRIPTS_DIR DEVKIT_CLAUDE_BIN="$espejo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-1.log" modelo-x high 40 >/dev/null 2>&1
  check "worker sin la variable exporta DEVKIT_SCRIPTS_DIR y DEVKIT_RUN_DIR" "$HERE $tmp/run" \
    "$(jq -r .result "$tmp/run/espejo-1.log" 2>/dev/null)"
  DEVKIT_SCRIPTS_DIR=/opt/devkit/scripts DEVKIT_CLAUDE_BIN="$espejo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-2.log" modelo-x high 40 >/dev/null 2>&1
  check "worker con la copia de la imagen en el entorno usa la suya" "$HERE $tmp/run" \
    "$(jq -r .result "$tmp/run/espejo-2.log" 2>/dev/null)"
  # --worker corre el `claude -p` con el candado tomado: debe avisarlo con
  # DEVKIT_LOCK_HELD=1, o task-block.sh no guarda el wip (DEVKIT-55, H2).
  local espejo_candado
  espejo_candado="$tmp/claude-espejo-candado"
  cat >"$espejo_candado" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"candado=%s","total_cost_usd":0,"num_turns":1}\n' "${DEVKIT_LOCK_HELD:-no}"
FIN
  chmod +x "$espejo_candado"
  env -u DEVKIT_LOCK_HELD DEVKIT_CLAUDE_BIN="$espejo_candado" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-candado.log" modelo-x high 40 >/dev/null 2>&1
  check "worker exporta DEVKIT_LOCK_HELD=1 al claude -p" "candado=1" \
    "$(jq -r .result "$tmp/run/espejo-candado.log" 2>/dev/null)"

  # DEVKIT_MODEL y DEVKIT_EFFORT llegan al `claude -p` con lo que se lanzó de
  # verdad (DEVKIT-58), no con lo que traiga el entorno del lanzador: un
  # task-document lanzado desde un task-start en opus no hereda su modelo.
  local espejo_modelo
  espejo_modelo="$tmp/claude-espejo-modelo"
  cat >"$espejo_modelo" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"%s %s","total_cost_usd":0,"num_turns":1}\n' "${DEVKIT_MODEL:-vacío}" "${DEVKIT_EFFORT:-vacío}"
FIN
  chmod +x "$espejo_modelo"
  DEVKIT_MODEL=heredado DEVKIT_EFFORT=heredado DEVKIT_CLAUDE_BIN="$espejo_modelo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-modelo.log" modelo-x max 40 >/dev/null 2>&1
  check "worker exporta DEVKIT_MODEL y DEVKIT_EFFORT resueltos" "modelo-x max" \
    "$(jq -r .result "$tmp/run/espejo-modelo.log" 2>/dev/null)"
  check "--sync exporta DEVKIT_MODEL y DEVKIT_EFFORT del rol" '{"result":"modelo-barato low","total_cost_usd":0,"num_turns":1}' \
    "$(env -u DEVKIT_MODELO_FORZADO DEVKIT_MODEL=heredado DEVKIT_CLAUDE_BIN="$espejo_modelo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-modelo" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-3' 2>/dev/null | tail -1)"
  check "--sync con modelo forzado exporta el forzado" '{"result":"modelo-forzado low","total_cost_usd":0,"num_turns":1}' \
    "$(DEVKIT_MODELO_FORZADO=modelo-forzado DEVKIT_CLAUDE_BIN="$espejo_modelo" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-modelo" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-3' 2>/dev/null | tail -1)"

  # DEVKIT_SKILL llega al `claude -p` con el nombre de la skill lanzada
  # (DEVKIT-91): lo necesita `hook-stop.sh` para saber si corre dentro de un
  # task-start o un task-fix.
  local espejo_skill
  espejo_skill="$tmp/claude-espejo-skill"
  cat >"$espejo_skill" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"%s","total_cost_usd":0,"num_turns":1}\n' "${DEVKIT_SKILL:-vacío}"
FIN
  chmod +x "$espejo_skill"
  DEVKIT_CLAUDE_BIN="$espejo_skill" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-fix DEVKIT-3' "$tmp/run/espejo-skill.log" modelo-x high 40 >/dev/null 2>&1
  check "worker exporta DEVKIT_SKILL con el nombre de la skill lanzada" "task-fix" \
    "$(jq -r .result "$tmp/run/espejo-skill.log" 2>/dev/null)"

  # H1 de pr-review (DEVKIT-65): DEVKIT_LANZADOR=watch, que watch.sh fija al
  # llamar a --sync para que task-fix sepa que lo lanzó el bucle y no firme
  # manual=1, debe llegar al `claude -p` hijo pese a ENV_LIMPIO=1 y su lista
  # blanca de `env -i` (no está en ENV_HEREDABLE: la copia run_claude aparte).
  local espejo_lanzador
  espejo_lanzador="$tmp/claude-espejo-lanzador"
  cat >"$espejo_lanzador" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"%s","total_cost_usd":0,"num_turns":1}\n' "${DEVKIT_LANZADOR:-vacío}"
FIN
  chmod +x "$espejo_lanzador"
  check "--sync con DEVKIT_LANZADOR=watch lo pasa al claude -p pese a env -i" '{"result":"watch","total_cost_usd":0,"num_turns":1}' \
    "$(DEVKIT_LANZADOR=watch DEVKIT_ENV_LIMPIO=1 DEVKIT_CLAUDE_BIN="$espejo_lanzador" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera-lanzador" \
       bash "$HERE/devkit-run.sh" --sync '/task-fix DEVKIT-3' 2>/dev/null | tail -1)"

  # DEVKIT-65: hipótesis no confirmada (ver el comentario de ENV_HEREDABLE
  # más arriba, H4 de pr-review) de que un `claude -p` lanzado por otro
  # (`epic-plan` corriendo dentro de un `claude -p`) hereda del padre las
  # marcas de sesión anidada (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, ...), que le
  # cambiarían a la CLI hija el nombre con el que monta el conector de Notion
  # y romperían `--allowedTools`. Confirmada o no, `run_claude` arranca con
  # `env -i` y la lista blanca de ENV_HEREDABLE como medida defensiva: aunque
  # el padre las meta, no llegan.
  local espejo_anidado
  espejo_anidado="$tmp/claude-espejo-anidado"
  cat >"$espejo_anidado" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"CLAUDECODE=%s ENTRYPOINT=%s","total_cost_usd":0,"num_turns":1}\n' \
  "${CLAUDECODE:-ausente}" "${CLAUDE_CODE_ENTRYPOINT:-ausente}"
FIN
  chmod +x "$espejo_anidado"
  CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_CHILD_SESSION=1 \
    DEVKIT_CLAUDE_BIN="$espejo_anidado" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-anidado.log" modelo-x high 40 >/dev/null 2>&1
  check "el claude -p hijo no hereda las marcas de sesión anidada del padre" 'CLAUDECODE=ausente ENTRYPOINT=ausente' \
    "$(jq -r .result "$tmp/run/espejo-anidado.log" 2>/dev/null)"

  # Ampliación de DEVKIT-65: `--allowedTools` trae los dos nombres con los
  # que la CLI puede montar el conector de Notion (el de la shell/bash y el
  # visto dentro de un agente anidado), por si vuelve a cambiar con una
  # versión de la CLI.
  local espejo_argv
  espejo_argv="$tmp/claude-espejo-argv"
  cat >"$espejo_argv" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*"
FIN
  chmod +x "$espejo_argv"
  DEVKIT_CLAUDE_BIN="$espejo_argv" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/espejo-argv.log" modelo-x high 40 >/dev/null 2>&1
  check "--allowedTools trae los dos nombres del conector de Notion" 2 \
    "$(grep -oE 'mcp__plugin_Notion_notion|mcp__claude_ai_Notion' "$tmp/run/espejo-argv.log" | sort -u | wc -l | tr -d ' ')"

  # DEVKIT-65: antes de lanzar de verdad, `run_claude` prueba con
  # `claude mcp list` que Notion está conectada en el entorno del hijo (el
  # mismo que va a usar, no el de quien llama). Conectada, todo sigue igual.
  local notion_ok
  notion_ok="$tmp/claude-notion-ok"
  cat >"$notion_ok" <<'FIN'
#!/usr/bin/env bash
if [ "$1 $2" = "mcp list" ]; then
  printf 'plugin:Notion:notion: https://mcp.notion.com/mcp (HTTP) - Connected\n'
  exit 0
fi
printf '{"result":"listo","total_cost_usd":0.01,"num_turns":1}\n'
FIN
  chmod +x "$notion_ok"
  DEVKIT_NOTION_CHECK=1 DEVKIT_CLAUDE_BIN="$notion_ok" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-3' "$tmp/run/notion-ok.log" modelo-x high 40 >/dev/null 2>&1
  check "Notion conectada: el lanzamiento sigue normal" 'listo' \
    "$(jq -r .result "$tmp/run/notion-ok.log" 2>/dev/null)"

  # --worker deja transcripción del claude -p real, igual que el bucle
  # (DEVKIT-102, H2): antes solo watch.sh la guardaba (dentro de run_skill),
  # así que un lanzamiento manual (`devkit-run task-fix 68`) o uno hecho por
  # task-start/task-close/epic-plan (que también usan --worker) no dejaba
  # nada que diagnosticar.
  local trans2_dir trans2_slug trans2_doble
  trans2_dir=$(mktemp -d "$tmp/trans2.XXXXXX")
  trans2_slug=$(printf '%s' "$trans2_dir" | tr '/' '-')
  mkdir -p "$trans2_dir/proyectos/$trans2_slug" "$trans2_dir/run"
  cat >"$trans2_dir/proyectos/$trans2_slug/22222222-2222-2222-2222-222222222222.jsonl" <<'FIN'
{"type":"user","message":{"role":"user","content":"/task-fix DEVKIT-94"}}
{"type":"assistant","message":{"role":"assistant","content":"trabajando"}}
FIN
  trans2_doble="$tmp/claude-worker-transcripcion"
  cat >"$trans2_doble" <<'FIN'
#!/usr/bin/env bash
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3,"session_id":"22222222-2222-2222-2222-222222222222"}\n'
FIN
  chmod +x "$trans2_doble"
  DEVKIT_CLAUDE_BIN="$trans2_doble" DEVKIT_RUN_DIR="$trans2_dir/run" DEVKIT_WS="$trans2_dir" \
    DEVKIT_CLAUDE_PROJECTS_DIR="$trans2_dir/proyectos" \
    bash "$HERE/devkit-run.sh" --worker '/task-fix DEVKIT-94' "$trans2_dir/run/task-fix-1.log" modelo-x high 40 >/dev/null 2>&1
  check "--worker deja transcripción, sin pasar por watch.sh (rc)" 1 \
    "$([ -f "$trans2_dir/run/task-fix-1-transcript.jsonl" ] && echo 1 || echo 0)"
  check "--worker: la transcripción trae el primer mensaje de usuario" 1 \
    "$(grep -c 'task-fix DEVKIT-94' "$trans2_dir/run/task-fix-1-transcript.jsonl" 2>/dev/null)"

  # Sin Notion conectada (un doble que no entiende `mcp list` se ve igual que
  # un servidor caído), no corre el `claude -p` real y queda la alarma en vez
  # de gastar turnos pidiendo autorizar el conector.
  : >"$tmp/run/watch.log"
  DEVKIT_NOTION_CHECK=1 DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    bash "$HERE/devkit-run.sh" --worker '/task-start DEVKIT-9' "$tmp/run/sin-notion.log" modelo-x high 40 >/dev/null 2>&1
  check "sin Notion conectada no corre el claude -p real" "" \
    "$(jq -r .result "$tmp/run/sin-notion.log" 2>/dev/null)"
  check "sin Notion conectada deja la alarma en watch.log" 'ALARMA: sin Notion conectado' \
    "$(grep -oE 'ALARMA: sin Notion conectado' "$tmp/run/watch.log" | head -1)"
  # H5 de pr-review (DEVKIT-65): una sola ALARMA por el evento, no la
  # genérica "terminó con error (rc=67)" de encima.
  check "sin Notion conectada no repite la alarma genérica de error" 0 \
    "$(grep -c 'ALARMA: terminó con error' "$tmp/run/watch.log")"

  # Notion conectada al probar, pero el final del `claude -p` dice lo
  # contrario (DEVKIT-65). H13 de pr-review: solo `permission_denials` con una
  # herramienta de Notion bloquea la card; la frase del agente deja una ALARMA
  # y nada más. `--worker` corre sincrónico, así la prueba no depende de
  # esperas. Imprime "<bloquea si|no> <cuántas ALARMA de texto>".
  caso_notion() {  # caso_notion <nombre de $tmp/result-<nombre>.json>
    local doble_real="$tmp/claude-result-$1"
    cat >"$doble_real" <<'FIN'
#!/usr/bin/env bash
if [ "$1 $2" = "mcp list" ]; then
  printf 'plugin:Notion:notion: https://mcp.notion.com/mcp (HTTP) - Connected\n'
  exit 0
fi
cat "${0/claude-result-/result-}.json"
FIN
    chmod +x "$doble_real"
    rm -f "$tmp/bloqueo.args"
    : >"$tmp/run/watch.log"
    DEVKIT_NOTION_CHECK=1 DEVKIT_CLAUDE_BIN="$doble_real" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
      DEVKIT_TASK_BLOCK_BIN="$bloqueo" \
      bash "$HERE/devkit-run.sh" --worker '/task-fix DEVKIT-9' "$tmp/run/notion-$1.log" modelo-x high 40 >/dev/null 2>&1
    printf '%s %s' "$([ -e "$tmp/bloqueo.args" ] && echo si || echo no)" \
      "$(grep -c 'ALARMA: el resultado describe falta de acceso a Notion' "$tmp/run/watch.log")"
  }

  # Un `result` con una herramienta de Notion en `permission_denials` bloquea,
  # con su propio motivo (H11), aunque el texto no diga nada.
  cat >"$tmp/result-permission-denials.json" <<'FIN'
{"result":"card sin cambios","permission_denials":[{"tool_name":"mcp__claude_ai_Notion__notion-fetch","tool_use_id":"x","tool_input":{}}],"total_cost_usd":0.01,"num_turns":2}
FIN
  check "permission_denials con mcp__claude_ai_Notion__notion-fetch bloquea la card sin ALARMA de texto" "si 0" \
    "$(caso_notion permission-denials)"
  check "el bloqueo por permission_denials deja su ALARMA en watch.log" 'ALARMA: terminó sin acceso a Notion' \
    "$(grep -oE 'ALARMA: terminó sin acceso a Notion' "$tmp/run/watch.log" | head -1)"
  check "el bloqueo por permission_denials es de DEVKIT-9" 'DEVKIT-9' \
    "$(cut -d'|' -f1 "$tmp/bloqueo.args" 2>/dev/null)"
  check "el motivo del bloqueo dice sin acceso a Notion, no pregunta abierta" 'sin acceso a Notion|' \
    "$(cut -d'|' -f2 "$tmp/bloqueo.args" 2>/dev/null | grep -oE 'sin acceso a Notion|pregunta abierta' | tr '\n' '|')"

  # Las frases con las que la card describe los incidentes: ALARMA, sin
  # bloquear (H9 y H13).
  printf '%s\n' '{"result":"no tengo acceso a Notion en esta sesión"}' >"$tmp/result-no-tengo-acceso.json"
  printf '%s\n' '{"result":"el plugin de Notion no tiene permiso en esta sesión headless"}' >"$tmp/result-sin-permiso.json"
  printf '%s\n' '{"result":"pidió autorizar mcp__claude_ai_Notion__* en permissions.allow"}' >"$tmp/result-otro-nombre.json"
  # H14: las mismas frases como las escribe el agente, con backticks,
  # comillas y otras conjugaciones de "autorizar".
  printf '%s\n' '{"result":"Pedí autorizar `mcp__claude_ai_Notion__*` en `permissions.allow`"}' >"$tmp/result-autorizar-backticks.json"
  printf '%s\n' '{"result":"El plugin `Notion` no tiene permiso en esta sesión headless"}' >"$tmp/result-plugin-backticks.json"
  printf '%s\n' '{"result":"No pude leer la card: \"El plugin de Notion no tiene permiso en esta sesión headless\""}' >"$tmp/result-entre-comillas.json"
  printf '%s\n' '{"result":"Las herramientas mcp__claude_ai_Notion__* no están autorizadas"}' >"$tmp/result-no-estan-autorizadas.json"
  local caso_texto
  for caso_texto in no-tengo-acceso sin-permiso otro-nombre autorizar-backticks plugin-backticks \
    entre-comillas no-estan-autorizadas; do
    check "el result $caso_texto deja ALARMA y no bloquea la card" "no 1" "$(caso_notion "$caso_texto")"
  done

  # H6: un `result` que solo cita un comando bloqueado por pr-guard, sin
  # mencionar Notion, ni bloquea ni alarma.
  printf '%s\n' '{"result":"el comando gh pr merge no autorizado por pr-guard; card en Revisión automática"}' \
    >"$tmp/result-pr-guard.json"
  check "un comando no autorizado por pr-guard no se confunde con sin acceso a Notion" "no 0" \
    "$(caso_notion pr-guard)"

  # H10 y H13: `result` reales de ejecuciones que terminaron bien y describen
  # este mismo mecanismo. Pueden alarmar; nunca bloquean la card.
  cat >"$tmp/result-pr-review-46-7fdb66e.json" <<'FIN'
{"result": "PR 46, veredicto **CAMBIOS**, 3 hallazgos (1 media, 2 baja). Informe publicado sobre el head 7fdb66e; la card DEVKIT-65 sigue en `Revisión automática`.\n\nQué encontré en este segundo ciclo:\n\n- **Los seis hallazgos anteriores quedaron corregidos.** H1 y H2 se confirman en vivo: esta misma sesión la lanzó el `run_claude` de la rama y su entorno ya trae `DEVKIT_LANZADOR=watch`, `DISABLE_AUTOUPDATER` y `MCP_OAUTH_CALLBACK_PORT`. H5 lo reproduje por el camino del lanzador y queda una sola alarma en lugar de tres. Las autopruebas pasan sin fallas: 118 casos en `devkit-run.sh --test` y 114 en `watch-test.sh`.\n- **H9 (media), el motivo del veredicto.** La sonda `claude mcp list` no reproduce el fallo, así que la única red que queda es la expresión sobre el `result`. Tras H6 solo reconoce \"no tengo acceso a Notion\" y \"no tengo/estoy autorizado\". Las frases con las que la card documenta los cuatro incidentes reales (\"el plugin de Notion no tiene permiso en esta sesión headless\", \"autorizar mcp__claude_ai_Notion__* en permissions.allow\") no coinciden. Si el fallo se repite, volvería a ser silencioso. Los logs de los incidentes ya no existen, así que lo contrasté con el texto citado en la card.\n- **H7 y H8 (baja).** Una frase del README sigue describiendo el disparador viejo de H6, y un comentario del caso de prueba afirma como hecho la causa que H4 retiró del resto.\n\nDos criterios quedan `No verificado` y son del humano: la demostración de la causa, que nadie ha logrado reproducir y el PR ya documenta con honestidad como hipótesis, y la prueba real con una Épica lanzada por `epic-plan`. Copia de trabajo y temporales eliminados.", "total_cost_usd": 0.01, "num_turns": 2}
FIN
  cat >"$tmp/result-task-start-1.json" <<'FIN'
{"result": "DEVKIT-65 entregada: PR #46 abierto con auto-merge, card en Revisión automática.\n\n**Resumen del cambio:** `run_claude` en `devkit-run.sh` ahora arma el `claude -p` hijo con `env -i` y una lista blanca de entorno (en vez de heredarlo tal cual), así un `task-start` lanzado por `epic-plan` anidado no arrastra las marcas de sesión anidada del padre (`CLAUDECODE`, etc.). Antes de lanzar, prueba con `claude mcp list` que Notion está conectada; si no, avisa con `ALARMA:` y no lanza. Si el propio resultado dice \"sin acceso a Notion\" pese a que la sonda pasó, bloquea la card. `--allowedTools` y `settings.json` cubren los dos nombres conocidos del conector. Documentado en README y en la entrada de Notion; 115+114 casos de autoprueba en verde, sin regresiones.\n\n**Limitación que dejé anotada en la card y el PR:** no pude correr la prueba real de punta a punta (una Épica completa lanzada por `epic-plan` en el contenedor de producción) porque esta sesión corre en una sandbox de agente en la nube, no en el devkit Docker real con Notion/GitHub conectados. Queda para confirmar quien revise o el humano.", "total_cost_usd": 0.01, "num_turns": 2}
FIN
  cat >"$tmp/result-task-fix-46-ce49aa6.json" <<'FIN'
{"result":"PR #46: corregí los 3 hallazgos (H10, H11, H12), no descarté ninguno. Head nuevo: `61eadf8`.\n\n- **H10:** `devkit-run.sh` ahora decide que el agente se quedó sin acceso a Notion sobre todo por el campo `permission_denials` del `result`. El texto queda de respaldo: \"notion\" y la frase de falta de acceso deben ir en la misma oración. Además, hice algo que el revisor no pidió: antes de buscar, se descarta lo que va entre comillas o backticks. Sin ese paso, los dos `result` reales (`pr-review-46-7fdb66e.log` y `task-start-1.log`) seguirían bloqueando la card, porque citan entre comillas la frase \"sin acceso a Notion\". Probé la detección con los 7 logs reales de `/run/devkit` y ninguno bloquea. Sumé a la autoprueba esos dos `result` reales, que no bloquean, y un caso que sí bloquea por `permission_denials`. También actualicé el README.\n- **H11:** `forzar_task_block` recibe el motivo como tercer argumento. Cuando falta Notion, la card ya no queda bloqueada con el motivo de \"pregunta abierta\". La autoprueba comprueba el motivo en los dos casos.\n- **H12:** agregué al registro de cambios, en \"Sin publicar\", una viñeta sobre este bloqueo automático.\n\nLa autoprueba `devkit-run.sh --test` pasa con 125 casos correctos, y `bash -n` pasa sin errores. Publiqué la respuesta en el PR con el marcador que lee `pr-review`, sin `manual=1` porque me lanzó el bucle. Después avisé al bucle para que revise.\n\nPor error publiqué antes en el PR un comentario de prueba incompleto. Lo borré enseguida y no afecta al ciclo.","total_cost_usd":0.01,"num_turns":2}
FIN
  local caso_real
  for caso_real in pr-review-46-7fdb66e task-start-1 task-fix-46-ce49aa6; do
    check "el result real de $caso_real.log no bloquea la card" no \
      "$(caso_notion "$caso_real" | cut -d' ' -f1)"
  done

  # El alias `devkit-run` de zshrc no existe en el Bash no interactivo con el
  # que corre `claude -p` (DEVKIT-54: epic-plan y task-close quedaron sin
  # lanzar la siguiente hija porque sus SKILL.md invocaban el alias). La
  # ruta explícita por `DEVKIT_SCRIPTS_DIR`, que es como las llaman ahora,
  # debe resolver igual en ese Bash no interactivo y sin el alias cargado.
  check "el alias devkit-run no existe en un bash -c no interactivo" '' \
    "$(bash -c 'type devkit-run' 2>/dev/null)"
  check "la ruta explícita por DEVKIT_SCRIPTS_DIR encuentra el script sin el alias" 'lanzado: /task-start DEVKIT-9' \
    "$(DEVKIT_SCRIPTS_DIR="$HERE" DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
       DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
       bash -c '"${DEVKIT_SCRIPTS_DIR:-/opt/devkit/scripts}/devkit-run.sh" task-start DEVKIT-9' | head -1)"

  # --modelo/--esfuerzo sin valor deben salir con el mensaje de uso, no
  # colgar el proceso (DEVKIT-50, H3).
  local rc
  timeout 5 bash "$HERE/devkit-run.sh" --modelo >/dev/null 2>&1; rc=$?
  check "--modelo sin valor no cuelga" 64 "$rc"
  timeout 5 bash "$HERE/devkit-run.sh" --esfuerzo >/dev/null 2>&1; rc=$?
  check "--esfuerzo sin valor no cuelga" 64 "$rc"

  # .devkit/roles.toml anula la tabla del template (DEVKIT-53, H3): se prioriza
  # sobre la de ../agents y la del template fallback.
  mkdir -p "$tmp/.devkit"
  cat >"$tmp/.devkit/roles.toml" <<'FIN'
frontera = ["anulacion-proyecto"]
revision.model_index = 1
revision.effort = "high"
revision.max_turns = 99
implementacion.model_index = 1
implementacion.effort = "high"
implementacion.max_turns = 99
FIN
  check "ROLES_FILE desde .devkit/roles.toml (pr-review)" "anulacion-proyecto high 99 -" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_WS="$tmp" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion-1" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" bash "$HERE/devkit-run.sh" --rol '/pr-review 9')"
  check "ROLES_FILE desde .devkit/roles.toml (task-fix)" "anulacion-proyecto high 99 1" \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_WS="$tmp" DEVKIT_FRONTERA_CACHE_DIR="$tmp/frontera-anulacion-2" DEVKIT_WATCH_LOG="$tmp/sonda-watch.log" bash "$HERE/devkit-run.sh" --rol '/task-fix DEVKIT-2')"

  # --- DEVKIT-57: quién lanzó, arranque y --estado ---------------------------
  # Origen por ancestros: el `claude -p /epic-plan` más cercano gana; los
  # lanzadores devkit-run.sh no cuentan; sin claude -p, humano.
  check "origen: claude -p /epic-plan entre los ancestros" epic-plan \
    "$(printf '%s\n' '500 bash -c devkit-run.sh task-start DEVKIT-3' \
         '400 /bin/zsh -c source snapshot; devkit-run task-start DEVKIT-3' \
         '300 claude -p /epic-plan DEVKIT-1 --model fable --effort max' \
         '200 bash /workspace/devkit/scripts/devkit-run.sh --worker /epic-plan DEVKIT-1 x.log fable max 50' \
         | origen_de)"
  check "origen: sin claude -p entre los ancestros es humano" humano \
    "$(printf '%s\n' '500 bash devkit-run.sh task-start DEVKIT-3' '400 -zsh' '1 /sbin/init' | origen_de)"
  check "origen: DEVKIT_ORIGEN declarado manda" task-close \
    "$(DEVKIT_ORIGEN=task-close origen_lanzamiento)"

  # Siguiente modelo de frontera: el que sigue, y tras el último, el primero.
  check "siguiente modelo tras modelo-barato" modelo-medio \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-sig" WATCH_LOG="$tmp/sonda-watch.log" siguiente_modelo modelo-barato)"
  check "siguiente modelo tras el último vuelve al primero" modelo-barato \
    "$(CLAUDE_BIN="$doble" ROLES_FILE="$tmp/roles.toml" FRONTERA_CACHE_DIR="$tmp/frontera-sig" WATCH_LOG="$tmp/sonda-watch.log" siguiente_modelo modelo-fuerte)"

  # Arranque fallido 1: sin el marcador ready, no lanza y lo dice.
  local sin_ready salida
  sin_ready="$tmp/run-sin-ready"
  mkdir -p "$sin_ready"
  salida=$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$sin_ready" DEVKIT_WS="$tmp" DEVKIT_READY_TIMEOUT=1 \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-5 2>&1); rc=$?
  check "arranque sin terminar: sale con 69 y no lanza" "69 no" \
    "$rc $([ -e "$sin_ready/task-start-1.log" ] && echo si || echo no)"
  check "arranque sin terminar: mensaje claro" 'el arranque del contenedor no terminó en 1s' \
    "$(printf '%s' "$salida" | grep -oE 'el arranque del contenedor no terminó en 1s')"

  # Arranque fallido 2: claude -p muere enseguida con error. devkit-run no
  # vuelve con "lanzado" a secas: imprime el final del log y sale con 70.
  local muere
  muere="$tmp/claude-muere"
  printf '#!/usr/bin/env bash\necho "error: token OAuth ausente" >&2\nexit 1\n' >"$muere"
  chmod +x "$muere"
  salida=$(DEVKIT_CLAUDE_BIN="$muere" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" --modelo modelo-x task-start DEVKIT-6 2>&1); rc=$?
  check "arranque fallido: sale con 70" 70 "$rc"
  check "arranque fallido: imprime las últimas líneas del log" 'error: token OAuth ausente' \
    "$(printf '%s' "$salida" | grep -oE 'error: token OAuth ausente' | head -1)"

  # `avisar_atras_de_origin` (DEVKIT-63): repo real, porque lo que mide es
  # `git rev-list --count main..origin/main`, no algo que un doble simule.
  local atras
  atras="$tmp/atras"
  mkdir -p "$atras"
  git init -q --bare "$atras/origin.git"
  git init -q "$atras/ws"
  git -C "$atras/ws" config user.email t@t.com
  git -C "$atras/ws" config user.name t
  git -C "$atras/ws" commit -q --allow-empty -m base
  git -C "$atras/ws" branch -M main
  git -C "$atras/ws" remote add origin "$atras/origin.git"
  git -C "$atras/ws" push -q origin main
  check "avisar_atras_de_origin: al día no avisa" "" \
    "$(WS="$atras/ws" WATCH_LOG="$atras/watch.log" avisar_atras_de_origin "/task-start DEVKIT-1" 2>&1)"
  check "avisar_atras_de_origin: al día no deja ALARMA" 0 \
    "$([ -f "$atras/watch.log" ] && grep -c 'ALARMA' "$atras/watch.log" || echo 0)"
  # origin/main avanza con un commit que el clon todavía no conoce.
  git -C "$atras/ws" commit -q --allow-empty -m adelante
  git -C "$atras/ws" push -q origin main
  git -C "$atras/ws" reset -q --hard HEAD^
  git -C "$atras/ws" fetch -q origin
  check "avisar_atras_de_origin: atrás lo dice por stderr" \
    'el workspace está 1 commit(s) detrás de origin/main' \
    "$(WS="$atras/ws" WATCH_LOG="$atras/watch.log" avisar_atras_de_origin "/task-start DEVKIT-1" 2>&1 >/dev/null \
        | grep -oE 'el workspace está 1 commit\(s\) detrás de origin/main')"
  check "avisar_atras_de_origin: atrás deja ALARMA en watch.log" \
    'ALARMA: workspace 1 commit(s) detrás de origin/main' \
    "$(grep -oE 'ALARMA: workspace 1 commit\(s\) detrás de origin/main' "$atras/watch.log" | head -1)"
  # H1 del PR #53: el remoto avanza otra vez desde un segundo clon y `ws`
  # nunca vuelve a hacer `git fetch` por su cuenta. Antes, la función
  # comparaba contra la referencia `origin/main` que ya tenía guardada -la
  # de la línea 2062, un commit atrás- y se quedaba corta.
  local otro_clon
  otro_clon="$tmp/atras-otro-clon"
  git clone -q "$atras/origin.git" "$otro_clon"
  git -C "$otro_clon" config user.email t@t.com
  git -C "$otro_clon" config user.name t
  git -C "$otro_clon" commit -q --allow-empty -m "avanza sin que ws se entere"
  git -C "$otro_clon" push -q origin main
  check "avisar_atras_de_origin: detecta sin fetch previo del clon" \
    'el workspace está 2 commit(s) detrás de origin/main' \
    "$(WS="$atras/ws" WATCH_LOG="$atras/watch.log" avisar_atras_de_origin "/task-start DEVKIT-1" 2>&1 >/dev/null \
        | grep -oE 'el workspace está 2 commit\(s\) detrás de origin/main')"

  # --estado con un watch.log fijo, un `ps` de mentira y una hora fija: un
  # caso por estado. Las fechas se cuentan hacia atrás desde AHORA.
  local est ahora pslist
  est="$tmp/estado"
  mkdir -p "$est"
  ahora=$(date -d '2026-09-16T12:00:00Z' +%s)
  printf '{"result":"a medias"}\n' >"$est/task-fix-2.log"
  : >"$est/task-start-2.log"
  cat >"$est/watch.log" <<FIN
2026-09-16T11:00:00Z PR #41 (DEVKIT-56) head abc1234 sin informe: lanzando pr-review
2026-09-16T11:00:00Z pr-review-41-abc1234 lanzando (origen=bucle): "/pr-review 41" log=$est/pr-review-41-abc1234.log
2026-09-16T11:05:00Z pr-review-41-abc1234 terminado: modelo=fable esfuerzo=high costo=1.0 turnos=9 :: OK
2026-09-16T11:06:00Z PR #100 (DEVKIT-100) head aaa1111 sin informe: lanzando pr-review
2026-09-16T11:06:00Z pr-review-100-aaa1111 lanzando (origen=bucle): "/pr-review 100" log=$est/pr-review-100-aaa1111.log
2026-09-16T11:07:00Z pr-review-100-aaa1111 terminado: modelo=fable esfuerzo=high costo=1.0 turnos=9 :: OK
2026-09-16T11:07:01Z PR #100 (DEVKIT-100) OK en aaa1111: task-document.sh
2026-09-16T11:08:00Z PR #101 (DEVKIT-101) head bbb2222 sin informe: lanzando pr-review
2026-09-16T11:08:00Z pr-review-101-bbb2222 lanzando (origen=bucle): "/pr-review 101" log=$est/pr-review-101-bbb2222.log
2026-09-16T11:09:00Z pr-review-101-bbb2222 terminado: modelo=fable esfuerzo=high costo=1.0 turnos=9 :: CAMBIOS
2026-09-16T11:09:01Z PR #101 (DEVKIT-101) CAMBIOS en bbb2222: lanzando task-fix
2026-09-16T11:10:00Z PR #102 (DEVKIT-102) head ccc3333 sin informe: lanzando pr-review
2026-09-16T11:10:00Z pr-review-102-ccc3333 lanzando (origen=bucle): "/pr-review 102" log=$est/pr-review-102-ccc3333.log
2026-09-16T11:11:00Z pr-review-102-ccc3333 terminado: modelo=fable esfuerzo=high costo=1.0 turnos=9 :: CAMBIOS
2026-09-16T11:11:01Z PR #102 (DEVKIT-102) 3 ciclos sin OK: bloqueando con task-block.sh
2026-09-16T11:11:02Z task-block.sh DEVKIT-102 Bloqueada desde Revisión automática: Tres ciclos de revisión y corrección sin veredicto OK en el PR https://github.com/o/r/pull/102
2026-09-16T11:11:03Z task-block-102 terminado: bash :: task-block: DEVKIT-102 Bloqueada desde Revisión automática
2026-09-16T11:08:00Z task-start-5 lanzando (origen=humano): "/task-start DEVKIT-5" log=$est/task-start-5.log
2026-09-16T11:10:00Z task-start-1 lanzando (origen=task-close): "/task-start DEVKIT-57" log=$est/task-start-1.log
2026-09-16T11:12:00Z task-block.sh DEVKIT-5 Bloqueada desde En progreso: motivo de la cinco.
2026-09-16T11:12:05Z devkit-run "/task-start DEVKIT-5" terminado [task-start-5]: modelo=opus esfuerzo=high ronda=1 :: bloqueada
2026-09-16T11:20:00Z task-fix-1 lanzando (origen=humano): "/task-fix DEVKIT-58" log=$est/task-fix-1.log
2026-09-16T11:21:00Z devkit-run "/task-fix DEVKIT-58" falló (rc=1) [task-fix-1]: modelo=opus esfuerzo=high ronda=2 :: error
2026-09-16T11:30:00Z task-start-3 lanzando (origen=epic-plan): "/task-start DEVKIT-59" log=$est/task-start-3.log
2026-09-16T11:31:00Z task-block.sh DEVKIT-59 Bloqueada desde En progreso: Qué intenté: X. Qué necesito: el token de Y.
2026-09-16T11:31:05Z devkit-run "/task-start DEVKIT-59" terminado [task-start-3]: modelo=opus esfuerzo=high :: bloqueada
2026-09-16T11:40:00Z task-start-2 lanzando (origen=humano): "/task-start DEVKIT-60" log=$est/task-start-2.log
2026-09-16T11:45:00Z task-start-4 lanzando (origen=task-close): "/task-start DEVKIT-63" log=$est/task-start-4.log
2026-09-16T11:46:00Z devkit-run "/task-start DEVKIT-63" terminado [task-start-4]: modelo=sonnet esfuerzo=high ronda=1 :: dejo la decisión a tu criterio
2026-09-16T11:46:00Z devkit-run "/task-start DEVKIT-63" ALARMA: terminó sin entregar ni bloquear (DEVKIT-63): card sigue En progreso, sin PR ni bloqueo
2026-09-16T11:59:58Z task-fix-2 lanzando (origen=humano): "/task-fix DEVKIT-61" log=$est/task-fix-2.log
FIN
  pslist="$tmp/ps-estado"
  printf '#!/usr/bin/env bash\necho "4242 bash devkit-run.sh --worker /task-start DEVKIT-57 %s/task-start-1.log opus high 40"\n' "$est" >"$pslist"
  chmod +x "$pslist"
  # Columna PR (DEVKIT-134): un doble de `gh repo view` determinista -sin él,
  # el enlace real depende de si el sandbox de la autoprueba tiene `gh`
  # autenticado o no-, con REPO_NAME_WITH_OWNER_CACHE apuntando a un archivo
  # propio: el real (poblado ya al arrancar el script, para ANCHO_PR) no debe
  # pisar esta corrida ni esta corrida pisarlo a él.
  local gh_doble_pr
  gh_doble_pr="$est/gh-doble"
  cat >"$gh_doble_pr" <<'FIN'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo 'o/r' ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$gh_doble_pr"
  local filas
  filas=$(REPO_NAME_WITH_OWNER_CACHE="$est/repo.cache" GH_BIN="$gh_doble_pr" PS_BIN="$pslist" LOCK="$est/skill.lock" estado_filas "$est/watch.log" "$ahora")
  fila() { printf '%s\n' "$filas" | awk -F'\t' -v c="$1" '$2 == c {print $5 "|" $3; exit}'; }
  check "estado terminó (pr-review, Clave desde la línea del PR)" "terminó|bucle" "$(fila DEVKIT-56)"
  # DEVKIT-134: columna PR, el enlace completo de la fila con PR (pr-review,
  # número tomado de su propio argumento) y "-" en la fila sin PR (task-start,
  # que crea la card sin PR todavía).
  check "columna PR: enlace completo para una fila con PR (pr-review)" \
    "https://github.com/o/r/pull/41" \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-56" {print $10}')"
  check "columna PR: un guion para una fila sin PR (task-start)" "-" \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-59" {print $10}')"
  check "estado en curso (proceso vivo)" "en curso|task-close" "$(fila DEVKIT-57)"
  check "estado error (rc distinto de cero)" "error|humano" "$(fila DEVKIT-58)"
  check "estado bloqueada, con el motivo" "bloqueada|epic-plan" "$(fila DEVKIT-59)"
  check "motivo del bloqueo en el detalle" "Qué intenté: X. Qué necesito: el token de Y." \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-59" {print $6}')"
  # Un lanzamiento de DEVKIT-57 entre medio no corta el bloqueo de DEVKIT-5:
  # la Clave se compara completa, no como prefijo.
  check "estado bloqueada con otra Clave que la extiende en medio" "bloqueada|humano" "$(fila DEVKIT-5)"
  check "estado no arrancó (sin proceso, log vacío, pasado el margen)" "no arrancó|humano" "$(fila DEVKIT-60)"
  # DEVKIT-77: un task-start que "terminó" pero dejó su card En progreso sin
  # PR ni bloqueo (DEVKIT-63) cuenta como error, no como avance.
  check "estado error: task-start terminó sin entregar ni bloquear" "error|task-close" "$(fila DEVKIT-63)"
  check "detalle: task-start terminó sin entregar ni bloquear" \
    "terminó sin entregar ni bloquear; card DEVKIT-63 sigue En progreso" \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-63" {print $6}')"
  # Evidencia del 2026-09-16: dos segundos después de "lanzando", sin ningún
  # proceso todavía, el lanzamiento ya cuenta como en curso.
  check "estado en curso desde la línea lanzando, sin proceso" "en curso|humano" "$(fila DEVKIT-61)"
  check "la tabla trae skill y hace cuánto" "task-fix 2s" \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-61" {print $1, $4}')"

  # DEVKIT-132: ESTADO de una fila pr-review terminada muestra el veredicto
  # del bucle, leído de la línea de decisión que watch.sh deja para ese PR y
  # head, no el genérico "terminó". DEVKIT-56 arriba ya cubre el caso "sin
  # línea de decisión todavía": sigue "terminó".
  check "pr-review terminado con OK: ESTADO Lista para merge" "Lista para merge|bucle" \
    "$(fila DEVKIT-100)"
  check "pr-review terminado con CAMBIOS: ESTADO CAMBIOS" "CAMBIOS|bucle" \
    "$(fila DEVKIT-101)"
  check "pr-review terminado y bloqueado (tres ciclos sin OK): ESTADO Bloqueada" \
    "Bloqueada|bucle" "$(fila DEVKIT-102)"
  check "detalle del bloqueo real de pr-review conserva el motivo" \
    "Tres ciclos de revisión y corrección sin veredicto OK en el PR https://github.com/o/r/pull/102" \
    "$(printf '%s\n' "$filas" | awk -F'\t' '$2 == "DEVKIT-102" {print $6}')"
  check "pr-review sin línea de decisión todavía: sigue terminó (DEVKIT-56)" \
    "terminó|bucle" "$(fila DEVKIT-56)"
  estado_de_fila() { printf '%s\n' "$filas" | awk -F'\t' -v c="$1" '$2 == c {print $5; exit}'; }
  check "icono: Lista para merge, mismo que terminó" '✔' \
    "$(glifo_estado_fila "$(estado_de_fila DEVKIT-100)" 0 1 1)"
  check "icono: Bloqueada (pr-review), mismo que bloqueada" '⊘' \
    "$(glifo_estado_fila "$(estado_de_fila DEVKIT-102)" 0 1 1)"
  check "icono: CAMBIOS, sin caso propio, cae en la alarma ámbar" '⚠' \
    "$(glifo_estado_fila "$(estado_de_fila DEVKIT-101)" 0 1 1)"
  check "color: Lista para merge, verde y negrita" verde-negrita \
    "$(color_de_estado_fila "Lista para merge")"
  check "color: Bloqueada (pr-review), rojo y negrita" rojo-negrita \
    "$(color_de_estado_fila "Bloqueada")"
  check "color: CAMBIOS, ámbar sin negrita (el defecto de color_de_estado_fila)" ambar \
    "$(color_de_estado_fila "CAMBIOS")"
  check "colorear: negrita sobre verde suma el atributo ANSI 1" si \
    "$(colorear verde-negrita texto 1 | grep -qF $'\033[1;32m' && echo si || echo no)"
  check "colorear: negrita sobre rojo suma el atributo ANSI 1" si \
    "$(colorear rojo-negrita texto 1 | grep -qF $'\033[1;31m' && echo si || echo no)"
  check "colorear: un color sin -negrita no suma el atributo 1" no \
    "$(colorear verde texto 1 | grep -qF $'\033[1;' && echo si || echo no)"
  check "formatear_fila: Lista para merge se pinta verde y negrita" si \
    "$(formatear_fila pr-review DEVKIT-100 - bucle 1m 1m "Lista para merge" fable/high -/40 - 0 1 1 \
        | grep -qF $'\033[1;32m' && echo si || echo no)"
  check "columna ESTADO no cambia de ancho con Lista para merge (el estado más largo)" \
    "$ANCHO_COLUMNAS_FIJAS" \
    "$(fila_ancho=$(COLUMNS=200 formatear_fila pr-review DEVKIT-100 - bucle 1m 1m "Lista para merge" fable/high -/40 - 0 1 0); echo $((${#fila_ancho} - 1)))"

  # DEVKIT-107: columnas DURÓ y TURNOS, más "no lanzó" cuando review-prep.sh
  # corta un pr-review con salida 3 (en vez de "error: murió sin resumen").
  # Watch.log aparte del de arriba: agregar filas ahí arriesgaba romper los
  # conteos de Épica/"bloquea a" que ya lo reutilizan más abajo.
  local turnos_est turnos_ahora filas_turnos
  turnos_est="$tmp/turnos"
  mkdir -p "$turnos_est"
  turnos_ahora=$(date -d '2026-09-19T12:00:10Z' +%s)
  : >"$turnos_est/pr-review-72-abc1234.log"
  printf 'nada que revisar (ya revisado en def5678)\n' >"$turnos_est/pr-review-73-def5678.log"
  cat >"$turnos_est/watch.log" <<FIN
2026-09-19T11:00:00Z task-fix-1 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-70" log=$turnos_est/task-fix-1.log
2026-09-19T11:10:12Z devkit-run "/task-fix DEVKIT-70" terminado [task-fix-1]: modelo=opus esfuerzo=high ronda=1 costo=0.50 turnos=45 duracion=612s :: OK
2026-09-19T11:20:00Z task-fix-2 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-71" log=$turnos_est/task-fix-2.log
2026-09-19T11:35:00Z devkit-run "/task-fix DEVKIT-71" terminado [task-fix-2]: modelo=opus esfuerzo=high ronda=1 costo=0.90 turnos=67 :: OK
2026-09-19T11:59:00Z PR #72 (DEVKIT-72) head abc1234 sin informe: lanzando pr-review
2026-09-19T11:59:00Z pr-review-72-abc1234 lanzando (origen=bucle) modelo=fable esfuerzo=high ronda=-: "/pr-review 72" log=$turnos_est/pr-review-72-abc1234.log
2026-09-19T12:00:00Z PR #73 (DEVKIT-73) head def5678 sin informe: lanzando pr-review
2026-09-19T12:00:00Z pr-review-73-def5678 lanzando (origen=bucle) modelo=fable esfuerzo=high ronda=-: "/pr-review 73" log=$turnos_est/pr-review-73-def5678.log
2026-09-19T12:00:05Z pr-review-73-def5678 no lanzó: nada que revisar (ya revisado en def5678)
FIN
  filas_turnos=$(estado_filas "$turnos_est/watch.log" "$turnos_ahora")
  campo() { printf '%s\n' "$filas_turnos" | awk -F'\t' -v c="$1" -v n="$2" '$2 == c {print $n; exit}'; }
  # presupuesto.task-fix = 60 en roles.toml.
  check "TURNOS dentro de la meta: usados/presupuesto, sin marca" "45/60" "$(campo DEVKIT-70 9)"
  check "TURNOS que supera la meta: usados/presupuesto con !" "67/60!" "$(campo DEVKIT-71 9)"
  check "TURNOS excedido lleva color rojo" si \
    "$(formatear_fila task-fix DEVKIT-71 - humano 15m 11m terminó opus/high '67/60!' - 0 1 1 \
        | grep -qF $'\033[31m' && echo si || echo no)"
  check "TURNOS dentro de la meta no lleva color" no \
    "$(formatear_fila task-fix DEVKIT-70 - humano 15m 10m terminó opus/high '45/60' - 0 1 1 \
        | grep -qF $'\033[31m' && echo si || echo no)"
  # presupuesto.pr-review = 40; "en curso" no tiene turnos todavía.
  check "TURNOS en curso: -/presupuesto" "-/40" "$(campo DEVKIT-72 9)"
  check "DURÓ con duracion=: mismo formato que HACE (612s -> 10m)" "10m" "$(campo DEVKIT-70 8)"
  check "DURÓ sin duracion= en la línea terminado: un guion" "-" "$(campo DEVKIT-71 8)"
  check "DURÓ en curso: crece con HACE (misma línea lanzando)" si \
    "$([ "$(campo DEVKIT-72 4)" = "$(campo DEVKIT-72 8)" ] && echo si || echo no)"
  # review-prep.sh (rc=3, "nada que revisar") no es un error: la fila queda en
  # estado normal "no lanzó", con el motivo -la única línea del log- en
  # DETALLE, no "murió sin resumen".
  check "review-prep corta con rc=3: ESTADO es 'no lanzó', no 'error'" "no lanzó" "$(campo DEVKIT-73 5)"
  check "review-prep corta con rc=3: DETALLE trae el motivo, no 'murió sin resumen'" \
    "nada que revisar (ya revisado en def5678)" "$(campo DEVKIT-73 6)"
  check "review-prep corta con rc=3: sin turnos, contra el presupuesto de pr-review" "-/40" "$(campo DEVKIT-73 9)"
  check "review-prep corta con rc=3: sin duracion=, DURÓ es un guion" "-" "$(campo DEVKIT-73 8)"
  check "icono: \"no lanzó\" también gris (mismo caso que \"no arrancó\")" gris \
    "$(color_de_estado_fila "no lanzó")"
  # DEVKIT-133 H3: "en espera" listado a propósito en el case, no dependiendo
  # del comodín `*)`, para que un case nuevo no lo pinte de otro color sin que
  # nadie lo note.
  check "icono: \"en espera\" (fila sintética de la card DEVKIT-133) color ámbar" ambar \
    "$(color_de_estado_fila "en espera")"
  check "encabezado_tabla: orden nuevo, DURÓ junto a HACE y TURNOS antes de DETALLE, PR entre CARD y LANZÓ" \
    "SKILL CARD PR LANZÓ HACE DURÓ ESTADO MODELO TURNOS DETALLE" \
    "$(encabezado_tabla | tr -s ' ')"

  # DEVKIT-106: un icono por estado, sobre las mismas filas de arriba. `fijo=1`
  # (una sola foto) deja "en curso" quieto en ⠿; con `fijo=0` (--seguir) gira
  # una posición por <idx>.
  local estado_de
  estado_de() { printf '%s\n' "$filas" | awk -F'\t' -v c="$1" '$2 == c {print $5; exit}'; }
  check "icono: en curso, girador fijo en una sola foto" '⠿' \
    "$(glifo_estado_fila "$(estado_de DEVKIT-57)" 0 1 1)"
  # LC_ALL=C.UTF-8 fijo (DEVKIT-106 H6, reabierto): sin esto, bash corta
  # `${GIRO_BRAILLE:1:1}` por bytes bajo la locale de quien corre la
  # autoprueba y devuelve un byte suelto en vez de ⠙.
  check "icono: en curso, gira una posición por refresco de --seguir" '⠙' \
    "$(LC_ALL=C.UTF-8 glifo_estado_fila "$(estado_de DEVKIT-57)" 1 0 1)"
  check "icono: terminó" '✔' "$(glifo_estado_fila "$(estado_de DEVKIT-56)" 0 1 1)"
  check "icono: terminó, color verde" verde "$(color_de_estado_fila "$(estado_de DEVKIT-56)")"
  check "icono: error" '✖' "$(glifo_estado_fila "$(estado_de DEVKIT-58)" 0 1 1)"
  check "icono: error, color rojo" rojo "$(color_de_estado_fila "$(estado_de DEVKIT-58)")"
  check "icono: bloqueada" '⊘' "$(glifo_estado_fila "$(estado_de DEVKIT-59)" 0 1 1)"
  check "icono: bloqueada, color rojo" rojo "$(color_de_estado_fila "$(estado_de DEVKIT-59)")"
  # DEVKIT-106 H1: `⛔` es East Asian Wide y mide dos celdas visibles aunque
  # `rellenar` la cuente como una -el icono debe medir una sola celda, igual
  # que el resto de la tabla.
  check "icono: bloqueada mide una sola celda visible, igual que terminó" si \
    "$([ "$(printf '⊘' | wc -L)" -eq "$(printf '✔' | wc -L)" ] && echo si || echo no)"
  check "icono: no arrancó (una card que nunca llegó a lanzar)" '○' \
    "$(glifo_estado_fila "$(estado_de DEVKIT-60)" 0 1 1)"
  check "icono: no arrancó, color gris" gris "$(color_de_estado_fila "$(estado_de DEVKIT-60)")"
  check "icono: \"no lanzó\" es el mismo caso que \"no arrancó\", mismo icono" '○' \
    "$(glifo_estado_fila "no lanzó" 0 1 1)"
  check "columna ESTADO no cambia de ancho con un estado corto (terminó)" "$ANCHO_COLUMNAS_FIJAS" \
    "$(fila_ancho=$(COLUMNS=200 formatear_fila task-start DEVKIT-1 - bucle 1m 9m terminó sonnet/high -/40 - 0 1 0); echo $((${#fila_ancho} - 1)))"
  # El estado más largo con icono es "⚠ sin registro" (14, DEVKIT-106 H2), no
  # "no arrancó" (10): antes este caso no probaba el borde real de la
  # columna y dejaba pasar la regresión de H2.
  check "columna ESTADO no cambia de ancho con el estado más largo (sin registro)" "$ANCHO_COLUMNAS_FIJAS" \
    "$(fila_ancho=$(COLUMNS=200 formatear_fila task-close DEVKIT-9 - bucle 8m 8m "sin registro" sonnet/high -/40 - 0 1 0); echo $((${#fila_ancho} - 1)))"
  check "columna ESTADO deja al menos un espacio antes de MODELO (sin registro)" si \
    "$(COLUMNS=200 formatear_fila task-close DEVKIT-9 - bucle 8m 8m "sin registro" sonnet/high -/40 - 0 1 0 \
        | grep -qF ' sonnet/high' && echo si || echo no)"
  # DEVKIT-107 H4: con CARD=11, DEVKIT-9999 (11 caracteres) llenaba toda la
  # columna y `rellenar` no agregaba el espacio de separación con la columna
  # PR que sigue (DEVKIT-134 corrió esta columna: antes era LANZÓ).
  check "columna CARD deja un espacio antes de PR con una Clave de 11 caracteres" si \
    "$(COLUMNS=200 formatear_fila task-start DEVKIT-9999 - bucle 1m 9m terminó sonnet/high -/40 - 0 1 0 \
        | grep -qF 'DEVKIT-9999 -' && echo si || echo no)"

  # DEVKIT-131: ANCHO_LANZO se fijaba a mano (8) y no le entraba "task-close"
  # (10) -la fila entera se corría dos columnas hacia la derecha, y con ella
  # el resto de la tabla-. Ahora sale de ORIGENES_LANZAMIENTO (junto a los
  # demás ANCHO_*, arriba). Esta fila prueba el caso real: task-close como
  # LANZÓ (no como SKILL, que ya cubría la fila de "estado más largo" de
  # abajo), comparando contra el mismo desplazamiento que usa `encabezado_tabla`.
  # ANCHO_PR (DEVKIT-134) suma al desplazamiento: PR se intercala entre CARD
  # y LANZÓ.
  off_hace_131=$((ANCHO_SKILL + ANCHO_CARD + ANCHO_PR + ANCHO_LANZO))
  fila_lanzo_131=$(COLUMNS=200 formatear_fila task-fix DEVKIT-12 - task-close 5m 5m terminó opus/high 3/60 - 0 1 0)
  check "LANZÓ=task-close: el ancho fijo total no cambia" "$ANCHO_COLUMNAS_FIJAS" \
    "$((${#fila_lanzo_131} - 1))"
  check "LANZÓ=task-close no corre la columna HACE, alineada con la cabecera" \
    "$(rellenar 5m "$ANCHO_HACE")" "${fila_lanzo_131:$off_hace_131:$ANCHO_HACE}"

  # Misma prueba de alineación para el otro extremo: el estado más largo
  # ("⚠ sin registro", 14) tampoco debe correr la columna que sigue a ESTADO
  # (MODELO).
  off_modelo_131=$((ANCHO_SKILL + ANCHO_CARD + ANCHO_PR + ANCHO_LANZO + ANCHO_HACE + ANCHO_DURO + ANCHO_ESTADO))
  fila_estado_131=$(COLUMNS=200 formatear_fila task-document DEVKIT-9 - humano 8m 8m "sin registro" fable/max -/40 - 0 1 0)
  check "ESTADO=sin registro no corre la columna MODELO, alineada con la cabecera" \
    "$(rellenar fable/max "$ANCHO_MODELO")" "${fila_estado_131:$off_modelo_131:$ANCHO_MODELO}"
  unset off_hace_131 fila_lanzo_131 off_modelo_131 fila_estado_131

  # DEVKIT-131 H1: SKILL salía de una lista fija de cinco nombres, y
  # template-propagate (18) ya no entraba en ANCHO_SKILL=14. El skill más
  # largo se toma de SKILLS_CON_LANZAMIENTO, la misma lista que arma
  # ANCHO_SKILL -si crece con un nombre más largo, este caso lo sigue sin
  # tocarlo a mano.
  skill_mas_largo_131=""
  for _skill_131 in "${SKILLS_CON_LANZAMIENTO[@]}"; do
    [ "${#_skill_131}" -gt "${#skill_mas_largo_131}" ] && skill_mas_largo_131=$_skill_131
  done
  fila_skill_131=$(COLUMNS=200 formatear_fila "$skill_mas_largo_131" DEVKIT-13 - humano 1m 1m terminó sonnet/high -/40 - 0 1 0)
  check "SKILL=<skill más largo> no corre la columna CARD, alineada con la cabecera" \
    "$(rellenar "$skill_mas_largo_131" "$ANCHO_SKILL")" "${fila_skill_131:0:$ANCHO_SKILL}"
  check "SKILL=<skill más largo>: el ancho fijo total no cambia" "$ANCHO_COLUMNAS_FIJAS" \
    "$((${#fila_skill_131} - 1))"
  unset _skill_131 skill_mas_largo_131 fila_skill_131

  # DEVKIT-134: columna PR (el enlace completo entre CARD y LANZÓ) y SKILL en
  # negrita para task-start. `pr_de_lanzamiento` primero: el número de PR de
  # cada skill real.
  check "pr_de_lanzamiento: pr-review lo recibe como su propio argumento" "41" \
    "$(pr_de_lanzamiento pr-review 41 pr-review-1)"
  check "pr_de_lanzamiento: task-fix lo lleva en el id (task-fix-<n>-<sha>)" "31" \
    "$(pr_de_lanzamiento task-fix DEVKIT-77 task-fix-31-abc1234)"
  check "pr_de_lanzamiento: task-document lo lleva en el id" "46" \
    "$(pr_de_lanzamiento task-document DEVKIT-9 task-document-46-def5678)"
  check "pr_de_lanzamiento: task-close lo lleva en el id (sin sha)" "31" \
    "$(pr_de_lanzamiento task-close - task-close-31)"
  check "pr_de_lanzamiento: task-start no tiene PR todavía" "-" \
    "$(pr_de_lanzamiento task-start DEVKIT-3 task-start-3)"

  # `url_de_pr`/`repo_name_with_owner`: el owner/repo real, con un doble de
  # `gh repo view` y REPO_NAME_WITH_OWNER_CACHE apuntando a un archivo propio
  # -no debe pisar ni ser pisado por el caché real de esta misma corrida de
  # `--test`, ya poblado al arrancar el script para ANCHO_PR.
  local pr_url_tmp gh_doble_pr_url gh_contador_pr
  pr_url_tmp=$(mktemp -d)
  gh_doble_pr_url="$pr_url_tmp/gh-doble"
  cat >"$gh_doble_pr_url" <<'FIN'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo 'byroncz/dotfiles' ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$gh_doble_pr_url"
  check "url_de_pr: arma el enlace completo con owner/repo de gh repo view" \
    "https://github.com/byroncz/dotfiles/pull/41" \
    "$(REPO_NAME_WITH_OWNER_CACHE="$pr_url_tmp/repo-1.cache" GH_BIN="$gh_doble_pr_url" url_de_pr 41)"
  check "url_de_pr: sin número de PR, un guion" "-" "$(url_de_pr -)"

  # Caché de verdad esta vez (no una nueva por llamada): dos lecturas seguidas
  # solo deben pagar una consulta a `gh`.
  gh_contador_pr="$pr_url_tmp/gh-contador"
  cat >"$gh_contador_pr" <<FIN
#!/usr/bin/env bash
echo x >> "$pr_url_tmp/llamadas"
echo 'o/r'
FIN
  chmod +x "$gh_contador_pr"
  REPO_NAME_WITH_OWNER_CACHE="$pr_url_tmp/repo-2.cache" GH_BIN="$gh_contador_pr" url_de_pr 1 >/dev/null
  REPO_NAME_WITH_OWNER_CACHE="$pr_url_tmp/repo-2.cache" GH_BIN="$gh_contador_pr" url_de_pr 2 >/dev/null
  check "repo_name_with_owner: una sola llamada a gh mientras la caché exista" 1 \
    "$(wc -l < "$pr_url_tmp/llamadas" | tr -d ' ')"

  # DEVKIT-134 H1: un fallo de `gh` no envenena la caché. Sobre el mismo
  # archivo, primero un doble que falla y después uno sano: la segunda
  # llamada debe volver a consultar `gh` y ya devolver el owner/repo.
  local gh_falla_pr repo_h1_cache
  gh_falla_pr="$pr_url_tmp/gh-falla"
  cat >"$gh_falla_pr" <<'FIN'
#!/usr/bin/env bash
exit 1
FIN
  chmod +x "$gh_falla_pr"
  repo_h1_cache="$pr_url_tmp/repo-h1.cache"
  check "repo_name_with_owner: '-' sin persistir cuando gh falla" "-" \
    "$(REPO_NAME_WITH_OWNER_CACHE="$repo_h1_cache" GH_BIN="$gh_falla_pr" repo_name_with_owner)"
  check "repo_name_with_owner: el fallo anterior no dejó caché" no \
    "$([ -s "$repo_h1_cache" ] && echo si || echo no)"
  check "repo_name_with_owner: se recupera en cuanto gh vuelve a responder" \
    "byroncz/dotfiles" \
    "$(REPO_NAME_WITH_OWNER_CACHE="$repo_h1_cache" GH_BIN="$gh_doble_pr_url" repo_name_with_owner)"
  unset gh_falla_pr repo_h1_cache
  rm -rf "$pr_url_tmp"

  # `formatear_fila`: la columna PR entre CARD y LANZÓ, con el enlace completo
  # ya armado (llega formateado desde `estado_filas`, esta función solo
  # alinea) y "-" en la fila sin PR.
  local off_pr_134 fila_con_pr_134 fila_sin_pr_134
  off_pr_134=$((ANCHO_SKILL + ANCHO_CARD))
  fila_con_pr_134=$(COLUMNS=200 formatear_fila task-fix DEVKIT-12 "https://github.com/o/r/pull/41" humano 5m 5m terminó opus/high 3/60 - 0 1 0)
  check "columna PR: el enlace completo entre CARD y LANZÓ" \
    "$(rellenar "https://github.com/o/r/pull/41" "$ANCHO_PR")" \
    "${fila_con_pr_134:$off_pr_134:$ANCHO_PR}"
  fila_sin_pr_134=$(COLUMNS=200 formatear_fila task-start DEVKIT-13 - bucle 1m 9m terminó sonnet/high -/40 - 0 1 0)
  check "columna PR: un guion en la fila sin PR (task-start)" \
    "$(rellenar - "$ANCHO_PR")" \
    "${fila_sin_pr_134:$off_pr_134:$ANCHO_PR}"
  unset off_pr_134 fila_con_pr_134 fila_sin_pr_134

  # SKILL en negrita solo para task-start (DEVKIT-134): distingue de un
  # vistazo la fila que abre una card de la que la continúa.
  check "SKILL en negrita para task-start" si \
    "$(COLUMNS=200 formatear_fila task-start DEVKIT-13 - bucle 1m 9m terminó sonnet/high -/40 - 0 1 1 \
        | grep -qF $'\033[1m' && echo si || echo no)"
  check "SKILL sin negrita para otra skill (task-fix)" no \
    "$(COLUMNS=200 formatear_fila task-fix DEVKIT-13 - bucle 1m 9m terminó sonnet/high -/40 - 0 1 1 \
        | grep -qF $'\033[1m' && echo si || echo no)"
  check "SKILL de task-start sin color habilitado: sin secuencias ANSI" no \
    "$(COLUMNS=200 formatear_fila task-start DEVKIT-13 - bucle 1m 9m terminó sonnet/high -/40 - 0 1 0 \
        | grep -qF $'\033[1m' && echo si || echo no)"

  # Respaldo ASCII (DEVKIT-106): un carácter equivalente por icono cuando
  # LANG/LC_ALL no declaran UTF-8 -bash cuenta bytes, no caracteres, fuera de
  # esa locale, y un icono multibyte desalinearía `rellenar`.
  check "utf8_disponible: LANG=C.UTF-8 cuenta como UTF-8" si \
    "$(LC_ALL= LANG=C.UTF-8 utf8_disponible && echo si || echo no)"
  check "utf8_disponible: LANG=C no cuenta como UTF-8" no \
    "$(LC_ALL= LANG=C utf8_disponible && echo si || echo no)"
  # DEVKIT-106 H8: LC_CTYPE manda sobre LANG, igual que en la libc -es lo que
  # decide cómo bash cuenta caracteres, aunque LANG declare UTF-8.
  check "utf8_disponible: LC_CTYPE=C gana a LANG=C.UTF-8" no \
    "$(LC_ALL= LANG=C.UTF-8 LC_CTYPE=C utf8_disponible && echo si || echo no)"
  check "icono ASCII: en curso" '*' "$(glifo_estado_fila "$(estado_de DEVKIT-57)" 0 1 0)"
  check "icono ASCII: terminó" 'ok' "$(glifo_estado_fila "$(estado_de DEVKIT-56)" 0 1 0)"
  check "icono ASCII: error" 'x' "$(glifo_estado_fila "$(estado_de DEVKIT-58)" 0 1 0)"
  check "icono ASCII: bloqueada" '!!' "$(glifo_estado_fila "$(estado_de DEVKIT-59)" 0 1 0)"
  check "icono ASCII: no arrancó" 'o' "$(glifo_estado_fila "$(estado_de DEVKIT-60)" 0 1 0)"

  # Punto de la cabecera (DEVKIT-106): verde con una fila en curso (aunque el
  # bucle esté MUERTO: la fila manda), ámbar sin ninguna pero con el bucle
  # vivo o esperando una skill, rojo con el bucle MUERTO o SIN SEÑAL.
  local filas_punto_en_curso filas_punto_sin
  filas_punto_en_curso=$'skill\tDEVKIT-1\torigen\t1s\ten curso\t-\tmodelo'
  filas_punto_sin=$'skill\tDEVKIT-1\torigen\t1s\tterminó\t-\tmodelo'
  check "punto: verde con una fila en curso, aunque el bucle esté MUERTO" si \
    "$(punto_estado "$filas_punto_en_curso" 'bucle: MUERTO, no encuentro watch.sh en ps' 0 1 1 1 \
        | grep -qF $'\033[32m' && echo si || echo no)"
  check "punto: ámbar sin filas en curso, con el bucle vivo" si \
    "$(punto_estado "$filas_punto_sin" 'bucle: vivo, último tick hace 3s' 0 1 1 1 \
        | grep -qF $'\033[33m' && echo si || echo no)"
  check "punto: ámbar sin filas en curso, con el bucle esperando una skill" si \
    "$(punto_estado "$filas_punto_sin" 'bucle: esperando pr-review-58 hace 10s' 0 1 1 1 \
        | grep -qF $'\033[33m' && echo si || echo no)"
  check "punto: rojo con el bucle MUERTO" si \
    "$(punto_estado "$filas_punto_sin" 'bucle: MUERTO, no encuentro watch.sh en ps' 0 1 1 1 \
        | grep -qF $'\033[31m' && echo si || echo no)"
  check "punto: rojo con el bucle SIN SEÑAL" si \
    "$(punto_estado "$filas_punto_sin" 'bucle: SIN SEÑAL hace 10m' 0 1 1 1 \
        | grep -qF $'\033[31m' && echo si || echo no)"
  check "punto: la palabra junto al punto (ejecutando/en espera/parado)" \
    "ejecutando|en espera|parado" \
    "$(printf '%s|%s|%s' \
        "$(punto_estado "$filas_punto_en_curso" 'bucle: MUERTO' 0 1 0 0 | cut -d' ' -f2-)" \
        "$(punto_estado "$filas_punto_sin" 'bucle: vivo, último tick hace 1s' 0 1 0 0 | cut -d' ' -f2-)" \
        "$(punto_estado "$filas_punto_sin" 'bucle: MUERTO' 0 1 0 0 | cut -d' ' -f2-)")"
  check "punto: alterna ● lleno y ○ hueco entre dos refrescos de --seguir" '●|○' \
    "$(printf '%s|%s' \
        "$(punto_estado "$filas_punto_en_curso" 'bucle: vivo' 0 0 1 0 | cut -d' ' -f1)" \
        "$(punto_estado "$filas_punto_en_curso" 'bucle: vivo' 1 0 1 0 | cut -d' ' -f1)")"
  check "punto: en una sola foto (sin --seguir) no parpadea, siempre lleno" '●|●' \
    "$(printf '%s|%s' \
        "$(punto_estado "$filas_punto_en_curso" 'bucle: vivo' 0 1 1 0 | cut -d' ' -f1)" \
        "$(punto_estado "$filas_punto_en_curso" 'bucle: vivo' 1 1 1 0 | cut -d' ' -f1)")"
  check "punto ASCII: alterna * lleno y o hueco" '*|o' \
    "$(printf '%s|%s' \
        "$(punto_estado "$filas_punto_en_curso" 'bucle: vivo' 0 0 0 0 | cut -d' ' -f1)" \
        "$(punto_estado "$filas_punto_en_curso" 'bucle: vivo' 1 0 0 0 | cut -d' ' -f1)")"

  # Iconos de `--tablero` (DEVKIT-106): mismo set, sobre el Estado de Notion.
  check "icono tablero: En progreso gira como en curso" '⠿' "$(glifo_estado_tablero "En progreso" 0 1 1)"
  check "icono tablero: Revisión automática gira como en curso" '⠿' \
    "$(glifo_estado_tablero "Revisión automática" 0 1 1)"
  check "icono tablero: Lista para merge" '✔' "$(glifo_estado_tablero "Lista para merge" 0 1 1)"
  check "icono tablero: Lista, la cola, todavía sin lanzar" '○' "$(glifo_estado_tablero Lista 0 1 1)"
  check "icono tablero: Bloqueada" '⊘' "$(glifo_estado_tablero Bloqueada 0 1 1)"

  # `agentes_en_curso_rapido` (DEVKIT-63) cuenta lo mismo que `estado_filas`
  # sobre este mismo watch.log: DEVKIT-57 (proceso vivo) y DEVKIT-61 (gracia).
  check "agentes_en_curso_rapido coincide con las filas en curso de estado_filas" 2 \
    "$(PS_BIN="$pslist" LOCK="$est/skill.lock" agentes_en_curso_rapido "$est/watch.log" "$ahora")"

  # DEVKIT-97 (ampliación del 19:07): ESTADO describe solo el lanzamiento; un
  # bloqueo posterior a que este ya terminó es de otra corrida, no de esta
  # fila -acá, de un `task-block.sh` corrido a mano bastante después, sin
  # ningún lanzamiento entre medio que "reclame" la Clave para sí mismo y
  # corte la búsqueda antes de tiempo.
  local log_bloqueo_tardio pslist_bloqueo_tardio
  log_bloqueo_tardio="$tmp/bloqueo-tardio-watch.log"
  cat >"$log_bloqueo_tardio" <<FIN
2026-09-16T08:00:00Z task-start-94 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-start DEVKIT-94" log=$est/task-start-94b.log
2026-09-16T08:06:00Z devkit-run "/task-start DEVKIT-94" terminado [task-start-94]: modelo=opus esfuerzo=high ronda=1 :: OK
2026-09-16T09:00:00Z task-block.sh DEVKIT-94 Bloqueada desde Lista para merge: motivo ajeno a este lanzamiento.
FIN
  pslist_bloqueo_tardio="$tmp/ps-bloqueo-tardio"
  printf '#!/usr/bin/env bash\n' >"$pslist_bloqueo_tardio"
  chmod +x "$pslist_bloqueo_tardio"
  check "ESTADO no hereda un bloqueo posterior a su propio cierre" "terminó" \
    "$(PS_BIN="$pslist_bloqueo_tardio" LOCK="$est/skill.lock" estado_filas "$log_bloqueo_tardio" "$ahora" \
        | awk -F'\t' '$2 == "DEVKIT-94" {print $5}')"

  # DEVKIT-97 H3: block_pr en watch.sh (tres ciclos sin OK, task-fix vacío dos
  # veces) siempre bloquea DESPUÉS del "terminado" del lanzamiento que cortó,
  # a diferencia de un task-block.sh corrido a mano (el caso de arriba): su
  # propia línea "PR #N (Clave) ...: bloqueando con task-block.sh" precede a
  # la de "Bloqueada" sin ningún lanzamiento nuevo entre medio, y sí debe
  # atribuirse a esta fila.
  local log_bloqueo_pr pslist_bloqueo_pr
  log_bloqueo_pr="$tmp/bloqueo-pr-watch.log"
  cat >"$log_bloqueo_pr" <<FIN
2026-09-16T11:20:00Z task-fix-61-abc lanzando (origen=bucle) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-95" log=$est/task-fix-61-abc.log
2026-09-16T11:25:00Z task-fix-61-abc terminado: modelo=opus esfuerzo=high costo=1.0 turnos=9 :: nada que corregir
2026-09-16T11:25:05Z PR #61 (DEVKIT-95) 3 ciclos sin OK: bloqueando con task-block.sh
2026-09-16T11:25:10Z task-block.sh DEVKIT-95 Bloqueada desde Revisión automática: Tres ciclos de revisión y corrección sin veredicto OK en el PR https://github.com/o/r/pull/61
2026-09-16T11:25:11Z task-block-61 terminado: bash :: task-block: DEVKIT-95 Bloqueada desde Revisión automática
FIN
  pslist_bloqueo_pr="$tmp/ps-bloqueo-pr"
  printf '#!/usr/bin/env bash\n' >"$pslist_bloqueo_pr"
  chmod +x "$pslist_bloqueo_pr"
  check "block_pr: el bloqueo tras el cierre de la fila que cortó sí se le atribuye" "bloqueada" \
    "$(PS_BIN="$pslist_bloqueo_pr" LOCK="$est/skill.lock" estado_filas "$log_bloqueo_pr" "$ahora" \
        | awk -F'\t' '$2 == "DEVKIT-95" {print $5}')"
  check "block_pr: el detalle trae el motivo de Bloqueada, no el de la línea bloqueando" \
    "Tres ciclos de revisión y corrección sin veredicto OK en el PR https://github.com/o/r/pull/61" \
    "$(PS_BIN="$pslist_bloqueo_pr" LOCK="$est/skill.lock" estado_filas "$log_bloqueo_pr" "$ahora" \
        | awk -F'\t' '$2 == "DEVKIT-95" {print $6}')"

  # DEVKIT-97 H6: atender_fix reintenta task-fix sobre la misma Clave antes de
  # que block_pr corte al tercer ciclo. Un lanzamiento nuevo de la Clave debe
  # cortar la lectura del awk de arriba (como ya hace el primer awk), no solo
  # resetear su marca: si sigue leyendo, el bloqueo del último task-fix
  # también se le atribuye a la fila del primero.
  local log_bloqueo_pr_doble pslist_bloqueo_pr_doble
  log_bloqueo_pr_doble="$tmp/bloqueo-pr-doble-watch.log"
  cat >"$log_bloqueo_pr_doble" <<FIN
2026-09-16T11:20:00Z task-fix-61-abc lanzando (origen=bucle) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-95" log=$est/task-fix-61-abc.log
2026-09-16T11:25:00Z task-fix-61-abc terminado: modelo=opus esfuerzo=high costo=1.0 turnos=9 :: nada que corregir
2026-09-16T11:26:00Z task-fix-62-abc lanzando (origen=bucle) modelo=opus esfuerzo=high ronda=2: "/task-fix DEVKIT-95" log=$est/task-fix-62-abc.log
2026-09-16T11:30:00Z task-fix-62-abc terminado: modelo=opus esfuerzo=high costo=1.0 turnos=9 :: nada que corregir
2026-09-16T11:30:05Z PR #61 (DEVKIT-95) 3 ciclos sin OK: bloqueando con task-block.sh
2026-09-16T11:30:10Z task-block.sh DEVKIT-95 Bloqueada desde Revisión automática: Tres ciclos de revisión y corrección sin veredicto OK en el PR https://github.com/o/r/pull/61
2026-09-16T11:30:11Z task-block-61 terminado: bash :: task-block: DEVKIT-95 Bloqueada desde Revisión automática
FIN
  pslist_bloqueo_pr_doble="$tmp/ps-bloqueo-pr-doble"
  printf '#!/usr/bin/env bash\n' >"$pslist_bloqueo_pr_doble"
  chmod +x "$pslist_bloqueo_pr_doble"
  check "block_pr con reintento: el lanzamiento anterior de la Clave no hereda el bloqueo" "terminó" \
    "$(PS_BIN="$pslist_bloqueo_pr_doble" LOCK="$est/skill.lock" estado_filas "$log_bloqueo_pr_doble" "$ahora" \
        | awk -F'\t' '$2 == "DEVKIT-95"' | sed -n '1p' | cut -f5)"
  check "block_pr con reintento: el último lanzamiento sí sale bloqueada" "bloqueada" \
    "$(PS_BIN="$pslist_bloqueo_pr_doble" LOCK="$est/skill.lock" estado_filas "$log_bloqueo_pr_doble" "$ahora" \
        | awk -F'\t' '$2 == "DEVKIT-95"' | sed -n '2p' | cut -f5)"

  # DEVKIT-81: columna modelo, con las dos formas de la línea "lanzando" en el
  # mismo log -la vieja, sin modelo=/esfuerzo=/ronda=, y la nueva.
  local modelo_log
  modelo_log="$tmp/modelo-watch.log"
  : >"$est/task-document-1.log"
  : >"$est/task-fix-3.log"
  cat >"$modelo_log" <<FIN
2026-09-16T11:55:00Z task-document-1 lanzando (origen=task-close) modelo=sonnet esfuerzo=high ronda=1: "/task-document DEVKIT-70" log=$est/task-document-1.log
2026-09-16T11:56:00Z task-fix-3 lanzando (origen=humano): "/task-fix DEVKIT-71" log=$est/task-fix-3.log
FIN
  local filas_modelo
  filas_modelo=$(PS_BIN="$pslist" LOCK="$est/skill.lock" estado_filas "$modelo_log" "$ahora")
  check "columna modelo: línea lanzando nueva, con ronda" "sonnet/high r1" \
    "$(printf '%s\n' "$filas_modelo" | awk -F'\t' '$2 == "DEVKIT-70" {print $7}')"
  check "columna modelo: línea lanzando vieja, sin modelo=, es -" "-" \
    "$(printf '%s\n' "$filas_modelo" | awk -F'\t' '$2 == "DEVKIT-71" {print $7}')"

  # DEVKIT-81, regla sin excepción: un `claude -p` vivo sin línea "lanzando"
  # aparece como fila `sin registro`. La sonda de modelo (`-p ok`) y la
  # lectura de cuota (`-p /usage`) no cuentan, aunque estén vivas.
  local pslist_reg
  pslist_reg="$tmp/ps-sinregistro"
  cat >"$pslist_reg" <<FIN
#!/usr/bin/env bash
cat <<TABLA
501 claude -p ok --model modelo-x --output-format json
502 claude -p /usage --output-format json
503 claude -p /pr-review 99 --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_reg"
  local filas_reg
  filas_reg=$(PS_BIN="$pslist_reg" LOCK="$est/skill.lock" estado_filas "$est/watch.log" "$ahora")
  check "sin registro: un claude -p sin línea lanzando aparece, uno solo" 1 \
    "$(printf '%s\n' "$filas_reg" | awk -F'\t' '$5 == "sin registro"' | wc -l | tr -d ' ')"
  check "sin registro: el detalle trae el pid y el prompt" \
    "claude -p vivo (pid 503) sin línea lanzando: /pr-review 99" \
    "$(printf '%s\n' "$filas_reg" | awk -F'\t' '$5 == "sin registro" {print $6}')"
  check "sin registro: la sonda de modelo (-p ok) no cuenta" 0 \
    "$(printf '%s\n' "$filas_reg" | grep -c 'pid 501')"
  check "sin registro: la lectura de cuota (-p /usage) no cuenta" 0 \
    "$(printf '%s\n' "$filas_reg" | grep -c 'pid 502')"

  # DEVKIT-81 H2: un prompt de más de 120 caracteres queda cortado en la
  # línea "lanzando" (`prompt_en_linea`); comparar el `ps` crudo, sin cortar,
  # contra esa forma daba un falso "sin registro".
  local comentario_largo prompt_largo log_largo pslist_largo
  comentario_largo="comentario humano bastante extenso que agrega contexto de sobra para superar el corte de ciento veinte caracteres que aplica prompt_en_linea sobre la línea lanzando"
  prompt_largo="/task-fix DEVKIT-99 $comentario_largo"
  log_largo="$tmp/largo-watch.log"
  : >"$est/task-fix-99.log"
  printf '%s task-fix-99 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "%s" log=%s/task-fix-99.log\n' \
    "$(date -u -d "@$ahora" +%FT%TZ)" "$(prompt_en_linea "$prompt_largo")" "$est" >"$log_largo"
  pslist_largo="$tmp/ps-largo"
  cat >"$pslist_largo" <<FIN
#!/usr/bin/env bash
cat <<TABLA
701 claude -p $prompt_largo --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_largo"
  check "sin registro: un prompt de más de 120 caracteres no cae en sin registro" 0 \
    "$(PS_BIN="$pslist_largo" LOCK="$est/skill.lock" estado_filas "$log_largo" "$ahora" \
        | awk -F'\t' '$5 == "sin registro"' | wc -l | tr -d ' ')"

  # DEVKIT-81 H2: comillas en el prompt (un comentario humano puede traerlas)
  # se convierten en espacios al escribir la línea "lanzando"
  # (`prompt_en_linea`); el `ps` crudo las conserva. Sin normalizar el lado
  # de `ps` antes de comparar, esto también daba un falso "sin registro".
  local comentario_comillas prompt_comillas log_comillas pslist_comillas
  comentario_comillas='dice "cuidado con esto" en el comentario'
  prompt_comillas="/task-fix DEVKIT-88 $comentario_comillas"
  log_comillas="$tmp/comillas-watch.log"
  : >"$est/task-fix-88.log"
  printf '%s task-fix-88 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "%s" log=%s/task-fix-88.log\n' \
    "$(date -u -d "@$ahora" +%FT%TZ)" "$(prompt_en_linea "$prompt_comillas")" "$est" >"$log_comillas"
  pslist_comillas="$tmp/ps-comillas"
  cat >"$pslist_comillas" <<FIN
#!/usr/bin/env bash
cat <<TABLA
702 claude -p $prompt_comillas --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_comillas"
  check "sin registro: un prompt con comillas normaliza igual que la línea lanzando" 0 \
    "$(PS_BIN="$pslist_comillas" LOCK="$est/skill.lock" estado_filas "$log_comillas" "$ahora" \
        | awk -F'\t' '$5 == "sin registro"' | wc -l | tr -d ' ')"

  # DEVKIT-81 H10: un comentario humano que trae " --" (por ejemplo "no uses
  # --forzar aquí") no debe cortarse ahí: `run_claude` siempre pone
  # `--model` justo después del prompt, así que cortar en el primer " --"
  # partía el prompt antes de tiempo y daba un falso "sin registro".
  local comentario_guiones prompt_guiones log_guiones pslist_guiones
  comentario_guiones="no uses --forzar aquí"
  prompt_guiones="/task-fix DEVKIT-91 $comentario_guiones"
  log_guiones="$tmp/guiones-watch.log"
  : >"$est/task-fix-91.log"
  printf '%s task-fix-91 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "%s" log=%s/task-fix-91.log\n' \
    "$(date -u -d "@$ahora" +%FT%TZ)" "$(prompt_en_linea "$prompt_guiones")" "$est" >"$log_guiones"
  pslist_guiones="$tmp/ps-guiones"
  cat >"$pslist_guiones" <<FIN
#!/usr/bin/env bash
cat <<TABLA
703 claude -p $prompt_guiones --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_guiones"
  check "sin registro: un comentario humano con -- no se corta ahí" 0 \
    "$(PS_BIN="$pslist_guiones" LOCK="$est/skill.lock" estado_filas "$log_guiones" "$ahora" \
        | awk -F'\t' '$5 == "sin registro"' | wc -l | tr -d ' ')"

  # DEVKIT-81 H2: un lanzamiento fuera de la cola visible (ESTADO_FILAS, 20
  # por defecto) sigue vivo y no debe salir como "sin registro"; antes,
  # `prompts_vistos` solo se llenaba con la cola recortada.
  local log_cola pslist_cola i
  log_cola="$tmp/cola-watch.log"
  : >"$est/task-vieja.log"
  printf '%s task-vieja lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-77" log=%s/task-vieja.log\n' \
    "$(date -u -d "@$((ahora - 3600))" +%FT%TZ)" "$est" >"$log_cola"
  for i in $(seq 1 25); do
    printf '%s relleno-%d lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-%d" log=%s/relleno-%d.log\n' \
      "$(date -u -d "@$((ahora - 3600 + i))" +%FT%TZ)" "$i" "$((900 + i))" "$est" "$i" >>"$log_cola"
    printf '%s devkit-run "/task-fix DEVKIT-%d" terminado [relleno-%d]: modelo=opus esfuerzo=high ronda=1 :: ok\n' \
      "$(date -u -d "@$((ahora - 3600 + i + 1))" +%FT%TZ)" "$((900 + i))" "$i" >>"$log_cola"
  done
  pslist_cola="$tmp/ps-cola"
  cat >"$pslist_cola" <<FIN
#!/usr/bin/env bash
cat <<TABLA
801 claude -p /task-fix DEVKIT-77 --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_cola"
  check "sin registro: un lanzamiento fuera de la cola visible sigue contando como activo" 0 \
    "$(PS_BIN="$pslist_cola" LOCK="$est/skill.lock" estado_filas "$log_cola" "$ahora" \
        | awk -F'\t' '$5 == "sin registro"' | wc -l | tr -d ' ')"

  # DEVKIT-97 (ampliación del 17:11 sobre DEVKIT-94): desde DEVKIT-90,
  # `--worker` arma `prompt_pleno` para task-start con el volcado de la card
  # bajo "## Card", y eso es lo que llega al `claude -p` real -no el prompt
  # corto que quedó en la línea "lanzando"-. Comparar por identidad
  # (skill+primer argumento) evita el falso "sin registro" con un prompt de
  # miles de caracteres, y evita el propio motivo largo en su DETALLE
  # -que antes ocupaba muchas líneas de pantalla- porque directamente no
  # aparece esa fila.
  local card_larga prompt_card log_card pslist_card
  card_larga="- Clave: DEVKIT-94
- Objetivo: $(printf 'texto de relleno de la card real %.0s' $(seq 1 100))"
  prompt_card=$(printf '/task-start DEVKIT-94  ## Card %s' "$(printf '%s' "$card_larga" | tr '\n' ' ')")
  check "el prompt de la card de prueba supera los 3000 caracteres" si \
    "$([ "${#prompt_card}" -gt 3000 ] && echo si || echo no)"
  log_card="$tmp/card-watch.log"
  : >"$est/task-start-94.log"
  printf '%s task-start-94 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-start DEVKIT-94" log=%s/task-start-94.log\n' \
    "$(date -u -d "@$ahora" +%FT%TZ)" "$est" >"$log_card"
  pslist_card="$tmp/ps-card"
  cat >"$pslist_card" <<FIN
#!/usr/bin/env bash
cat <<TABLA
701 bash devkit-run.sh --worker /task-start DEVKIT-94 $est/task-start-94.log opus high 40
801 claude -p $prompt_card --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_card"
  local filas_card
  filas_card=$(PS_BIN="$pslist_card" LOCK="$est/skill.lock" estado_filas "$log_card" "$ahora")
  check "task-start con la card completa en ps: una sola fila, sin sin registro" "1|0" \
    "$(printf '%s\n' "$filas_card" | awk -F'\t' '$2 == "DEVKIT-94" {c++} $5 == "sin registro" {s++} END{print (c+0)"|"(s+0)}')"
  check "task-start con la card completa en ps: la fila queda en curso" "en curso" \
    "$(printf '%s\n' "$filas_card" | awk -F'\t' '$2 == "DEVKIT-94" {print $5}')"

  # DEVKIT-81 H11: un lanzamiento que ya terminó no debe seguir "cubriendo"
  # a un `claude -p` vivo que repite su mismo prompt -por ejemplo, la misma
  # revisión relanzada a mano después de que la primera terminó.
  local log_repetido pslist_repetido
  log_repetido="$tmp/repetido-watch.log"
  : >"$est/pr-review-58.log"
  printf '%s pr-review-58 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/pr-review 58" log=%s/pr-review-58.log\n' \
    "$(date -u -d "@$((ahora - 60))" +%FT%TZ)" "$est" >"$log_repetido"
  printf '%s devkit-run "/pr-review 58" terminado [pr-review-58]: modelo=opus esfuerzo=high ronda=1 :: ok\n' \
    "$(date -u -d "@$((ahora - 30))" +%FT%TZ)" >>"$log_repetido"
  pslist_repetido="$tmp/ps-repetido"
  cat >"$pslist_repetido" <<FIN
#!/usr/bin/env bash
cat <<TABLA
901 claude -p /pr-review 58 --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_repetido"
  check "sin registro: un lanzamiento ya terminado no cubre un claude -p vivo que repite su prompt" 1 \
    "$(PS_BIN="$pslist_repetido" LOCK="$est/skill.lock" estado_filas "$log_repetido" "$ahora" \
        | awk -F'\t' '$5 == "sin registro"' | wc -l | tr -d ' ')"

  # DEVKIT-81 H6: `lanzamientos()` filtra primero con `grep -nF` antes del
  # `while`/`BASH_REMATCH` en bash puro. Con 20 000 líneas, la versión sin
  # filtrar tardaba cerca de 1 s; `agentes_en_curso_rapido` la llama en cada
  # prompt del shell, con un presupuesto de 50 ms (`prompt-status.sh`).
  local log_grande t0_grande t1_grande ms_grande
  log_grande="$tmp/grande-watch.log"
  : >"$log_grande"
  for i in $(seq 1 19980); do printf '2026-09-16T11:00:00Z ruido de relleno %s\n' "$i"; done >>"$log_grande"
  printf '2026-09-16T11:59:58Z task-fix-grande lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-88" log=%s/task-fix-grande.log\n' \
    "$est" >>"$log_grande"
  t0_grande=$(date +%s%N)
  lanzamientos "$log_grande" >/dev/null
  t1_grande=$(date +%s%N)
  ms_grande=$(( (t1_grande - t0_grande) / 1000000 ))
  check "lanzamientos con 20 000 líneas corre bajo 300ms" si \
    "$([ "$ms_grande" -lt 300 ] && echo si || echo "no (${ms_grande}ms)")"

  # DEVKIT-81: una fila `en curso` que pasa SKILL_TIMEOUT se marca `lento`,
  # igual que la alarma de watch_long_running en watch.sh.
  local lento_log lento_ts pslist_lento
  lento_log="$tmp/lento-watch.log"
  lento_ts=$(date -u -d "@$((ahora - SKILL_TIMEOUT - 100))" +%FT%TZ)
  printf '%s task-fix-9 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-90" log=%s/task-fix-9.log\n' \
    "$lento_ts" "$est" >"$lento_log"
  pslist_lento="$tmp/ps-lento"
  printf '#!/usr/bin/env bash\necho "601 bash devkit-run.sh --worker /task-fix DEVKIT-90 %s/task-fix-9.log opus high 40"\n' "$est" >"$pslist_lento"
  chmod +x "$pslist_lento"
  check "lento: una fila en curso que pasa SKILL_TIMEOUT se marca" "en curso|lento" \
    "$(PS_BIN="$pslist_lento" LOCK="$est/skill.lock" estado_filas "$lento_log" "$ahora" \
        | awk -F'\t' '$2 == "DEVKIT-90" {print $5"|"$6}')"
  # DEVKIT-106: "lento" suma su propio icono ámbar delante del detalle,
  # aparte del girador de ESTADO -son dos alarmas distintas, sigue en curso
  # pero además va lento. LC_ALL=C.UTF-8 fijo (DEVKIT-106 H6): sin esto, con
  # la locale de quien corre la autoprueba en C -sin UTF-8-, `utf8_disponible`
  # cae a ASCII y estos casos prueban la rama equivocada.
  local fila_lento
  fila_lento=$(LC_ALL=C.UTF-8 formatear_fila task-fix DEVKIT-90 - humano 5m 5m "en curso" opus/high -/60 lento 0 1 0)
  check "icono: lento se suma al detalle, aparte del girador de en curso" "si|si" \
    "$(printf '%s' "$fila_lento" | grep -qF '⠿ en curso' && echo -n si || echo -n no)|$(printf '%s' "$fila_lento" | grep -qF '⚠ lento' && echo -n si || echo -n no)"
  check "icono: lento lleva color ámbar" si \
    "$(LC_ALL=C.UTF-8 formatear_fila task-fix DEVKIT-90 - humano 5m 5m "en curso" opus/high -/60 lento 0 1 1 | grep -qF $'\033[33m' && echo si || echo no)"
  # DEVKIT-106 H3: el color se pinta después de recortar, no antes -antes,
  # con poco espacio para DETALLE, el corte caía en medio de `\033[33m` y el
  # ámbar quedaba sin su `\033[0m`, filtrándose a las filas siguientes.
  # `$ANCHO_COLUMNAS_FIJAS + 5` (no un número a mano, DEVKIT-134 le sumó
  # ANCHO_PR y desactualizaría cualquier cifra fija): pocas celdas para
  # DETALLE, cada apertura de color debe tener su cierre igual.
  check "icono: lento con poco espacio no deja un color ámbar sin cerrar" 1 \
    "$(fila_lento_angosta=$(COLUMNS=$((ANCHO_COLUMNAS_FIJAS + 5)) LC_ALL=C.UTF-8 formatear_fila task-fix DEVKIT-90 - humano 5m 5m "en curso" opus/high -/60 lento 0 1 1)
       abre=$(grep -o $'\033\[33m' <<<"$fila_lento_angosta" | wc -l)
       cierra=$(grep -o $'\033\[0m' <<<"$fila_lento_angosta" | wc -l)
       [ "$abre" -eq "$cierra" ] && echo 1 || echo 0)"

  # DEVKIT-97: DETALLE se recorta al ancho disponible de la terminal -sin
  # esto, un motivo largo (una card completa, un "murió sin resumen; ver
  # <log>") desbordaba una sola fila a varias líneas de pantalla, y el
  # redibujo en el sitio de `--seguir` apilaba cuadros en vez de refrescar
  # uno solo.
  check "recortar: entra entero, sin cambios" "hola" "$(recortar hola 10)"
  check "recortar: exacto al ancho, sin cambios" "hola" "$(recortar hola 4)"
  check "recortar: más largo que el ancho, con puntos suspensivos" "hol…" "$(recortar holaa 4)"
  check "recortar: ancho 0 o negativo nunca revienta" '…' "$(recortar hola 0)"
  local motivo_largo fila_ancha
  motivo_largo=$(printf 'motivo bien largo %.0s' $(seq 1 20))
  fila_ancha=$(COLUMNS=100 formatear_fila task-fix DEVKIT-1 - humano 5m - "no arrancó" opus/high -/60 "$motivo_largo")
  check "formatear_fila: la fila entera no pasa del ancho de la terminal" 1 \
    "$([ "${#fila_ancha}" -le 100 ] && echo 1 || echo 0)"
  check "formatear_fila: DETALLE recortado termina en puntos suspensivos" '…' \
    "${fila_ancha: -1}"
  check "formatear_fila: sin recorte, un DETALLE corto queda entero" "$motivo_largo" \
    "$(COLUMNS=1000 formatear_fila task-fix DEVKIT-1 - humano 5m - "no arrancó" opus/high -/60 "$motivo_largo" \
        | sed -E "s/^.{$ANCHO_COLUMNAS_FIJAS}//")"

  # DEVKIT-107 H1: con las columnas fijas angostadas (89, antes 97) una
  # terminal de 80 columnas -menos que las columnas fijas más un DETALLE
  # mínimo- todavía desbordaba una fila a dos líneas, rompiendo el ajuste al
  # alto de `--seguir` (DEVKIT-97). La fila entera se recorta al ancho de la
  # terminal como último recurso, después de angostar las columnas.
  check "formatear_fila: con COLUMNS=80, ninguna fila pasa de 80 caracteres visibles" 1 \
    "$(fila_80=$(COLUMNS=80 formatear_fila task-fix DEVKIT-71 - humano 15m 11m terminó opus/high '67/60!' - 0 1 1)
       visible=$(printf '%s' "$fila_80" | sed -E $'s/\x1b\\[[0-9;]*m//g')
       [ "${#visible}" -le 80 ] && echo 1 || echo 0)"
  check "formatear_fila: con COLUMNS=80, los colores siguen balanceados (sin uno sin cerrar)" 1 \
    "$(fila_80=$(COLUMNS=80 formatear_fila task-fix DEVKIT-71 - humano 15m 11m terminó opus/high '67/60!' - 0 1 1)
       abre=$(grep -oE $'\x1b\\[(31|32)m' <<<"$fila_80" | wc -l)
       cierra=$(grep -o $'\033\[0m' <<<"$fila_80" | wc -l)
       [ "$abre" -eq "$cierra" ] && echo 1 || echo 0)"

  # DEVKIT-97 H1: sin COLUMNS/LINES pero con TERM definido (el contenedor,
  # watch.sh, cron con TERM heredado, `--estado | grep`) no hay tty real, y
  # antes de este hallazgo `ancho_terminal`/`alto_terminal` caían a `tput`, que
  # sin tty pero con TERM devuelve 80/24 en vez del respaldo ancho: DETALLE
  # quedaba en 3 caracteres.
  local motivo_medio="bloquea a: DEVKIT-61, DEVKIT-99"
  check "ancho_terminal: sin COLUMNS, con TERM definido, no cae a tput (respaldo ancho)" 200 \
    "$(unset COLUMNS; TERM=xterm ancho_terminal)"
  check "alto_terminal: sin LINES, con TERM definido, no cae a tput (respaldo alto)" 1000 \
    "$(unset LINES; TERM=xterm alto_terminal)"
  check "formatear_fila: TERM definido sin COLUMNS no trunca DETALLE a 3 caracteres" \
    "$motivo_medio" \
    "$(unset COLUMNS; TERM=xterm formatear_fila task-fix DEVKIT-1 - humano 5m - "no arrancó" opus/high -/60 "$motivo_medio" \
        | sed -E "s/^.{$ANCHO_COLUMNAS_FIJAS}//")"

  # DEVKIT-97: la tabla se recorta al alto de la terminal -las filas más
  # recientes, con un resumen de cuántas quedaron afuera- y `--todo`
  # (`DEVKIT_ESTADO_TODO`) lo desactiva para verlas todas. `imprimir_tabla`
  # directo, no `mostrar_estado`: así 40 lanzamientos de prueba no chocan con
  # `ESTADO_FILAS` (20 por defecto), que ya recorta cuántos lanzamientos del
  # log entran a la tabla, antes y aparte de este recorte por alto.
  local -a filas_40=()
  for i in $(seq 1 40); do filas_40+=("fila-$i"); done
  local salida_40
  salida_40=$(LINES=20 imprimir_tabla "${filas_40[@]}")
  check "imprimir_tabla: con 40 filas en una terminal de 20 líneas, la más vieja no aparece" 0 \
    "$(printf '%s\n' "$salida_40" | grep -c '^fila-1$')"
  check "imprimir_tabla: se queda con las más recientes" 1 \
    "$(printf '%s\n' "$salida_40" | grep -c '^fila-40$')"
  check "imprimir_tabla: línea de resumen con cuántas quedaron afuera" 1 \
    "$(printf '%s\n' "$salida_40" | grep -c '… 29 filas más antiguas (devkit-run --estado --todo para verlas)')"
  local salida_40_todo
  salida_40_todo=$(LINES=20 DEVKIT_ESTADO_TODO=1 imprimir_tabla "${filas_40[@]}")
  check "imprimir_tabla: --todo desactiva el recorte, aparecen todas" "1|1|0" \
    "$(printf '%s\n' "$salida_40_todo" | grep -c '^fila-1$')|$(printf '%s\n' "$salida_40_todo" | grep -c '^fila-40$')|$(printf '%s\n' "$salida_40_todo" | grep -c 'filas más antiguas')"

  # DEVKIT-97 H4: RESERVA_LINEAS_TABLA solo contaba 1 línea para el bloque
  # Consumo, que en realidad imprime 4 (en blanco, título, sesión, semana), y
  # ninguna para la línea de resumen "… N filas más antiguas": con LINES=20 el
  # cuadro completo de `--seguir` (3 líneas de cabecera, afuera de
  # mostrar_estado) desbordaba. Cuenta las líneas reales de `mostrar_estado`
  # -títulos, filas, resumen y Consumo con cuota oficial (el caso de 4 líneas,
  # el peor)- y verifica que, sumadas a esas 3 de cabecera, no pasan de LINES.
  local muchas_log pslist_muchas cuota_h4 salida_muchas total_muchas i
  muchas_log="$tmp/muchas-filas-watch.log"
  : >"$muchas_log"
  for i in $(seq 1 20); do
    printf '2026-09-16T11:00:00Z task-fix-%s lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-1%02d" log=%s/task-fix-%s.log\n' \
      "$i" "$i" "$est" "$i" >>"$muchas_log"
    printf '2026-09-16T11:01:00Z task-fix-%s terminado: modelo=opus esfuerzo=high costo=1.0 turnos=1 :: OK\n' "$i" >>"$muchas_log"
  done
  pslist_muchas="$tmp/ps-muchas-filas"
  printf '#!/usr/bin/env bash\n' >"$pslist_muchas"
  chmod +x "$pslist_muchas"
  cuota_h4="$tmp/cuota-h4"
  mkdir -p "$cuota_h4"
  printf '%s\tok\t42\tSep 17, 5:10pm (UTC)\t7\tSep 22, 11pm (UTC)\n' "$(date +%s)" >"$cuota_h4/cuota.cache"
  salida_muchas=$(PS_BIN="$pslist_muchas" LOCK="$est/skill.lock" LINES=20 \
    CLAUDE_BIN=/bin/false CUOTA_TTL=9999 CUOTA_CACHE="$cuota_h4/cuota.cache" CUOTA_LOCK="$cuota_h4/cuota.lock" \
    WATCH_LOG="$muchas_log" DEVKIT_AHORA="$ahora" mostrar_estado)
  total_muchas=$(printf '%s\n' "$salida_muchas" | wc -l | tr -d ' ')
  check "H4: mostrar_estado con muchas filas y LINES=20 no desborda el cuadro de --seguir" 1 \
    "$([ "$total_muchas" -le $((20 - 3)) ] && echo 1 || echo 0)"

  # DEVKIT-81: señal de vida del bucle en la cabecera de `--estado --seguir`.
  local pslist_bucle_vivo pslist_sin_bucle tick_log tick_viejo_log
  pslist_bucle_vivo="$tmp/ps-bucle-vivo"
  printf '#!/usr/bin/env bash\necho "1 bash /workspace/devkit/scripts/watch.sh"\n' >"$pslist_bucle_vivo"
  chmod +x "$pslist_bucle_vivo"
  pslist_sin_bucle="$tmp/ps-sin-bucle"
  printf '#!/usr/bin/env bash\necho "1 bash algo-que-no-es-el-bucle"\n' >"$pslist_sin_bucle"
  chmod +x "$pslist_sin_bucle"
  tick_log="$tmp/tick-watch.log"
  printf '%s consultando GitHub\n' "$(date -u -d "@$((ahora - 60))" +%FT%TZ)" >"$tick_log"
  check "senal_bucle: vivo con un tick reciente" "bucle: vivo, último tick hace 1m" \
    "$(PS_BIN="$pslist_bucle_vivo" senal_bucle "$tick_log" "$ahora")"
  tick_viejo_log="$tmp/tick-viejo-watch.log"
  printf '%s consultando GitHub\n' "$(date -u -d "@$((ahora - 2 * INTERVALO_BUCLE - 60))" +%FT%TZ)" >"$tick_viejo_log"
  check "senal_bucle: SIN SEÑAL con un tick viejo (más del doble del intervalo)" 1 \
    "$(PS_BIN="$pslist_bucle_vivo" senal_bucle "$tick_viejo_log" "$ahora" | grep -c 'SIN SEÑAL hace')"
  # DEVKIT-97: caso 1, `pgrep -f watch.sh` vacío es `MUERTO`, no `SIN SEÑAL`
  # -son cosas distintas: acá no hay bucle del que esperar nada.
  check "senal_bucle: MUERTO si watch.sh no está en ps" 1 \
    "$(PS_BIN="$pslist_sin_bucle" senal_bucle "$tick_log" "$ahora" | grep -c 'MUERTO, no encuentro watch.sh en ps')"
  # DEVKIT-81 H4: con color pedido (terminal), MUERTO y las dos ramas SIN
  # SEÑAL van en rojo; sin él (autoprueba, sin terminal), sin códigos de color
  # -ya cubierto por los checks de arriba, que no piden color.
  check "senal_bucle: MUERTO en rojo si se pide" \
    $'\033[31mbucle: MUERTO, no encuentro watch.sh en ps\033[0m' \
    "$(PS_BIN="$pslist_sin_bucle" senal_bucle "$tick_log" "$ahora" 1)"
  local sin_tick_log
  sin_tick_log="$tmp/sin-tick-watch.log"
  : >"$sin_tick_log"
  check "senal_bucle: SIN SEÑAL sin ningún tick, en rojo si se pide" \
    $'\033[31mbucle: SIN SEÑAL, watch.sh vive pero sin ningún tick "consultando GitHub" todavía\033[0m' \
    "$(PS_BIN="$pslist_bucle_vivo" senal_bucle "$sin_tick_log" "$ahora" 1)"
  check "senal_bucle: SIN SEÑAL con un tick viejo, en rojo si se pide" \
    $'\033[31mbucle: SIN SEÑAL hace 5m\033[0m' \
    "$(PS_BIN="$pslist_bucle_vivo" senal_bucle "$tick_viejo_log" "$ahora" 1)"
  check "senal_bucle: vivo no se pinta aunque se pida color" "bucle: vivo, último tick hace 1m" \
    "$(PS_BIN="$pslist_bucle_vivo" senal_bucle "$tick_log" "$ahora" 1)"

  # DEVKIT-97: caso 2, una fila en curso de origen bucle explica por qué el
  # tick no llegó -`run_skill` en watch.sh espera de forma síncrona a que la
  # skill termine antes de seguir con el próximo PR, así que una corrección
  # larga (13 min con DEVKIT-87) no puede dejar un tick nuevo mientras corre.
  # Sin tick alguno en el log: igual gana "esperando" sobre "sin ningún tick".
  local esperando_log pslist_esperando
  esperando_log="$tmp/esperando-watch.log"
  printf '%s task-fix-50 lanzando (origen=bucle) modelo=x esfuerzo=high ronda=1: "/task-fix DEVKIT-87" log=%s/task-fix-50.log\n' \
    "$(date -u -d "@$((ahora - 300))" +%FT%TZ)" "$est" >"$esperando_log"
  pslist_esperando="$tmp/ps-esperando"
  printf '#!/usr/bin/env bash\ncat <<TABLA\n1 bash /workspace/devkit/scripts/watch.sh\n999 bash devkit-run.sh --sync /task-fix DEVKIT-87\nTABLA\n' >"$pslist_esperando"
  chmod +x "$pslist_esperando"
  check "senal_bucle: esperando una skill de origen bucle, sin alarma" \
    "bucle: esperando task-fix-87 hace 5m" \
    "$(PS_BIN="$pslist_esperando" LOCK="$est/skill.lock" senal_bucle "$esperando_log" "$ahora")"
  check "senal_bucle: esperando no se pinta aunque se pida color" \
    "bucle: esperando task-fix-87 hace 5m" \
    "$(PS_BIN="$pslist_esperando" LOCK="$est/skill.lock" senal_bucle "$esperando_log" "$ahora" 1)"
  # El caso 2 no oculta la marca "lento" de la fila: sigue siendo la alarma de
  # la skill, no del bucle (criterio de aceptación de DEVKIT-97).
  local esperando_lento_log
  esperando_lento_log="$tmp/esperando-lento-watch.log"
  printf '%s task-fix-51 lanzando (origen=bucle) modelo=x esfuerzo=high ronda=1: "/task-fix DEVKIT-87" log=%s/task-fix-51.log\n' \
    "$(date -u -d "@$((ahora - SKILL_TIMEOUT - 100))" +%FT%TZ)" "$est" >"$esperando_lento_log"
  check "senal_bucle: esperando, sin alarma, aunque la fila esté lenta" \
    "bucle: esperando task-fix-87 hace $(hace $((SKILL_TIMEOUT + 100)))" \
    "$(PS_BIN="$pslist_esperando" LOCK="$est/skill.lock" senal_bucle "$esperando_lento_log" "$ahora")"
  check "senal_bucle: esperando lento: la fila conserva su propia marca lento" \
    "en curso|lento" \
    "$(PS_BIN="$pslist_esperando" LOCK="$est/skill.lock" estado_filas "$esperando_lento_log" "$ahora" \
        | awk -F'\t' '$2 == "DEVKIT-87" {print $5"|"$6}')"

  # DEVKIT-97 H2: task-start con origen bucle viene de `lanzar_cola` ->
  # `cola.sh` -> `devkit-run.sh task-start`, un worker `nohup setsid` que
  # no bloquea a `watch.sh` -a diferencia de `run_skill` (pr-review/task-fix/
  # task-close/task-document), que corre con `--sync` y `wait`. Con el worker
  # todavía en `ps` (fila `en curso`) pero sin `--sync /task-start` y un tick
  # viejo, el caso 2 no debe tapar el SIN SEÑAL real.
  local ts_esperando_log pslist_ts_esperando
  ts_esperando_log="$tmp/task-start-esperando-watch.log"
  printf '%s task-start-90 lanzando (origen=bucle) modelo=x esfuerzo=high ronda=-: "/task-start DEVKIT-90" log=%s/task-start-90.log\n' \
    "$(date -u -d "@$((ahora - 300))" +%FT%TZ)" "$est" >"$ts_esperando_log"
  printf '%s consultando GitHub\n' "$(date -u -d "@$((ahora - 2 * INTERVALO_BUCLE - 60))" +%FT%TZ)" \
    >>"$ts_esperando_log"
  pslist_ts_esperando="$tmp/ps-task-start-esperando"
  printf '#!/usr/bin/env bash\ncat <<TABLA\n1 bash /workspace/devkit/scripts/watch.sh\n999 bash devkit-run.sh --worker /task-start DEVKIT-90 %s/task-start-90.log opus high 40\nTABLA\n' \
    "$est" >"$pslist_ts_esperando"
  chmod +x "$pslist_ts_esperando"
  check "senal_bucle: task-start en curso con origen bucle, sin --sync en ps y tick viejo, no tapa SIN SEÑAL" 1 \
    "$(PS_BIN="$pslist_ts_esperando" LOCK="$est/skill.lock" senal_bucle "$ts_esperando_log" "$ahora" \
        | grep -c 'SIN SEÑAL hace')"

  # DEVKIT-81 H5, regla sin excepción: un `claude -p` vivo de cada origen real
  # -humano (terminal), bucle (run_skill lanza pr-review/task-fix/
  # task-document, y watch.sh también lanza cola.sh con este origen tras el
  # OK y en cada pasada sin nada en curso), task-close (task-close.sh lo
  # declara, y lanza cola.sh con el mismo origen tras el merge) y epic-plan
  # (detectado por ancestro)-
  # aparece `en curso` con su origen, nunca `sin registro`. `ps` trae las dos
  # entradas de un lanzamiento real: el `bash devkit-run.sh --worker` con el
  # log (lo que ve la fila principal) y el `claude -p` hijo (lo que ve
  # `filas_sin_registro`).
  local origen_prueba
  for origen_prueba in humano bucle task-close epic-plan; do
    local log_origen pslist_origen logf_origen
    logf_origen="$est/task-fix-origen-$origen_prueba.log"
    : >"$logf_origen"
    log_origen="$tmp/origen-$origen_prueba-watch.log"
    printf '%s task-fix-origen-%s lanzando (origen=%s) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-155" log=%s\n' \
      "$(date -u -d "@$((ahora - ESTADO_GRACIA - 10))" +%FT%TZ)" "$origen_prueba" "$origen_prueba" "$logf_origen" >"$log_origen"
    pslist_origen="$tmp/ps-origen-$origen_prueba"
    cat >"$pslist_origen" <<FIN
#!/usr/bin/env bash
cat <<TABLA
701 bash devkit-run.sh --worker /task-fix DEVKIT-155 $logf_origen opus high 40
702 claude -p /task-fix DEVKIT-155 --model opus --effort high --output-format json
TABLA
FIN
    chmod +x "$pslist_origen"
    check "origen $origen_prueba: en curso con su origen, sin sin registro" "en curso|$origen_prueba|0" \
      "$(PS_BIN="$pslist_origen" LOCK="$est/skill.lock" estado_filas "$log_origen" "$ahora" \
          | awk -F'\t' -v c=DEVKIT-155 'BEGIN{estado="";origen="";sr=0} $2==c{estado=$5;origen=$3} $5=="sin registro"{sr++} END{print estado"|"origen"|"sr}')"
  done

  # DEVKIT-81 H3: cada renglón del cuadro lleva `\033[K` al final -incluido el
  # último, antes del salto de línea que agrega `printf`-, para que un
  # renglón más corto que en el cuadro anterior no deje texto viejo pegado a
  # la derecha; `\033[J` solo limpia debajo del último renglón, no a la
  # derecha de uno más corto.
  check "cuadro_sin_parpadeo: \\033[H al inicio, \\033[K por renglón (incluido el último) y \\033[J al final" \
    $'\033[Hlinea uno\033[K\nlinea dos\033[K\n\033[J' \
    "$(cuadro_sin_parpadeo $'linea uno\nlinea dos')"

  # DEVKIT-79: con COLUMNS en el entorno (una terminal integrada, como la del
  # editor, lo exporta) `ps` sin `-ww` recorta la línea y estado_filas deja
  # de ver el proceso. Este caso usa el `ps` real del sistema (PS_BIN por
  # defecto), no un doble que ignore la variable: sin `-ww` en `estado_filas`
  # fallaría con COLUMNS=60.
  local sleeper_ww logf_larga_ww ww_pid watch_ww tabla_ww
  sleeper_ww="$tmp/sleeper-ww"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$sleeper_ww"
  chmod +x "$sleeper_ww"
  logf_larga_ww="$tmp/ww/relleno-$(printf 'x%.0s' $(seq 1 80))/task-start-1.log"
  mkdir -p "$(dirname "$logf_larga_ww")"
  "$sleeper_ww" --worker /task-start DEVKIT-9 "$logf_larga_ww" opus high 40 &
  ww_pid=$!
  watch_ww="$tmp/ww/watch.log"
  printf '%s task-start-1 lanzando (origen=humano): "/task-start DEVKIT-9" log=%s\n' \
    "$(date -u +%FT%T%:z)" "$logf_larga_ww" >"$watch_ww"
  tabla_ww=$(COLUMNS=60 estado_filas "$watch_ww" "$(date +%s)")
  kill "$ww_pid" 2>/dev/null; wait "$ww_pid" 2>/dev/null
  check "estado_filas con COLUMNS=60 y ps real: sigue viendo el proceso (-ww)" "en curso" \
    "$(printf '%s\n' "$tabla_ww" | awk -F'\t' '$2 == "DEVKIT-9" {print $5}')"

  # DEVKIT-79: confirmar_arranque elige el `claude -p` que de verdad
  # desciende del worker recién lanzado, no el primero que `ps` liste con el
  # mismo prompt (podría ser el de un lanzamiento anterior, todavía vivo).
  # `sleep` real como raíz -confirmar_arranque solo comprueba con `kill -0`
  # que el worker sigue vivo-, y una tabla de `ps` de mentira con dos
  # `claude -p` del mismo prompt: uno bajo un worker viejo (55500), otro bajo
  # la raíz real.
  local root_pid pslist_conf salida_conf claude_nuevo_pid
  sleep 5 &
  root_pid=$!
  claude_nuevo_pid=$((root_pid + 20000))
  pslist_conf="$tmp/ps-confirmar"
  cat >"$pslist_conf" <<FIN
#!/usr/bin/env bash
cat <<TABLA
55500 1 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-9 /run/devkit/task-start-1.log opus high 40
55501 55500 claude -p /task-start DEVKIT-9 --model opus --effort high --output-format json
$root_pid 1 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-9 /run/devkit/task-start-2.log opus high 40
$claude_nuevo_pid $root_pid claude -p /task-start DEVKIT-9 --model opus --effort high --output-format json
TABLA
FIN
  chmod +x "$pslist_conf"
  salida_conf=$(PS_BIN="$pslist_conf" ARRANQUE_ESPERA=1 confirmar_arranque "$root_pid" "/task-start DEVKIT-9" "$tmp/confirmar.log")
  kill "$root_pid" 2>/dev/null; wait "$root_pid" 2>/dev/null
  check "confirmar_arranque elige el claude -p del worker nuevo, no el viejo" \
    "arrancó: claude -p vivo (pid $claude_nuevo_pid)" "$salida_conf"

  # H1 de pr-review en el PR #56: mismo caso que lanzamiento_duplicado, pero
  # para claude_descendiente, que comparte el mismo patrón.
  local tabla_desc
  tabla_desc='90000 1 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-79 /run/devkit/task-start-1.log opus high 40
90001 90000 claude -p /task-start DEVKIT-79 --model opus --effort high --output-format json'
  check "claude_descendiente: Clave prefijo de otra no da falso positivo" "" \
    "$(printf '%s\n' "$tabla_desc" | claude_descendiente 90000 '/task-start DEVKIT-7')"

  # El doble genérico no trae "Current session"/"Current week": mostrar_estado
  # no se cae por eso, solo agrega el bloque Consumo con el aviso de que
  # todavía no hay lectura en caché. `head -1` porque, desde DEVKIT-62,
  # mostrar_estado siempre agrega ese bloque al final, con o sin lanzamientos.
  # PS_BIN de mentira, vacío: sin él, `filas_sin_registro` (DEVKIT-81) vería
  # los `claude -p` reales de esta misma sesión con el `ps` de verdad.
  local pslist_vacio
  pslist_vacio="$tmp/ps-vacio"
  printf '#!/usr/bin/env bash\n' >"$pslist_vacio"
  chmod +x "$pslist_vacio"
  check "--estado sin lanzamientos lo dice" "sin lanzamientos registrados en $est/vacio.log" \
    "$(PS_BIN="$pslist_vacio" CLAUDE_BIN="$doble" CUOTA_CACHE="$tmp/cuota-vacio/cuota.cache" CUOTA_LOCK="$tmp/cuota-vacio/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | head -1)"

  # Columna "bloquea a" (ampliación de la card): caché ya tibia, sin llamar a
  # notion.sh en el propio check -el refresco es en segundo plano y no debe
  # bloquear la lectura (H1 de pr-review, mismo criterio que Consumo).
  local bloq
  bloq="$tmp/bloqueos"
  mkdir -p "$bloq"
  printf '%s\t%s\n' "$(date +%s)" '[{"clave":"DEVKIT-57","bloquea_a":["DEVKIT-61","DEVKIT-99"]}]' \
    >"$bloq/bloqueos.cache"
  check "bloquea_a: card en Lista para merge lista a quién frena" "bloquea a: DEVKIT-61, DEVKIT-99" \
    "$(BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" bloquea_a DEVKIT-57)"
  check "bloquea_a: card que no frena a nadie, vacío" "" \
    "$(BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" bloquea_a DEVKIT-999)"
  check "--estado suma la columna a la fila que corresponde" "bloquea a: DEVKIT-61, DEVKIT-99" \
    "$(BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" \
        CLAUDE_BIN="$doble" CUOTA_CACHE="$tmp/cuota-vacio2/cuota.cache" CUOTA_LOCK="$tmp/cuota-vacio2/cuota.lock" \
        PS_BIN="$pslist" LOCK="$est/skill.lock" DEVKIT_AHORA="$ahora" \
        WATCH_LOG="$est/watch.log" mostrar_estado | grep 'DEVKIT-57' | grep -oE 'bloquea a: DEVKIT-61, DEVKIT-99')"

  # Agrupar por Épica de origen (DEVKIT-80): DEVKIT-57 y DEVKIT-58 son hijas
  # de la Épica DEVKIT-50 En progreso, DEVKIT-59 y DEVKIT-60 de la Épica
  # DEVKIT-51 En progreso, ambas presentes en el mismo watch.log de arriba.
  # Caché ya tibia, mismo criterio que Bloqueos: sin llamar a notion.sh en el
  # propio check.
  local epic salida_epicas bloque_50 bloque_51 bloque_sin
  epic="$tmp/epicas"
  mkdir -p "$epic"
  printf '%s\t%s\n' "$(date +%s)" \
    '[{"clave":"DEVKIT-57","epica":"DEVKIT-50","epica_titulo":"Alfa"},{"clave":"DEVKIT-58","epica":"DEVKIT-50","epica_titulo":"Alfa"},{"clave":"DEVKIT-59","epica":"DEVKIT-51","epica_titulo":"Beta"},{"clave":"DEVKIT-60","epica":"DEVKIT-51","epica_titulo":"Beta"}]' \
    >"$epic/epicas.cache"
  check "epica_de: Clave con Épica activa" "Épica DEVKIT-50: Alfa" \
    "$(EPICAS_CACHE="$epic/epicas.cache" EPICAS_LOCK="$epic/epicas.lock" epica_de DEVKIT-57)"
  check "epica_de: Clave sin Épica activa, vacío" "" \
    "$(EPICAS_CACHE="$epic/epicas.cache" EPICAS_LOCK="$epic/epicas.lock" epica_de DEVKIT-56)"
  salida_epicas=$(EPICAS_CACHE="$epic/epicas.cache" EPICAS_LOCK="$epic/epicas.lock" \
      BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" \
      CLAUDE_BIN="$doble" CUOTA_CACHE="$tmp/cuota-epicas/cuota.cache" CUOTA_LOCK="$tmp/cuota-epicas/cuota.lock" \
      PS_BIN="$pslist" LOCK="$est/skill.lock" DEVKIT_AHORA="$ahora" \
      WATCH_LOG="$est/watch.log" mostrar_estado)
  check "--estado con dos Épicas En progreso: un encabezado por Épica, en orden de aparición" \
    "Épica DEVKIT-50: Alfa
Épica DEVKIT-51: Beta" \
    "$(printf '%s\n' "$salida_epicas" | grep '^Épica ')"
  bloque_50=$(printf '%s\n' "$salida_epicas" | sed -n '/^Épica DEVKIT-50:/,/^$/p')
  bloque_51=$(printf '%s\n' "$salida_epicas" | sed -n '/^Épica DEVKIT-51:/,/^$/p')
  bloque_sin=$(printf '%s\n' "$salida_epicas" | sed -n '/^(sin Épica)/,/^$/p')
  check "grupo de DEVKIT-50: sus dos Tareas, no las de la otra Épica" "1 1 0" \
    "$(printf '%s' "$bloque_50" | grep -c 'DEVKIT-57 ') $(printf '%s' "$bloque_50" | grep -c 'DEVKIT-58 ') $(printf '%s' "$bloque_50" | grep -c 'DEVKIT-59 ')"
  check "grupo de DEVKIT-51: sus dos Tareas, no las de la otra Épica" "1 1 0" \
    "$(printf '%s' "$bloque_51" | grep -c 'DEVKIT-59 ') $(printf '%s' "$bloque_51" | grep -c 'DEVKIT-60 ') $(printf '%s' "$bloque_51" | grep -c 'DEVKIT-57 ')"
  check "(sin Épica) trae las Claves sin Épica activa, no las agrupadas" "1 1 1 1 0" \
    "$(printf '%s' "$bloque_sin" | grep -c 'DEVKIT-56 ') $(printf '%s' "$bloque_sin" | grep -c 'DEVKIT-5 ') \
$(printf '%s' "$bloque_sin" | grep -c 'DEVKIT-63 ') $(printf '%s' "$bloque_sin" | grep -c 'DEVKIT-61 ') \
$(printf '%s' "$bloque_sin" | grep -c 'DEVKIT-57 ')"
  local epic_sola
  epic_sola="$tmp/epicas-sola"
  mkdir -p "$epic_sola"
  printf '%s\t%s\n' "$(date +%s)" '[{"clave":"DEVKIT-57","epica":"DEVKIT-50","epica_titulo":"Alfa"}]' \
    >"$epic_sola/epicas.cache"
  check "--estado con una sola Épica En progreso: tabla plana, sin encabezados" 0 \
    "$(EPICAS_CACHE="$epic_sola/epicas.cache" EPICAS_LOCK="$epic_sola/epicas.lock" \
        BLOQUEOS_CACHE="$bloq/bloqueos.cache" BLOQUEOS_LOCK="$bloq/bloqueos.lock" \
        CLAUDE_BIN="$doble" CUOTA_CACHE="$tmp/cuota-epica-sola/cuota.cache" CUOTA_LOCK="$tmp/cuota-epica-sola/cuota.lock" \
        PS_BIN="$pslist" LOCK="$est/skill.lock" DEVKIT_AHORA="$ahora" \
        WATCH_LOG="$est/watch.log" mostrar_estado | grep -c '^Épica ')"

  # --- DEVKIT-133: fila "(en espera)" cuando nada está en curso -----------
  # watch.log aparte del de arriba (`$est`, que sí tiene DEVKIT-57 en curso):
  # sin ningún "en curso", solo un cierre "terminado" y, antes, la línea de
  # arranque del bucle.
  local espera_est espera_ahora salida_espera pslist_espera
  espera_est="$tmp/en-espera"
  mkdir -p "$espera_est"
  cat >"$espera_est/watch.log" <<FIN
2026-09-20T09:00:00Z vigilancia iniciada (cada 30s, guardia de 200 ciclos; PRs mergeados cada 300s)
2026-09-20T09:05:00Z task-fix-1 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-fix DEVKIT-70" log=$espera_est/task-fix-1.log
2026-09-20T09:10:00Z task-fix-1 terminado: modelo=opus esfuerzo=high ronda=1 costo=0.10 turnos=5 duracion=300s :: OK
FIN
  espera_ahora=$(date -d '2026-09-20T09:25:00Z' +%s)
  check "ultima_actividad_ts: la última línea terminado, no la de lanzando" \
    "$(date -d '2026-09-20T09:10:00Z' +%s)" "$(ultima_actividad_ts "$espera_est/watch.log")"
  check "arranque_bucle_ts: la línea de vigilancia iniciada" \
    "$(date -d '2026-09-20T09:00:00Z' +%s)" "$(arranque_bucle_ts "$espera_est/watch.log")"

  local espera_solo_arranque
  espera_solo_arranque="$tmp/en-espera-arranque"
  mkdir -p "$espera_solo_arranque"
  printf '2026-09-20T09:00:00Z vigilancia iniciada (cada 30s, guardia de 200 ciclos; PRs mergeados cada 300s)\n' \
    >"$espera_solo_arranque/watch.log"
  check "ultima_actividad_ts: sin ningún cierre todavía, vacío (rc=1)" 1 \
    "$(ultima_actividad_ts "$espera_solo_arranque/watch.log" >/dev/null 2>&1; echo $?)"

  local merge_vacio merge_con merge_digitos
  merge_vacio="$tmp/merge-vacio"
  mkdir -p "$merge_vacio"
  printf '%s\t%s\n' "$(date +%s)" '[]' >"$merge_vacio/merge.cache"
  check "esperando_aprobacion: sin cards Lista para merge, vacío" "" \
    "$(MERGE_CACHE="$merge_vacio/merge.cache" MERGE_LOCK="$merge_vacio/merge.lock" esperando_aprobacion)"
  merge_con="$tmp/merge-con"
  mkdir -p "$merge_con"
  printf '%s\t%s\n' "$(date +%s)" \
    '[{"clave":"DEVKIT-40","estado":"En progreso","tipo":"feature","nivel":"Tarea","pr":""},{"clave":"DEVKIT-30","estado":"Lista para merge","tipo":"bug","nivel":"Tarea","pr":"https://github.com/o/r/pull/3"}]' \
    >"$merge_con/merge.cache"
  check "esperando_aprobacion: la Clave en Lista para merge" "DEVKIT-30" \
    "$(MERGE_CACHE="$merge_con/merge.cache" MERGE_LOCK="$merge_con/merge.lock" esperando_aprobacion)"

  merge_digitos="$tmp/merge-digitos"
  mkdir -p "$merge_digitos"
  printf '%s\t%s\n' "$(date +%s)" \
    '[{"clave":"DEVKIT-97","estado":"Lista para merge","tipo":"bug","nivel":"Tarea","pr":""},{"clave":"DEVKIT-133","estado":"Lista para merge","tipo":"feature","nivel":"Tarea","pr":""}]' \
    >"$merge_digitos/merge.cache"
  check "esperando_aprobacion: la más antigua, no la que ordena antes como texto" "DEVKIT-97" \
    "$(MERGE_CACHE="$merge_digitos/merge.cache" MERGE_LOCK="$merge_digitos/merge.lock" esperando_aprobacion)"

  check "fila_en_espera: HACE y DURÓ iguales, desde el último terminado (15m)" "15m|15m|en espera|cola vacía" \
    "$(MERGE_CACHE="$merge_vacio/merge.cache" MERGE_LOCK="$merge_vacio/merge.lock" \
        fila_en_espera "$espera_est/watch.log" "$espera_ahora" | awk -F'\t' '{print $4"|"$8"|"$5"|"$6}')"
  check "fila_en_espera: DETALLE con la Clave que espera aprobación" "esperando aprobación de DEVKIT-30" \
    "$(MERGE_CACHE="$merge_con/merge.cache" MERGE_LOCK="$merge_con/merge.lock" \
        fila_en_espera "$espera_est/watch.log" "$espera_ahora" | awk -F'\t' '{print $6}')"
  check "fila_en_espera: columna PR (10.º campo) en -, no vacía" "-" \
    "$(MERGE_CACHE="$merge_vacio/merge.cache" MERGE_LOCK="$merge_vacio/merge.lock" \
        fila_en_espera "$espera_est/watch.log" "$espera_ahora" | awk -F'\t' '{print $10}')"
  check "fila_en_espera: sin watch.log, vacío (rc=1)" 1 \
    "$(fila_en_espera "$tmp/en-espera-inexistente/watch.log" "$espera_ahora" >/dev/null 2>&1; echo $?)"
  check "fila_en_espera: DETALLE bucle parado con el bucle MUERTO, no cola vacía" "bucle parado" \
    "$(MERGE_CACHE="$merge_vacio/merge.cache" MERGE_LOCK="$merge_vacio/merge.lock" \
        fila_en_espera "$espera_est/watch.log" "$espera_ahora" 'bucle: MUERTO, no encuentro watch.sh en ps' \
        | awk -F'\t' '{print $6}')"
  check "fila_en_espera: DETALLE bucle parado con SIN SEÑAL, ni con card esperando aprobación" "bucle parado" \
    "$(MERGE_CACHE="$merge_con/merge.cache" MERGE_LOCK="$merge_con/merge.lock" \
        fila_en_espera "$espera_est/watch.log" "$espera_ahora" 'bucle: SIN SEÑAL hace 10m' \
        | awk -F'\t' '{print $6}')"

  pslist_espera="$tmp/ps-en-espera"
  printf '#!/usr/bin/env bash\n' >"$pslist_espera"
  chmod +x "$pslist_espera"
  salida_espera=$(PS_BIN="$pslist_espera" LOCK="$espera_est/skill.lock" CLAUDE_BIN="$doble" \
      CUOTA_CACHE="$tmp/cuota-espera/cuota.cache" CUOTA_LOCK="$tmp/cuota-espera/cuota.lock" \
      MERGE_CACHE="$merge_vacio/merge.cache" MERGE_LOCK="$merge_vacio/merge.lock" \
      DEVKIT_AHORA="$espera_ahora" WATCH_LOG="$espera_est/watch.log" mostrar_estado)
  # Última línea de la tabla, antes del bloque Consumo que `mostrar_estado`
  # agrega siempre después de una línea en blanco (DEVKIT-62).
  check "--estado sin nada en curso: agrega la fila (en espera) al final de la tabla" si \
    "$(printf '%s\n' "$salida_espera" | awk '/^$/{exit} {l=$0} END{print l}' | grep -qF '(en espera)' && echo si || echo no)"
  check "--estado sin nada en curso: HACE y DURÓ, ambos 15m" si \
    "$(printf '%s\n' "$salida_espera" | grep '(en espera)' | grep -qE '15m +15m' && echo si || echo no)"
  check "--estado sin nada en curso: DETALLE cola vacía" si \
    "$(printf '%s\n' "$salida_espera" | grep '(en espera)' | grep -qF 'cola vacía' && echo si || echo no)"
  check "--estado con una skill en curso: sin fila (en espera)" no \
    "$(PS_BIN="$pslist" LOCK="$est/skill.lock" CLAUDE_BIN="$doble" \
        CUOTA_CACHE="$tmp/cuota-con-curso/cuota.cache" CUOTA_LOCK="$tmp/cuota-con-curso/cuota.lock" \
        MERGE_CACHE="$merge_vacio/merge.cache" MERGE_LOCK="$merge_vacio/merge.lock" \
        DEVKIT_AHORA="$ahora" WATCH_LOG="$est/watch.log" mostrar_estado \
        | grep -qF '(en espera)' && echo si || echo no)"

  # --- DEVKIT-62: cuota en vivo con `claude -p "/usage"` -----------------
  # La compuerta de la card probó que el campo `result` de
  # `claude -p "/usage" --output-format json` trae el mismo texto que la
  # sesión interactiva. Un doble que lo imita, para probar la extracción sin
  # gastar cuota ni depender de una sesión real.
  local doble_cuota resultado_cuota
  doble_cuota="$tmp/claude-usage"
  cat >"$doble_cuota" <<'FIN'
#!/usr/bin/env bash
cat <<'JSON'
{"result":"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 42% used · resets Sep 17, 5:10pm (UTC)\nCurrent week (all models): 7% used · resets Sep 22, 11pm (UTC)\n","total_cost_usd":0}
JSON
FIN
  chmod +x "$doble_cuota"
  resultado_cuota=$(CLAUDE_BIN="$doble_cuota" leer_cuota)
  check "leer_cuota extrae el porcentaje de sesión" "42" "$(printf '%s' "$resultado_cuota" | cut -f1)"
  check "leer_cuota extrae cuándo reinicia la sesión" "Sep 17, 5:10pm (UTC)" \
    "$(printf '%s' "$resultado_cuota" | cut -f2)"
  check "leer_cuota extrae el porcentaje de semana" "7" "$(printf '%s' "$resultado_cuota" | cut -f3)"
  check "leer_cuota extrae cuándo reinicia la semana" "Sep 22, 11pm (UTC)" \
    "$(printf '%s' "$resultado_cuota" | cut -f4)"

  # DEVKIT-78: el texto de /cost en vez del de /usage (visto de verdad el
  # 2026-09-17, evidencia de la card) no debe confundirse con una lectura
  # válida: sin las líneas "Current session"/"Current week", leer_cuota falla
  # como con cualquier salida sin las líneas esperadas.
  local doble_cuota_costo
  doble_cuota_costo="$tmp/claude-usage-costo"
  cat >"$doble_cuota_costo" <<'FIN'
#!/usr/bin/env bash
cat <<'JSON'
{"result":"Total cost:            $0.0000\nTotal duration (API):  0s\nTotal duration (wall): 0s\nTotal code changes:    0 lines added, 0 lines removed\nUsage by model:\n\nUsage: 0 input, 0 output, 0 cache read, 0 cache write","total_cost_usd":0}
JSON
FIN
  chmod +x "$doble_cuota_costo"
  check "leer_cuota no confunde el texto de /cost con una lectura de /usage" 1 \
    "$(CLAUDE_BIN="$doble_cuota_costo" leer_cuota >/dev/null 2>&1; echo $?)"

  # H2 de pr-review: leer_cuota no debe dejar una sesión propia de Claude
  # Code en ~/.claude/projects/ (con --seguir serían miles por hora).
  local doble_cuota_args args_cuota
  doble_cuota_args="$tmp/claude-usage-args"
  cat >"$doble_cuota_args" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$DEVKIT_TEST_ARGS_FILE"
cat <<'JSON'
{"result":"Current session: 1% used · resets nunca\nCurrent week (all models): 1% used · resets nunca\n","total_cost_usd":0}
JSON
FIN
  chmod +x "$doble_cuota_args"
  args_cuota="$tmp/args-cuota.txt"
  DEVKIT_TEST_ARGS_FILE="$args_cuota" CLAUDE_BIN="$doble_cuota_args" leer_cuota >/dev/null
  check "leer_cuota pide --no-session-persistence a claude -p /usage" 1 \
    "$(grep -c -- '--no-session-persistence' "$args_cuota")"

  # H1 de pr-review: --estado no espera nunca la lectura de la cuota. Con
  # caché fresca, muestra la lectura sin volver a invocar `claude` (CLAUDE_BIN
  # apunta a un binario roto: si mostrar_consumo lo llamara, este caso caería).
  local cuota_fresca
  cuota_fresca="$tmp/cuota-fresca"
  mkdir -p "$cuota_fresca"
  printf '%s\tok\t42\tSep 17, 5:10pm (UTC)\t7\tSep 22, 11pm (UTC)\n' "$(date +%s)" >"$cuota_fresca/cuota.cache"
  check "con caché fresca, el bloque Consumo trae el encabezado con la cuota oficial" \
    "Consumo (cuota oficial, leída" \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=9999 CUOTA_CACHE="$cuota_fresca/cuota.cache" CUOTA_LOCK="$cuota_fresca/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | grep -oE '^Consumo \(cuota oficial, leída')"
  check "con caché fresca, el bloque Consumo trae sesión y semana sin invocar claude" \
    "sesión: 42% usada, reinicia Sep 17, 5:10pm (UTC)|semana: 7% usada, reinicia Sep 22, 11pm (UTC)" \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=9999 CUOTA_CACHE="$cuota_fresca/cuota.cache" CUOTA_LOCK="$cuota_fresca/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | sed -n 's/^  //p' | paste -sd'|')"

  # Con la caché en fail (una lectura anterior sin fuente), --estado lo dice
  # sin romper el resto, tampoco esperando un nuevo intento.
  local cuota_fail
  cuota_fail="$tmp/cuota-fail"
  mkdir -p "$cuota_fail"
  printf '%s\tfail\n' "$(date +%s)" >"$cuota_fail/cuota.cache"
  check "con la caché en fail, --estado avisa sin colgarse" \
    'Consumo: no se pudo leer la cuota oficial con `claude -p "/usage"` ahora' \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=9999 CUOTA_CACHE="$cuota_fail/cuota.cache" CUOTA_LOCK="$cuota_fail/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | tail -1)"

  # Caché vencida: se sigue mostrando la última lectura al instante, y se
  # dispara un refresco en segundo plano que la reemplaza sin que --estado lo
  # espere.
  local doble_cuota_lento cuota_vieja intento
  doble_cuota_lento="$tmp/claude-usage-lento"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$doble_cuota_lento"
  chmod +x "$doble_cuota_lento"
  cuota_vieja="$tmp/cuota-vieja"
  mkdir -p "$cuota_vieja"
  printf '%s\tok\t10\tya\t10\tya\n' "$(( $(date +%s) - 120 ))" >"$cuota_vieja/cuota.cache"
  check "caché vencida: se muestra igual, sin esperar el refresco" \
    "sesión: 10% usada, reinicia ya|semana: 10% usada, reinicia ya" \
    "$(CLAUDE_BIN="$doble_cuota" CUOTA_TTL=60 CUOTA_CACHE="$cuota_vieja/cuota.cache" CUOTA_LOCK="$cuota_vieja/cuota.lock" \
        WATCH_LOG="$est/vacio.log" mostrar_estado | sed -n 's/^  //p' | paste -sd'|')"
  local refrescada=0
  for intento in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(cut -f2,3 "$cuota_vieja/cuota.cache" 2>/dev/null)" = "$(printf 'ok\t42')" ] && { refrescada=1; break; }
    sleep 0.3
  done
  check "el refresco en segundo plano reemplaza la caché vencida" 1 "$refrescada"

  # H4 de pr-review DEVKIT-78: una caché `ok` del formato viejo, de 6 campos
  # sin `ts_ok` (la que ya existe en `.devkit/run/` al actualizar el devkit),
  # es su propia lectura buena. El primer fallo tras el cambio no debe
  # borrarla -antes caía en la rama sin `prev_tsok` y perdía el porcentaje.
  local cuota_vieja_h4 ts_vieja_h4 refrescada_h4
  cuota_vieja_h4="$tmp/cuota-vieja-h4"
  mkdir -p "$cuota_vieja_h4"
  ts_vieja_h4=$(( $(date +%s) - 120 ))
  printf '%s\tok\t10\tya\t10\tya\n' "$ts_vieja_h4" >"$cuota_vieja_h4/cuota.cache"
  CLAUDE_BIN=/bin/false CUOTA_TTL=60 CUOTA_CACHE="$cuota_vieja_h4/cuota.cache" \
    CUOTA_LOCK="$cuota_vieja_h4/cuota.lock" WATCH_LOG="$est/vacio.log" mostrar_estado >/dev/null
  refrescada_h4=0
  for intento in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(cut -f2 "$cuota_vieja_h4/cuota.cache" 2>/dev/null)" = fail ] && { refrescada_h4=1; break; }
    sleep 0.3
  done
  check "H4: el primer fallo tras una caché ok de 6 campos corre" 1 "$refrescada_h4"
  check "H4: ese fallo conserva ts_ok con la hora de la lectura ok vieja, no la borra" "$ts_vieja_h4" \
    "$(cut -f7 "$cuota_vieja_h4/cuota.cache" 2>/dev/null)"

  # DEVKIT-78: un fallo con una lectura buena previa (más vieja que CUOTA_TTL,
  # el caso del criterio de aceptación) no borra esa lectura: --estado sigue
  # mostrando el último porcentaje bueno, con su hora y desde cuándo no se
  # refresca, en vez de "no se pudo leer".
  local cuota_fail_con_buena
  cuota_fail_con_buena="$tmp/cuota-fail-con-buena"
  mkdir -p "$cuota_fail_con_buena"
  printf '%s\tfail\t10\tya\t10\tya\t%s\n' "$(( $(date +%s) - 120 ))" "$(( $(date +%s) - 200 ))" \
    >"$cuota_fail_con_buena/cuota.cache"
  check "última lectura buena más vieja que el TTL: se sigue mostrando, no 'no se pudo leer'" \
    "Consumo (última cuota oficial leída" \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=60 CUOTA_CACHE="$cuota_fail_con_buena/cuota.cache" \
        CUOTA_LOCK="$cuota_fail_con_buena/cuota.lock" WATCH_LOG="$est/vacio.log" mostrar_estado \
        | grep -oE "Consumo \(última cuota oficial leída")"
  check "última lectura buena más vieja que el TTL: trae sesión y semana" \
    "sesión: 10% usada, reinicia ya|semana: 10% usada, reinicia ya" \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=60 CUOTA_CACHE="$cuota_fail_con_buena/cuota.cache" \
        CUOTA_LOCK="$cuota_fail_con_buena/cuota.lock" WATCH_LOG="$est/vacio.log" mostrar_estado \
        | sed -n 's/^  //p' | paste -sd'|')"

  # H2 de pr-review DEVKIT-78: el segundo dato de esa línea es la hora del
  # último intento fallido, no "sin refrescar desde" -esa frase usaba la
  # misma hora y, con fallos repetidos, afirmaba algo falso.
  check "última lectura buena más vieja que el TTL: dice 'último intento fallido', no 'sin refrescar desde'" \
    1 \
    "$(CLAUDE_BIN=/bin/false CUOTA_TTL=60 CUOTA_CACHE="$cuota_fail_con_buena/cuota.cache" \
        CUOTA_LOCK="$cuota_fail_con_buena/cuota.lock" WATCH_LOG="$est/vacio.log" mostrar_estado \
        | grep -c -E 'Consumo \(última cuota oficial leída [0-9:]+, último intento fallido [0-9:]+\)')"

  # H1 de pr-review DEVKIT-78: un fallo espera CUOTA_TTL_FALLO, no CUOTA_TTL,
  # antes de reintentar. Con CUOTA_TTL=60 vencido pero CUOTA_TTL_FALLO=1800
  # sin vencer, no debe disparar `refrescar_cuota_bg` -si lo hiciera, el
  # primer campo (ts) cambiaría a "ahora".
  local cuota_ttl_fallo ts_sin_vencer
  cuota_ttl_fallo="$tmp/cuota-ttl-fallo"
  mkdir -p "$cuota_ttl_fallo"
  ts_sin_vencer=$(( $(date +%s) - 90 ))
  printf '%s\tfail\t10\tya\t10\tya\t%s\n' "$ts_sin_vencer" "$(( $(date +%s) - 200 ))" \
    >"$cuota_ttl_fallo/cuota.cache"
  CLAUDE_BIN=/bin/false CUOTA_TTL=60 CUOTA_TTL_FALLO=1800 CUOTA_CACHE="$cuota_ttl_fallo/cuota.cache" \
    CUOTA_LOCK="$cuota_ttl_fallo/cuota.lock" WATCH_LOG="$est/vacio.log" mostrar_estado >/dev/null
  sleep 0.5
  check "un fallo no reintenta antes de CUOTA_TTL_FALLO, aunque venció CUOTA_TTL" "$ts_sin_vencer" \
    "$(cut -f1 "$cuota_ttl_fallo/cuota.cache" 2>/dev/null)"

  # Pasado CUOTA_TTL_FALLO, el fallo sí vuelve a intentar.
  local cuota_ttl_fallo_vencido ts_vencido refrescado_fallo intento
  cuota_ttl_fallo_vencido="$tmp/cuota-ttl-fallo-vencido"
  mkdir -p "$cuota_ttl_fallo_vencido"
  ts_vencido=$(( $(date +%s) - 90 ))
  printf '%s\tfail\t10\tya\t10\tya\t%s\n' "$ts_vencido" "$(( $(date +%s) - 200 ))" \
    >"$cuota_ttl_fallo_vencido/cuota.cache"
  CLAUDE_BIN=/bin/false CUOTA_TTL=60 CUOTA_TTL_FALLO=1 CUOTA_CACHE="$cuota_ttl_fallo_vencido/cuota.cache" \
    CUOTA_LOCK="$cuota_ttl_fallo_vencido/cuota.lock" WATCH_LOG="$est/vacio.log" mostrar_estado >/dev/null
  refrescado_fallo=0
  for intento in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(cut -f1 "$cuota_ttl_fallo_vencido/cuota.cache" 2>/dev/null)" != "$ts_vencido" ] && { refrescado_fallo=1; break; }
    sleep 0.3
  done
  check "pasado CUOTA_TTL_FALLO, un fallo sí reintenta" 1 "$refrescado_fallo"

  # DEVKIT-78: `permitir_refresco_cuota=0` (lo que pasan `seguir_estado` y
  # `seguir_lanzamiento` pasado CUOTA_DESATENDIDO) muestra la caché vencida
  # igual, pero no dispara `refrescar_cuota_bg` -- CLAUDE_BIN apunta a un
  # binario roto: si igual refrescara, quedaría "fail" en la caché.
  local cuota_desatendida
  cuota_desatendida="$tmp/cuota-desatendida"
  mkdir -p "$cuota_desatendida"
  printf '%s\tok\t10\tya\t10\tya\n' "$(( $(date +%s) - 120 ))" >"$cuota_desatendida/cuota.cache"
  CLAUDE_BIN=/bin/false CUOTA_TTL=60 CUOTA_CACHE="$cuota_desatendida/cuota.cache" \
    CUOTA_LOCK="$cuota_desatendida/cuota.lock" WATCH_LOG="$est/vacio.log" mostrar_estado 0 >/dev/null
  sleep 0.5
  check "permitir_refresco_cuota=0: no dispara un refresco de fondo con la caché vencida" ok \
    "$(cut -f2 "$cuota_desatendida/cuota.cache" 2>/dev/null)"

  # H3 de pr-review DEVKIT-78: calcular_permitir_refresco_cuota es la función
  # compartida por seguir_estado y seguir_lanzamiento -- antes solo el primero
  # cortaba el refresco pasado CUOTA_DESATENDIDO.
  check "calcular_permitir_refresco_cuota: recién arrancado, permite refrescar" 1 \
    "$(CUOTA_DESATENDIDO=900 calcular_permitir_refresco_cuota 1000 1000)"
  check "calcular_permitir_refresco_cuota: pasado CUOTA_DESATENDIDO, ya no permite" 0 \
    "$(CUOTA_DESATENDIDO=900 calcular_permitir_refresco_cuota 1000 2000)"

  # H3 de pr-review: la subshell de refrescar_cuota_bg no debe heredar los
  # descriptores del llamador. Antes de cerrarlos, leer --estado por pipe (o
  # `$(...)`, como aquí con `tail -1`) esperaba a que el refresco de fondo
  # terminara, hasta CUOTA_TIMEOUT.
  local cuota_pipe salida_pipe t0_pipe t1_pipe ms_pipe
  cuota_pipe="$tmp/cuota-pipe"
  mkdir -p "$cuota_pipe"
  printf '%s\tok\t10\tya\t10\tya\n' "$(( $(date +%s) - 120 ))" >"$cuota_pipe/cuota.cache"
  t0_pipe=$(date +%s%N)
  salida_pipe=$(CLAUDE_BIN="$doble_cuota_lento" CUOTA_TIMEOUT=3 CUOTA_TTL=60 \
    CUOTA_CACHE="$cuota_pipe/cuota.cache" CUOTA_LOCK="$cuota_pipe/cuota.lock" \
    WATCH_LOG="$est/vacio.log" mostrar_estado | tail -1)
  t1_pipe=$(date +%s%N)
  ms_pipe=$(( (t1_pipe - t0_pipe) / 1000000 ))
  check "leído por pipe, --estado no espera el refresco de fondo" si \
    "$([ "$ms_pipe" -lt 1000 ] && echo si || echo "no (${ms_pipe}ms)")"
  check "leído por pipe, el bloque Consumo igual llega completo" \
    "semana: 10% usada, reinicia ya" \
    "$(printf '%s\n' "$salida_pipe" | grep -oE 'semana: 10% usada, reinicia ya')"

  # El criterio de la card: sin caché y con un `claude -p "/usage"` que no
  # responde, --estado sigue respondiendo bajo un segundo, incluso con un
  # watch.log de mil líneas.
  local watch_mil cuota_lenta t0 t1 ms salida_mil
  watch_mil="$tmp/watch-mil.log"
  : >"$watch_mil"
  for i in $(seq 1000); do printf '2026-09-16T11:00:00Z ruido de relleno %s\n' "$i"; done >>"$watch_mil"
  cuota_lenta="$tmp/cuota-lenta"
  salida_mil="$tmp/salida-mil.txt"
  t0=$(date +%s%N)
  CLAUDE_BIN="$doble_cuota_lento" CUOTA_TIMEOUT=1 \
    CUOTA_CACHE="$cuota_lenta/cuota.cache" CUOTA_LOCK="$cuota_lenta/cuota.lock" \
    WATCH_LOG="$watch_mil" mostrar_estado >"$salida_mil"
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  check "--estado responde bajo 1s con un /usage lento y un watch.log de mil líneas" si \
    "$([ "$ms" -lt 1000 ] && echo si || echo "no (${ms}ms)")"
  check "sin caché, --estado avisa que va a refrescar en segundo plano" \
    "Consumo: todavía no hay una lectura de la cuota oficial, refrescando en segundo plano" \
    "$(tail -1 "$salida_mil")"
  for intento in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$cuota_lenta/cuota.cache" ] && break
    sleep 0.3
  done
  check "el refresco en segundo plano respeta CUOTA_TIMEOUT y deja fail en la caché" fail \
    "$(cut -f2 "$cuota_lenta/cuota.cache" 2>/dev/null)"

  # De punta a punta: un lanzamiento real deja su línea lanzando y --estado
  # lo muestra terminado. El origen esperado se calcula aquí y no se fija en
  # `humano`: esta prueba puede correr dentro de un `claude -p /task-start`
  # de verdad, y entonces ese es el origen correcto.
  local origen_esperado
  origen_esperado=$(unset DEVKIT_ORIGEN; origen_lanzamiento)
  : >"$tmp/run/watch.log"
  env -u DEVKIT_ORIGEN DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-submit DEVKIT-7 >/dev/null 2>&1
  check "lanzamiento real: línea lanzando con el origen de sus ancestros" \
    "lanzando (origen=${origen_esperado:-?}): \"/task-submit DEVKIT-7\"" \
    "$(grep -oE 'lanzando \(origen=[^)]*\)( modelo=[^ ]+ esfuerzo=[^ ]+ ronda=[^:]+)?: "/task-submit DEVKIT-7"' "$tmp/run/watch.log" \
        | sed -E 's/\) modelo=[^:]+:/):/' | head -1)"
  # DEVKIT-106: la columna ESTADO ahora lleva un icono delante ("✔ terminó"),
  # así que el 5º campo por espacios ya no es la palabra -se busca la palabra
  # en la fila entera, sin fijarse en su posición.
  check "lanzamiento real: --estado lo muestra terminado" si \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
        bash "$HERE/devkit-run.sh" --estado | awk '/DEVKIT-7/' | grep -qF 'terminó' && echo si || echo no)"
  # DEVKIT-106 H4: `--estado` sin `--seguir` (una sola foto) también muestra
  # la cabecera con el punto fijo, no solo la tabla.
  check "--estado (foto única) muestra la cabecera con el punto" si \
    "$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
        bash "$HERE/devkit-run.sh" --estado | head -1 | grep -qE '^devkit-run --estado  .*[●*]' && echo si || echo no)"

  # --seguir <skill> <Clave> (DEVKIT-82): lanza igual que el uso normal y se
  # queda mostrando --estado hasta que termina; la última línea es el
  # resumen de watch.log de ese lanzamiento. DEVKIT_ESTADO_INTERVALO baja a
  # 1 s para no esperar los 3 s de verdad; el doble de claude responde al
  # instante, así que el propio lanzamiento ya terminó cuando entra al bucle.
  local seguir_out
  seguir_out=$(DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    DEVKIT_ESTADO_INTERVALO=1 \
    timeout 15 bash "$HERE/devkit-run.sh" --seguir task-start DEVKIT-97 2>&1)
  # El prompt entre comillas ya no es solo "/task-start DEVKIT-97": lleva el
  # volcado de task-begin.sh bajo "## Card" (DEVKIT-90), así que la
  # comparación es por prefijo, no por el prompt completo.
  check "--seguir <skill> <Clave>: la última línea es el resumen terminado del lanzamiento" si \
    "$(printf '%s\n' "$seguir_out" | tail -1 \
        | grep -qE 'devkit-run "/task-start DEVKIT-97.*terminado \[task-start-[0-9]+\]: modelo=.*costo=' \
        && echo si || echo no)"

  # Ctrl-C durante --seguir no mata al agente (DEVKIT-82): una señal al
  # monitor solo lo cierra, con un aviso; el doble de "claude" -que tarda en
  # responder, para que siga vivo cuando llega la señal- sigue corriendo.
  # El lanzamiento real ya nace con `setsid` (más arriba en el script), así
  # que ni siquiera una señal de la terminal entera lo alcanzaría; esta
  # prueba cubre la parte que sí se puede probar sin una tty real: que el
  # propio monitor no lo toca.
  local doble_lento pid_seguir out_seguir rc_seguir vivo_tras intento
  doble_lento="$tmp/claude-seguir-lento"
  cat >"$doble_lento" <<'FIN'
#!/usr/bin/env bash
sleep 6
printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n'
FIN
  chmod +x "$doble_lento"
  out_seguir="$tmp/seguir-ctrlc.out"
  : >"$out_seguir"
  (
    DEVKIT_CLAUDE_BIN="$doble_lento" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
      DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
      DEVKIT_ESTADO_INTERVALO=1 DEVKIT_ARRANQUE_ESPERA=1 \
      bash "$HERE/devkit-run.sh" --seguir task-start DEVKIT-98 >"$out_seguir" 2>&1
  ) &
  pid_seguir=$!
  for intento in $(seq 1 20); do
    grep -qE 'devkit-run --seguir task-start-[0-9]+' "$out_seguir" 2>/dev/null && break
    sleep 0.3
  done
  kill -INT "$pid_seguir" 2>/dev/null
  wait "$pid_seguir" 2>/dev/null; rc_seguir=$?
  vivo_tras=$(pgrep -f "$doble_lento" >/dev/null 2>&1 && echo si || echo no)
  check "Ctrl-C en --seguir: sale con 130" 130 "$rc_seguir"
  check "Ctrl-C en --seguir: avisa que cierra el monitor sin matar el lanzamiento" si \
    "$(grep -qE 'Ctrl-C cierra el monitor.*sigue en curso.*devkit-run --estado' "$out_seguir" && echo si || echo no)"
  check "Ctrl-C en --seguir: el agente (doble de claude) sigue vivo" si "$vivo_tras"
  pkill -f "$doble_lento" 2>/dev/null
  wait 2>/dev/null

  # --tablero (DEVKIT-82): una sola consulta a notion.sh `activas`, con
  # "bloquea a" (misma caché de DEVKIT-63) y agrupada por Épica de origen
  # cuando hay más de una Épica En progreso (misma caché de DEVKIT-80).
  # Cachés ya tibias, mismo criterio que las pruebas de --estado de arriba:
  # sin llamar a Notion en el propio check.
  local tablero_ws tablero_fixture notion_tablero tablero_bloq tablero_epic salida_tablero
  tablero_ws="$tmp/tablero-ws"
  mkdir -p "$tablero_ws/.devkit"
  printf 'project = "DEVKIT"\n' >"$tablero_ws/.devkit/devkit.toml"
  tablero_fixture="$tmp/tablero-activas.json"
  cat >"$tablero_fixture" <<'JSON'
[{"clave":"DEVKIT-57","estado":"En progreso","tipo":"feature","pr":""},{"clave":"DEVKIT-58","estado":"Lista para merge","tipo":"bug","pr":"https://github.com/o/r/pull/9"},{"clave":"DEVKIT-59","estado":"En progreso","tipo":"chore","pr":""}]
JSON
  notion_tablero="$tmp/notion-tablero"
  cat >"$notion_tablero" <<FIN
#!/usr/bin/env bash
[ "\$1" = activas ] && cat "$tablero_fixture"
FIN
  chmod +x "$notion_tablero"
  tablero_bloq="$tmp/tablero-bloqueos"
  mkdir -p "$tablero_bloq"
  printf '%s\t%s\n' "$(date +%s)" '[{"clave":"DEVKIT-58","bloquea_a":["DEVKIT-61"]}]' >"$tablero_bloq/bloqueos.cache"
  tablero_epic="$tmp/tablero-epicas"
  mkdir -p "$tablero_epic"
  printf '%s\t%s\n' "$(date +%s)" \
    '[{"clave":"DEVKIT-57","epica":"DEVKIT-50","epica_titulo":"Alfa"},{"clave":"DEVKIT-58","epica":"DEVKIT-51","epica_titulo":"Beta"}]' \
    >"$tablero_epic/epicas.cache"
  # LC_ALL=C.UTF-8 fijo (DEVKIT-106 H6): mismo motivo que en las pruebas de
  # "lento" -sin esto, con la locale de quien corre la autoprueba en C, los
  # casos de icono de abajo prueban la rama ASCII en vez de la UTF-8.
  salida_tablero=$(LC_ALL=C.UTF-8 NOTION_BIN="$notion_tablero" WS="$tablero_ws" \
    BLOQUEOS_CACHE="$tablero_bloq/bloqueos.cache" BLOQUEOS_LOCK="$tablero_bloq/bloqueos.lock" \
    EPICAS_CACHE="$tablero_epic/epicas.cache" EPICAS_LOCK="$tablero_epic/epicas.lock" \
    mostrar_tablero)
  check "--tablero: agrupa por Épica de origen con más de una En progreso" \
    "Épica DEVKIT-50: Alfa
Épica DEVKIT-51: Beta" \
    "$(printf '%s\n' "$salida_tablero" | grep '^Épica ')"
  check "--tablero: DEVKIT-58 trae bloquea a en su fila" si \
    "$(printf '%s\n' "$salida_tablero" | grep 'DEVKIT-58' | grep -q 'DEVKIT-61' && echo si || echo no)"
  check "--tablero: DEVKIT-59 sin Épica activa cae en el bloque final" si \
    "$(printf '%s\n' "$salida_tablero" | awk '/^\(sin Épica\)$/{f=1} f' | grep -q 'DEVKIT-59' && echo si || echo no)"
  # DEVKIT-106: --tablero reutiliza los mismos iconos que --estado.
  check "--tablero: DEVKIT-57 En progreso lleva el girador de en curso" si \
    "$(printf '%s\n' "$salida_tablero" | grep 'DEVKIT-57' | grep -qF '⠿' && echo si || echo no)"
  check "--tablero: DEVKIT-58 Lista para merge lleva ✔" si \
    "$(printf '%s\n' "$salida_tablero" | grep 'DEVKIT-58' | grep -qF '✔' && echo si || echo no)"

  # H1 (pr-review sobre DEVKIT-82): con las cachés de bloqueos/epicas vacías
  # -contenedor recién arrancado, sin ningún `--estado` previo-, `--tablero`
  # las asegura en primer plano antes de pintar, así que agrupa y trae
  # "bloquea a" desde la primera llamada, no la segunda.
  local notion_tablero_frio tablero_bloq_frio tablero_epic_frio salida_tablero_frio
  notion_tablero_frio="$tmp/notion-tablero-frio"
  cat >"$notion_tablero_frio" <<FIN
#!/usr/bin/env bash
case "\$1" in
  activas) cat "$tablero_fixture" ;;
  bloqueos) echo '[{"clave":"DEVKIT-58","bloquea_a":["DEVKIT-61"]}]' ;;
  epicas) echo '[{"clave":"DEVKIT-57","epica":"DEVKIT-50","epica_titulo":"Alfa"},{"clave":"DEVKIT-58","epica":"DEVKIT-51","epica_titulo":"Beta"}]' ;;
esac
FIN
  chmod +x "$notion_tablero_frio"
  tablero_bloq_frio="$tmp/tablero-bloqueos-frio"
  tablero_epic_frio="$tmp/tablero-epicas-frio"
  salida_tablero_frio=$(NOTION_BIN="$notion_tablero_frio" WS="$tablero_ws" \
    BLOQUEOS_CACHE="$tablero_bloq_frio/bloqueos.cache" BLOQUEOS_LOCK="$tablero_bloq_frio/bloqueos.lock" \
    EPICAS_CACHE="$tablero_epic_frio/epicas.cache" EPICAS_LOCK="$tablero_epic_frio/epicas.lock" \
    mostrar_tablero)
  check "--tablero H1: agrupa por Épica desde la primera llamada con cachés vacías" \
    "Épica DEVKIT-50: Alfa
Épica DEVKIT-51: Beta" \
    "$(printf '%s\n' "$salida_tablero_frio" | grep '^Épica ')"
  check "--tablero H1: trae bloquea a desde la primera llamada con cachés vacías" si \
    "$(printf '%s\n' "$salida_tablero_frio" | grep 'DEVKIT-58' | grep -q 'DEVKIT-61' && echo si || echo no)"

  # H2 (pr-review sobre DEVKIT-82): una card sin Tipo (null) y sin PR (cadena
  # vacía, lo que devuelve `activas` de verdad, no null) no corre el PR a la
  # columna Tipo: el jq convierte ambos campos vacíos en "-" antes del `@tsv`,
  # así que `IFS=$'\t'` -que colapsa tabulaciones consecutivas como cualquier
  # separador en blanco- ya no ve un campo vacío que saltarse.
  local h2_json h2_linea h2_tipo h2_pr
  h2_json='[{"clave":"DEVKIT-70","estado":"Lista","tipo":null,"pr":""}]'
  h2_linea=$(jq -r '.[] | [.clave, .estado, (.tipo // "" | if . == "" then "-" else . end), (.pr // "" | if . == "" then "-" else . end)] | @tsv' <<<"$h2_json")
  IFS=$'\t' read -r _ _ h2_tipo h2_pr <<<"$h2_linea"
  check "--tablero H2: Tipo null se muestra como guion, no como el PR" "-" "$h2_tipo"
  check "--tablero H2: PR vacío también se muestra como guion" "-" "$h2_pr"

  local notion_tablero_vacio
  notion_tablero_vacio="$tmp/notion-tablero-vacio"
  cat >"$notion_tablero_vacio" <<'FIN'
#!/usr/bin/env bash
[ "$1" = activas ] && echo '[]'
FIN
  chmod +x "$notion_tablero_vacio"
  check "--tablero sin cards activas lo dice" "sin cards activas en el proyecto DEVKIT" \
    "$(NOTION_BIN="$notion_tablero_vacio" WS="$tablero_ws" mostrar_tablero)"

  local ws_sin_proyecto tablero_err rc_sin_proyecto
  ws_sin_proyecto="$tmp/sin-proyecto"
  mkdir -p "$ws_sin_proyecto"
  tablero_err=$(WS="$ws_sin_proyecto" mostrar_tablero); rc_sin_proyecto=$?
  check "--tablero sin \"project\" en devkit.toml: sale con error" 1 "$rc_sin_proyecto"
  check "--tablero sin \"project\" en devkit.toml: lo avisa" si \
    "$(printf '%s' "$tablero_err" | grep -q 'no encuentro' && echo si || echo no)"

  # --cola (DEVKIT-119): un paso al costado, `cola.sh --lista`. Doble que
  # anota sus argumentos, para comprobar que se llama con --lista y que
  # devkit-run se limita a mostrar su salida, sin tocar Notion por su cuenta.
  local cola_doble cola_llamadas cola_salida
  cola_doble="$tmp/cola-doble"
  cola_llamadas="$tmp/cola-llamadas"
  cat >"$cola_doble" <<FIN
#!/usr/bin/env bash
echo "\$*" >>"$cola_llamadas"
echo "DEVKIT-51 DEVKIT-50 hija de prueba"
FIN
  chmod +x "$cola_doble"
  cola_salida=$(DEVKIT_COLA_BIN="$cola_doble" bash "$HERE/devkit-run.sh" --cola)
  check "--cola: llama a cola.sh --lista" "--lista" "$(cat "$cola_llamadas")"
  check "--cola: muestra la salida de cola.sh --lista" "DEVKIT-51 DEVKIT-50 hija de prueba" "$cola_salida"

  # H3 (pr-review sobre DEVKIT-82): si el worker muere sin dejar su línea de
  # cierre en watch.log (SIGKILL, OOM), `seguir_lanzamiento` no espera para
  # siempre: pasado MARGEN_LANZAMIENTO_MUERTO desde que `kill -0` empieza a
  # fallar, lo dice y sale con un código distinto de cero. `h3_pid_muerto` es
  # un PID real ya cosechado con `wait`, así que `kill -0` falla desde ya.
  local h3_watch h3_pid_muerto h3_salida h3_rc
  h3_watch="$tmp/h3-watch.log"
  : >"$h3_watch"
  (: ) & h3_pid_muerto=$!
  wait "$h3_pid_muerto" 2>/dev/null
  h3_salida=$(CLAUDE_BIN="$doble" PS_BIN="$pslist_vacio" \
    CUOTA_CACHE="$tmp/cuota-h3/cuota.cache" CUOTA_LOCK="$tmp/cuota-h3/cuota.lock" \
    BLOQUEOS_CACHE="$tmp/bloqueos-h3/bloqueos.cache" BLOQUEOS_LOCK="$tmp/bloqueos-h3/bloqueos.lock" \
    EPICAS_CACHE="$tmp/epicas-h3/epicas.cache" EPICAS_LOCK="$tmp/epicas-h3/epicas.lock" \
    WATCH_LOG="$h3_watch" ESTADO_INTERVALO=1 MARGEN_LANZAMIENTO_MUERTO=1 \
    seguir_lanzamiento h3-lanzamiento "$h3_pid_muerto" 2>&1)
  h3_rc=$?
  check "--seguir H3: worker muerto sin resumen sale con error" 1 "$([ "$h3_rc" -ne 0 ] && echo 1 || echo 0)"
  check "--seguir H3: worker muerto sin resumen lo dice" si \
    "$(printf '%s\n' "$h3_salida" | grep -q 'murió sin dejar resumen' && echo si || echo no)"

  # DEVKIT-79: un lanzamiento duplicado (mismo prompt, worker vivo o
  # esperando el candado) no se lanza dos veces. Doble de `ps` que informa un
  # worker ya corriendo para "/task-start DEVKIT-9"; sin --forzar, el
  # lanzamiento se rechaza antes de escribir la línea "lanzando".
  local pslist_dup dup_out dup_rc
  pslist_dup="$tmp/ps-dup"
  printf '#!/usr/bin/env bash\necho "9001 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-9 %s/task-start-9.log opus high 40"\n' \
    "$tmp/run" >"$pslist_dup"
  chmod +x "$pslist_dup"
  printf '%s task-start-9 lanzando (origen=humano) modelo=opus esfuerzo=high ronda=1: "/task-start DEVKIT-9" log=%s/task-start-9.log\n' \
    "$(date +%FT%T%:z)" "$tmp/run" >"$tmp/run/watch.log"
  dup_out=$(DEVKIT_PS_BIN="$pslist_dup" DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-9 2>&1); dup_rc=$?
  check "lanzamiento duplicado: sale con error" 68 "$dup_rc"
  check "lanzamiento duplicado: avisa con el pid y el log del lanzamiento vivo (línea nueva con modelo/esfuerzo/ronda)" 1 \
    "$(printf '%s' "$dup_out" | grep -c "ya hay un lanzamiento de \"/task-start DEVKIT-9\" en curso (pid 9001, log $tmp/run/task-start-9.log)")"
  check "lanzamiento duplicado: no agrega una segunda línea lanzando" 1 \
    "$(grep -c 'lanzando' "$tmp/run/watch.log" 2>/dev/null)"
  check "lanzamiento duplicado: --forzar sí lanza (agrega su propia línea lanzando)" 2 \
    "$(DEVKIT_PS_BIN="$pslist_dup" DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp/run" DEVKIT_WS="$tmp" \
        DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp/run/frontera" \
        bash "$HERE/devkit-run.sh" --forzar task-start DEVKIT-9 >/dev/null 2>&1
      grep -c 'lanzando' "$tmp/run/watch.log")"

  # DEVKIT-81 H1: el aviso de duplicado también debe encontrar el log de una
  # línea "lanzando" del formato viejo, sin modelo/esfuerzo/ronda, que puede
  # seguir en watch.log tras una actualización del devkit.
  local pslist_dup_viejo dup_out_viejo tmp_viejo
  tmp_viejo="$tmp/dup-viejo"
  mkdir -p "$tmp_viejo/run"
  pslist_dup_viejo="$tmp/ps-dup-viejo"
  printf '#!/usr/bin/env bash\necho "9002 bash /workspace/devkit/scripts/devkit-run.sh --worker /task-start DEVKIT-9 %s/task-start-9.log opus high 40"\n' \
    "$tmp_viejo/run" >"$pslist_dup_viejo"
  chmod +x "$pslist_dup_viejo"
  printf '%s task-start-9 lanzando (origen=humano): "/task-start DEVKIT-9" log=%s/task-start-9.log\n' \
    "$(date +%FT%T%:z)" "$tmp_viejo/run" >"$tmp_viejo/run/watch.log"
  dup_out_viejo=$(DEVKIT_PS_BIN="$pslist_dup_viejo" DEVKIT_CLAUDE_BIN="$doble" DEVKIT_RUN_DIR="$tmp_viejo/run" DEVKIT_WS="$tmp" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$tmp_viejo/run/frontera" \
    bash "$HERE/devkit-run.sh" task-start DEVKIT-9 2>&1)
  check "lanzamiento duplicado: avisa con el pid y el log del lanzamiento vivo (línea vieja sin modelo/esfuerzo/ronda)" 1 \
    "$(printf '%s' "$dup_out_viejo" | grep -c "ya hay un lanzamiento de \"/task-start DEVKIT-9\" en curso (pid 9002, log $tmp_viejo/run/task-start-9.log)")"

  # --- DEVKIT-89: costos.log y devkit-run --costos --------------------------
  check "resumen incluye duracion= desde duration_ms del JSON" "duracion=12s" \
    "$(printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3,"duration_ms":12345}\n' >"$tmp/dur.log"
       resumen "$tmp/dur.log" m e 99 | grep -oE 'duracion=[0-9]+s')"
  check "resumen usa ? en duracion= cuando falta duration_ms, no un 0 inventado (H4)" "duracion=?s" \
    "$(printf '{"result":"listo","total_cost_usd":0.02,"num_turns":3}\n' >"$tmp/sindur.log"
       resumen "$tmp/sindur.log" m e 99 | grep -oE 'duracion=\?s')"

  check "costos_log_candidata acepta un lanzamiento de las seis skills" 0 \
    "$(costos_log_candidata '2026-09-10T10:00:00-05:00 task-start-1 lanzando (origen=humano) modelo=m esfuerzo=e ronda=1: "/task-start DEVKIT-1" log=/x.log'; echo $?)"
  check "costos_log_candidata rechaza una línea narrativa del bucle" 1 \
    "$(costos_log_candidata '2026-09-10T10:00:00-05:00 PR #31 (DEVKIT-1) head abc1234 sin informe: lanzando pr-review'; echo $?)"
  check "costos_log_candidata rechaza task-block, fuera de la tabla de --costos" 1 \
    "$(costos_log_candidata '2026-09-10T10:00:00-05:00 task-block-31 terminado: bash :: bloqueada'; echo $?)"
  check "costos_log_candidata acepta el ALARMA de un cierre con error de run_skill" 0 \
    "$(costos_log_candidata '2026-09-10T10:00:00-05:00 ALARMA: task-fix-1 terminó con error (rc=1): modelo=m esfuerzo=e ronda=1 costo=0.05 turnos=3 duracion=10s tokens: entrada=1 cache=1 salida=1 :: error; ver /x.log'; echo $?)"
  check "costos_log_candidata acepta el falló (rc=) de devkit-run.sh --worker" 0 \
    "$(costos_log_candidata '2026-09-10T10:00:00-05:00 devkit-run "/task-fix DEVKIT-1" falló (rc=1) [task-fix-1]: modelo=m esfuerzo=e ronda=1 costo=0.05 turnos=3 duracion=10s :: error'; echo $?)"
  check "costos_log_candidata acepta el falló (rc=) de task-close-N en bash" 0 \
    "$(costos_log_candidata '2026-09-10T10:00:00-05:00 task-close-31 falló (rc=1): bash, cerrado 15s después del merge :: error'; echo $?)"

  # Una card completa: task-start, una revisión de pr-review (sin Clave en su
  # prompt, se resuelve por el título del PR con un doble de gh), un
  # task-fix y el cierre bash de task-close (sin línea "lanzando").
  local costos_tmp=$tmp/costos
  mkdir -p "$costos_tmp"
  cat >"$costos_tmp/costos.log" <<'FIN'
2026-09-10T10:00:00-05:00 task-start-1 lanzando (origen=humano) modelo=modelo-barato esfuerzo=low ronda=1: "/task-start DEVKIT-77" log=/run/devkit/task-start-1.log
2026-09-10T10:00:30-05:00 task-start-1 terminado: modelo=modelo-barato esfuerzo=low ronda=1 costo=0.01 turnos=1 duracion=30s tokens: entrada=1 cache=1 salida=1 :: listo
2026-09-10T10:05:00-05:00 pr-review-31-abc1234 lanzando (origen=bucle) modelo=modelo-fuerte esfuerzo=high ronda=-: "/pr-review 31" log=/run/devkit/pr-review-31-abc1234.log
2026-09-10T10:06:00-05:00 pr-review-31-abc1234 terminado: modelo=modelo-fuerte esfuerzo=high ronda=- costo=0.20 turnos=5 duracion=60s tokens: entrada=1 cache=1 salida=1 :: revisado
2026-09-10T10:10:00-05:00 task-fix-31-abc1234 lanzando (origen=bucle) modelo=modelo-medio esfuerzo=medium ronda=2: "/task-fix DEVKIT-77" log=/run/devkit/task-fix-31-abc1234.log
2026-09-10T10:11:30-05:00 task-fix-31-abc1234 terminado: modelo=modelo-medio esfuerzo=medium ronda=2 costo=0.15 turnos=8 duracion=90s tokens: entrada=1 cache=1 salida=1 :: corregido
2026-09-10T10:20:00-05:00 task-close-31 terminado: bash, cerrado 15s después del merge :: cerrada
FIN
  cat >"$costos_tmp/gh-doble" <<'FIN'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = view ] && [ "$3" = 31 ]; then
  echo "DEVKIT-77 algo de prueba"
  exit 0
fi
exit 1
FIN
  chmod +x "$costos_tmp/gh-doble"
  GH_BIN="$costos_tmp/gh-doble" COSTOS_LOG="$costos_tmp/costos.log"

  check "clave_de_lanzamiento la toma del prompt cuando está" "DEVKIT-77" \
    "$(clave_de_lanzamiento '/task-fix DEVKIT-77' task-fix-31-abc1234)"
  check "clave_de_lanzamiento resuelve pr-review por el título del PR (gh)" "DEVKIT-77" \
    "$(GH_BIN="$costos_tmp/gh-doble" clave_de_lanzamiento '/pr-review 31' pr-review-31-abc1234)"

  check "costos_filas trae las cuatro filas de la card (task-close incluido)" 4 \
    "$(costos_filas "$COSTOS_LOG" DEVKIT-77 | wc -l)"

  # DEVKIT-94: `--costos <Clave>` marca con "!" la fila cuyos turnos pasaron
  # el presupuesto vigente en roles.toml para ese skill. task-fix-31 gastó 8
  # turnos; con `presupuesto.task-fix = 5` queda marcado, task-start (1
  # turno, tope 40 por defecto) y pr-review (5 turnos, tope 50 por defecto)
  # no.
  cat >"$costos_tmp/roles.toml" <<'FIN'
frontera = ["modelo-barato"]
implementacion.model_index = 1
implementacion.effort = "low"
implementacion.max_turns = 40
revision.model_index = 1
revision.effort = "high"
revision.max_turns = 50
presupuesto.task-fix = 5
FIN
  check "--costos <Clave> marca con ! la fila que superó el presupuesto" 1 \
    "$(ROLES_FILE="$costos_tmp/roles.toml" costos_tabla_card DEVKIT-77 | grep -c '8!')"
  check "--costos <Clave> no marca las filas dentro del presupuesto" 0 \
    "$(ROLES_FILE="$costos_tmp/roles.toml" costos_tabla_card DEVKIT-77 | grep -cE '\b(1|5)!')"

  # H3 de pr-review en DEVKIT-89: pr-review-31 y task-close-31 comparten el
  # PR 31; con CLAVE_DE_PR_CACHE, la segunda resolución sale del archivo y no
  # de un segundo `gh pr view`.
  local llamadas_gh=$costos_tmp/llamadas-gh cache_pr
  : > "$llamadas_gh"
  cat >"$costos_tmp/gh-contador" <<FIN
#!/usr/bin/env bash
echo x >> "$llamadas_gh"
if [ "\$1" = pr ] && [ "\$2" = view ] && [ "\$3" = 31 ]; then
  echo "DEVKIT-77 algo de prueba"
  exit 0
fi
exit 1
FIN
  chmod +x "$costos_tmp/gh-contador"
  cache_pr=$(mktemp)
  GH_BIN="$costos_tmp/gh-contador" CLAVE_DE_PR_CACHE="$cache_pr" costos_filas "$COSTOS_LOG" DEVKIT-77 >/dev/null
  rm -f "$cache_pr"
  GH_BIN="$costos_tmp/gh-doble"
  check "clave_de_pr con caché llama a gh una sola vez pese a dos líneas del mismo PR" 1 \
    "$(wc -l < "$llamadas_gh")"

  # H3 de pr-review en DEVKIT-89, segunda vuelta: dos cards de PR distinto en
  # el mismo log. Sin poblar_cache_pr, costos_filas resolvería la Clave de
  # las dos (antes de filtrar) con dos `gh pr view`; con la caché poblada por
  # una sola `gh pr list`, el total de llamadas a gh es 1, no 2.
  local llamadas_gh2=$costos_tmp/llamadas-gh2 cache_pr2 dos_prs_log=$costos_tmp/dos-prs.log
  : > "$llamadas_gh2"
  cat >"$costos_tmp/gh-contador2" <<FIN
#!/usr/bin/env bash
echo x >> "$llamadas_gh2"
if [ "\$1" = pr ] && [ "\$2" = list ]; then
  echo '[{"number":101,"title":"DEVKIT-101 algo"},{"number":102,"title":"DEVKIT-102 otra cosa"}]'
  exit 0
fi
exit 1
FIN
  chmod +x "$costos_tmp/gh-contador2"
  cat >"$dos_prs_log" <<'FIN'
2026-09-18T10:00:00-05:00 pr-review-101 lanzando (origen=bucle) modelo=modelo-fuerte esfuerzo=high ronda=-: "/pr-review 101" log=/run/devkit/pr-review-101.log
2026-09-18T10:01:00-05:00 pr-review-101 terminado: modelo=modelo-fuerte esfuerzo=high ronda=- costo=0.10 turnos=2 duracion=30s tokens: entrada=1 cache=1 salida=1 :: revisado
2026-09-18T10:02:00-05:00 pr-review-102 lanzando (origen=bucle) modelo=modelo-fuerte esfuerzo=high ronda=-: "/pr-review 102" log=/run/devkit/pr-review-102.log
2026-09-18T10:03:00-05:00 pr-review-102 terminado: modelo=modelo-fuerte esfuerzo=high ronda=- costo=0.20 turnos=3 duracion=40s tokens: entrada=1 cache=1 salida=1 :: revisado
FIN
  cache_pr2=$(mktemp)
  GH_BIN="$costos_tmp/gh-contador2" poblar_cache_pr "$cache_pr2"
  GH_BIN="$costos_tmp/gh-contador2" CLAVE_DE_PR_CACHE="$cache_pr2" costos_filas "$dos_prs_log" DEVKIT-101 >/dev/null
  rm -f "$cache_pr2"
  GH_BIN="$costos_tmp/gh-doble"
  check "poblar_cache_pr resuelve dos PR distintos con una sola llamada a gh" 1 \
    "$(wc -l < "$llamadas_gh2")"

  check "costos_totales_card suma turnos, costo y minutos; cuenta 1 revisión" \
    "14	0.3600	3	1" \
    "$(costos_totales_card DEVKIT-77)"
  check "costos_totales_card sin filas no inventa un 0 turnos, 0 USD (H5)" 1 \
    "$(costos_totales_card DEVKIT-999 >/dev/null 2>&1; echo $?)"

  check "costos_tabla_card muestra la fila TOTAL con lo mismo que costos_totales_card" 1 \
    "$(costos_tabla_card DEVKIT-77 | grep -c '^TOTAL.*14.*0.3600.*3 (1 revisiones)')"
  check "costos_tabla_card muestra modelo/esfuerzo/ronda por fila" 1 \
    "$(costos_tabla_card DEVKIT-77 | grep -c 'modelo-medio/medium r2')"
  check "costos_tabla_card no pega la fecha con zona horaria a la columna siguiente (H7)" 1 \
    "$(costos_tabla_card DEVKIT-77 | grep -c '2026-09-10T10:00:00-05:00 ')"

  check "costos_tabla_card de una Clave sin lanzamientos no revienta" 1 \
    "$(costos_tabla_card DEVKIT-999 | grep -c 'Sin lanzamientos de DEVKIT-999')"

  check "mostrar_costos sin costos.log avisa en vez de fallar" 1 \
    "$(COSTOS_LOG="$tmp/no-existe/costos.log" mostrar_costos | grep -c 'Sin costos.log todavía')"

  # H2 de pr-review en DEVKIT-89: un cierre con error también gastó turnos y
  # costo, y no debe perderse ni contarse como card cerrada.
  local costos_error=$tmp/costos-error
  mkdir -p "$costos_error"
  cat >"$costos_error/costos.log" <<'FIN'
2026-09-11T10:00:00-05:00 task-fix-40 lanzando (origen=bucle) modelo=modelo-medio esfuerzo=medium ronda=1: "/task-fix DEVKIT-80" log=/run/devkit/task-fix-40.log
2026-09-11T10:01:00-05:00 ALARMA: task-fix-40 terminó con error (rc=1): modelo=modelo-medio esfuerzo=medium ronda=1 costo=0.07 turnos=4 duracion=20s tokens: entrada=1 cache=1 salida=1 :: error; ver /run/devkit/task-fix-40.log
2026-09-11T10:05:00-05:00 task-close-40 falló (rc=1): bash, cerrado 5s después del merge :: error
FIN
  check "costos_cierre_de empareja el ALARMA de un cierre con error" 1 \
    "$(costos_cierre_de "$costos_error/costos.log" 1 task-fix-40 | grep -c 'costo=0.07 turnos=4')"
  check "costos_filas no pierde el costo de un lanzamiento que terminó con error" "0.07" \
    "$(costos_filas "$costos_error/costos.log" DEVKIT-80 | cut -f9)"
  check "costos_resumen_proyecto no cuenta un task-close-N falló como card cerrada" 1 \
    "$(COSTOS_LOG="$costos_error/costos.log" costos_resumen_proyecto | grep -c 'Sin cards cerradas')"

  # DEVKIT-107 H2: un pr-review que no lanzó ("ya revisado en <sha>") y que
  # luego se relanza con el mismo id (mismo head, tras un devkit-fix sin
  # push) no debe emparejar el cierre del primer lanzamiento con el
  # "terminado" del segundo, ni contar ese costo dos veces.
  local no_lanzo_log=$tmp/no-lanzo-costos.log cache_no_lanzo
  cache_no_lanzo=$(mktemp)
  printf '73\tDEVKIT-73\n' >"$cache_no_lanzo"
  rm -f "$no_lanzo_log"
  # Las líneas pasan por costos_log_candidata/costos_log, no se escriben a
  # mano: así la prueba cubre también que "no lanzó" sí llegue a costos.log
  # (reabierto en la segunda vuelta de DEVKIT-107 H2, antes descartada ahí).
  (
    COSTOS_LOG=$no_lanzo_log
    costos_log '2026-09-19T12:00:00-05:00 pr-review-73-abc1234 lanzando (origen=bucle) modelo=modelo-fuerte esfuerzo=high ronda=-: "/pr-review 73" log=/run/devkit/pr-review-73-abc1234.log'
    costos_log '2026-09-19T12:00:05-05:00 pr-review-73-abc1234 no lanzó: nada que revisar (ya revisado en abc1234)'
    costos_log '2026-09-19T12:05:00-05:00 pr-review-73-abc1234 lanzando (origen=bucle) modelo=modelo-fuerte esfuerzo=high ronda=-: "/pr-review 73" log=/run/devkit/pr-review-73-abc1234.log'
    costos_log '2026-09-19T12:10:00-05:00 pr-review-73-abc1234 terminado: modelo=modelo-fuerte esfuerzo=high ronda=- costo=0.20 turnos=10 duracion=30s tokens: entrada=1 cache=1 salida=1 :: revisado'
  )
  check "costos_log copia 'no lanzó' a costos.log (H2 reabierto: antes se descartaba)" 4 \
    "$(wc -l <"$no_lanzo_log")"
  check "costos_cierre_de empareja 'no lanzó' como cierre, sin saltar al del relanzamiento" 1 \
    "$(costos_cierre_de "$no_lanzo_log" 1 pr-review-73-abc1234 | grep -c 'no lanzó')"
  check "costos_filas no cuenta dos veces el costo de un id relanzado tras 'no lanzó'" 1 \
    "$(CLAVE_DE_PR_CACHE="$cache_no_lanzo" costos_filas "$no_lanzo_log" DEVKIT-73 | wc -l)"
  check "costos_filas: la única fila trae el costo del relanzamiento, no uno vacío" 0.20 \
    "$(CLAVE_DE_PR_CACHE="$cache_no_lanzo" costos_filas "$no_lanzo_log" DEVKIT-73 | cut -f9)"
  rm -f "$cache_no_lanzo"

  check "--costos-totales de la card, por línea de comandos" "14	0.3600	3	1" \
    "$(DEVKIT_GH_BIN="$costos_tmp/gh-doble" DEVKIT_COSTOS_LOG="$costos_tmp/costos.log" \
       bash "$HERE/devkit-run.sh" --costos-totales DEVKIT-77)"

  # DEVKIT-89 criterio 1: watch.sh y devkit-run.sh copian lanzando/terminado a
  # costos.log de verdad, no solo en la teoría de costos_log_candidata.
  local costos_real=$tmp/costos-real
  mkdir -p "$costos_real/run"
  touch "$costos_real/run/ready"  # sin esto, esperar_arranque espera 120s de verdad
  DEVKIT_WS="$costos_real" DEVKIT_RUN_DIR="$costos_real/run" DEVKIT_CLAUDE_BIN="$doble" \
    DEVKIT_ROLES_FILE="$tmp/roles.toml" DEVKIT_FRONTERA_CACHE_DIR="$costos_real/run/frontera" \
    DEVKIT_NOTION_CHECK=0 bash "$HERE/devkit-run.sh" task-start DEVKIT-30 >/dev/null 2>&1
  local intentos=0
  while ! grep -q 'terminado' "$costos_real/.devkit/costos.log" 2>/dev/null && [ "$intentos" -lt 100 ]; do
    sleep 0.05; intentos=$((intentos + 1))
  done
  check "devkit-run.sh escribe lanzando y terminado en .devkit/costos.log" 2 \
    "$(grep -cE '(task-start-1 lanzando|terminado \[task-start-1\])' "$costos_real/.devkit/costos.log" 2>/dev/null)"

  # --- task-submit.sh (DEVKIT-91), con gh y notion.sh simulados -------------
  # `--mensaje` sin valor (H6): antes entraba en bucle infinito por un
  # `shift 2` que fallaba sin desplazar; el `timeout` es la red por si
  # regresa.
  timeout 5 bash "$HERE/task-submit.sh" --mensaje >/dev/null 2>&1
  check "task-submit (--mensaje sin valor): sale con 64, no cuelga" 64 "$?"

  # Workspace propio con un origin local de verdad, mismo patrón que la
  # batería de task-begin.sh de más arriba: `git push` necesita un remoto al
  # que empujar.
  local ts_dir
  ts_dir=$(mktemp -d)
  git init -q --bare "$ts_dir/origin.git"
  git init -q "$ts_dir/ws"
  git -C "$ts_dir/ws" config user.email test@example.com
  git -C "$ts_dir/ws" config user.name test
  git -C "$ts_dir/ws" remote add origin "$ts_dir/origin.git"
  git -C "$ts_dir/ws" commit -q --allow-empty -m init --no-gpg-sign
  git -C "$ts_dir/ws" branch -q -m main
  git -C "$ts_dir/ws" push -q -u origin main
  git -C "$ts_dir/ws" switch -q -c feat/DEVKIT-9301-probar-task-submit
  git -C "$ts_dir/ws" push -q -u origin feat/DEVKIT-9301-probar-task-submit
  mkdir -p "$ts_dir/run" "$ts_dir/ws/.devkit"
  cat >"$ts_dir/notion-doble" <<'FIN'
#!/usr/bin/env bash
case "$1" in
  card) printf '{"id":"card-1","url":"https://notion.so/card1","estado":"En progreso","titulo":"Probar task-submit"}' ;;
  set) shift; printf '%s\n' "$*" >>"$FAKE_DIR/set-llamadas" ;;
  comentar) shift; printf '%s\n' "$*" >>"$FAKE_DIR/comentar-llamadas" ;;
esac
FIN
  chmod +x "$ts_dir/notion-doble"
  cat >"$ts_dir/gh-doble" <<'FIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/llamadas-gh"
case "$1 $2" in
  "pr view")
    if [ -s "$FAKE_DIR/pr-existe" ]; then cat "$FAKE_DIR/pr-existe"; exit 0; else exit 1; fi ;;
  "pr create")
    cat >"$FAKE_DIR/cuerpo-create"
    echo "https://github.com/o/r/pull/42"
    printf '{"url":"https://github.com/o/r/pull/42","number":42}' >"$FAKE_DIR/pr-existe"
    exit 0 ;;
  "pr edit")
    cat >"$FAKE_DIR/cuerpo-edit"
    exit 0 ;;
  "pr merge")
    exit 0 ;;
  *) exit 1 ;;
esac
FIN
  chmod +x "$ts_dir/gh-doble"
  local ts_env=(FAKE_DIR="$ts_dir" DEVKIT_WS="$ts_dir/ws" DEVKIT_RUN_DIR="$ts_dir/run" \
    DEVKIT_NOTION_BIN="$ts_dir/notion-doble" DEVKIT_GH_BIN="$ts_dir/gh-doble")

  cat >"$ts_dir/ws/.devkit/pr-body.md" <<'FIN'
## Qué cambia
Primera línea del cambio.
Segunda línea del cambio.

## Cómo probarlo
bash -n devkit/scripts/task-submit.sh

## Cambios requeridos
Ninguno.
FIN
  echo "algo nuevo" >"$ts_dir/ws/archivo.txt"
  env "${ts_env[@]}" bash "$HERE/task-submit.sh" --mensaje "feat(DEVKIT-9301): probar task-submit" >/dev/null 2>&1
  check "task-submit (PR nuevo): sale con 0" 0 "$?"
  check "task-submit (PR nuevo): comitea con el mensaje recibido" "feat(DEVKIT-9301): probar task-submit" \
    "$(git -C "$ts_dir/ws" log -1 --format=%s)"
  check "task-submit (PR nuevo): el commit no incluye .devkit/pr-body.md" 0 \
    "$(git -C "$ts_dir/ws" show --name-only --format= HEAD | grep -c 'pr-body.md')"
  check "task-submit (PR nuevo): sube el commit a origin" 1 \
    "$(git -C "$ts_dir/ws" ls-remote --heads origin 2>/dev/null | grep -c 'feat/DEVKIT-9301')"
  check "task-submit (PR nuevo): crea el PR (no lo edita)" 1 \
    "$([ -e "$ts_dir/cuerpo-create" ] && echo 1 || echo 0)"
  check "task-submit (PR nuevo): el cuerpo trae la sección Card y la marca de modelo" 1 \
    "$(grep -cE '^Implementado con .+, esfuerzo .+' "$ts_dir/cuerpo-create")"
  check "task-submit (PR nuevo): activa auto-merge" 1 \
    "$(grep -c '^pr merge --auto --squash' "$ts_dir/llamadas-gh")"
  check "task-submit (PR nuevo): deja PR y Estado=Revisión automática en la card" \
    'card-1 PR=https://github.com/o/r/pull/42 Estado=Revisión automática' \
    "$(cat "$ts_dir/set-llamadas")"
  check "task-submit (PR nuevo): comenta las dos primeras líneas de Qué cambia" \
    'card-1 Primera línea del cambio.
Segunda línea del cambio.' "$(cat "$ts_dir/comentar-llamadas")"
  check "task-submit (PR nuevo): toca /run/devkit/poke" 1 "$([ -e "$ts_dir/run/poke" ] && echo 1 || echo 0)"
  check "task-submit (PR nuevo): borra .devkit/pr-body.md" 1 \
    "$([ -e "$ts_dir/ws/.devkit/pr-body.md" ] && echo 0 || echo 1)"

  # PR existente: no vuelve a crear, edita el mismo número.
  rm -f "$ts_dir/set-llamadas" "$ts_dir/comentar-llamadas"
  cat >"$ts_dir/ws/.devkit/pr-body.md" <<'FIN'
## Qué cambia
Cambio nuevo sobre el PR existente.

## Cómo probarlo
Nada nuevo.

## Cambios requeridos
Ninguno.
FIN
  echo "otro cambio" >>"$ts_dir/ws/archivo.txt"
  env "${ts_env[@]}" bash "$HERE/task-submit.sh" --mensaje "feat(DEVKIT-9301): segundo cambio" >/dev/null 2>&1
  check "task-submit (PR existente): sale con 0" 0 "$?"
  check "task-submit (PR existente): edita el PR en vez de crear otro" 1 \
    "$(grep -c '^pr create' "$ts_dir/llamadas-gh")"
  check "task-submit (PR existente): el cuerpo editado trae el cambio nuevo" 1 \
    "$(grep -c 'Cambio nuevo sobre el PR existente' "$ts_dir/cuerpo-edit")"

  # Diff grande (DEVKIT-94, H2 del informe sobre el PR #68): el aviso va
  # después de "## Card", nunca dentro de "## Cambios requeridos" -esa
  # sección la copia tal cual `task-document.sh` (`seccion`) a la entrada de
  # Documentación y, de ahí, a la card de release.
  rm -f "$ts_dir/set-llamadas" "$ts_dir/comentar-llamadas" "$ts_dir/cuerpo-edit"
  seq 1 400 >"$ts_dir/ws/archivo-grande.txt"
  cat >"$ts_dir/ws/.devkit/pr-body.md" <<'FIN'
## Qué cambia
Un archivo grande.

## Cómo probarlo
N/A

## Cambios requeridos
Ninguno.
FIN
  env "${ts_env[@]}" bash "$HERE/task-submit.sh" --mensaje "feat(DEVKIT-9301): diff grande" >/dev/null 2>&1
  check "task-submit (diff grande): avisa en el cuerpo" 1 \
    "$(grep -cE '^Diff grande: [0-9]+ líneas$' "$ts_dir/cuerpo-edit")"
  check "task-submit (diff grande): el aviso queda después de \"## Card\", no antes" 1 \
    "$([ "$(grep -n '^Diff grande:' "$ts_dir/cuerpo-edit" | head -1 | cut -d: -f1)" -gt \
        "$(grep -n '^## Card' "$ts_dir/cuerpo-edit" | head -1 | cut -d: -f1)" ] 2>/dev/null && echo 1 || echo 0)"
  check "task-submit (diff grande): \"Cambios requeridos\" no lo incluye" "Ninguno." \
    "$(awk '/^## Cambios requeridos/{c=1;next} /^## /{c=0} c && NF' "$ts_dir/cuerpo-edit")"

  # Verificación que falla (bash -n sobre un .sh tocado): no comitea, no
  # sube, no toca el PR ni la card, y deja el error en stderr.
  rm -f "$ts_dir/set-llamadas" "$ts_dir/comentar-llamadas"
  printf 'if [ true ]; then echo hi\n' >"$ts_dir/ws/roto.sh"
  cat >"$ts_dir/ws/.devkit/pr-body.md" <<'FIN'
## Qué cambia
No debería llegar a entregarse.

## Cómo probarlo
N/A

## Cambios requeridos
Ninguno.
FIN
  ts_err=$(env "${ts_env[@]}" bash "$HERE/task-submit.sh" --mensaje "feat(DEVKIT-9301): no debería pasar" 2>&1 >/dev/null)
  ts_rc=$?
  check "task-submit (verificación falla): sale con 1" 1 "$ts_rc"
  check "task-submit (verificación falla): el error nombra el script roto" 2 \
    "$(printf '%s' "$ts_err" | grep -c 'roto.sh')"
  check "task-submit (verificación falla): no comitea lo pendiente" 1 \
    "$(git -C "$ts_dir/ws" status --porcelain | grep -c roto.sh)"
  check "task-submit (verificación falla): no toca la card" 1 \
    "$([ -e "$ts_dir/set-llamadas" ] && echo 0 || echo 1)"
  check "task-submit (verificación falla): conserva .devkit/pr-body.md" 1 \
    "$([ -e "$ts_dir/ws/.devkit/pr-body.md" ] && echo 1 || echo 0)"

  # Clave explícita que no coincide con la rama actual (H5): rechaza antes de
  # tocar Notion o hacer push, no solo cuando falta en el nombre de la rama.
  rm -f "$ts_dir/ws/roto.sh" "$ts_dir/set-llamadas"
  ts_err=$(env "${ts_env[@]}" bash "$HERE/task-submit.sh" DEVKIT-9999 --mensaje "feat(DEVKIT-9999): no debería pasar" 2>&1 >/dev/null)
  check "task-submit (Clave no coincide con la rama): sale con 1" 1 "$?"
  check "task-submit (Clave no coincide con la rama): lo dice en el error" 1 \
    "$(printf '%s' "$ts_err" | grep -c 'no es una rama de card válida')"
  check "task-submit (Clave no coincide con la rama): no toca la card" 1 \
    "$([ -e "$ts_dir/set-llamadas" ] && echo 0 || echo 1)"

  # Rama main (H5): el script nunca debe entregar directo desde main.
  git -C "$ts_dir/ws" switch -q main
  ts_err=$(env "${ts_env[@]}" bash "$HERE/task-submit.sh" DEVKIT-9301 --mensaje "feat(DEVKIT-9301): no debería pasar" 2>&1 >/dev/null)
  check "task-submit (rama main): sale con 1" 1 "$?"
  check "task-submit (rama main): lo dice en el error" 1 \
    "$(printf '%s' "$ts_err" | grep -c 'no es una rama de card válida')"
  git -C "$ts_dir/ws" switch -q feat/DEVKIT-9301-probar-task-submit

  # Sin .devkit/pr-body.md (H7): falla antes de comitear y subir, no después.
  rm -f "$ts_dir/ws/.devkit/pr-body.md"
  echo "cambio que no debería subirse" >>"$ts_dir/ws/archivo.txt"
  cabeza_previa=$(git -C "$ts_dir/ws" rev-parse HEAD)
  ts_err=$(env "${ts_env[@]}" bash "$HERE/task-submit.sh" --mensaje "feat(DEVKIT-9301): no debería pasar" 2>&1 >/dev/null)
  check "task-submit (sin pr-body.md): sale con 1" 1 "$?"
  check "task-submit (sin pr-body.md): lo dice en el error" 1 \
    "$(printf '%s' "$ts_err" | grep -c 'falta .*pr-body.md')"
  check "task-submit (sin pr-body.md): no comitea" "$cabeza_previa" \
    "$(git -C "$ts_dir/ws" rev-parse HEAD)"
  rm -rf "$ts_dir"

  # --- hook-post-edit.sh (DEVKIT-91) -----------------------------------------
  local hpe_dir
  hpe_dir=$(mktemp -d)
  printf 'def f():\n    return undefined_name\n' >"$hpe_dir/malo.py"
  check "hook-post-edit: .py con aviso que ruff no puede arreglar solo" 1 \
    "$(jq -nc --arg f "$hpe_dir/malo.py" '{tool_input:{file_path:$f}}' \
       | bash "$HERE/hook-post-edit.sh" | grep -c 'F821')"
  printf '#!/usr/bin/env bash\necho hola\n' >"$hpe_dir/bueno.sh"
  check "hook-post-edit: .sh válido no dice nada" "" \
    "$(jq -nc --arg f "$hpe_dir/bueno.sh" '{tool_input:{file_path:$f}}' | bash "$HERE/hook-post-edit.sh")"
  printf 'if [ true ]; then echo hola\n' >"$hpe_dir/malo.sh"
  check "hook-post-edit: .sh con error de sintaxis lo devuelve" 1 \
    "$(jq -nc --arg f "$hpe_dir/malo.sh" '{tool_input:{file_path:$f}}' \
       | bash "$HERE/hook-post-edit.sh" | grep -c 'syntax error')"
  printf 'hola\n' >"$hpe_dir/nota.md"
  check "hook-post-edit: cualquier otra extensión, nada" "" \
    "$(jq -nc --arg f "$hpe_dir/nota.md" '{tool_input:{file_path:$f}}' | bash "$HERE/hook-post-edit.sh")"
  check "hook-post-edit: nunca sale distinto de 0 (informa, no bloquea)" 0 \
    "$(jq -nc --arg f "$hpe_dir/malo.sh" '{tool_input:{file_path:$f}}' | bash "$HERE/hook-post-edit.sh" >/dev/null; echo $?)"
  rm -rf "$hpe_dir"

  # --- hook-stop.sh (DEVKIT-91) -----------------------------------------------
  local hs_dir
  hs_dir=$(mktemp -d)
  git init -q --bare "$hs_dir/origin.git"
  git init -q "$hs_dir/ws"
  git -C "$hs_dir/ws" config user.email test@example.com
  git -C "$hs_dir/ws" config user.name test
  git -C "$hs_dir/ws" remote add origin "$hs_dir/origin.git"
  git -C "$hs_dir/ws" commit -q --allow-empty -m init --no-gpg-sign
  git -C "$hs_dir/ws" branch -q -m main
  git -C "$hs_dir/ws" push -q -u origin main
  git -C "$hs_dir/ws" switch -q -c feat/DEVKIT-9302-probar-hook-stop
  mkdir -p "$hs_dir/run"

  check "hook-stop: fuera de task-start/task-fix, no hace nada" "" \
    "$(echo '{}' | DEVKIT_SKILL=pr-review DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run" bash "$HERE/hook-stop.sh")"
  # DEVKIT_STOP_ID fija el mismo id de contador en las tres llamadas: cada una
  # corre en su propio subshell de pipeline (un $PPID distinto), y el conteo
  # de "misma sesión" que se prueba aquí depende de compartirlo.
  check "hook-stop: rama sin push, bloquea con la instrucción concreta" true \
    "$(echo '{}' | DEVKIT_SKILL=task-start DEVKIT_STOP_ID=9302 DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run" bash "$HERE/hook-stop.sh" \
       | jq -r '.decision == "block" and (.reason | contains("task-submit.sh"))')"
  check "hook-stop: segundo bloqueo seguido, todavía bloquea" 'block' \
    "$(echo '{}' | DEVKIT_SKILL=task-start DEVKIT_STOP_ID=9302 DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run" bash "$HERE/hook-stop.sh" | jq -r .decision)"
  check "hook-stop: tercer intento, ya no bloquea (tope de dos por sesión)" "" \
    "$(echo '{}' | DEVKIT_SKILL=task-start DEVKIT_STOP_ID=9302 DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run" bash "$HERE/hook-stop.sh")"

  git -C "$hs_dir/ws" push -q -u origin feat/DEVKIT-9302-probar-hook-stop
  cat >"$hs_dir/notion-en-progreso" <<'FIN'
#!/usr/bin/env bash
[ "$1" = card ] && printf '{"id":"card-1","estado":"En progreso","pr":""}'
FIN
  chmod +x "$hs_dir/notion-en-progreso"
  mkdir -p "$hs_dir/run2"
  check "hook-stop: rama subida pero card En progreso sin PR, bloquea" 'block' \
    "$(echo '{}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run2" \
       DEVKIT_NOTION_BIN="$hs_dir/notion-en-progreso" bash "$HERE/hook-stop.sh" | jq -r .decision)"

  cat >"$hs_dir/notion-con-pr" <<'FIN'
#!/usr/bin/env bash
[ "$1" = card ] && printf '{"id":"card-1","estado":"En progreso","pr":"https://github.com/o/r/pull/1"}'
FIN
  chmod +x "$hs_dir/notion-con-pr"
  mkdir -p "$hs_dir/run3"
  check "hook-stop: rama subida y card con PR, no bloquea" "" \
    "$(echo '{}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run3" \
       DEVKIT_NOTION_BIN="$hs_dir/notion-con-pr" bash "$HERE/hook-stop.sh")"

  echo "cambio sin commitear" >>"$hs_dir/ws/algo.txt"
  mkdir -p "$hs_dir/run4"
  check "hook-stop: en task-fix, la instrucción es comitear y pushear (no task-submit.sh)" true \
    "$(echo '{}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run4" bash "$HERE/hook-stop.sh" \
       | jq -r '(.reason | contains("git push origin")) and ((.reason | contains("task-submit.sh")) | not)')"
  rm -f "$hs_dir/ws/algo.txt"

  git -C "$hs_dir/ws" commit -q --allow-empty -m "commit local sin subir" --no-gpg-sign
  mkdir -p "$hs_dir/run5"
  check "hook-stop: commit local sin subir a origin, bloquea nombrando el motivo" true \
    "$(echo '{}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run5" bash "$HERE/hook-stop.sh" \
       | jq -r '.decision == "block" and (.reason | contains("commits sin subir"))')"

  # H8: session_id del JSON arma la clave del contador en vez de $PPID, que
  # cambia en cada llamada porque cada una corre en su propio subshell de
  # pipeline (mismo problema que si el hook corriera vía `sh -c` sin `exec`).
  # Sin DEVKIT_STOP_ID de por medio, solo compartir "sess-abc" debe bastar
  # para que el tope de dos por sesión se cumpla.
  mkdir -p "$hs_dir/run6"
  check "hook-stop: session_id arma el contador (primera llamada, \$PPID distinto)" 1 \
    "$(echo '{"session_id":"sess-abc"}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run6" bash "$HERE/hook-stop.sh" >/dev/null
       cat "$hs_dir/run6/stop-sess-abc" 2>/dev/null)"
  check "hook-stop: segunda llamada en otro \$PPID, mismo session_id, sigue el contador" 2 \
    "$(echo '{"session_id":"sess-abc"}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run6" bash "$HERE/hook-stop.sh" >/dev/null
       cat "$hs_dir/run6/stop-sess-abc" 2>/dev/null)"
  check "hook-stop: tercera llamada con el mismo session_id, tope alcanzado, ya no bloquea" "" \
    "$(echo '{"session_id":"sess-abc"}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run6" bash "$HERE/hook-stop.sh")"

  # H8: `stop_hook_active` en true evita reiniciar la cuenta desde cero
  # cuando el contador de esta clave todavía no existe.
  mkdir -p "$hs_dir/run7"
  check "hook-stop: stop_hook_active=true sin contador previo, cuenta como segundo bloqueo" 2 \
    "$(echo '{"session_id":"sess-def","stop_hook_active":true}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run7" bash "$HERE/hook-stop.sh" >/dev/null
       cat "$hs_dir/run7/stop-sess-def" 2>/dev/null)"
  check "hook-stop: con stop_hook_active=true, la siguiente llamada ya no bloquea (tope de dos)" "" \
    "$(echo '{"session_id":"sess-def"}' | DEVKIT_SKILL=task-fix DEVKIT_WS="$hs_dir/ws" DEVKIT_RUN_DIR="$hs_dir/run7" bash "$HERE/hook-stop.sh")"
  rm -rf "$hs_dir"

  return $fail
}

case "${1:-}" in
  --rol)
    model_effort_of "${2:-}"
    exit 0
    ;;
  --sync)
    # Un `watch.sh` anterior a DEVKIT-55, todavía vivo tras el merge hasta el
    # próximo `devkit recreate`, sigue pidiendo "/task-close <Clave> <URL>" y
    # "/task-block <Clave> <motivo>" como skills. Esas skills ya no existen:
    # se atienden con los scripts bash, para que el cambio de versión no deje
    # cards sin cerrar ni un `claude -p` improvisando un paso que no conoce.
    case "${2:-}" in
      /task-close\ *|/task-block\ *)
        read -r sync_skill sync_clave sync_resto <<<"${2#/}"
        if [ "$sync_skill" = task-block ]; then
          "$TASK_BLOCK_BIN" "$sync_clave" "$sync_resto"
        else
          # shellcheck disable=SC2086  # la URL del PR es una sola palabra
          "$TASK_CLOSE_BIN" "$sync_clave" $sync_resto
        fi
        exit $?
        ;;
    esac
    read -r modelo esfuerzo _ _ < <(model_effort_of "${2:-}" "${DEVKIT_RONDA:-}")
    [ -z "${DEVKIT_MODELO_FORZADO:-}" ] || modelo=$DEVKIT_MODELO_FORZADO
    modelo_valido "${modelo:-}" "${2:-}" || exit 65
    run_claude "${2:-}" "$modelo" "$esfuerzo"
    exit $?
    ;;
  --resumen)
    resumen "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    exit 0
    ;;
  --guardar-transcripcion)
    # --guardar-transcripcion <logf> <destino>: lo llama watch.sh tras su
    # propio `--sync` (DEVKIT-102, H2), que redirige la salida de `claude -p`
    # a un log que solo watch.sh conoce; `--worker` (más abajo) llama a
    # `guardar_transcripcion` directo, porque ya tiene `$logf` a mano.
    guardar_transcripcion "${2:-}" "${3:-}"
    exit 0
    ;;
  --worker)
    # --worker <prompt> <log> <modelo> <esfuerzo> <presupuesto> [manual] [ronda]: ya
    # corre dentro de un proceso desacoplado (nohup); toma el mismo candado
    # que `run_skill` antes de tocar /workspace, ejecuta y al terminar deja
    # el resumen en watch.log, igual que el bucle. `manual` (cualquier valor
    # no vacío) marca que `--modelo`/`--esfuerzo` anularon el rol resuelto.
    # Las alarmas de skill lenta, error y pregunta abierta son las mismas de
    # `run_skill` en watch.sh (DEVKIT-46/DEVKIT-50): un lanzamiento manual o
    # desde task-close/epic-plan no corre por el bucle, así que las repite
    # aquí en vez de perderlas.
    cd "$WS" 2>/dev/null || exit 1
    mkdir -p "$RUN_DIR"
    prompt=${2:-} logf=${3:-} modelo=${4:-} esfuerzo=${5:-} presupuesto=${6:-} manual=${7:-} ronda=${8:--}
    modelo_valido "$modelo" "$prompt" || exit 65
    exec 9>"$LOCK"
    if ! flock -n 9; then
      printf '%s devkit-run "%s" espera: otra skill ocupa el workspace\n' "$(date +%FT%T%:z)" "$prompt" >> "$WATCH_LOG"
      flock 9
    fi
    # task-begin.sh (DEVKIT-90, H1+H2 del informe sobre el PR #64): corre acá,
    # ya con el candado tomado, para que `--otros-agentes` no confunda a un
    # task-start que solo esperaba este mismo candado con un conflicto real.
    # `prompt` sigue corto en el resto de esta función -logs, alarmas,
    # `task_start_sin_entregar`, `forzar_task_block`-; solo `prompt_pleno`,
    # con el volcado de la card bajo `## Card`, llega a `run_claude`.
    prompt_pleno="$prompt"
    if [ "$(printf '%s' "$prompt" | sed -nE 's#^/([a-zA-Z-]+).*#\1#p')" = task-start ]; then
      clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
      begin_err=$(mktemp)
      card_md=$("$TASK_BEGIN_BIN" "$clave" 2>"$begin_err")
      begin_rc=$?
      begin_motivo=$(tail -1 "$begin_err" 2>/dev/null)
      rm -f "$begin_err"
      if [ "$begin_rc" -ne 0 ]; then
        task_begin_fallo "$prompt" "$clave" "$begin_motivo"
        # Misma forma que el cierre normal de más abajo ("terminado [<id>]:"),
        # para que `confirmar_arranque` en el lanzador -que ya imprimió
        # "lanzado" y espera este worker- lo lea como un cierre limpio y no
        # como un worker que murió sin terminar (una ALARMA de más sobre un
        # "no lanza" que task_begin_fallo ya registró).
        linea_fin=$(printf '%s devkit-run "%s" %s [%s]: %s' "$(date +%FT%T%:z)" "$(prompt_en_linea "$prompt")" terminado \
          "$(basename "$logf" .log)" "no lanzó: ${begin_motivo:-task-begin.sh no dejó lista la card}")
        printf '%s\n' "$linea_fin" >> "$WATCH_LOG"
        costos_log "$linea_fin"
        # H8 del informe sobre el PR #64 (esta card): sin este archivo, el
        # `while [ -e "$RUN_DIR/$skill-$n.log" ]` del lanzador no ve ocupado
        # este número y el siguiente task-start real lo reutiliza, con lo que
        # `--costos` empareja su cierre con esta "lanzando" huérfana y duplica
        # el costo.
        printf '%s\n' "${begin_motivo:-task-begin.sh no dejó lista la card}" > "$logf" 2>/dev/null
        flock -u 9
        exec 9>&-
        exit 71
      fi
      prompt_pleno="$prompt

## Card
$card_md"
    fi
    # El candado queda tomado durante todo el `claude -p`: task-block.sh lo
    # sabe por DEVKIT_LOCK_HELD y guarda el wip sin volver a pedirlo.
    DEVKIT_LOCK_HELD=1 run_claude "$prompt_pleno" "$modelo" "$esfuerzo" >"$logf" 2>&1 &
    skill_pid=$!
    watch_long_running "$prompt" "$skill_pid" &
    watcher_pid=$!
    wait "$skill_pid"
    rc=$?
    kill "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
    flock -u 9
    exec 9>&-
    # rc=3 (DEVKIT-93, "nada que revisar") corta antes de cualquier `claude
    # -p` real: no hay session_id que buscar. Cubre task-start, task-close,
    # epic-plan y `devkit-run <skill> <Clave>` manual (DEVKIT-102, H2): antes
    # solo watch.sh dejaba transcripción.
    [ "$rc" -eq 3 ] || guardar_transcripcion "$logf" "$RUN_DIR/$(basename "$logf" .log)-transcript.jsonl"
    estado=terminado
    if [ "$rc" -eq 3 ]; then
      # DEVKIT-93: review-prep.sh dijo que no había nada que revisar; el
      # log trae su motivo en texto plano, no JSON. Con el prefijo "no
      # lanzó: ", `confirmar_arranque` lo reconoce igual que el corte de
      # task-begin.sh y no lo trata como un worker muerto.
      resumen_txt="no lanzó: $(tr '\n' ' ' < "$logf" 2>/dev/null | sed -E 's/[[:space:]]+$//')"
    else
      [ $rc -eq 0 ] || estado="falló (rc=$rc)"
      resumen_txt="$(resumen "$logf" "$modelo" "$esfuerzo" "$presupuesto" "$ronda")"
    fi
    [ -z "$manual" ] || resumen_txt="$resumen_txt (anulación manual)"
    # `[<id>]` une el resumen con su línea "lanzando" para `--estado`: dos
    # lanzamientos del mismo prompt solo se distinguen por el log.
    linea_fin=$(printf '%s devkit-run "%s" %s [%s]: %s' "$(date +%FT%T%:z)" "$(prompt_en_linea "$prompt")" "$estado" \
      "$(basename "$logf" .log)" "$resumen_txt")
    printf '%s\n' "$linea_fin" >> "$WATCH_LOG"
    costos_log "$linea_fin"
    turnos_reales=$(tail -1 "$logf" 2>/dev/null | jq -r '.num_turns // empty' 2>/dev/null)
    if [ -n "$presupuesto" ] && [ "$presupuesto" != - ] && [ -n "$turnos_reales" ] \
       && [ "$turnos_reales" -gt "$presupuesto" ] 2>/dev/null; then
      # DEVKIT-105: presupuesto excedido nunca bloquea la card, es una meta
      # de optimización, no un límite (ver el comentario sobre
      # `avisar_presupuesto_excedido`, arriba).
      avisar_presupuesto_excedido "$prompt" "$logf" "$presupuesto" "$turnos_reales"
    fi
    if [ $rc -eq 0 ]; then
      resultado=$(tail -1 "$logf" 2>/dev/null | jq -r '.result // ""' 2>/dev/null)
      if pregunta_abierta "$resultado"; then
        forzar_task_block "$prompt" "$logf" \
          "terminó con una pregunta abierta en vez de un estado observable (barrera mecánica de DEVKIT-50 sobre DEVKIT-44)" \
          "ALARMA: terminó con una pregunta abierta en vez de un estado observable"
      elif notion_denegado "$logf"; then
        # La sonda de arriba vio Notion conectado, pero la CLI negó una
        # herramienta de Notion (DEVKIT-65): mismo remedio que la pregunta
        # abierta, la card queda sin resolver y necesita al humano. H11: con
        # su propio motivo, para que el humano no busque una pregunta que no
        # existe.
        forzar_task_block "$prompt" "$logf" \
          "terminó sin acceso a Notion pese a que \`claude mcp list\` la vio conectada (DEVKIT-65)" \
          "ALARMA: terminó sin acceso a Notion (permission_denials)"
      elif result_sin_notion "$logf"; then
        # H13 de pr-review: el texto solo avisa; el humano mira el resultado.
        printf '%s devkit-run "%s" ALARMA: el resultado describe falta de acceso a Notion (ver resultado)\n' \
          "$(date +%FT%T%:z)" "$prompt" >> "$WATCH_LOG"
      fi
      # Respaldo de DEVKIT-77: ninguna barrera de arriba se disparó, pero eso
      # no prueba que `task-start` haya entregado. DEVKIT-63 dejó una rama
      # vacía, sin comentar el plan y sin PR, con la card `En progreso` y sin
      # bloquear -un corte silencioso que el humano descubrió por `--estado`
      # mostrando "terminó". Solo aplica a `task-start`: `task-fix`,
      # `task-submit` y `task-document` actúan sobre una card que ya tiene PR
      # o no le cambian el Estado.
      clave=$(printf '%s' "$prompt" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
      if task_start_sin_entregar "$prompt" "$clave"; then
        printf '%s devkit-run "%s" ALARMA: terminó sin entregar ni bloquear (%s): card sigue En progreso, sin PR ni bloqueo\n' \
          "$(date +%FT%T%:z)" "$prompt" "$clave" >> "$WATCH_LOG"
      fi
    elif [ "$rc" -eq 3 ]; then
      : # DEVKIT-93: nada que revisar; no es un error, sin ALARMA.
    elif [ "$rc" -ne 67 ]; then
      # rc=67 (sin Notion conectada) ya dejó su propia alarma en
      # `alarma_sin_notion`, dentro de `run_claude`; repetirla aquí es una
      # segunda alarma por el mismo evento (H5 de pr-review, DEVKIT-65).
      printf '%s devkit-run "%s" ALARMA: terminó con error (rc=%s): %s; ver %s\n' \
        "$(date +%FT%T%:z)" "$prompt" "$rc" "$resumen_txt" "$logf" >> "$WATCH_LOG"
    fi
    # Poke (DEVKIT-108): `--worker` es el camino de cualquier lanzamiento
    # humano (task-start.sh, task-close.sh, epic-plan y un `devkit-run
    # <skill> <Clave>` manual), aparte de `--sync`, que es solo del bucle. Sin
    # esto, un pr-review o task-fix que corre el humano a mano dejaba a
    # watch.sh esperando el resto de INTERVAL antes de notar que ya terminó.
    touch "$RUN_DIR/poke" 2>/dev/null || true
    exit $rc
    ;;
  --otros-agentes)
    otros_agentes
    exit $?
    ;;
  --pregunta-abierta)
    # DEVKIT-77 H1: `watch.sh` lanza pr-review/task-fix/task-document con
    # `--sync`, un camino que no pasaba por `pregunta_abierta` (solo lo hacía
    # `--worker`) y se había quedado con el `grep` viejo de DEVKIT-50.
    # Subcomando puro, igual que `--resumen`/`--rol`, para que las dos
    # llamadas usen la misma regla.
    pregunta_abierta "${2:-}"
    exit $?
    ;;
  --presupuesto-corte)
    # --presupuesto-corte <prompt> <logf> <presupuesto> <turnos> [clave]:
    # DEVKIT-94, H1 del informe sobre el PR #68. `watch.sh` lanza pr-review,
    # task-fix y task-document con `--sync`, un camino aparte de `--worker`,
    # así que este subcomando le da el mismo aviso; se queda con el nombre
    # histórico aunque, desde DEVKIT-105, ya no corta nada -avisa, mismo
    # `avisar_presupuesto_excedido` que usa `--worker`, para no duplicar la
    # regla. `clave` viaja aparte porque `/pr-review <N>` no la trae en el
    # prompt.
    if [ -n "${4:-}" ] && [ "${4:-}" != - ] && [ -n "${5:-}" ] \
       && [ "${5:-}" -gt "${4:-}" ] 2>/dev/null; then
      avisar_presupuesto_excedido "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    fi
    exit 0
    ;;
  --estado)
    # --todo (DEVKIT-97) desactiva el recorte de la tabla al alto de la
    # terminal, en cualquier posición junto a --seguir.
    case " ${2:-} ${3:-} " in *" --todo "*) export DEVKIT_ESTADO_TODO=1 ;; esac
    if [ "${2:-}" = --seguir ] || [ "${3:-}" = --seguir ]; then seguir_estado; fi
    # COLUMNS/LINES de verdad, tomados con tty real (DEVKIT-97 H1): mismo
    # motivo que en seguir_estado, para que un `--estado` interactivo (sin
    # `--seguir`) también recorte al tamaño real en vez del respaldo ancho.
    if [ -t 1 ]; then export COLUMNS=$(tput cols 2>/dev/null) LINES=$(tput lines 2>/dev/null); fi
    # Una sola foto (DEVKIT-106): girador y punto fijos (fijo=1), color solo
    # con tty real -acá `[ -t 1 ]` sí ve la tty de verdad, a diferencia de
    # dentro de un `$(...)` (ver seguir_estado/senal_bucle).
    estado_color=''; [ -t 1 ] && estado_color=1
    # Misma cabecera que --seguir, con el punto fijo (DEVKIT-106 H4): sin
    # esto, la foto única no mostraba el punto que pide la card, solo la
    # tabla. <estado_filas_una> se reutiliza en `mostrar_estado` (DEVKIT-106
    # H5) para no leer watch.log/ps dos veces en esta misma foto.
    estado_ahora_una=${DEVKIT_AHORA:-$(date +%s)}
    estado_filas_una=$(estado_filas "$WATCH_LOG" "$estado_ahora_una")
    estado_bucle_una=$(senal_bucle "$WATCH_LOG" "$estado_ahora_una" "$estado_color")
    estado_utf_una=0; utf8_disponible && estado_utf_una=1
    printf 'devkit-run --estado  %s %s\n%s\n\n' "$(date +%T)" \
      "$(punto_estado "$estado_filas_una" "$estado_bucle_una" 0 1 "$estado_utf_una" "$estado_color")" \
      "$estado_bucle_una"
    mostrar_estado 1 0 1 "$estado_color" "$estado_filas_una" "$estado_bucle_una"
    exit 0
    ;;
  --tablero)
    if [ "${2:-}" = --seguir ]; then seguir_tablero; fi
    tablero_color=''; [ -t 1 ] && tablero_color=1
    mostrar_tablero 0 1 "$tablero_color"
    exit $?
    ;;
  --cola)
    # DEVKIT-119: la misma cola que decide "la siguiente card", en formato de
    # lista para que el humano la vea sin abrir Notion.
    "$COLA_BIN" --lista
    exit $?
    ;;
  --agentes)
    # Para el segmento `agentes:<a>` del prompt: `agentes_en_curso_rapido`,
    # no `estado_filas` (ver el comentario junto a su definición). Tampoco
    # toca la red: solo lee watch.log y `ps`.
    agentes_en_curso_rapido "$WATCH_LOG" "${DEVKIT_AHORA:-$(date +%s)}"
    exit 0
    ;;
  --siguiente-modelo)
    siguiente_modelo "${2:-}"
    exit $?
    ;;
  --costos)
    # CLAVE_DE_PR_CACHE vive solo esta corrida (H3 de pr-review en
    # DEVKIT-89): sin ella, `clave_de_pr` llama a `gh pr view` una vez por
    # línea de pr-review/task-close, aunque compartan PR. `poblar_cache_pr`
    # la llena con una sola llamada a `gh pr list` antes de leer el log
    # (segunda vuelta de H3): así ni PRs distintos vuelven a tocar la red.
    CLAVE_DE_PR_CACHE=$(mktemp)
    poblar_cache_pr "$CLAVE_DE_PR_CACHE"
    mostrar_costos "${2:-}"
    rc=$?
    rm -f "$CLAVE_DE_PR_CACHE"
    exit $rc
    ;;
  --costos-totales)
    # Para task-close.sh (DEVKIT-89): "turnos costo minutos revisiones" de la
    # card, sin tabla, misma función que la fila TOTAL de `--costos <Clave>`.
    [ -n "${2:-}" ] || exit 64
    CLAVE_DE_PR_CACHE=$(mktemp)
    poblar_cache_pr "$CLAVE_DE_PR_CACHE"
    costos_totales_card "$2"
    rc=$?
    rm -f "$CLAVE_DE_PR_CACHE"
    exit $rc
    ;;
  --test)
    run_tests
    exit $?
    ;;
esac

# Anulación manual del rol para este lanzamiento (no toca roles.toml): un
# humano sube o baja modelo/esfuerzo puntualmente, por ejemplo para forzar el
# modelo fuerte en una card que se ve difícil. Van antes de <skill> <Clave>
# porque son opcionales y `shift 2` de más abajo asume esa posición fija.

# Sin esto, --modelo o --esfuerzo como último argumento cuelgan el proceso:
# `shift 2` falla por falta de argumentos, el error se traga y el bucle no
# avanza (DEVKIT-50, hallazgo H3 de pr-review).
falta_valor() {  # falta_valor <valor>
  case "${1-}" in
    ''|-*) return 0 ;;
    *) return 1 ;;
  esac
}

uso() {
  echo "uso: devkit-run [--modelo <alias>] [--esfuerzo <low|medium|high|xhigh|max>] [--forzar] [--seguir] <skill> <Clave> [texto extra...]" >&2
  echo "     devkit-run --estado [--seguir] [--todo] | --tablero [--seguir] | --cola | --costos [<Clave>] | --test" >&2
}

modelo_manual="" esfuerzo_manual="" forzar="" seguir_tras_lanzar=""
while true; do
  case "${1:-}" in
    --modelo)
      if falta_valor "${2:-}"; then uso; exit 64; fi
      modelo_manual="$2"; shift 2 ;;
    --esfuerzo)
      if falta_valor "${2:-}"; then uso; exit 64; fi
      esfuerzo_manual="$2"; shift 2 ;;
    --forzar)
      forzar=1; shift ;;
    --seguir)
      seguir_tras_lanzar=1; shift ;;
    *) break ;;
  esac
done

skill="${1:-}"
clave="${2:-}"
if [ -z "$skill" ] || [ -z "$clave" ]; then
  uso
  exit 64
fi
shift 2 2>/dev/null

# task-close y task-block dejaron de ser skills en DEVKIT-55: son bash contra
# la API de Notion, corren en primer plano en segundos y no resuelven modelo.
# `devkit-run task-close <Clave> [URL]` y `devkit-run task-block <Clave>
# <motivo>` siguen valiendo, para no cambiar la costumbre del humano.
case "$skill" in
  task-close|task-block)
    if [ "$skill" = task-block ]; then exec "$TASK_BLOCK_BIN" "$clave" "$@"; fi
    exec "$TASK_CLOSE_BIN" "$clave" "$@"
    ;;
esac

prompt="/$skill $clave"
[ $# -eq 0 ] || prompt="$prompt $*"

# DEVKIT-79: ¿ya hay un worker o un `claude -p` de este mismo prompt vivo o
# esperando el candado? El relanzamiento manual sobre un falso "no arrancó"
# (ver el comentario junto a PS_BIN) puso dos agentes a trabajar la misma
# card sin que nadie lo supiera hasta revisar `ps` a mano. `--forzar` salta
# esta comprobación, por ejemplo tras matar a mano el proceso viejo.
if [ -z "$forzar" ]; then
  if dup_pid=$("$PS_BIN" -eo pid=,args= -ww 2>/dev/null | lanzamiento_duplicado "$prompt"); then
    dup_log=$(grep -F ": \"$(prompt_en_linea "$prompt")\" log=" "$WATCH_LOG" 2>/dev/null \
      | tail -1 | grep -oE 'log=.*$' | sed 's/^log=//')
    echo "devkit-run: ya hay un lanzamiento de \"$prompt\" en curso (pid $dup_pid, log ${dup_log:-desconocido}); síguelo con \`devkit-run --estado\` (o usa --forzar para lanzarlo igual)." >&2
    exit 68
  fi
fi

# Antes de resolver el modelo: la sonda de frontera también necesita el
# token que el arranque todavía no terminó de cargar.
esperar_arranque "$prompt" || exit 69
avisar_atras_de_origin "$prompt"
mkdir -p "$RUN_DIR"

# task-begin.sh (DEVKIT-90): los pasos mecánicos de task-start (workspace,
# rama, Notion) corren dentro de `--worker`, ya con el candado tomado (H1 del
# informe sobre el PR #64 de esta misma card). Antes corrían aquí, en el
# lanzador, sin candado: `devkit-run --otros-agentes` (que task-begin.sh
# consulta) veía el `claude -p` de cualquier skill viva -aunque solo fuera
# otro task-start esperando este mismo candado- y bloqueaba una card `Lista`
# válida. Con el candado ya tomado, un `claude -p` ajeno es un conflicto de
# verdad. El lanzador ya no sabe si task-begin.sh va a dejar la card lista;
# si falla, el worker lo registra en watch.log (H2) sin haber llegado a
# `claude -p`.
n=1
while [ -e "$RUN_DIR/$skill-$n.log" ]; do n=$((n + 1)); done
logf="$RUN_DIR/$skill-$n.log"
read -r modelo esfuerzo presupuesto ronda < <(model_effort_of "$prompt")
manual=""
if [ -n "$modelo_manual" ]; then modelo="$modelo_manual"; manual=1; fi
if [ -n "$esfuerzo_manual" ]; then esfuerzo="$esfuerzo_manual"; manual=1; fi
modelo_valido "${modelo:-}" "$prompt" || exit 65
# Con anulación manual no hay presupuesto de roles.toml que comparar con el
# turno real: el rol resuelto ya no aplica.
[ -z "$manual" ] || presupuesto="-"

# Sin DEVKIT_LANZADOR: la pone `watch.sh` solo a lo que lanza su bucle, y un
# `claude -p` lanzado por el bucle que a su vez llama a devkit-run no debe
# heredarla. Un task-fix lanzado así es manual y marca `manual=1` (DEVKIT-56).
#
# La línea "lanzando" va antes del `nohup`: desde ella el lanzamiento cuenta
# para `--estado`, aunque su `claude -p` todavía no exista (DEVKIT-57).
linea_inicio=$(linea_lanzando "$(basename "$logf" .log)" "$(origen_lanzamiento)" "$prompt" "$logf" "$modelo" "$esfuerzo" "$ronda")
printf '%s\n' "$linea_inicio" >> "$WATCH_LOG" 2>/dev/null
costos_log "$linea_inicio"
"$SETSID_BIN" nohup env -u DEVKIT_LANZADOR -u DEVKIT_ORIGEN -u DEVKIT_MODELO_FORZADO -u DEVKIT_RONDA \
  "$HERE/devkit-run.sh" --worker "$prompt" "$logf" "$modelo" "$esfuerzo" "$presupuesto" "$manual" "$ronda" \
  >/dev/null 2>&1 &
worker=$!
disown
echo "lanzado: $prompt"
echo "modelo=$modelo esfuerzo=$esfuerzo ronda=$ronda log=$logf pid=$worker"
confirmar_arranque "$worker" "$prompt" "$logf"
rc_confirmar=$?
# 2 = task-begin.sh cortó antes de claude -p: el motivo ya salió por stderr
# (H8 del informe sobre el PR #64) y el lanzador sale con el mismo código
# que usó el worker, en vez del 70 genérico de "no arrancó".
[ "$rc_confirmar" -ne 2 ] || exit 71
[ "$rc_confirmar" -eq 0 ] || exit 70
if [ -n "$seguir_tras_lanzar" ]; then
  seguir_lanzamiento "$(basename "$logf" .log)" "$worker"
  exit $?
fi

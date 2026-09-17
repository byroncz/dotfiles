#!/bin/sh
# devkit: comandos del día a día, desde el Mac. Lo instala new-project.sh en
# ~/.devkit/bin/devkit. Solo necesita Docker.
#
#   devkit up <proyecto>        levantar (construye la imagen si falta)
#   devkit shell <proyecto>     abrir una shell dentro del contenedor
#   devkit code <proyecto>      abrir el editor VS Code del proyecto en el navegador
#   devkit stop <proyecto>      detener sin perder nada
#   devkit down <proyecto>      destruir el contenedor (el código no committeado se pierde)
#   devkit recreate <proyecto>  recrear los contenedores: relee secretos y devkit.env, y
#                               reconstruye las capas que cambiaron (en modo dev,
#                               con el devkit/ del workspace)
#   devkit rebuild <proyecto>   reconstruir las imágenes desde cero y recrear
#   devkit update <proyecto>    subir a la versión de template que pide .devkit/devkit.toml
#   devkit logs <proyecto>      ver el arranque y los bucles
#   devkit net-open <proyecto>  red abierta en esta sesión (solo depuración)
#   devkit awake <proyecto>     impedir el reposo del Mac mientras el contenedor esté vivo
#                               (caffeinate -i; no evita el reposo al cerrar la tapa)
#   devkit ls                   proyectos instanciados
set -eu
ROOT="${DEVKIT_HOME:-$HOME/.devkit}"
REPO="${DEVKIT_TEMPLATE_REPO:-byroncz/dotfiles}"
cmd="${1:-}"; proj="${2:-}"
usage() { sed -n '2,19p' "$0"; exit 1; }  # el bloque de comentario de la cabecera
[ -n "$cmd" ] || usage
if [ "$cmd" = "ls" ]; then ls -1 "$ROOT" 2>/dev/null | grep -v -e '^bin$' -e '^bws-token$' -e '^cache$'; exit 0; fi
[ -n "$proj" ] || usage
dir="$ROOT/$proj"; [ -d "$dir" ] || { echo "no existe $dir; usa new-project.sh" >&2; exit 1; }
cd "$dir"
# devkit.toml es plano (una tabla [devkit], valores de una línea): se lee con
# expresiones regulares, no con un parser de TOML.
toml_field() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
toml_list() {
  sed -n "s/^$1[[:space:]]*=[[:space:]]*\\[\\(.*\\)\\].*/\\1/p" \
    | tr ',' '\n' | sed -E 's/^[[:space:]"]*//; s/[[:space:]"]*$//' | tr '\n' ' ' | sed 's/ *$//'
}
# `apt` y `domains` de .devkit/devkit.toml alimentan el build y el proxy vía
# compose, que los interpola desde este .env: sin esto, editar devkit.toml no hacía
# nada (DEVKIT-6). Solo si el contenedor ya existe: en el primer `up` el
# proyecto aún no está clonado.
sync_toml_env() {
  toml="$(docker exec "devkit-$proj" cat /workspace/.devkit/devkit.toml 2>/dev/null)" || return 0
  apt="$(printf '%s\n' "$toml" | toml_list apt)"
  domains="$(printf '%s\n' "$toml" | toml_list domains)"
  grep -v -e '^DEVKIT_EXTRA_APT=' -e '^DEVKIT_ALLOW_DOMAINS=' "$dir/.env" > "$dir/.env.tmp" 2>/dev/null || : > "$dir/.env.tmp"
  { cat "$dir/.env.tmp"; printf 'DEVKIT_EXTRA_APT=%s\n' "$apt"; printf 'DEVKIT_ALLOW_DOMAINS=%s\n' "$domains"; } > "$dir/.env"
  rm -f "$dir/.env.tmp"
}
# El contexto de build es $dir/template, una copia del template que solo
# new-project.sh y `devkit update` refrescan. En modo dev el template es el
# `devkit/` del workspace, que vive únicamente dentro del contenedor: no hay
# bind mount desde el Mac, así que `docker cp` es la única vía para llevarlo al
# contexto. Sin esto, un cambio en zsh/, proxy/, vscode/ o el Dockerfile
# se mergeaba y la imagen seguía construyéndose con la copia vieja (DEVKIT-30).
sync_dev_template() {
  [ "$(sed -n 's/^DEVKIT_VERSION=//p' "$dir/.env" | head -1)" = dev ] || return 0
  if ! docker exec "devkit-$proj" test -d /workspace/devkit 2>/dev/null; then
    echo "devkit: aviso: el contenedor no responde; se construye con la copia de $dir/template" >&2
    return 0
  fi
  rm -rf "$dir/template.tmp"; mkdir -p "$dir/template.tmp"
  if docker cp "devkit-$proj:/workspace/devkit/." "$dir/template.tmp" >/dev/null; then
    rm -rf "$dir/template"; mv "$dir/template.tmp" "$dir/template"
    echo "devkit: modo dev: contexto de build actualizado desde el workspace"
    warn_host_stale
  else
    rm -rf "$dir/template.tmp"
    echo "devkit: aviso: no se pudo copiar devkit/ del workspace; se construye con la copia de $dir/template" >&2
  fi
}
# curl_ovx <url> <archivo-salida>: imprime el código HTTP; 000 si no hubo
# forma de conectar. --retry reintenta un 5xx de Open VSX antes de rendirse
# (curl trata un 5xx como error transitorio y lo reintenta aunque no se pida
# -f); un 000 solo ocurre si el propio curl no pudo ni conectar (sin red),
# igual que antes de DEVKIT-73.
curl_ovx() {
  code="$(curl -sS -o "$2" -w '%{http_code}' --retry 5 --retry-delay 3 "$1" 2>/dev/null)" || code=000
  printf '%s' "${code:-000}"
}
# json_field <clave> <archivo>: valor de "<clave>":"<valor>" en un JSON de
# Open VSX (una línea, sin anidar objetos salvo "engines").
json_field() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | head -1 | sed -E 's/.*"([^"]*)"$/\1/'
}
# json_engine_vscode <archivo>: "vscode" dentro del objeto "engines" de la
# respuesta de Open VSX, p. ej. de {"engines":{"node":">=20","vscode":"^1.137.0"}}.
json_engine_vscode() {
  grep -o '"engines"[[:space:]]*:[[:space:]]*{[^}]*}' "$1" | head -1 \
    | grep -o '"vscode"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/'
}
# engine_check <rango-engines.vscode> <versión-editor>: "ok", "no" o
# "desconocido". Open VSX solo usa "^X.Y.Z" (semver de npm: compatible desde
# X.Y.Z hasta antes de (X+1).0.0) y ">=X.Y.Z" para engines.vscode; cualquier
# otro formato se acepta con aviso, no se rechaza (DEVKIT-73).
engine_check() {
  awk -v range="$1" -v ed="$2" '
    function parte(v,   n, a) { n = split(v, a, "."); return (a[1]+0)*1000000 + (a[2]+0)*1000 + (a[3]+0) }
    BEGIN {
      e = parte(ed)
      if (range ~ /^\^[0-9]+\.[0-9]+\.[0-9]+$/) {
        split(substr(range, 2), p, ".")
        print (e >= parte(substr(range, 2)) && e < (p[1] + 1) * 1000000) ? "ok" : "no"
      } else if (range ~ /^>=[0-9]+\.[0-9]+\.[0-9]+$/) {
        print (e >= parte(substr(range, 3))) ? "ok" : "no"
      } else {
        print "desconocido"
      }
    }'
}
# ultima_compatible <ns> <ext> <archivo-de-/latest>: recorre "allVersions" del
# JSON de /latest (solo versiones estables X.Y.Z, ordenadas aquí mismo de la
# más nueva a la más vieja, sin depender del orden en que las entregue Open
# VSX) y consulta cada una hasta encontrar la primera cuyo engines.vscode
# admite $editor. Imprime "versión motor"; sale en 1 si ninguna calza o si
# Open VSX no responde.
ultima_compatible() {
  ns="$1"; ext="$2"; archivo="$3"
  versiones="$(grep -o '"[0-9][0-9.]*"[[:space:]]*:[[:space:]]*"https://open-vsx\.org/api/[^"]*"' "$archivo" \
    | sed -E 's/^"([0-9.]+)".*/\1/' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr)"
  for v in $versiones; do
    resp="$(mktemp)"
    http_code="$(curl_ovx "https://open-vsx.org/api/$ns/$ext/$v" "$resp")"
    motor=""
    [ "$http_code" = 200 ] && motor="$(json_engine_vscode "$resp")"
    rm -f "$resp"
    [ -n "$motor" ] || continue
    [ "$(engine_check "$motor" "$editor")" != no ] && { printf '%s %s\n' "$v" "$motor"; return 0; }
  done
  return 1
}
# devkit/vscode/extensions.toml declara las extensiones del editor: una
# versión fija se instala tal cual, "latest" se resuelve aquí contra Open VSX
# antes de construir. La resolución queda en $dir/extensions.lock (una por
# proyecto) para poder seguir construyendo sin red, y se pasa a compose como
# DEVKIT_EXTENSIONS, igual que DEVKIT_EXTRA_APT. Corre después de
# sync_dev_template (o de bajar la etiqueta destino en `update`), así que
# $dir/template/vscode/extensions.toml ya está al día.
#
# Además, cada extensión (fija o "latest") se comprueba contra engines.vscode
# en Open VSX frente a $editor, la versión de openvscode-server que trae la
# imagen: instalar una que exige un VS Code más nuevo tumbaba el build a
# mitad del Dockerfile, con el error de openvscode-server, no antes
# (DEVKIT-73). Sin red para esa comprobación, una versión fija se instala sin
# verificar, igual que antes de DEVKIT-73.
resolve_extensions() {
  toml="$dir/template/vscode/extensions.toml"
  if [ ! -f "$toml" ]; then
    echo "devkit: aviso: no hay $toml; se construye sin extensiones" >&2
    grep -v '^DEVKIT_EXTENSIONS=' "$dir/.env" > "$dir/.env.tmp" 2>/dev/null || : > "$dir/.env.tmp"
    mv "$dir/.env.tmp" "$dir/.env"
    return 0
  fi
  # $dir/template/Dockerfile es la única fuente de la versión del editor: si
  # se duplicara a mano aquí, subir OPENVSCODE_VERSION en el Dockerfile y
  # olvidar este archivo dejaría el chequeo comparando contra una versión
  # vieja sin avisar (DEVKIT-73).
  editor="$(sed -n 's/^ARG OPENVSCODE_VERSION=\([0-9.]*\).*/\1/p' "$dir/template/Dockerfile" | head -1)"
  [ -n "$editor" ] || { echo "devkit: no se encontró ARG OPENVSCODE_VERSION en $dir/template/Dockerfile" >&2; return 1; }
  lock="$dir/extensions.lock"
  # Una línea no vacía y sin comentario que no calce con "id" = "versión" se
  # ignoraba en silencio y la extensión desaparecía de la imagen sin aviso
  # (H5, DEVKIT-67); gen-stack.sh repite este mismo aviso al generar la lista.
  # El comentario final es opcional: el `sed` de abajo ya lo tolera (H9,
  # DEVKIT-67), así que la validación admite el mismo formato o avisaría de
  # una línea que sí se usa.
  malas="$(grep -vE '^[[:space:]]*(#.*)?$' "$toml" | grep -vE '^"[^"]*"[[:space:]]*=[[:space:]]*"[^"]*"[[:space:]]*(#.*)?$')"
  if [ -n "$malas" ]; then
    echo "devkit: aviso: $toml tiene líneas que no calzan con \"id\" = \"versión\" y se ignoran:" >&2
    printf '%s\n' "$malas" | sed 's/^/  /' >&2
  fi
  declarados="$(sed -n 's/^"\([^"]*\)"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1 \2/p' "$toml")"
  resuelto=""
  while IFS= read -r linea; do
    [ -n "$linea" ] || continue
    id="${linea%% *}"; version="${linea#* }"
    ns="${id%%.*}"; ext="${id#*.}"
    if [ "$version" = latest ]; then
      resp="$(mktemp)"
      http_code="$(curl_ovx "https://open-vsx.org/api/$ns/$ext/latest" "$resp")"
      if [ "$http_code" = 404 ]; then
        rm -f "$resp"
        echo "devkit: extensión $id no existe en Open VSX (404)" >&2
        return 1
      fi
      fetched=""; motor=""
      if [ "$http_code" = 200 ]; then
        fetched="$(json_field version "$resp")"
        motor="$(json_engine_vscode "$resp")"
      fi
      if [ -n "$fetched" ]; then
        estado="$(engine_check "$motor" "$editor")"
        if [ "$estado" = no ]; then
          if alt="$(ultima_compatible "$ns" "$ext" "$resp")"; then
            echo "devkit: aviso: $id $fetched exige VS Code $motor; la imagen lleva $editor; se usa ${alt% *} (VS Code ${alt#* })" >&2
            fetched="${alt% *}"
          else
            rm -f "$resp"
            echo "devkit: $id $fetched exige VS Code $motor; la imagen lleva $editor y no hay ninguna versión publicada que calce" >&2
            return 1
          fi
        elif [ "$estado" = desconocido ]; then
          echo "devkit: aviso: $id declara engines.vscode \"$motor\", un formato que no reconozco; se instala sin verificar" >&2
        fi
        rm -f "$resp"
        version="$fetched"
      else
        rm -f "$resp"
        cached="$(awk -F= -v id="$id" '$1==id{print substr($0, length(id)+2); exit}' "$lock" 2>/dev/null)"
        # 000 es curl sin poder ni conectar (sin red); cualquier otro código
        # (5xx, 429) sí llegó a Open VSX, así que el aviso lo distingue de un
        # Mac sin red (H8, DEVKIT-67).
        if [ "$http_code" = 000 ]; then
          razon_aviso="sin red para Open VSX"; razon_seco="sin red"
        else
          razon_aviso="Open VSX respondió $http_code"; razon_seco="$razon_aviso"
        fi
        if [ -n "$cached" ]; then
          echo "devkit: aviso: $razon_aviso; se usa la última versión resuelta de $id ($cached)" >&2
          version="$cached"
        else
          echo "devkit: $razon_seco y sin resolución previa para $id; construye una vez con red o fija su versión en extensions.toml" >&2
          return 1
        fi
      fi
    else
      resp="$(mktemp)"
      http_code="$(curl_ovx "https://open-vsx.org/api/$ns/$ext/$version" "$resp")"
      if [ "$http_code" = 404 ]; then
        rm -f "$resp"
        echo "devkit: extensión $id $version no existe en Open VSX (404)" >&2
        return 1
      fi
      if [ "$http_code" = 200 ]; then
        motor="$(json_engine_vscode "$resp")"
        rm -f "$resp"
        if [ -n "$motor" ]; then
          estado="$(engine_check "$motor" "$editor")"
          if [ "$estado" = no ]; then
            echo "devkit: $id $version exige VS Code $motor; la imagen lleva $editor" >&2
            resp2="$(mktemp)"
            if lhttp="$(curl_ovx "https://open-vsx.org/api/$ns/$ext/latest" "$resp2")" && [ "$lhttp" = 200 ] \
               && alt="$(ultima_compatible "$ns" "$ext" "$resp2")"; then
              echo "devkit: sugerencia: ${alt% *} sí calza con VS Code $editor" >&2
            fi
            rm -f "$resp2"
            return 1
          elif [ "$estado" = desconocido ]; then
            echo "devkit: aviso: $id declara engines.vscode \"$motor\", un formato que no reconozco; se instala sin verificar" >&2
          fi
        fi
      else
        rm -f "$resp"
        echo "devkit: aviso: no se pudo verificar el motor de $id $version ($http_code); se instala sin comprobar" >&2
      fi
    fi
    resuelto="$resuelto${resuelto:+ }$id=$version"
  done <<EOF_DECLARADOS
$declarados
EOF_DECLARADOS
  printf '%s\n' "$resuelto" | tr ' ' '\n' > "$lock"
  grep -v '^DEVKIT_EXTENSIONS=' "$dir/.env" > "$dir/.env.tmp" 2>/dev/null || : > "$dir/.env.tmp"
  { cat "$dir/.env.tmp"; printf 'DEVKIT_EXTENSIONS=%s\n' "$resuelto"; } > "$dir/.env"
  rm -f "$dir/.env.tmp"
}
# Lo que new-project.sh instaló en el Mac desde el template (el compose.yaml del
# proyecto y el propio comando devkit) no lo refresca nadie. Reemplazarlo aquí
# no es seguro: el script se sobrescribiría a sí mismo mientras corre. Se avisa
# y se deja la decisión al humano.
warn_host_stale() {
  if [ -f "$dir/template/compose.yaml" ] && ! cmp -s "$dir/template/compose.yaml" "$dir/compose.yaml"; then
    echo "devkit: aviso: $dir/compose.yaml difiere del template; reinstala con new-project.sh --ref <rama>" >&2
  fi
  if [ -f "$ROOT/bin/devkit" ] && [ -f "$dir/template/host/devkit.sh" ] \
     && ! cmp -s "$dir/template/host/devkit.sh" "$ROOT/bin/devkit"; then
    echo "devkit: aviso: el comando devkit difiere del template; reinstala con new-project.sh --ref <rama>" >&2
  fi
}
compose() { docker compose --project-directory "$dir" "$@"; }
wait_ready() {
  # El arranque tarda unos segundos (lee secretos, clona). Esperar al marcador
  # evita seguir sin las variables cargadas.
  i=0
  until docker exec "devkit-$proj" test -f /run/devkit/ready 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 120 ] && { echo "el arranque no terminó en 120 s; mira 'devkit logs $proj'" >&2; return 1; }
    [ "$i" -eq 1 ] && printf 'esperando el arranque del contenedor'
    printf '.'; sleep 1
  done
  [ "$i" -gt 0 ] && echo
  return 0
}
shell() { wait_ready && docker exec -it "devkit-$proj" zsh; }
code() {
  wait_ready || return 1
  token="$(docker exec "devkit-$proj" cat /run/devkit/vscode-token 2>/dev/null)"
  [ -n "$token" ] || { echo "sin token de VS Code; crea el secreto vscode-token en Bitwarden y corre 'devkit recreate $proj'" >&2; return 1; }
  port="$(sed -n 's/^DEVKIT_VSCODE_PORT=//p' "$dir/.env" 2>/dev/null | head -1)"; port="${port:-3000}"
  url="http://127.0.0.1:${port}/?tkn=${token}"
  if command -v open >/dev/null 2>&1 && open "$url"; then
    return 0
  fi
  echo "$url"
  return 0
}
# macOS suspende el Mac por inactividad y con él la VM de Docker: los bucles del
# contenedor dejan de correr. `caffeinate -i` sostiene una aserción contra ese
# reposo mientras vive el proceso que envuelve; `docker wait` vive lo mismo que
# el contenedor, así que la aserción se suelta sola cuando el contenedor se
# detiene. No impide el reposo al cerrar la tapa (DEVKIT-66).
awake() {
  command -v caffeinate >/dev/null 2>&1 || { echo "falta caffeinate: 'devkit awake' solo funciona en macOS" >&2; return 1; }
  [ "$(docker inspect -f '{{.State.Running}}' "devkit-$proj" 2>/dev/null)" = true ] \
    || { echo "el contenedor devkit-$proj no está corriendo; arráncalo con 'devkit up $proj'" >&2; return 1; }
  echo "devkit: el Mac no se suspende por inactividad mientras devkit-$proj esté vivo (Ctrl-C para soltar)"
  caffeinate -i docker wait "devkit-$proj" >/dev/null
}
confirm() { printf 'Se destruye el contenedor actual. Lo no committeado fuera de sandbox.local se pierde. Escribe "si": '; read -r ok; [ "$ok" = "si" ]; }
case "$cmd" in
  up)       sync_dev_template; resolve_extensions && compose up -d --build ;;
  shell)    shell ;;
  code)     code ;;
  awake)    awake ;;
  stop)     compose stop ;;
  down)     confirm && compose down ;;
  recreate) confirm && sync_toml_env && sync_dev_template && resolve_extensions && compose up -d --build --force-recreate ;;
  rebuild)  confirm && sync_toml_env && sync_dev_template && resolve_extensions && compose build --no-cache && compose up -d --force-recreate ;;
  update)
    toml="$(docker exec "devkit-$proj" cat /workspace/.devkit/devkit.toml 2>/dev/null)" \
      || { echo "el contenedor no responde; arráncalo con 'devkit up $proj' primero" >&2; exit 1; }
    target="$(printf '%s\n' "$toml" | toml_field template)"
    [ -n "$target" ] || { echo ".devkit/devkit.toml no declara 'template'" >&2; exit 1; }
    current="$(sed -n 's/^DEVKIT_VERSION=//p' "$dir/.env" | head -1)"
    if [ "$target" = "$current" ]; then
      # En modo dev no hay etiqueta que descargar: el template es el workspace y
      # quien lo lleva a la imagen es `recreate`. Decirlo evita creer que este
      # comando ya aplicó lo mergeado (DEVKIT-30).
      if [ "$target" = dev ]; then
        echo "en modo dev el template es el workspace; usa 'devkit recreate $proj' para llevar devkit/ a la imagen"
      else
        echo "ya en $target"
      fi
      exit 0
    fi
    # $dir/compose.yaml es del Mac: solo new-project.sh lo escribe, `update`
    # trae devkit/ pero nunca lo toca. Si quedó de antes de DEVKIT-67, no
    # declara el ARG EXTENSIONS y la imagen se reconstruye sin extensiones,
    # sin aviso (`warn_host_stale` solo corre desde `sync_dev_template`, que
    # `update` no llama). Se detiene en vez de construir un editor incompleto.
    grep -q 'EXTENSIONS:' "$dir/compose.yaml" 2>/dev/null \
      || { echo "devkit: $dir/compose.yaml no declara EXTENSIONS; reinstala con 'new-project.sh $proj --version $target' antes de actualizar" >&2; exit 1; }
    echo "devkit: actualizando template $current -> $target"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://github.com/$REPO/archive/refs/tags/v$target.tar.gz" | tar -xz -C "$tmp"
    src="$(find "$tmp" -maxdepth 2 -type d -name devkit | head -1)"
    [ -d "$src" ] || { echo "el tarball no contiene devkit/" >&2; exit 1; }
    rm -rf "$dir/template"; cp -R "$src" "$dir/template"
    grep -v '^DEVKIT_VERSION=' "$dir/.env" > "$dir/.env.tmp"
    { cat "$dir/.env.tmp"; printf 'DEVKIT_VERSION=%s\n' "$target"; } > "$dir/.env"; rm -f "$dir/.env.tmp"
    resolve_extensions && sync_toml_env && compose up -d --build --force-recreate
    ;;
  logs)     compose logs -f --tail 100 ;;
  net-open) DEVKIT_NET_OPEN=1 compose up -d --force-recreate proxy && echo "red abierta hasta el próximo 'devkit up'" ;;
  *)        usage ;;
esac

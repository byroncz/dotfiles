#!/usr/bin/env bash
# Suma valores a `extensions`, `domains` o `apt` de .devkit/devkit.toml sin
# card, sin revisión de agentes y sin editar a mano (DEVKIT-268): abre el PR
# `<CÓDIGO>-0 declarar <clave>: <valores>` con auto-merge y lo deja listo
# para que el humano lo apruebe.
#
# Uso:
#   declarar.sh <extensions|domains|apt> <valor>...
#   declarar.sh --test
#
# Trabaja en un worktree temporal desde origin/main, nunca en $WS: no toca la
# rama, el índice ni el candado de una card en curso. La Clave `<CÓDIGO>-0`
# la descarta `key_of` de watch.sh (como `chore/ITSC-0-template-1.2.0` de
# template-propagate), así que el bucle no revisa este PR ni intenta cerrar
# una card por él: no hay nada que cambiar en watch.sh.
#
# Códigos de salida: 0 PR abierto, o nada que hacer (todo ya declarado, o ya
# hay un PR -0 abierto de esa clave); 64 uso o valor inválido; 1 fallo de git
# o de gh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${DEVKIT_WS:-/workspace}"
GH="${DEVKIT_GH_BIN:-gh}"
WORKTREE_DIR="${DEVKIT_DECLARAR_WORKTREE_DIR:-/tmp}"
TOML=.devkit/devkit.toml

err() { printf 'declarar: %s\n' "$*" >&2; }

# Mismo `sed` que toml_list de host/devkit.sh: los valores de la línea
# `<clave> = [...]`, separados por espacios.
toml_list() {
  sed -n "s/^$1[[:space:]]*=[[:space:]]*\\[\\(.*\\)\\].*/\\1/p" \
    | tr ',' '\n' | sed -E 's/^[[:space:]"]*//; s/[[:space:]"]*$//' | tr '\n' ' ' | sed 's/ *$//'
}

# valido <clave> <valor>: sale 0 si el valor tiene el formato de la clave.
# Ningún valor puede traer comillas, comas, corchetes ni barras invertidas:
# romperían la línea de una sola línea que lee toml_list.
valido() {
  local clave=$1 valor=$2
  case "$valor" in *[\"\\,\[\]]*) return 1 ;; esac
  case "$clave" in
    # El mismo patrón de resolve_extensions (DEVKIT-181).
    extensions) printf '%s' "$valor" | grep -qE '^[^.@[:space:]]+\.[^@[:space:]]+(@[^@[:space:]]+)?$' ;;
    # Sin esquema, puerto ni barra; `*.` inicial permitido: la lista blanca
    # del proxy es fnmatch (allowlist.base tiene `*.github.com`).
    domains) printf '%s' "$valor" | grep -qE '^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' ;;
    # Nombre de paquete Debian: minúsculas, dígitos y `+ - .`, desde dos
    # caracteres y empezando por letra o dígito.
    apt) printf '%s' "$valor" | grep -qE '^[a-z0-9][a-z0-9+.-]+$' ;;
  esac
}

# identidad <clave> <valor>: lo que identifica al valor para detectar
# duplicados, en minúsculas. En `extensions` es el id, sin `@versión`.
identidad() {
  local v
  v=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
  [ "$1" = extensions ] && v=${v%%@*}
  printf '%s' "$v"
}

ejemplo_de() {
  case "$1" in
    extensions) echo 'ms-python.python o ms-python.python@2024.2.1' ;;
    domains) echo 'pypi.org o *.pythonhosted.org' ;;
    apt) echo 'jq' ;;
  esac
}

# agregar_valores <archivo> <clave> <valores en toml: "a", "b">: reescribe la
# línea `<clave> = [...]` con los valores al final, sin tocar el resto; si la
# clave no existe, la crea tras la última línea de [devkit].
agregar_valores() {
  local archivo=$1 clave=$2 nuevos=$3 tmp ultimo
  tmp=$(mktemp) || return 1
  if grep -qE "^$clave[[:space:]]*=" "$archivo"; then
    awk -v key="$clave" -v add="$nuevos" '
      !hecho && match($0, "^" key "[[:space:]]*=[[:space:]]*\\[") {
        cabeza = substr($0, 1, RLENGTH)
        ultimo = 0
        for (i = length($0); i > RLENGTH; i--) if (substr($0, i, 1) == "]") { ultimo = i; break }
        interior = substr($0, RLENGTH + 1, ultimo - RLENGTH - 1)
        cola = substr($0, ultimo)
        sub(/[ \t]*,?[ \t]*$/, "", interior)
        if (interior ~ /^[ \t]*$/) interior = add; else interior = interior ", " add
        print cabeza interior cola
        hecho = 1
        next
      }
      { print }' "$archivo" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    ultimo=$(awk '
      /^\[/ { en = ($0 ~ /^\[devkit\][[:space:]]*(#.*)?$/); next }
      en && $0 !~ /^[[:space:]]*$/ { n = NR }
      END { print n + 0 }' "$archivo")
    if [ "$ultimo" -eq 0 ]; then
      rm -f "$tmp"
      err "no encuentro la sección [devkit] con contenido en $TOML"
      return 1
    fi
    awk -v n="$ultimo" -v linea="$clave = [$nuevos]" '{ print } NR == n { print linea }' "$archivo" >"$tmp" \
      || { rm -f "$tmp"; return 1; }
  fi
  cat "$tmp" >"$archivo"
  rm -f "$tmp"
}

# `devkit recreate` lee `extensions`, `domains` y `apt` del checkout vivo de
# /workspace (sync_toml_env), no de origin/main, y un PR -0 no actualiza ese
# checkout: con una card en curso, o con main sin traer, el primer recreate
# usa la lista vieja. Ese recreate re-clona main, así que el segundo ya la
# aplica.
NOTA_RECREATE="Ojo: recreate lee el valor del checkout vivo de /workspace, no de origin/main; si /workspace no está en un main al día (una card en curso, por ejemplo), el primer recreate usa la lista vieja y hace falta correrlo una segunda vez, que ya clona main con el valor."

paso_siguiente() {  # paso_siguiente <clave> <rama> <proyecto>
  case "$1" in
    domains)
      echo "Paso siguiente, en el host: \`devkit proxy <proyecto> --ref $2\` aplica los dominios ya, sin esperar el merge; tras el merge, \`devkit recreate <proyecto>\`. $NOTA_RECREATE"
      ;;
    *)
      echo "Paso siguiente, en el host y tras el merge: \`devkit recreate <proyecto>\` (basta recreate: reconstruye con caché la capa de $1). $NOTA_RECREATE"
      ;;
  esac
}

main() {
  local clave=${1:-} codigo rama slug titulo cuerpo url lista pr_previo wt actuales
  shift || true
  local -a pedidos=() nuevos=() ya_declarados=()
  if [ -z "$clave" ] || [ "$#" -eq 0 ]; then
    echo "uso: declarar.sh <extensions|domains|apt> <valor>..." >&2
    return 64
  fi
  case "$clave" in
    extensions|domains|apt) ;;
    *) err "clave desconocida \"$clave\": las que se pueden declarar son extensions, domains y apt."; return 64 ;;
  esac

  # Todo se valida antes de tocar nada: un valor malo no deja ni el worktree.
  local v
  for v in "$@"; do
    valido "$clave" "$v" || {
      err "valor inválido para $clave: \"$v\" (ejemplo: $(ejemplo_de "$clave"))."
      return 64
    }
    pedidos+=("$v")
  done

  codigo=$(sed -n 's/^project[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/$TOML" 2>/dev/null | head -1)
  [ -n "$codigo" ] || { err "no encuentro \"project\" en $WS/$TOML"; return 1; }

  # gh resuelve el repo desde el directorio en que corre: sin esto, invocado
  # desde ~ o desde un clon anidado (sandbox.local/) mira otro repo que el del
  # origin al que se sube la rama.
  cd "$WS" || { err "no puedo entrar a $WS"; return 1; }

  git -C "$WS" fetch -q origin main 2>/dev/null || { err "git fetch origin main falló; sin red no se puede abrir el PR."; return 1; }

  # Qué falta, contra el toml de origin/main (no el del workspace, que puede
  # estar en la rama de una card con otro contenido).
  actuales=$(git -C "$WS" show "origin/main:$TOML" 2>/dev/null | toml_list "$clave") \
    || { err "no pude leer $TOML de origin/main"; return 1; }
  # Un valor es duplicado por su identidad, no por la cadena entera: una
  # extensión con otra versión (`ms-python.python@2026.2.0`) sigue siendo la
  # misma y dejaría dos entradas para un solo id (H3).
  local p id w existente
  local -a en_toml=()
  read -ra en_toml <<<"$actuales"  # sin globbing: un dominio puede traer `*.`
  for p in "${pedidos[@]}"; do
    id=$(identidad "$clave" "$p")
    existente=""
    for w in ${en_toml[@]+"${en_toml[@]}"}; do
      [ "$(identidad "$clave" "$w")" = "$id" ] && { existente=$w; break; }
    done
    if [ -n "$existente" ]; then
      if [ "$(printf '%s' "$existente" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$p" | tr 'A-Z' 'a-z')" ]; then
        ya_declarados+=("$p")
      else
        ya_declarados+=("$p (ya está como $existente)")
      fi
      continue
    fi
    for w in ${nuevos[@]+"${nuevos[@]}"}; do
      [ "$(identidad "$clave" "$w")" = "$id" ] || continue
      if [ "$(printf '%s' "$w" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$p" | tr 'A-Z' 'a-z')" ]; then
        err "pediste $w y $p, que son la misma extensión con distinta versión: elige una."
        return 64
      fi
      continue 2
    done
    nuevos+=("$p")
  done
  if [ "${#nuevos[@]}" -eq 0 ]; then
    echo "Ya está declarado en $clave de origin/main: ${ya_declarados[*]}. No se abre ningún PR."
    return 0
  fi
  [ "${#ya_declarados[@]}" -eq 0 ] || echo "Ya estaba en $clave y se omite: ${ya_declarados[*]}."

  # Dos PRs -0 sobre la misma clave chocarían al mezclar la misma línea.
  lista=$("$GH" pr list --state open --limit 100 --json number,title,url) \
    || { err "gh pr list no respondió"; return 1; }
  pr_previo=$(printf '%s' "$lista" | jq -r --arg pre "$codigo-0 declarar $clave:" \
    '[.[] | select(.title | startswith($pre))] | first | .url // empty') \
    || { err "gh pr list devolvió algo que no es JSON"; return 1; }
  if [ -n "$pr_previo" ]; then
    echo "Ya hay un PR abierto que declara $clave: $pr_previo"
    echo "Espera su merge (o ciérralo) antes de abrir otro: dos PRs sobre la misma línea chocarían al mezclar. No se abre ningún PR."
    return 0
  fi

  slug=$("$HERE/slugify.sh" "${nuevos[*]}")
  rama="chore/$codigo-0-$clave-$slug"
  # Una rama de un intento anterior (PR cerrado sin mergear) sigue en origin.
  if git -C "$WS" ls-remote --exit-code --heads origin "$rama" >/dev/null 2>&1; then
    rama="$rama-$(date +%m%d%H%M%S)"
  fi

  wt="$WORKTREE_DIR/devkit-declarar-$$"
  git -C "$WS" worktree add -q --detach "$wt" origin/main 2>/dev/null \
    || { err "no pude crear el worktree en $wt"; return 1; }
  trap 'git -C "$WS" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$wt"' RETURN

  local toml_nuevos
  toml_nuevos=$(printf '"%s", ' "${nuevos[@]}")
  toml_nuevos=${toml_nuevos%, }
  agregar_valores "$wt/$TOML" "$clave" "$toml_nuevos" || return 1

  titulo="$codigo-0 declarar $clave: ${nuevos[*]}"
  git -C "$wt" add "$TOML" || return 1
  git -C "$wt" commit -q -m "chore($codigo-0): declarar $clave ${nuevos[*]}" \
    || { err "git commit falló (¿user.name y user.email configurados?)"; return 1; }
  git -C "$wt" push -q origin "HEAD:refs/heads/$rama" 2>/dev/null \
    || { err "git push de $rama falló"; return 1; }

  cuerpo="## Qué cambia

Suma a \`$clave\` de \`$TOML\`: ${nuevos[*]}.

Abierto con \`dk --declarar\`, sin card ni revisión de agentes: la Clave \`$codigo-0\` la ignora el bucle.

## Cómo aplicarlo

$(paso_siguiente "$clave" "$rama")"
  url=$("$GH" pr create --base main --head "$rama" --title "$titulo" --body "$cuerpo") \
    || { err "gh pr create falló; la rama $rama quedó en origin."; return 1; }
  url=$(printf '%s\n' "$url" | tail -1)
  [ -n "$url" ] || { err "gh pr create no devolvió la URL; la rama $rama quedó en origin."; return 1; }
  if ! "$GH" pr merge "$url" --auto --squash >/dev/null 2>&1; then
    err "aviso: no pude activar el auto-merge de $url; actívalo a mano o aprueba y mergea."
  fi

  echo "PR abierto: $url"
  paso_siguiente "$clave" "$rama"
}

# --- Autoprueba: git real sobre un origin local, doble de gh --------------------
run_tests() {
  local fail=0 tmp
  check() {
    if [ "$2" = "$3" ]; then printf 'ok   %-58s %s\n' "$1" "$3"
    else printf 'FAIL %-58s esperado %s, obtenido %s\n' "$1" "$2" "${3:-<vacío>}"; fail=1; fi
  }
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN

  # origin local con main y un toml de prueba; $WS es un clon que además está
  # sobre una rama de card con cambios sin commitear, para probar que no se toca.
  git init -q --bare -b main "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/ws" 2>/dev/null
  git -C "$tmp/ws" config user.name prueba
  git -C "$tmp/ws" config user.email prueba@example.com
  mkdir -p "$tmp/ws/.devkit"
  cat >"$tmp/ws/$TOML" <<'FIN'
[devkit]
template = "dev"
project  = "DEVKIT"
# comentario
domains  = ["open-vsx.org", "github.com"]
FIN
  git -C "$tmp/ws" add . && git -C "$tmp/ws" commit -q -m base && git -C "$tmp/ws" push -q origin HEAD:main
  git -C "$tmp/ws" switch -q -c feat/DEVKIT-1-otra-card
  echo sucio >"$tmp/ws/sin-commit.txt"
  local estado_antes rama_antes
  estado_antes=$(git -C "$tmp/ws" status --short)
  rama_antes=$(git -C "$tmp/ws" branch --show-current)

  # Doble de gh: registra cada llamada; `pr list` responde con $GH_LISTA.
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/gh" <<'FIN'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
echo "$PWD" >>"$GH_PWD"
case "$1 $2" in
  "pr list") cat "$GH_LISTA" ;;
  "pr create") echo "https://github.com/o/r/pull/77" ;;
esac
exit 0
FIN
  chmod +x "$tmp/bin/gh"
  echo '[]' >"$tmp/lista.json"
  : >"$tmp/gh.log"
  : >"$tmp/gh.pwd"
  local -a entorno=(DEVKIT_WS="$tmp/ws" DEVKIT_GH_BIN="$tmp/bin/gh" GH_LOG="$tmp/gh.log" GH_PWD="$tmp/gh.pwd" GH_LISTA="$tmp/lista.json"
                DEVKIT_DECLARAR_WORKTREE_DIR="$tmp")
  local salida rc
  correr() { env "${entorno[@]}" bash "${BASH_SOURCE[0]}" "$@" 2>&1; }
  toml_de() { git -C "$tmp/origin.git" show "$1:$TOML"; }

  # 1. Suma a una lista existente, sin duplicar ni reordenar.
  salida=$(correr domains pypi.org github.com files.pythonhosted.org); rc=$?
  check "domains: sale 0" 0 "$rc"
  check "domains: URL del PR en la salida" 1 "$(printf '%s' "$salida" | grep -c 'pull/77')"
  check "domains: omite el que ya estaba" 1 "$(printf '%s' "$salida" | grep -c 'Ya estaba en domains y se omite: github.com')"
  local rama
  rama=$(git -C "$tmp/origin.git" for-each-ref --format='%(refname:short)' refs/heads/chore | head -1)
  check "domains: rama con -0" chore/DEVKIT-0-domains-pypi-org-files-pythonhosted-org "$rama"
  check "domains: línea reescrita al final, orden intacto" \
    'domains  = ["open-vsx.org", "github.com", "pypi.org", "files.pythonhosted.org"]' \
    "$(git -C "$tmp/origin.git" show "$rama:$TOML" | grep '^domains')"
  check "domains: el resto del toml no cambia" 4 \
    "$(git -C "$tmp/origin.git" show "$rama:$TOML" | grep -cE '^(\[devkit\]|template|project|# comentario)')"
  check "domains: commit chore(DEVKIT-0)" "chore(DEVKIT-0): declarar domains pypi.org files.pythonhosted.org" \
    "$(git -C "$tmp/origin.git" log -1 --format=%s "$rama")"
  check "gh pr create: título con -0" 1 \
    "$(grep -c -F 'pr create --base main --head '"$rama"' --title DEVKIT-0 declarar domains: pypi.org files.pythonhosted.org --body' "$tmp/gh.log")"
  check "gh pr merge: --auto --squash" 1 "$(grep -c 'pr merge https://github.com/o/r/pull/77 --auto --squash' "$tmp/gh.log")"
  check "PR: cuerpo con Qué cambia y Cómo aplicarlo" 2 \
    "$(grep -oE 'Qué cambia|Cómo aplicarlo' "$tmp/gh.log" | wc -l | tr -d ' ')"
  check "domains: paso siguiente es devkit proxy --ref" 1 "$(printf '%s' "$salida" | grep -c "devkit proxy <proyecto> --ref $rama")"
  check "main de origin sin cambios" 1 "$(toml_de main | grep -c '^domains  = \["open-vsx.org", "github.com"\]$')"

  # 2. /workspace intacto: misma rama, mismo estado, sin worktrees ni ramas sobrantes.
  check "workspace: misma rama" "$rama_antes" "$(git -C "$tmp/ws" branch --show-current)"
  check "workspace: mismo git status" "$estado_antes" "$(git -C "$tmp/ws" status --short)"
  check "workspace: sin worktrees sobrantes" 1 "$(git -C "$tmp/ws" worktree list | wc -l | tr -d ' ')"
  check "workspace: sin ramas locales chore" 0 "$(git -C "$tmp/ws" branch --list 'chore/*' | wc -l | tr -d ' ')"

  # 3. Crea la clave si falta, al final de [devkit].
  : >"$tmp/gh.log"
  salida=$(correr extensions ms-python.python ms-python.python); rc=$?
  check "extensions: sale 0" 0 "$rc"
  check "extensions: sin duplicar el valor repetido" 1 \
    "$(git -C "$tmp/origin.git" show chore/DEVKIT-0-extensions-ms-python-python:$TOML | grep -c '^extensions = \["ms-python.python"\]$')"
  check "extensions: creada tras la última línea de [devkit]" 'extensions = ["ms-python.python"]' \
    "$(git -C "$tmp/origin.git" show chore/DEVKIT-0-extensions-ms-python-python:$TOML | tail -1)"
  check "extensions: paso siguiente es recreate" 1 "$(printf '%s' "$salida" | grep -c 'devkit recreate <proyecto>')"
  check "extensions: avisa que recreate puede hacer falta dos veces" 1 \
    "$(printf '%s' "$salida" | grep -c 'el primer recreate usa la lista vieja y hace falta correrlo una segunda vez')"
  check "extensions: título de la spec" 1 \
    "$(grep -c -F -- '--title DEVKIT-0 declarar extensions: ms-python.python --body' "$tmp/gh.log")"

  # 4. Todo ya declarado: mensaje y ningún PR ni rama.
  : >"$tmp/gh.log"
  salida=$(correr domains github.com); rc=$?
  check "ya declarado: sale 0" 0 "$rc"
  check "ya declarado: mensaje claro" 1 "$(printf '%s' "$salida" | grep -c 'Ya está declarado en domains')"
  check "ya declarado: gh no crea nada" 0 "$(grep -c 'pr create' "$tmp/gh.log")"

  # 5. Valores y claves inválidos: 64, ningún PR, ninguna rama nueva.
  local ramas_antes ramas_despues
  ramas_antes=$(git -C "$tmp/origin.git" for-each-ref refs/heads | wc -l | tr -d ' ')
  : >"$tmp/gh.log"
  correr repos foo >/dev/null; check "clave desconocida: 64" 64 "$?"
  correr domains https://pypi.org >/dev/null; check "dominio con esquema: 64" 64 "$?"
  correr domains pypi.org/simple >/dev/null; check "dominio con barra: 64" 64 "$?"
  correr extensions python >/dev/null; check "extensión sin punto: 64" 64 "$?"
  correr extensions 'ms-python.python@' >/dev/null; check "extensión con @ sin versión: 64" 64 "$?"
  correr apt 'Jq' >/dev/null; check "paquete con mayúscula: 64" 64 "$?"
  correr apt 'jq","x' >/dev/null; check "valor con comillas y coma: 64" 64 "$?"
  correr apt >/dev/null; check "sin valores: 64" 64 "$?"
  correr >/dev/null; check "sin argumentos: 64" 64 "$?"
  ramas_despues=$(git -C "$tmp/origin.git" for-each-ref refs/heads | wc -l | tr -d ' ')
  check "inválidos: ninguna rama nueva en origin" "$ramas_antes" "$ramas_despues"
  check "inválidos: gh ni se llama" 0 "$(wc -l <"$tmp/gh.log" | tr -d ' ')"
  correr domains '*.pythonhosted.org' >/dev/null; check "dominio con comodín *. es válido" 0 "$?"

  # 6. Ya hay un PR -0 abierto de la misma clave: avisa con su URL y no abre otro.
  : >"$tmp/gh.log"
  echo '[{"number":5,"title":"DEVKIT-0 declarar apt: jq","url":"https://github.com/o/r/pull/5"}]' >"$tmp/lista.json"
  salida=$(correr apt curl); rc=$?
  check "PR previo: sale 0" 0 "$rc"
  check "PR previo: avisa con su URL" 1 "$(printf '%s' "$salida" | grep -c 'pull/5')"
  check "PR previo: no abre otro" 0 "$(grep -c 'pr create' "$tmp/gh.log")"
  salida=$(correr domains pypi.org); rc=$?
  check "PR previo de otra clave no estorba" 0 "$(printf '%s' "$salida" | grep -c 'Ya hay un PR abierto')"

  # 7. El workspace sigue igual tras todo lo anterior.
  check "workspace: mismo git status al final" "$estado_antes" "$(git -C "$tmp/ws" status --short)"
  check "workspace: misma rama al final" "$rama_antes" "$(git -C "$tmp/ws" branch --show-current)"

  # 8. gh corre siempre desde el workspace, sin importar desde dónde se invoque.
  : >"$tmp/gh.pwd"
  echo '[]' >"$tmp/lista.json"
  mkdir -p "$tmp/otro/repo-anidado"
  salida=$(cd "$tmp/otro/repo-anidado" && env "${entorno[@]}" bash "$HERE/declarar.sh" apt wget 2>&1); rc=$?
  check "otro directorio: sale 0" 0 "$rc"
  check "otro directorio: abre el PR" 1 "$(printf '%s' "$salida" | grep -c 'pull/77')"
  check "otro directorio: gh se llamó 3 veces (list, create, merge)" 3 "$(wc -l <"$tmp/gh.pwd" | tr -d ' ')"
  check "otro directorio: todas las llamadas de gh desde el workspace" "$tmp/ws" "$(sort -u "$tmp/gh.pwd")"

  # 9. Una extensión ya declarada se reconoce por su id, con o sin versión (H3).
  # Un clon aparte suma la extensión a main; $WS trae ese main con su fetch.
  git clone -q "$tmp/origin.git" "$tmp/ws2" 2>/dev/null
  git -C "$tmp/ws2" config user.name prueba
  git -C "$tmp/ws2" config user.email prueba@example.com
  echo 'extensions = ["ms-python.python"]' >>"$tmp/ws2/$TOML"
  git -C "$tmp/ws2" commit -q -am 'declara ms-python.python' && git -C "$tmp/ws2" push -q origin HEAD:main
  : >"$tmp/gh.log"
  salida=$(correr extensions ms-python.python@2026.2.0); rc=$?
  check "id con versión ya declarado sin ella: sale 0" 0 "$rc"
  check "id con versión: avisa con la entrada existente" 1 \
    "$(printf '%s' "$salida" | grep -c 'ms-python.python@2026.2.0 (ya está como ms-python.python)')"
  check "id con versión: no abre PR" 0 "$(grep -c 'pr create' "$tmp/gh.log")"
  salida=$(correr extensions MS-Python.Python); rc=$?
  check "id con otras mayúsculas: ya declarado" 1 "$(printf '%s' "$salida" | grep -c 'Ya está declarado en extensions')"
  git -C "$tmp/ws2" reset -q --hard HEAD~1
  echo 'extensions = ["ms-python.python@2026.2.0"]' >>"$tmp/ws2/$TOML"
  git -C "$tmp/ws2" commit -q -am 'declara ms-python.python con versión' && git -C "$tmp/ws2" push -q -f origin HEAD:main
  salida=$(correr extensions ms-python.python); rc=$?
  check "id sin versión ya declarado con ella: sale 0" 0 "$rc"
  check "id sin versión: avisa con la entrada existente" 1 \
    "$(printf '%s' "$salida" | grep -c 'ms-python.python (ya está como ms-python.python@2026.2.0)')"
  check "id sin versión: no abre PR" 0 "$(grep -c 'pr create' "$tmp/gh.log")"
  correr extensions redhat.java redhat.java@1.0.0 >/dev/null; check "mismo id con dos versiones en el pedido: 64" 64 "$?"
  check "dos versiones: no abre PR" 0 "$(grep -c 'pr create' "$tmp/gh.log")"
  salida=$(correr extensions redhat.java REDHAT.java); rc=$?
  check "mismo id repetido en el pedido: sale 0" 0 "$rc"
  check "mismo id repetido: una sola entrada en la rama" 1 \
    "$(git -C "$tmp/origin.git" show chore/DEVKIT-0-extensions-redhat-java:$TOML | grep '^extensions' | grep -oi 'redhat\.java' | wc -l | tr -d ' ')"

  return $fail
}

if [ "${1:-}" = --test ]; then
  run_tests
  exit $?
fi
main "$@"
exit $?

#!/usr/bin/env bash
# Hook PreToolUse para Bash. Reduce los rodeos que el deny por prefijo de
# settings.json no ve porque compara el inicio exacto del comando: revisa el
# comando completo, en cualquier posición de sus argumentos. Es una
# inspección de texto, no una sandbox: no ve variables de shell, alias de
# gh ni una API que no conozca, así que reduce evasiones accidentales o
# perezosas, no las garantiza. La compuerta real es GitHub (ruleset de
# main + cuenta máquina sin permiso de aprobar). El porqué de cada regla
# vive en la entrada de Documentación "Stack y comandos del devkit", no aquí.
# Uso normal: recibe por stdin el JSON del hook y responde con el protocolo
# de Claude Code (sale 2 y el motivo por stderr si bloquea).
#      pr-guard.sh --test   corre la tabla de autoprueba y sale 1 si falla.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Corta el comando en sub-comandos por operadores de shell, para no mezclar
# uno con otro al buscar un patrón (ej. "ls; git push origin main").
segments_of() {
  printf '%s\n' "$1" | sed -E 's/(&&|\|\||;|\|)/\n/g'
}

# Un token por línea, respetando comillas (ej. -b "texto con -a adentro" es
# un solo token). Vacío y exit != 0 si las comillas del segmento no cierran:
# el llamador cae entonces al chequeo por substring, más estricto.
tokens_of() {
  printf '%s' "$1" | xargs -n1 -- printf '%s\n' 2>/dev/null
}

# True si algún token de $1 (separado por espacios) es exactamente uno de
# $2... Usa read -ra en vez de un `for tok in $1` para no arriesgar
# expansión de comodines sobre el texto del comando.
has_token() {
  local hay="$1"; shift
  local -a toks
  read -ra toks <<< "$hay"
  local tok want
  for tok in "${toks[@]}"; do
    for want in "$@"; do
      [ "$tok" = "$want" ] && return 0
    done
  done
  return 1
}

# True si algún token de $1 es exactamente uno de $2... o ese prefijo con
# "=valor" pegado: gh y git tratan --flag X y --flag=X igual.
has_flag() {
  local hay="$1"; shift
  local -a toks
  read -ra toks <<< "$hay"
  local tok want
  for tok in "${toks[@]}"; do
    for want in "$@"; do
      if [ "$tok" = "$want" ] || [[ "$tok" == "$want"=* ]]; then
        return 0
      fi
    done
  done
  return 1
}

# True si el segmento solo comprueba que un token de /run/devkit existe
# (test/[/[[ con -e/-f/-r/-s), no si lee su contenido. Lista blanca, no
# negra: cualquier otra forma de tocar la ruta cae al bloqueo por defecto
# del llamador. El comando de la comprobación debe ser el primer token del
# segmento (o el primero tras "docker exec <contenedor>", el único
# envoltorio que se usa hoy): así "grep ls ..." o "xargs ls < ..." no cuelan
# solo por traer "ls" en cualquier posición, que era el hueco de DEVKIT-51
# (H8). $(...) y las comillas invertidas bloquean siempre, porque pueden
# inyectar el contenido del archivo como argumento de un comando que sí
# pasaría la lista blanca (ej. "ls $(cat vscode-token)"). "ls" y "stat" no
# están en la lista: su salida (listado, "%n") puede reinyectar la ruta o
# el nombre del archivo a un lector posterior en el mismo pipe (ej. "ls
# /run/devkit/vscode-token | xargs cat"), y ese segundo segmento no
# menciona la ruta, así que este chequeo nunca lo ve. Es el límite
# documentado de una inspección de texto por segmento (DEVKIT-51, cuarto
# ciclo): formas alternativas de la ruta no se persiguen aquí.
is_token_existence_check() {
  local hay="$1"
  case "$hay" in
    *'$('*|*'`'*) return 1 ;;
  esac
  local -a toks
  read -ra toks <<< "$hay"
  local i=0
  if [ "${toks[0]:-}" = docker ] && [ "${toks[1]:-}" = exec ]; then
    i=3
  fi
  case "${toks[$i]:-}" in
    test|'['|'[[')
      has_flag "$hay" -e -f -r -s
      ;;
    *)
      return 1
      ;;
  esac
}

# Motivo de bloqueo de un solo sub-comando, o vacío si puede pasar.
reason_for_segment() {
  local raw="$1"
  # $'...' es el quoting ANSI-C de bash, distinto de "..."/'...': el $ queda
  # pegado al valor citado y sobrevive a un tr -d ingenuo, rompiendo los
  # límites [[:space:]] de las regex (ej. gh pr review 42 $'--approve'). Se
  # colapsa a comillas simples normales antes de todo lo demás, así el resto
  # del normalizado lo trata igual que --approve entre comillas comunes.
  local seg
  seg="$(printf '%s' "$raw" | sed "s/\$'/'/g")"
  # Comillas y barras invertidas rompen los límites [[:space:]] de las
  # regex de abajo (ej. gh pr review 42 "--approve", git push origin
  # ma\in): se matchea sobre una copia normalizada, nunca sobre $seg.
  local nseg
  nseg="$(printf '%s' "$seg" | tr -d '\\' | tr -d "\"'")"

  if [[ "$nseg" =~ gh[[:space:]]+alias[[:space:]]+set ]]; then
    printf 'gh alias set está prohibido: esconde el comando real de este hook'
    return 0
  fi

  if [[ "$nseg" =~ gh[[:space:]]+pr[[:space:]]+review ]]; then
    local tokens has_approve
    if tokens="$(tokens_of "$seg")"; then
      # Comillas bien formadas: solo bloquea si --approve/-a es un token
      # completo (o esa forma con "=valor" pegado, ej. --approve=true: gh
      # trata sus flags booleanos igual con o sin "=valor"), para no
      # confundirlo con un -a suelto dentro de un texto citado (ej. --body
      # "revisa -a detalle este cambio").
      has_approve="$(printf '%s\n' "$tokens" | grep -qxE -- '(--approve|-a)(=.*)?' && echo 1)"
    elif [[ "$nseg" =~ (^|[[:space:]])(--approve|-a)(=[^[:space:]]*)?([[:space:]]|$) ]]; then
      has_approve=1
    fi
    if [ -n "${has_approve:-}" ]; then
      printf 'gh pr review --approve está prohibido; usa --comment'
      return 0
    fi
  fi

  if [[ "$nseg" =~ gh[[:space:]]+api[[:space:]]+graphql ]] \
    && [[ "$nseg" =~ (APPROVE|addPullRequestReview|mergePullRequest) ]]; then
    printf 'gh api graphql que apruebe o mergee un PR está prohibido'
    return 0
  fi

  if [[ "$nseg" =~ gh[[:space:]]+api ]] && [[ "$nseg" =~ /pulls/[^[:space:]]*/reviews ]]; then
    # Cualquier flag de escritura, no solo event=APPROVE: el valor puede
    # viajar en un archivo (--input) o en un campo tipado (-F).
    if has_flag "$nseg" -X --method -f -F --raw-field --input; then
      printf 'gh api de escritura sobre /pulls/*/reviews está prohibido'
      return 0
    fi
  fi

  if [[ "$nseg" =~ gh[[:space:]]+pr[[:space:]]+merge ]]; then
    if has_flag "$nseg" --admin; then
      printf 'gh pr merge --admin está prohibido'
      return 0
    fi
    if ! has_flag "$nseg" --auto; then
      printf 'gh pr merge sin --auto está prohibido'
      return 0
    fi
    # --auto es booleano (pflag/cobra): a diferencia de --admin y --approve,
    # un "=valor" falsy invierte el sentido y desactiva el auto-merge, el
    # mismo caso que el chequeo de arriba ya prohíbe.
    if [[ "$nseg" =~ (^|[[:space:]])--auto=(0|[Ff](alse)?|off)([[:space:]]|$) ]]; then
      printf 'gh pr merge sin --auto está prohibido'
      return 0
    fi
  fi

  if [[ "$nseg" =~ gh[[:space:]]+api ]] \
    && [[ "$nseg" =~ /pulls/[^[:space:]]*/merge ]] \
    && [[ "$nseg" =~ (-X[[:space:]]*PUT|--method[[:space:]=]+PUT) ]]; then
    printf 'gh api PUT sobre /pulls/*/merge está prohibido; usa gh pr merge --auto'
    return 0
  fi

  if [[ "$nseg" =~ gh[[:space:]]+api ]] \
    && [[ "$nseg" =~ /git/refs/heads/main ]] \
    && [[ "$nseg" =~ (-X[[:space:]]*(PUT|POST|PATCH|DELETE)|--method[[:space:]=]+(PUT|POST|PATCH|DELETE)) ]]; then
    printf 'gh api de escritura sobre refs/heads/main está prohibido'
    return 0
  fi

  if [[ "$nseg" =~ git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push ]]; then
    # $VAR, $(comando) o $'...' en un git push no son evaluables por este
    # hook: el texto que ve no es el comando que bash termina ejecutando.
    # Los agentes no necesitan un push con destino dinámico.
    if [[ "$raw" == *'$'* ]]; then
      printf 'git push con expansión de shell ($) está prohibido'
      return 0
    fi

    if has_flag "$nseg" --force --force-with-lease --force-if-includes; then
      printf 'git push --force está prohibido'
      return 0
    fi

    local -a toks
    read -ra toks <<< "$nseg"
    local tok
    for tok in "${toks[@]}"; do
      # -f suelto o dentro de cualquier grupo de flags cortos (-fu, -uf),
      # pero nunca una opción larga (--force ya se cubrió arriba).
      if [[ "$tok" =~ ^-[a-zA-Z]*f[a-zA-Z]*$ ]]; then
        printf 'git push --force está prohibido'
        return 0
      fi
    done

    for tok in "${toks[@]}"; do
      case "$tok" in
        main|+main|*:main)
          printf 'git push a main está prohibido'
          return 0
          ;;
      esac
      if [[ "$tok" == *refs/heads/main* ]]; then
        printf 'git push a main está prohibido'
        return 0
      fi
    done
  fi

  if [[ "$nseg" =~ /run/devkit/vscode-token ]] && ! is_token_existence_check "$nseg"; then
    printf 'leer /run/devkit/vscode-token expone el token; no se pega en un chat ni en una card (ver runbook "El editor no abre")'
    return 0
  fi

  # DEVKIT-55: la misma regla para el token de Notion. Los scripts que lo usan
  # (notion.sh, task-close.sh, task-block.sh) lo leen por dentro; un agente no
  # necesita tocar la ruta.
  if [[ "$nseg" =~ /run/devkit/notion_token ]] && ! is_token_existence_check "$nseg"; then
    printf 'leer /run/devkit/notion_token expone el token de Notion; usa notion.sh, que lo lee sin imprimirlo'
    return 0
  fi

  return 1
}

# Motivo de bloqueo del comando completo, o vacío si puede pasar.
reason_to_block() {
  local command="$1" seg r
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    if r="$(reason_for_segment "$seg")"; then
      printf '%s' "$r"
      return 0
    fi
  done < <(segments_of "$command")
  return 1
}

run_tests() {
  local fail=0
  check() {
    local cmd="$1" want="$2" got
    if reason_to_block "$cmd" >/dev/null; then got=block; else got=allow; fi
    if [ "$want" = "$got" ]; then
      printf 'ok   %-72s -> %s\n' "$cmd" "$got"
    else
      printf 'FAIL %-72s esperado %s, obtenido %s\n' "$cmd" "$want" "$got"
      fail=1
    fi
  }

  check 'gh pr review 42 --approve' block
  check 'gh pr review --approve 42' block
  check 'gh pr review 42 -a' block
  check 'gh api repos/o/r/pulls/42/reviews -f event=APPROVE' block
  check 'gh api -X POST repos/o/r/pulls/42/reviews -f event=APPROVE' block
  check 'gh pr merge 42' block
  check 'gh pr merge --squash 42' block
  check 'gh pr merge --admin' block
  check 'gh api -X PUT repos/o/r/pulls/42/merge' block
  check 'gh api --method PUT repos/o/r/pulls/42/merge' block
  check 'gh api -X DELETE repos/o/r/git/refs/heads/main' block
  check 'git push origin main' block
  check 'git -C /workspace/devkit push origin main' block
  check 'git push origin HEAD:main' block
  check 'git push origin refs/heads/main' block
  check 'git push origin :main' block
  check 'git push origin --delete main' block
  check 'git push --force origin feat/x' block
  check 'git -C /tmp/repo push -f origin feat/x' block
  check 'git push --force-with-lease origin feat/x' block
  check 'echo hola && gh pr review 42 --approve' block
  check 'gh pr review 42 "--approve"' block
  check "gh pr review 42 '--approve'" block
  check 'git push origin "main"' block
  check "git push origin 'main'" block
  check 'git push origin fix/algo:main' block
  check 'git push origin feat/x:main' block
  check "gh pr review 42 \$'--approve'" block
  check "git push origin \$'main'" block

  # DEVKIT-20, segunda ronda: evasiones que la tabla de arriba no cubría.
  check 'git push origin +main' block
  check 'git push upstream main' block
  check 'git push https://github.com/byroncz/dotfiles.git main' block
  check 'git push -fu origin feat/x' block
  check 'git push -uf origin feat/x' block
  check 'git push --force-with-lease=main origin feat/x' block
  check 'git push --force-if-includes origin feat/x' block
  check 'git push origin ma\in' block
  check 'gh api --method=PUT repos/o/r/pulls/42/merge' block
  check 'gh api repos/o/r/pulls/42/reviews --input body.json' block
  check "gh api graphql -f query='mutation { addPullRequestReview(input:{pullRequestId:\"X\", event:APPROVE}) {clientMutationId} }'" block
  check "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"X\"}) {clientMutationId} }'" block
  check "gh alias set ap \"pr review --approve\" && gh ap 42" block
  check 'B=main; git push origin $B' block
  check 'git push origin $(echo main)' block
  check 'gh pr merge 42 --auto --admin' block

  # DEVKIT-20, tercera ronda: gh acepta "--flag=valor" en sus flags
  # booleanos (pflag/cobra), no solo "--flag valor".
  check 'gh pr review 42 --approve=true' block
  check 'gh pr review 42 -a=true' block
  check 'gh pr merge 42 --auto --admin=true' block

  # DEVKIT-51: leer el token del editor en crudo no se pega en un chat.
  check 'cat /run/devkit/vscode-token' block
  check 'docker exec devkit-x cat /run/devkit/vscode-token' block
  check 'tail /run/devkit/vscode-token' block
  check 'grep tkn /run/devkit/vscode-token' block
  check 'head /run/devkit/vscode-token' block
  check 'less /run/devkit/vscode-token' block
  check 'more /run/devkit/vscode-token' block
  check 'od -c /run/devkit/vscode-token' block
  check 'xxd /run/devkit/vscode-token' block
  check 'strings /run/devkit/vscode-token' block
  check 'base64 /run/devkit/vscode-token' block
  check 'cp /run/devkit/vscode-token /tmp/t' block
  check 'mv /run/devkit/vscode-token /tmp/t' block
  check 'docker cp devkit-x:/run/devkit/vscode-token .' block

  # DEVKIT-51, segundo ciclo: lista blanca en vez de negra. Cualquier forma
  # de tocar la ruta que no sea una comprobación de existencia bloquea,
  # incluida la redirección y el intérprete, que la lista negra no cubría.
  check 'read t < /run/devkit/vscode-token' block
  check 'echo $(</run/devkit/vscode-token)' block
  check 'python3 -c "print(open(\"/run/devkit/vscode-token\").read())"' block
  check 'sed -n 1p /run/devkit/vscode-token' block

  # DEVKIT-51, tercer ciclo: la lista blanca aceptaba "ls" o "test -f" en
  # cualquier posición del segmento, no solo como comando real.
  check 'grep ls /run/devkit/vscode-token' block
  check 'xargs ls < /run/devkit/vscode-token' block
  check 'ls $(cat /run/devkit/vscode-token)' block

  # DEVKIT-51, cuarto ciclo: "ls" y "stat" ya no están en la lista blanca.
  # Su salida reinyecta la ruta o el nombre del archivo a un segundo
  # segmento del pipe que no menciona la ruta, y ese segundo segmento es el
  # que termina imprimiendo el token.
  check 'ls /run/devkit/vscode-token | xargs cat' block
  check 'stat -c %n /run/devkit/vscode-token | xargs cat' block

  # DEVKIT-55: el token de Notion sigue la misma regla que el del editor.
  check 'cat /run/devkit/notion_token' block
  check 'curl -H "Authorization: Bearer $(cat /run/devkit/notion_token)" https://api.notion.com/v1/users' block
  check 'base64 /run/devkit/notion_token' block
  check 'test -s /run/devkit/notion_token' allow
  check 'bash /workspace/devkit/scripts/notion.sh card DEVKIT-55' allow

  # DEVKIT-20, cuarta ronda: --auto es booleano y "=false"/"=0" lo apaga,
  # el mismo caso que "sin --auto" ya prohíbe.
  check 'gh pr merge 42 --auto=false' block
  check 'gh pr merge 42 --auto=0' block

  check 'gh pr review --comment 42' allow
  check 'gh pr review 42 --comment "listo"' allow
  check 'gh pr review 42 --comment -b "revisa -a detalle este cambio"' allow
  check 'gh api repos/o/r/pulls/42/reviews' allow
  check 'gh pr merge --auto 42' allow
  check 'gh pr merge --auto --squash 42' allow
  check 'gh pr merge 42 --auto=true' allow
  check 'git push -u origin feat/DEVKIT-20-hook-bloquear-aprobar-pr' allow
  check 'git push -u origin feat/DEVKIT-20-main-algo' allow
  check 'git push origin fix/DEVKIT-9-algo' allow
  check 'git push origin chore/main-cleanup' allow
  check 'git status' allow
  check 'docker exec devkit-x test -f /run/devkit/vscode-token && echo ok' allow
  check 'docker exec devkit-x cat /run/devkit/vscode.log' allow

  # DEVKIT-51, tercer ciclo: comprobaciones de existencia igual de inocuas
  # que la lista blanca original bloqueaba por no reconocer la forma.
  check '[[ -f /run/devkit/vscode-token ]]' allow
  check 'test -e /run/devkit/vscode-token' allow
  check 'test -r /run/devkit/vscode-token' allow
  check '[ -s /run/devkit/vscode-token ]' allow

  # El hook completo (stdin -> denials.log), no solo reason_to_block: el
  # registro de denegaciones de DEVKIT-45 vive en el bloque de más abajo, que
  # ninguno de los checks de arriba ejercita.
  local tmp
  tmp=$(mktemp -d)
  printf '{"tool_input":{"command":"gh pr review 42 --approve"}}' \
    | DEVKIT_RUN_DIR="$tmp" bash "$HERE/pr-guard.sh" >/dev/null 2>&1
  check_denial() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      printf 'ok   %-72s -> %s\n' "$name" "$got"
    else
      printf 'FAIL %-72s esperado %s, obtenido %s\n' "$name" "$want" "${got:-<vacío>}"
      fail=1
    fi
  }
  check_denial 'hook completo anota el bloqueo en denials.log' 1 \
    "$(grep -c 'gh pr review 42 --approve' "$tmp/denials.log" 2>/dev/null || echo 0)"
  rm -rf "$tmp"

  return $fail
}

if [ "${1:-}" = "--test" ]; then
  run_tests
  exit $?
fi

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
if [ -n "$command" ]; then
  if reason="$(reason_to_block "$command")"; then
    # Registro de denegaciones (DEVKIT-45): esta es la compuerta real en
    # modo headless, no la lista `allow` de settings.json (ver la nota al
    # principio de este archivo y la entrada de Documentación de DEVKIT-45).
    # Si bloquea algo legítimo, este log dice qué ampliar en
    # `reason_for_segment`.
    printf '%s pr-guard denegó: %s :: %s\n' "$(date -u +%FT%TZ)" "$reason" "$command" \
      >> "${DEVKIT_RUN_DIR:-/run/devkit}/denials.log" 2>/dev/null
    printf 'pr-guard: %s\n' "$reason" >&2
    exit 2
  fi
fi
exit 0

#!/usr/bin/env bash
# Hook PreToolUse para Bash. Cierra los rodeos que el deny por prefijo de
# settings.json no ve porque compara el inicio exacto del comando: revisa el
# comando completo, en cualquier posición de sus argumentos. El porqué de
# cada regla vive en la entrada de Documentación "Stack y comandos del
# devkit", no aquí.
# Uso normal: recibe por stdin el JSON del hook y responde con el protocolo
# de Claude Code (sale 2 y el motivo por stderr si bloquea).
#      pr-guard.sh --test   corre la tabla de autoprueba y sale 1 si falla.
set -u

# Corta el comando en sub-comandos por operadores de shell, para no mezclar
# uno con otro al buscar un patrón (ej. "ls; git push origin main").
segments_of() {
  printf '%s\n' "$1" | sed -E 's/(&&|\|\||;|\|)/\n/g'
}

# Motivo de bloqueo de un solo sub-comando, o vacío si puede pasar.
reason_for_segment() {
  local seg="$1"

  if [[ "$seg" =~ gh[[:space:]]+pr[[:space:]]+review ]] \
    && [[ "$seg" =~ (^|[[:space:]])(--approve|-a)([[:space:]]|$) ]]; then
    printf 'gh pr review --approve está prohibido; usa --comment'
    return 0
  fi

  if [[ "$seg" =~ gh[[:space:]]+api ]] \
    && [[ "$seg" =~ /pulls/[^[:space:]\"\']*/reviews ]] \
    && [[ "$seg" =~ event[\"\']?[[:space:]]*[:=][[:space:]]*[\"\']?APPROVE ]]; then
    printf 'gh api con event=APPROVE sobre /pulls/*/reviews está prohibido'
    return 0
  fi

  if [[ "$seg" =~ gh[[:space:]]+pr[[:space:]]+merge ]] \
    && ! [[ "$seg" =~ (^|[[:space:]])--auto([[:space:]]|$) ]]; then
    printf 'gh pr merge sin --auto está prohibido'
    return 0
  fi

  if [[ "$seg" =~ gh[[:space:]]+api ]] \
    && [[ "$seg" =~ /pulls/[^[:space:]\"\']*/merge ]] \
    && [[ "$seg" =~ (-X[[:space:]]*PUT|--method[[:space:]]+PUT) ]]; then
    printf 'gh api PUT sobre /pulls/*/merge está prohibido; usa gh pr merge --auto'
    return 0
  fi

  if [[ "$seg" =~ gh[[:space:]]+api ]] \
    && [[ "$seg" =~ /git/refs/heads/main ]] \
    && [[ "$seg" =~ (-X[[:space:]]*(PUT|POST|PATCH|DELETE)|--method[[:space:]]+(PUT|POST|PATCH|DELETE)) ]]; then
    printf 'gh api de escritura sobre refs/heads/main está prohibido'
    return 0
  fi

  if [[ "$seg" =~ git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push ]]; then
    if [[ "$seg" =~ (--force(-with-lease)?)([[:space:]]|$) ]] \
      || [[ "$seg" =~ (^|[[:space:]])-f([[:space:]]|$) ]]; then
      printf 'git push --force está prohibido'
      return 0
    fi
    if [[ "$seg" =~ origin[[:space:]]+main([[:space:]]|$) ]] \
      || [[ "$seg" =~ origin[[:space:]]+:main([[:space:]]|$) ]] \
      || [[ "$seg" =~ HEAD:main([[:space:]]|$) ]] \
      || [[ "$seg" =~ refs/heads/main([[:space:]]|$) ]] \
      || { [[ "$seg" =~ --delete ]] && [[ "$seg" =~ (^|[[:space:]])main([[:space:]]|$) ]]; }; then
      printf 'git push a main está prohibido'
      return 0
    fi
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

  check 'gh pr review --comment 42' allow
  check 'gh pr review 42 --comment "listo"' allow
  check 'gh api repos/o/r/pulls/42/reviews' allow
  check 'gh pr merge --auto 42' allow
  check 'git push -u origin feat/DEVKIT-20-hook-bloquear-aprobar-pr' allow
  check 'git push -u origin feat/DEVKIT-20-main-algo' allow
  check 'git push origin fix/DEVKIT-9-algo' allow
  check 'git status' allow

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
    printf 'pr-guard: %s\n' "$reason" >&2
    exit 2
  fi
fi
exit 0

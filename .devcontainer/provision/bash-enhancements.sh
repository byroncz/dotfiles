# ─────────────────────────────────────────────────────────────────────────
#  Bash enhancements for the devcontainer — ASCII-safe, zero external deps.
#  Sourced from ~/.bashrc. Gives: informative prompt (exit code, git branch,
#  python venv), large shared history, sane shell options, color + aliases.
#  Relies only on bash builtins + git (already in the image) + bash-completion
#  (apt package, see Dockerfile). No oh-my-zsh / starship / nerd fonts needed.
# ─────────────────────────────────────────────────────────────────────────

# ── History: large, deduped, appended across sessions, timestamped ──────────
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups   # drop dups and leading-space cmds
export HISTTIMEFORMAT='%F %T  '
shopt -s histappend cmdhist

# Historial persistente entre rebuilds: /commandhistory es un volumen Docker
# (ver docker-compose.yml). Si no está montado, se usa el ~/.bash_history normal.
[ -d /commandhistory ] && export HISTFILE=/commandhistory/.bash_history

# ── Quality-of-life shell options ───────────────────────────────────────────
shopt -s checkwinsize           # keep $LINES/$COLUMNS right after a resize
shopt -s globstar  2>/dev/null  # ** matches recursively
shopt -s autocd    2>/dev/null  # type a dir name to cd into it
shopt -s cdspell dirspell 2>/dev/null  # autocorrect small typos in cd paths

# ── Color + pager + common aliases ──────────────────────────────────────────
export CLICOLOR=1
export LESS='-R'
alias ls='ls --color=auto'
alias ll='ls -alFh --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status'
alias gl='git log --oneline --graph --decorate -20'
alias gd='git diff'
alias gb='git branch'
alias gco='git checkout'

# ── Load git tab-completion even if bash-completion loader is absent ─────────
# (bash-completion's main loader auto-discovers this; we source it directly as
#  a fallback so `git <TAB>` works regardless.)
if ! type -t __git_complete >/dev/null 2>&1; then
  [ -f /usr/share/bash-completion/completions/git ] && \
    . /usr/share/bash-completion/completions/git 2>/dev/null
fi

# ── Self-contained git-branch segment (no git-prompt.sh dependency) ──────────
__dc_git_segment() {
  local b
  b=$(git symbolic-ref --short -q HEAD 2>/dev/null) \
    || b=$(git describe --tags --exact-match 2>/dev/null) \
    || b=$(git rev-parse --short HEAD 2>/dev/null) \
    || return 0
  local dirty=''
  git diff --quiet --ignore-submodules HEAD -- 2>/dev/null || dirty='*'
  printf ' (%s%s)' "$b" "$dirty"
}

# ── Python virtualenv segment ────────────────────────────────────────────────
__dc_venv_segment() {
  [ -n "${VIRTUAL_ENV:-}" ] && printf ' [venv:%s]' "$(basename "$VIRTUAL_ENV")"
}

# ── Prompt: exit-status-aware, user@host, cwd, venv, git branch. ASCII only. ─
__dc_prompt() {
  local last=$?
  history -a                                   # share history immediately
  local R='\[\e[0m\]'                           # reset
  local GREEN='\[\e[1;32m\]' BLUE='\[\e[1;34m\]'
  local YELLOW='\[\e[33m\]'  CYAN='\[\e[36m\]'  RED='\[\e[1;31m\]'
  local stat=''
  [ "$last" -ne 0 ] && stat="${RED}[${last}]${R} "
  PS1="${stat}${GREEN}\u@\h${R}:${BLUE}\w${R}${CYAN}$(__dc_venv_segment)${R}${YELLOW}$(__dc_git_segment)${R}\$ "
}
PROMPT_COMMAND='__dc_prompt'

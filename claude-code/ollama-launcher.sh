#!/usr/bin/env bash
#
# ollama-launcher.sh — dedicated launcher for Ollama Cloud models.
#
# Invoked via keybind (Ctrl+Y in Zellij / bash) or alias (`oc`):
#   Desktop: bind in Zellij config or run directly
#   Phone  : ssh -t desktop "~/dev/dev-environment/claude-code/ollama-launcher.sh"
#
# Flow:
#   1. fzf menu to pick a model from ~/.config/ollama-claude-models
#   2. Native bash toggle-menu for launch options (arrows + Enter, works on phone)
#   3. exec ollama launch claude --model <model> <options>
#
set -euo pipefail

# fzf: local binary (installed without sudo in ~/.fzf/bin), fall back to the PATH.
FZF="$HOME/.fzf/bin/fzf"
[[ -x "$FZF" ]] || FZF="$(command -v fzf 2>/dev/null || true)"

# ANSI colors
G=$'\e[32m'; D=$'\e[90m'; R=$'\e[0m'; O=$'\e[36m'

# Model list (same file the `ollama launch claude` wrapper uses).
OLLAMA_MODELS_FILE="${OLLAMA_CLAUDE_MODELS:-$HOME/.config/ollama-claude-models}"
[[ -r "$OLLAMA_MODELS_FILE" ]] || { echo "ollama: liste de modèles introuvable ($OLLAMA_MODELS_FILE)" >&2; exit 1; }

models=()
mapfile -t models < <(grep -vE '^[[:space:]]*(#|$)' "$OLLAMA_MODELS_FILE" 2>/dev/null || true)
[[ ${#models[@]} -eq 0 ]] && { echo "ollama: liste de modèles vide ($OLLAMA_MODELS_FILE)" >&2; exit 1; }

# Launch options (toggleable). All ON by default.
OLLAMA_OPTS=(
  "--dangerously-skip-permissions"
  "--verbose"
  "--debug"
)

# run : LAST command — `exec` (replaces the process).
run() { exec "$@"; }

# --- pick model (fzf: this is the FIRST fzf in the script, no TTY issues) ----
[[ -x "$FZF" ]] || { echo "fzf not found (~/.fzf/bin/fzf) — run: ~/.fzf/install --bin" >&2; exit 1; }

model=$(printf '%s\n' "${models[@]}" | "$FZF" \
  --no-multi --layout=reverse --no-border \
  --color=pointer:8 --prompt='model ❯ ' \
  --header="Enter: select model  ·  Esc: cancel" \
) || exit 0
# Nettoyage après fzf (certains terminaux laissent des résidus de border).
printf '\n\n\n\n\n\n\n\n' >&2

# --- option toggle menu (native bash, works on phone via ssh/mosh) -----------
option_menu() {  # $1 = model name
  local model="$1" _key _rest _cursor=0 _total _i
  local -a _state=(1 1 1)
  local _n=${#OLLAMA_OPTS[@]}
  _total=$(( _n + 2 ))   # options + Lancer + Annuler

  while true; do
    # Pas de clear (bug sous Termux/SSH) : on saute juste des lignes.
    printf '\n\n  ◆ Ollama (claude)  —  %s\n\n' "$model" >&2

    for ((_i=0; _i<_n; _i++)); do
      local _mark
      if ((_state[_i])); then _mark="[x]"; else _mark="[ ]"; fi
      if ((_i == _cursor)); then
        printf '  >  %s %s\n' "$_mark" "${OLLAMA_OPTS[_i]}" >&2
      else
        printf '      %s %s\n' "$_mark" "${OLLAMA_OPTS[_i]}" >&2
      fi
    done

    printf '\n' >&2
    if ((_cursor == _n));   then printf '  >  Lancer\n' >&2;   else printf '      Lancer\n' >&2;   fi
    if ((_cursor == _n+1)); then printf '  >  Annuler\n' >&2; else printf '      Annuler\n' >&2; fi

    IFS= read -rs -n1 _key </dev/tty 2>/dev/null || { echo >&2; return 1; }

    case "$_key" in
      $'\003')   # Ctrl+C (ETX)
        return 1
        ;;
      $'\e')
        # Flèches : \e[A/\e[B (normal) ou \eOA/\eOB (application cursor keys).
        # Timeout plus long (0.2s) pour les connexions SSH/mosh lentes.
        IFS= read -rs -t 0.2 -n2 _rest </dev/tty 2>/dev/null || _rest=""
        case "$_rest" in
          '[A'|'OA') ((_cursor > 0)) && ((_cursor--)) ;;   # ↑
          '[B'|'OB') ((_cursor < _total - 1)) && ((_cursor++)) ;;  # ↓
          '')        return 1 ;;   # Esc = cancel
          *)         ;;            # ignore séquence inconnue
        esac
        ;;
      $'\n'|$'\r'|"")
        if ((_cursor < _n)); then
          _state[_cursor]=$(( 1 - _state[_cursor] ))   # toggle option
        elif ((_cursor == _n)); then
          break   # Lancer
        else
          return 1   # Annuler
        fi
        ;;
    esac
  done

  local -a _cmd_args=()
  for ((_i=0; _i<_n; _i++)); do
    ((_state[_i])) && _cmd_args+=("${OLLAMA_OPTS[_i]}")
  done
  run ollama launch claude --model "$model" "${_cmd_args[@]}"
}

option_menu "$model"

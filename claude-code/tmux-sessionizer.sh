#!/usr/bin/env bash
#
# tmux-sessionizer.sh — menu de sessions tmux pour le téléphone (thin client).
#
# Déclenché par les fonctions `pc` / `pcm` du bashrc Termux :
#   pc  -> ssh  -t desktop  "~/dev/dev-environment/claude-code/tmux-sessionizer.sh"
#   pcm -> mosh   desktop -- bash -lc "~/dev/.../tmux-sessionizer.sh"
#
# Affiche un menu fzf qui fusionne, en une seule liste :
#   ● sessions tmux DÉJÀ actives   -> on s'y rattache (attach)
#   ○ projets ~/dev sans session   -> crée la session DANS le bon dossier
#   ◆ vaults Obsidian              -> crée la session DANS le vault
#   ＋ nouveau (nom libre)          -> crée une session ad hoc
#
# À la CRÉATION, lance `env -u TMUX claude` :
#   - `env -u TMUX` car Claude Code se rabaisse en 256 couleurs dès qu'il voit
#     $TMUX (cf. ~/.tmux.conf + mémoire claude-truecolor-tmux). Le wrapper bash
#     claude() ne s'applique pas ici (commande directe, pas de shell interactif)
#     -> on reproduit le `env -u TMUX` à la main.
#   - `; exec bash` derrière : quand Claude quitte, on retombe sur un shell au
#     lieu de fermer la session.
#
# Hooks de debug (sans effet en usage normal) :
#   --list        : imprime le menu généré puis sort
#   PC_PICK=<tsv> : court-circuite fzf avec un choix forcé (type<TAB>name<TAB>label)
#   PC_DRYRUN=1   : imprime la commande tmux au lieu de l'exécuter
#
set -euo pipefail

DEV_DIR="${PC_DEV_DIR:-$HOME/dev}"
VAULTS_DIR="${PC_VAULTS_DIR:-/mnt/c/obsidian-vaults}"

# fzf : binaire local (installé sans sudo dans ~/.fzf/bin), repli sur le PATH.
FZF="$HOME/.fzf/bin/fzf"
[[ -x "$FZF" ]] || FZF="$(command -v fzf 2>/dev/null || true)"

# --- collecte ------------------------------------------------------------
actives=()
mapfile -t actives < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort || true)

projects=()
mapfile -t projects < <(find "$DEV_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true)

# vaults Obsidian = sous-dossiers de VAULTS_DIR qui contiennent un .obsidian/
# (c'est ce qui distingue un vrai vault d'un simple dossier).
vaults=()
mapfile -t vaults < <(find "$VAULTS_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -d '{}/.obsidian' ';' -printf '%f\n' 2>/dev/null | sort || true)

# couleurs ANSI (interprétées par fzf --ansi)
G=$'\e[32m'; D=$'\e[90m'; R=$'\e[0m'; M=$'\e[35m'

# --- menu (TSV : type <TAB> name <TAB> label affiché) --------------------
build_menu() {
  local s p v has
  for s in "${actives[@]}"; do
    printf 'active\t%s\t%s● %s%s  %s(active)%s\n' "$s" "$G" "$s" "$R" "$D" "$R"
  done
  for p in "${projects[@]}"; do
    has=0
    for s in "${actives[@]}"; do [[ "$s" == "$p" ]] && { has=1; break; }; done
    (( has )) || printf 'project\t%s\t%s○%s %s\n' "$p" "$D" "$R" "$p"
  done
  for v in "${vaults[@]}"; do
    has=0
    for s in "${actives[@]}"; do [[ "$s" == "$v" ]] && { has=1; break; }; done
    (( has )) || printf 'vault\t%s\t%s◆%s %s %s(vault)%s\n' "$v" "$M" "$R" "$v" "$D" "$R"
  done
  printf 'new\t\t%s＋ nouveau (nom libre)%s\n' "$G" "$R"
}

[[ "${1:-}" == "--list" ]] && { build_menu; exit 0; }

# --- sélection -----------------------------------------------------------
if [[ -n "${PC_PICK:-}" ]]; then
  choice="$PC_PICK"
else
  [[ -x "$FZF" ]] || { echo "fzf introuvable (~/.fzf/bin/fzf) — lance: ~/.fzf/install --bin" >&2; exit 1; }
  # --with-nth=3 : on n'AFFICHE que le label (champ 3), qui contient déjà le nom
  # -> la frappe filtre sur ce qu'on voit (WYSIWYG). Pas de --nth : fzf réécrit
  # la ligne avant d'appliquer --nth, donc --nth=2,3 chercherait des champs
  # disparus -> zéro match. La VALEUR retournée reste la ligne d'origine (3 champs).
  choice="$(build_menu | "$FZF" \
      --ansi --delimiter=$'\t' --with-nth=3 \
      --layout=reverse --no-multi \
      --prompt='pc ❯ ' \
      --header='↑↓ choisir · tape = filtrer · Entrée = ouvrir · Échap = annuler' \
    )" || exit 0
fi
[[ -z "$choice" ]] && exit 0

type="$(cut -f1 <<<"$choice")"
name="$(cut -f2 <<<"$choice")"

# --- action --------------------------------------------------------------
run() { if [[ -n "${PC_DRYRUN:-}" ]]; then printf 'DRYRUN: '; printf '%q ' "$@"; echo; else exec "$@"; fi; }

case "$type" in
  active)
    run tmux attach-session -t "$name"
    ;;
  project)
    run tmux new-session -A -s "$name" -c "$DEV_DIR/$name" "env -u TMUX claude; exec bash"
    ;;
  vault)
    run tmux new-session -A -s "$name" -c "$VAULTS_DIR/$name" "env -u TMUX claude; exec bash"
    ;;
  new)
    if [[ -z "$name" ]]; then
      read -rp "Nom de la session : " name || exit 0   # Ctrl-D = annule proprement
      [[ -z "$name" ]] && exit 0
    fi
    [[ -d "$DEV_DIR/$name" ]] && start="$DEV_DIR/$name" || start="$HOME"
    run tmux new-session -A -s "$name" -c "$start" "env -u TMUX claude; exec bash"
    ;;
  *)
    echo "choix non reconnu : $type" >&2; exit 1
    ;;
esac

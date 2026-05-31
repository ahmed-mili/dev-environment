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
G=$'\e[32m'; D=$'\e[90m'; R=$'\e[0m'; M=$'\e[38;5;141m'   # M = violet (vaults Obsidian)

# Dédup : on ne montre un projet/vault que s'il n'a pas déjà une session active.
# (On calcule les listes affichées ici pour connaître aussi les POSITIONS, dont
# se servent les binds de navigation fzf plus bas.)
in_actives() { local x="$1" s; for s in "${actives[@]}"; do [[ "$s" == "$x" ]] && return 0; done; return 1; }
shown_projects=(); for _x in "${projects[@]}"; do in_actives "$_x" || shown_projects+=("$_x"); done
shown_vaults=();   for _x in "${vaults[@]}";   do in_actives "$_x" || shown_vaults+=("$_x"); done
n_active=${#actives[@]}; n_proj=${#shown_projects[@]}; n_vault=${#shown_vaults[@]}

# --- menu (TSV : type <TAB> name <TAB> label affiché) --------------------
build_menu() {
  local s p v
  for s in "${actives[@]}"; do
    printf 'active\t%s\t%s● %s%s  %s(active)%s\n' "$s" "$G" "$s" "$R" "$D" "$R"
  done
  for p in "${shown_projects[@]}"; do
    printf 'project\t%s\t%s○%s %s\n' "$p" "$D" "$R" "$p"
  done
  # vaults Obsidian : leur propre section, sous un séparateur, items en ○ normal.
  if (( n_vault )); then
    # type 'sep' : ligne décorative ; les flèches la sautent (binds), et un clic
    # dessus rouvre le menu (dispatch 'sep') — on ne peut donc pas la "choisir".
    printf 'sep\t\t%s──────  %s◆ Obsidian Vaults%s  ──────%s\n' "$D" "$M" "$D" "$R"
    for v in "${shown_vaults[@]}"; do
      printf 'vault\t%s\t%s○%s %s\n' "$v" "$M" "$R" "$v"
    done
  fi
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
  # Navigation : sauter le séparateur (down/up) et basculer projets ⇄ vaults (Tab).
  # Positions 1-based (layout reverse, liste NON filtrée) :
  #   [sessions 1..n_active] [projets ..] [sep] [vaults ..] [nouveau]
  # Le garde `[ -z {q} ]` désactive saut/bascule dès qu'un filtre est tapé : une
  # fois la liste filtrée, ces positions absolues ne veulent plus rien dire.
  nav=(); hdr='↑↓ choisir · tape = filtrer · Entrée = ouvrir · Échap = annuler'
  if (( n_vault )); then
    sep=$(( n_active + n_proj + 1 )); vfirst=$(( sep + 1 ))
    nav=(
      --bind "down:transform:[ -z {q} ] && [ \$((FZF_POS+1)) -eq $sep ] && echo down+down || echo down"
      --bind "up:transform:[ -z {q} ] && [ \$((FZF_POS-1)) -eq $sep ] && echo up+up || echo up"
      --bind "tab:transform:[ -n {q} ] && echo ignore || ( [ \$FZF_POS -lt $vfirst ] && echo 'pos($vfirst)' || echo 'pos(1)' )"
    )
    hdr='↑↓ choisir · Tab = projets ⇄ vaults · tape = filtrer · Entrée = ouvrir'
  fi
  # --color=pointer:green : sans ça, fzf colore son pointeur (le ▌ de la ligne
  # courante) en rose-rouge (couleur 161 de son thème par défaut) — la SEULE
  # couleur hors de la palette du menu (vert/violet/gris). On le ramène au vert
  # des sessions actives/＋ : reste distinct sur toutes les lignes (y compris les
  # vaults en violet, où un pointeur violet se fondrait dans le ○).
  choice="$(build_menu | "$FZF" \
      --ansi --delimiter=$'\t' --with-nth=3 \
      --layout=reverse --no-multi \
      --color=pointer:green \
      --prompt='pc ❯ ' \
      --header="$hdr" \
      "${nav[@]}" \
    )" || exit 0
fi
[[ -z "$choice" ]] && exit 0

type="$(cut -f1 <<<"$choice")"
name="$(cut -f2 <<<"$choice")"

# --- action --------------------------------------------------------------
# Commande lancée dans le pane à la création : `env -u TMUX` rend le truecolor à
# Claude (il se rabaisse en 256 couleurs s'il voit $TMUX) ; `exec bash` → on
# retombe sur un shell quand Claude quitte, au lieu de fermer la session.
CLAUDE_CMD='env -u TMUX claude; exec bash'

# run  : DERNIÈRE commande — `exec` (remplace le process) ; en PC_DRYRUN, imprime.
# step : commande de PRÉPARATION — exécute sans `exec` ; en PC_DRYRUN, imprime.
run()  { if [[ -n "${PC_DRYRUN:-}" ]]; then printf 'DRYRUN: '; printf '%q ' "$@"; echo; else exec "$@"; fi; }
step() { if [[ -n "${PC_DRYRUN:-}" ]]; then printf 'DRYRUN: '; printf '%q ' "$@"; echo; else "$@"; fi; }

# Rejoindre une session DÉJÀ active. Dans tmux, `attach` est interdit (nesting) →
# `switch-client` ; hors tmux → `attach`.
attach_session() {  # $1 = nom de session
  if [[ -n "${TMUX:-}" ]]; then run tmux switch-client  -t "$1"
  else                          run tmux attach-session -t "$1"; fi
}

# Créer (ou rejoindre si déjà là) une session dans $2. Hors tmux : `new-session -A`
# (attach-or-create) en une fois. Dans tmux : on ne peut pas attach → créer détaché
# (idempotent : `|| true` si la session existe déjà) puis `switch-client`.
create_session() {  # $1 = nom   $2 = dossier de départ
  if [[ -n "${TMUX:-}" ]]; then
    step tmux new-session -d -s "$1" -c "$2" "$CLAUDE_CMD" || true
    run  tmux switch-client -t "$1"
  else
    run tmux new-session -A -s "$1" -c "$2" "$CLAUDE_CMD"
  fi
}

case "$type" in
  sep)
    [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0   # pas de boucle en mode test
    exec "$0"                                          # séparateur : rouvre le menu
    ;;
  active)
    attach_session "$name"
    ;;
  project)
    create_session "$name" "$DEV_DIR/$name"
    ;;
  vault)
    create_session "$name" "$VAULTS_DIR/$name"
    ;;
  new)
    if [[ -z "$name" ]]; then
      read -rp "Nom de la session : " name || exit 0   # Ctrl-D = annule proprement
      [[ -z "$name" ]] && exit 0
    fi
    [[ -d "$DEV_DIR/$name" ]] && start="$DEV_DIR/$name" || start="$HOME"
    create_session "$name" "$start"
    ;;
  *)
    echo "choix non reconnu : $type" >&2; exit 1
    ;;
esac

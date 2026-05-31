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
#   ◆ vaults Obsidian              -> PowerShell natif dans le vault (voir plus bas)
#   ＋ nouveau (nom libre)          -> crée une session ad hoc
#
# À la CRÉATION (projets / new), ouvre juste un shell (bash interactif) dans le bon
# dossier — PAS de `claude` auto : l'user le lance lui-même pour choisir ses options
# (--resume, --model, etc.). Le wrapper claude() du ~/.bashrc fait alors le
# `env -u TMUX` qui rend le truecolor à Claude (il se rabaisse en 256 couleurs
# s'il voit $TMUX ; cf. ~/.tmux.conf + mémoire claude-truecolor-tmux).
#
# CAS À PART — vaults Obsidian : ils vivent sur C: (NTFS), où l'I/O natif Windows
# est ~7,5× plus rapide que via /mnt/c depuis WSL (cf. mémoire
# feedback_claude-side-matches-filesystem) -> on ouvre un PowerShell natif, pas bash :
#   - desktop (F2)  : nouvel onglet Windows Terminal (`wt.exe -w 0 nt`, pwsh natif)
#   - tél (pc/ssh)  : `pwsh.exe` dans un pane tmux (seul affichage joignable à distance)
# Détection via SSH_CONNECTION (is_remote). L'user tape `claude` (sa config PowerShell).
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

# Chaque projet/vault reste à SA place dans sa section ; s'il a une session active
# du même nom, on le marque ● (active) au lieu de le déplacer en haut. Helpers
# d'appartenance.
in_list()   { local x="$1"; shift; local e; for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done; return 1; }
is_active() { in_list "$1" "${actives[@]}"; }

# Orphelines = sessions actives qui ne sont NI un projet NI un vault (typiquement
# créées via «＋ nouveau»). Sans section propre -> petite zone en tête de menu.
orphans=()
for _s in "${actives[@]}"; do
  in_list "$_s" "${projects[@]}" || in_list "$_s" "${vaults[@]}" || orphans+=("$_s")
done

# Compteurs pour les POSITIONS des binds de navigation fzf (plus bas).
n_orphan=${#orphans[@]}; n_proj=${#projects[@]}; n_vault=${#vaults[@]}

# --- menu (TSV : type <TAB> name <TAB> label affiché) --------------------
build_menu() {
  local s p v
  # 1) sessions orphelines (ni projet ni vault) — pas de section, en tête
  for s in "${orphans[@]}"; do
    printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$s" "$G" "$R" "$s" "$G" "$R"
  done
  # 2) projets ~/dev : section propre sous un titre « ◆ Projects » (texte clair sur
  #    tirets gris) ; chacun à SA place ; actif -> ● (active), sinon ○ gris.
  if (( n_proj )); then
    printf 'sep\t\t%s──────  %s◆ Projects%s  ──────%s\n' "$D" "$R" "$D" "$R"
    for p in "${projects[@]}"; do
      if is_active "$p"; then
        printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$p" "$G" "$R" "$p" "$G" "$R"
      else
        printf 'project\t%s\t%s○%s %s\n' "$p" "$D" "$R" "$p"
      fi
    done
  fi
  # 3) vaults Obsidian : leur propre section sous un séparateur ; même règle d'actif.
  if (( n_vault )); then
    # type 'sep' : ligne décorative ; les flèches la sautent (binds), et un clic
    # dessus rouvre le menu (dispatch 'sep') — on ne peut donc pas la "choisir".
    printf 'sep\t\t%s──────  %s◆ Obsidian Vaults%s  ──────%s\n' "$D" "$M" "$D" "$R"
    for v in "${vaults[@]}"; do
      if is_active "$v"; then
        printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$v" "$G" "$R" "$v" "$G" "$R"
      else
        printf 'vault\t%s\t%s○%s %s\n' "$v" "$M" "$R" "$v"
      fi
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
  # Navigation : sauter les titres « ◆ … » (↑↓) et basculer projets ⇄ vaults (Tab).
  # Positions 1-based (layout reverse, liste NON filtrée) :
  #   [orphelines 1..n_orphan] [« ◆ Projects »] [projets ..] [« ◆ Vaults »] [vaults ..] [nouveau]
  # psep/vsep = lignes-titres (sautées) ; pfirst/vfirst = 1er item de chaque section ;
  # cursor0 = 1er item SÉLECTIONNABLE (où démarre le curseur — jamais sur un titre).
  # Le garde `[ -z {q} ]` désactive saut/bascule dès qu'un filtre est tapé : une fois
  # la liste filtrée, ces positions absolues ne veulent plus rien dire.
  nav=(); hdr='↑↓ choisir · tape = filtrer · Entrée = ouvrir · Échap = annuler'
  psep=0; vsep=0; pfirst=0; vfirst=0
  (( n_proj ))  && { psep=$(( n_orphan + 1 )); pfirst=$(( psep + 1 )); }
  (( n_vault )) && { vsep=$(( n_orphan + (n_proj ? n_proj + 1 : 0) + 1 )); vfirst=$(( vsep + 1 )); }
  if   (( n_orphan )); then cursor0=1
  elif (( n_proj ));   then cursor0=$pfirst
  elif (( n_vault ));  then cursor0=$vfirst
  else                      cursor0=1; fi
  if (( psep || vsep )); then
    nav=(
      --bind "load:pos($cursor0)"
      --bind "down:transform:[ -z {q} ] && { [ \$((FZF_POS+1)) -eq $psep ] || [ \$((FZF_POS+1)) -eq $vsep ]; } && echo down+down || echo down"
      --bind "up:transform:[ -z {q} ] || { echo up; exit 0; }; p=\$((FZF_POS-1)); if [ $psep -gt 0 ] && [ \$p -eq $psep ]; then [ $psep -eq 1 ] && echo ignore || echo up+up; elif [ $vsep -gt 0 ] && [ \$p -eq $vsep ]; then echo up+up; else echo up; fi"
    )
    if (( n_proj && n_vault )); then
      nav+=( --bind "tab:transform:[ -n {q} ] && echo ignore || ( [ \$FZF_POS -lt $vfirst ] && echo 'pos($vfirst)' || echo 'pos($pfirst)' )" )
      hdr='↑↓ choisir · Tab = projets ⇄ vaults · tape = filtrer · Entrée = ouvrir'
    fi
  fi
  # --color=pointer:8 : par défaut fzf peint son pointeur (le ▌ de la ligne
  # courante) en rose-rouge (couleur 161), seule couleur hors palette
  # (vert/violet/gris). On le met en gris neutre (8 = le $D des ○)
  # pour qu'il lise comme un pur curseur ; le TYPE est déjà porté par la pastille
  # colorée à sa droite (● vert / ○ gris / ○ violet).
  # NB : un pointeur "caméléon" (couleur selon l'item visé) est IMPOSSIBLE dans
  # fzf — --color=pointer est global, aucune action change-color n'existe, et
  # l'ANSI dans le pointeur est rejeté (largeur uniseg ≤ 2). Vérifié dans le
  # source 0.73.1 (terminal.go:7952, options.go:3605). Ne pas retenter.
  choice="$(build_menu | "$FZF" \
      --ansi --delimiter=$'\t' --with-nth=3 \
      --layout=reverse --no-multi \
      --color=pointer:8 \
      --prompt='pc ❯ ' \
      --header="$hdr" \
      "${nav[@]}" \
    )" || exit 0
fi
[[ -z "$choice" ]] && exit 0

type="$(cut -f1 <<<"$choice")"
name="$(cut -f2 <<<"$choice")"

# --- action --------------------------------------------------------------
# À la création on n'injecte AUCUNE commande : tmux ouvre le shell par défaut
# (bash interactif), qui source ~/.bashrc → le wrapper claude() est dispo. L'user
# tape `claude` lui-même quand il veut, avec les options qu'il veut. Le wrapper
# fait le `env -u TMUX` qui rend le truecolor (cf. mémoire claude-truecolor-tmux).

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
# $3 = commande optionnelle lancée dans la session (string passée à sh -c par tmux) ;
# absente -> tmux ouvre le shell par défaut (bash interactif). Sert au vault distant
# qui lance `pwsh.exe` au lieu du shell.
create_session() {  # $1 = nom   $2 = dossier   $3 = commande (optionnel)
  if [[ -n "${TMUX:-}" ]]; then
    step tmux new-session -d -s "$1" -c "$2" ${3:+"$3"} || true
    run  tmux switch-client -t "$1"
  else
    run tmux new-session -A -s "$1" -c "$2" ${3:+"$3"}
  fi
}

# is_remote : suis-je lancé depuis le tél (via `pc` = `ssh -t desktop …`) plutôt que
# depuis le desktop physique (F2 / ble.sh) ? ssh exporte SSH_CONNECTION ; F2 ne l'a
# pas. Sert à choisir le rendu d'un vault Obsidian : onglet Windows Terminal natif
# (desktop, GUI visible) vs pwsh dans un pane tmux (tél, seul affichage joignable).
is_remote() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; }

# open_wt_pwsh : ouvre un vault dans un NOUVEL ONGLET Windows Terminal (fenêtre
# courante, `-w 0 nt`), via le PROFIL nommé « PowerShell » (`-p`) et NON l'exe brut.
# `-p` applique tout le profil (titre « PowerShell » + icône + couleurs + police) ;
# passer `pwsh.exe` en commande donnait un onglet « pwsh.exe » à icône générique.
# `-d` force le dossier de départ vers le vault (chemin Windows via wslpath), en
# surchargeant le startingDirectory du profil. Process Windows natif = I/O natif
# sur C: (cf. mémoire feedback_claude-side-matches-filesystem) ; l'user y tape `claude`.
open_wt_pwsh() {  # $1 = dossier WSL du vault
  run wt.exe -w 0 nt -p "PowerShell" -d "$(wslpath -w "$1")"
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
    # Vault Obsidian = sur C: (NTFS) → on veut du PowerShell natif Windows.
    #   desktop (F2)  : onglet Windows Terminal natif (GUI visible localement)
    #   tél (pc/ssh)  : pwsh dans un pane tmux (seul affichage joignable à distance)
    if is_remote; then create_session "$name" "$VAULTS_DIR/$name" "pwsh.exe -NoLogo"
    else               open_wt_pwsh "$VAULTS_DIR/$name"; fi
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

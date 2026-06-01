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
#   - tél (pc/ssh)  : ce menu ne peut PAS l'ouvrir (hop WSL→Windows cassé par un bug WSL
#                     mirrored) -> rappel d'utiliser la commande `vault` (ssh direct du tél
#                     vers le sshd Windows). Cf. plan vault-native-pwsh-ssh.
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

# VUE (PC_VIEW) — même menu, périmètre différent, posé par les fonctions du tél.
# On partitionne par MONDE (côté du filesystem / où ça tourne le mieux), pas par type :
#   all (défaut, F2 desktop) : tout — sessions + projets + vaults
#   wsl (`wsl`, ex-`pc`)     : monde Linux/ext4 — sessions tmux + projets ~/dev, SANS vaults
#   ps  (`pwsh`, ex-`obs`)   : monde Windows/C: en pwsh natif — vaults Obsidian (extensible
#                              à tout dossier C: mieux en PowerShell). Aucun n'est une session tmux.
# On élague les tableaux ICI, en amont du calcul des positions/sections → tout le
# reste (navigation fzf, build_menu, dispatch) marche sans aucune autre modif.
case "${PC_VIEW:-all}" in
  wsl) vaults=() ;;                  # wsl : pas de vaults
  ps)  actives=(); projects=() ;;   # ps  : que les trucs C: (aucun n'est une session tmux)
esac

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
  # type 'sep' = titre décoratif : les flèches le sautent (binds), un clic dessus
  # rouvre le menu (dispatch 'sep') -> non sélectionnable.
  # 1) sessions hors-catégorie (ni projet ~/dev ni vault) sous un titre « ◆ Sessions ».
  if (( n_orphan )); then
    printf 'sep\t\t%s──────  %s◆ Sessions%s  ──────%s\n' "$D" "$R" "$D" "$R"
    for s in "${orphans[@]}"; do
      printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$s" "$G" "$R" "$s" "$G" "$R"
    done
  fi
  # 2) projets ~/dev sous « ◆ Projects » (texte clair sur tirets gris) ; chacun à SA
  #    place ; actif -> ● (active), sinon ○ gris.
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
  # 3) vaults Obsidian sous « ◆ Obsidian Vaults » (violet) ; même règle d'actif.
  if (( n_vault )); then
    printf 'sep\t\t%s──────  %s◆ Obsidian Vaults%s  ──────%s\n' "$D" "$M" "$D" "$R"
    for v in "${vaults[@]}"; do
      if is_active "$v"; then
        printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$v" "$G" "$R" "$v" "$G" "$R"
      else
        printf 'vault\t%s\t%s○%s %s\n' "$v" "$M" "$R" "$v"
      fi
    done
  fi
  # Plus de ligne « ＋ nouveau » : la création passe par le raccourci Ctrl-N
  # (--expect=ctrl-n + prompt) — cf. bloc « sélection » plus bas.
}

[[ "${1:-}" == "--list" ]] && { build_menu; exit 0; }

# --- sélection -----------------------------------------------------------
if [[ -n "${PC_PICK:-}" ]]; then
  key="${PC_KEY:-}"; choice="$PC_PICK"
else
  [[ -x "$FZF" ]] || { echo "fzf not found (~/.fzf/bin/fzf) — run: ~/.fzf/install --bin" >&2; exit 1; }
  # --with-nth=3 : on n'AFFICHE que le label (champ 3), qui contient déjà le nom
  # -> la frappe filtre sur ce qu'on voit (WYSIWYG). Pas de --nth : fzf réécrit
  # la ligne avant d'appliquer --nth, donc --nth=2,3 chercherait des champs
  # disparus -> zéro match. La VALEUR retournée reste la ligne d'origine (3 champs).
  # Navigation : sauter les titres « ◆ … » (↑↓), basculer projets ⇄ vaults (Tab),
  # créer une session (Ctrl-N, via --expect plus bas).
  # Positions 1-based (layout reverse, liste NON filtrée) :
  #   [« ◆ Sessions »] [orphelines ..] [« ◆ Projects »] [projets ..] [« ◆ Vaults »] [vaults ..]
  # ssep/psep/vsep = lignes-titres ; pfirst/vfirst = 1er item projet/vault ;
  # cursor0 = 1er item SÉLECTIONNABLE (où démarre le curseur — jamais sur un titre) ;
  # $seps = positions de TOUS les titres présents (les ↑↓ les enjambent, via `case`).
  # Le garde `[ -z {q} ]` désactive saut/bascule dès qu'un filtre est tapé : une fois
  # la liste filtrée, ces positions absolues ne veulent plus rien dire.
  # Aide : header minimal « ^G commandes » TOUJOURS visible ; Ctrl-G le bascule
  # avec la liste COMPLÈTE (hdr_full).
  nav=(); hdr_min='Ctrl+G  help'
  hdr_full='↑↓ navigate · ⏎ open · Ctrl+N new · Ctrl+R rename · Ctrl+X kill · Ctrl+G hide'
  ssep=0; psep=0; vsep=0; pfirst=0; vfirst=0; pos=0
  (( n_orphan )) && { ssep=$(( pos + 1 )); pos=$(( pos + 1 + n_orphan )); }
  (( n_proj ))   && { psep=$(( pos + 1 )); pfirst=$(( psep + 1 )); pos=$(( pos + 1 + n_proj )); }
  (( n_vault ))  && { vsep=$(( pos + 1 )); vfirst=$(( vsep + 1 )); pos=$(( pos + 1 + n_vault )); }
  if   (( n_orphan )); then cursor0=$(( ssep + 1 ))
  elif (( n_proj ));   then cursor0=$pfirst
  elif (( n_vault ));  then cursor0=$vfirst
  else                      cursor0=1; fi
  seps=""
  (( ssep )) && seps="$seps $ssep"
  (( psep )) && seps="$seps $psep"
  (( vsep )) && seps="$seps $vsep"
  if (( ssep || psep || vsep )); then
    nav+=(
      --bind "load:pos($cursor0)"
      --bind "down:transform:[ -z {q} ] || { echo down; exit 0; }; n=\$((FZF_POS+1)); case \" $seps \" in *\" \$n \"*) echo down+down;; *) echo down;; esac"
      --bind "up:transform:[ -z {q} ] || { echo up; exit 0; }; p=\$((FZF_POS-1)); case \" $seps \" in *\" \$p \"*) [ \$p -eq 1 ] && echo ignore || echo up+up;; *) echo up;; esac"
      # Souris : OUVERTURE au DOUBLE-clic ; le SIMPLE clic sert de « survol » (le hover
      # est impossible dans fzf — pas de tracking « all-motion » 1003) : il place le
      # curseur ▌ sur la ligne SANS ouvrir, on confirme au 2e clic.
      #
      # fzf place le curseur sur la ligne cliquée (t.vset) AVANT de lancer l'action
      # left-click / double-click (terminal.go:7848 et :7836) → \$FZF_POS = ligne cliquée.
      # Donc :
      #  - left-click sur un TITRE « ◆ … » ($seps) → on REBONDIT d'un cran (echo down)
      #    vers le 1er item de la section (un titre est toujours suivi d'≥1 item) : le
      #    curseur ne se pose JAMAIS sur un titre au clic, comme avec les flèches. C'est
      #    CE bind qui rend les titres non-sélectionnables. Sur un item → ignore (déjà
      #    positionné par t.vset).
      #  - double-click sur un item → accept (ouvre) ; sur un titre → REBOND (down) lui
      #    aussi, jamais d'ouverture : ainsi AUCUNE action souris ne laisse le curseur
      #    sur un titre (le 2e clic re-vset sur le titre, le down le ré-éjecte).
      # Binder left-click NE casse PAS le double-clic : chemins distincts (7833 vs 7842).
      # Filtre tapé ({q} non vide) : titres filtrés hors-liste → pas de test de position.
      --bind "left-click:transform:[ -n {q} ] && echo ignore || { case \" $seps \" in *\" \$FZF_POS \"*) echo down;; *) echo ignore;; esac; }"
      --bind "double-click:transform:[ -n {q} ] && echo accept || { case \" $seps \" in *\" \$FZF_POS \"*) echo down;; *) echo accept;; esac; }"
    )
    if (( n_proj && n_vault )); then
      nav+=( --bind "tab:transform:[ -n {q} ] && echo ignore || ( [ \$FZF_POS -lt $vfirst ] && echo 'pos($vfirst)' || echo 'pos($pfirst)' )" )
      # ↹ = U+21B9, symbole « touche Tab » à DEUX flèches. Absent de JetBrainsMono
      # Nerd Font mais rendu par la police de secours (bloc Unicode Arrows, comme ⇄).
      hdr_full='↑↓ navigate · ↹ switch category · ⏎ open · Ctrl+N new · Ctrl+R rename · Ctrl+X kill · Ctrl+G hide'
    fi
  fi
  # Aide togglable SANS jamais perdre l'indice : header minimal « ^G commandes »
  # par défaut, Ctrl-G bascule vers/depuis la liste complète. fzf n'ayant pas de
  # variable d'état, on mémorise min/full dans un fichier. ^G (pas ^H = Backspace).
  HSTATE="${TMPDIR:-/tmp}/.pc-sessionizer-hdr.$(id -u)"; printf min > "$HSTATE"
  nav+=( --bind "ctrl-g:transform-header:if [ \"\$(cat '$HSTATE' 2>/dev/null)\" = full ]; then printf min > '$HSTATE'; printf '%s' \"$hdr_min\"; else printf full > '$HSTATE'; printf '%s' \"$hdr_full\"; fi" )
  # --color=pointer:8 : par défaut fzf peint son pointeur (le ▌ de la ligne
  # courante) en rose-rouge (couleur 161), seule couleur hors palette
  # (vert/violet/gris). On le met en gris neutre (8 = le $D des ○)
  # pour qu'il lise comme un pur curseur ; le TYPE est déjà porté par la pastille
  # colorée à sa droite (● vert / ○ gris / ○ violet).
  # NB : un pointeur "caméléon" (couleur selon l'item visé) est IMPOSSIBLE dans
  # fzf — --color=pointer est global, aucune action change-color n'existe, et
  # l'ANSI dans le pointeur est rejeté (largeur uniseg ≤ 2). Vérifié dans le
  # source 0.73.1 (terminal.go:7952, options.go:3605). Ne pas retenter.
  # --expect : ces touches font quitter fzf en mettant la touche sur la 1re ligne de
  # sortie (vide pour Entrée), la sélection sur la 2e. ^N = créer, ^X = tuer,
  # ^R = renommer. (^G toggle l'aide SANS quitter fzf -> pas dans --expect.)
  out="$(build_menu | "$FZF" \
      --ansi --delimiter=$'\t' --with-nth=3 \
      --layout=reverse --no-multi \
      --color=pointer:8 \
      --prompt='pc ❯ ' \
      --header="$hdr_min" \
      --expect=ctrl-n,ctrl-x,ctrl-r \
      "${nav[@]}" \
    )" || exit 0
  key="$(sed -n '1p' <<<"$out")"
  choice="$(sed -n '2p' <<<"$out")"
fi

# Ctrl-N : on réutilise le flux de création « new » (prompt nom + create_session),
# sans ligne « ＋ nouveau » dans le menu.
if [[ "$key" == "ctrl-n" ]]; then
  type="new"; name=""
else
  [[ -z "$choice" ]] && exit 0
  type="$(cut -f1 <<<"$choice")"
  name="$(cut -f2 <<<"$choice")"
fi

# --- action --------------------------------------------------------------
# À la création on n'injecte AUCUNE commande : tmux ouvre le shell par défaut
# (bash interactif), qui source ~/.bashrc → le wrapper claude() est dispo. L'user
# tape `claude` lui-même quand il veut, avec les options qu'il veut. Le wrapper
# fait le `env -u TMUX` qui rend le truecolor (cf. mémoire claude-truecolor-tmux).

# run  : DERNIÈRE commande — `exec` (remplace le process) ; en PC_DRYRUN, imprime.
# step : commande de PRÉPARATION — exécute sans `exec` ; en PC_DRYRUN, imprime.
run()  { if [[ -n "${PC_DRYRUN:-}" ]]; then printf 'DRYRUN: '; printf '%q ' "$@"; echo; else exec "$@"; fi; }
step() { if [[ -n "${PC_DRYRUN:-}" ]]; then printf 'DRYRUN: '; printf '%q ' "$@"; echo; else "$@"; fi; }

# read_or_cancel : lit une saisie sur /dev/tty (fzf a rendu le terminal). Si la
# PREMIÈRE touche est Échap, ANNULE -> retourne 1 (pour abandonner un raccourci
# Ctrl-N/R/X déclenché par erreur). Sinon la saisie complète va dans $REPLY_OC.
# `-sn1` intercepte Échap AVANT tout écho ; le 1er caractère est ré-affiché à la
# main, puis on lit le reste de la ligne normalement.
read_or_cancel() {
  local first rest; REPLY_OC=""
  IFS= read -rsn1 first </dev/tty 2>/dev/null || return 1   # Ctrl-D / pas de tty
  [[ "$first" == $'\e' ]] && { echo >&2; return 1; }        # Échap -> annule
  [[ -z "$first" ]] && { echo >&2; return 0; }              # Entrée seule -> vide
  printf '%s' "$first" >&2
  IFS= read -r rest </dev/tty 2>/dev/null || rest=""
  REPLY_OC="$first$rest"
}

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
# absente -> tmux ouvre le shell par défaut (bash interactif).
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

# Méta-actions clavier (--expect) sur une session ACTIVE : Ctrl-X tuer, Ctrl-R
# renommer. Sans effet sur un projet/vault non démarré — on rouvre juste le menu
# pour refléter l'état. `read </dev/tty` car fzf a rendu le terminal.
case "$key" in
  ctrl-x)
    if [[ "$type" == "active" ]]; then
      # kill ≠ delete : une session-PROJET / vault SURVIT au kill (repasse en ○ inactif,
      # garde sa place dans le menu) car son dossier ancre encore la ligne ○ ; une session
      # JETABLE (nom libre, aucun dossier) DISPARAÎT du menu — rien où ancrer un ○. Le
      # prompt précise lequel des deux cas s'applique, pour éviter la surprise de la 1re.
      if in_list "$name" "${projects[@]}" || in_list "$name" "${vaults[@]}"; then
        printf "Kill '%s'? Stays listed as ○ inactive. [y/N] " "$name" >&2
      else
        printf "Kill '%s'? Disposable — disappears from the list. [y/N] " "$name" >&2
      fi
      # Échap (ou réponse ≠ y) -> pas de kill ; on rafraîchit juste le menu.
      if read_or_cancel && [[ "$REPLY_OC" == [yY]* ]]; then
        step tmux kill-session -t "$name"
      fi
    fi
    [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0   # pas de boucle en mode test
    exec "$0"                                          # rafraîchir le menu
    ;;
  ctrl-r)
    if [[ "$type" == "active" ]]; then
      printf "New name for '%s': " "$name" >&2
      # Échap (ou nom vide) -> pas de rename ; on rafraîchit le menu.
      if read_or_cancel && [[ -n "$REPLY_OC" ]]; then
        step tmux rename-session -t "$name" "$REPLY_OC"
      fi
    fi
    [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0
    exec "$0"
    ;;
esac

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
    # Vault Obsidian = sur C: (NTFS) → PowerShell natif Windows (I/O natif, cf. mémoire
    # feedback_claude-side-matches-filesystem).
    #   desktop (F2)  : onglet Windows Terminal natif (GUI visible localement)
    #   tél (pc/ssh)  : le sessionizer tourne dans WSL, et le hop WSL→Windows est CASSÉ par
    #     un bug WSL mirrored (127.0.0.1 détourné vers loopback0, handshake échoue) → ce menu
    #     ne peut PAS ouvrir un vault en pwsh natif lui-même. Mais le TÉL, lui, sait joindre
    #     Windows (ssh direct, cmd `vault`). Donc on DÉLÈGUE : on dépose le nom du vault choisi
    #     et on sort avec le code 42 ; pc()/pcm() (côté tél) interceptent ce 42 et lancent
    #     `vault <nom>` automatiquement → l'user choisit dans le menu et le vault s'ouvre, sans
    #     rien taper. Cf. docs/superpowers/plans/2026-06-01-vault-native-pwsh-ssh.md +
    #     mémoires reference_ssh-wsl-no-interop / reference_wsl-mirrored-loopback-broken.
    if is_remote; then
      req="${PC_VAULT_REQ:-$HOME/.cache/pc-vault-request}"
      mkdir -p "$(dirname "$req")" 2>/dev/null || true
      printf '%s\n' "$name" > "$req" 2>/dev/null || true
      [[ -n "${PC_DRYRUN:-}" ]] && { echo "DRYRUN: open vault '$name' client-side (a écrit \$req, sortirait 42)"; exit 0; }
      exit 42
    else
      open_wt_pwsh "$VAULTS_DIR/$name"
    fi
    ;;
  new)
    if [[ -z "$name" ]]; then
      printf 'Session name: ' >&2
      # Échap / saisie vide / Ctrl-D -> annule la création et revient au menu.
      if ! read_or_cancel || [[ -z "$REPLY_OC" ]]; then
        [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0
        exec "$0"
      fi
      name="$REPLY_OC"
    fi
    [[ -d "$DEV_DIR/$name" ]] && start="$DEV_DIR/$name" || start="$HOME"
    create_session "$name" "$start"
    ;;
  *)
    echo "unknown choice: $type" >&2; exit 1
    ;;
esac

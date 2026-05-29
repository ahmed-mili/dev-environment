#!/data/data/com.termux/files/usr/bin/bash
# install.sh — déploie les scripts Termux depuis le repo vers les bons endroits.
#
# Cible : un téléphone Android avec Termux + Termux:Boot + Termux:API installés
# (depuis F-Droid). Lance ce script DEPUIS le tél (Termux), pas depuis le desktop.
# Idempotent : safe à relancer après git pull, mise à jour, ou reset du tél.
#
# Comment l'amener sur le tél :
#   scp claude-code/termux/install.sh phone:~/install.sh    (depuis desktop)
#   ou : git clone https://github.com/ahmed-mili/dev-environment.git ~/dev-environment
#       puis ~/dev-environment/claude-code/termux/install.sh
#
# Mapping repo -> runtime :
#   boot-screenshot-watcher -> ~/.termux/boot/screenshot-watcher   (renommé!)
#   start-sshd              -> ~/.termux/boot/start-sshd
#   screenshot-watcher      -> ~/bin/screenshot-watcher
#   termux-file-editor      -> ~/bin/termux-file-editor
#   img2claude              -> ~/img2claude                         (home racine)
#
# Le shebang absolu /data/data/com.termux/files/usr/bin/bash est obligatoire :
# Termux:Boot ne charge pas termux-exec donc /usr/bin/env ne résoudrait pas.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_DIR="$HOME/.termux/boot"
BIN_DIR="$HOME/bin"

# Format : "<nom dans le repo>:<chemin dest absolu>"
DEPLOY_MAP=(
    "boot-screenshot-watcher:$BOOT_DIR/screenshot-watcher"
    "start-sshd:$BOOT_DIR/start-sshd"
    "screenshot-watcher:$BIN_DIR/screenshot-watcher"
    "termux-file-editor:$BIN_DIR/termux-file-editor"
    "watcher-toggle:$BIN_DIR/watcher-toggle"
    "img2claude:$HOME/img2claude"
)

say()  { printf '[install] %s\n' "$*"; }
ok()   { printf '[install] \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '[install] \033[33mWARN\033[0m %s\n' "$*"; }
die()  { printf '[install] \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d /data/data/com.termux ]] || die "Pas dans Termux. Lance ce script DEPUIS le tél (pas le desktop)."

# Crée les répertoires destination
mkdir -p "$BOOT_DIR" "$BIN_DIR"

# Déploiement
say "Déploiement repo -> runtime"
for entry in "${DEPLOY_MAP[@]}"; do
    src_name="${entry%%:*}"
    dst_path="${entry##*:}"
    src_path="$REPO_DIR/$src_name"
    [[ -f "$src_path" ]] || die "Manquant dans le repo : $src_name"
    cp -f "$src_path" "$dst_path"
    chmod +x "$dst_path"
    ok "$src_name -> $dst_path"
done

# Flux par défaut : CAPTURES et PHOTOS tous deux ON. Les flags sont des fichiers
# persistants dans $HOME (survivent aux reboots ET à un redéploiement de scripts,
# qui ne touche pas $HOME). On ne les (re)crée QUE s'ils sont absents -> idempotent :
# un `photos-off` (ou un `rm` du flag) explicite par l'user n'est PAS ré-écrasé à la
# prochaine exécution. Photos ON par défaut est sûr depuis qu'img2claude ne fait que
# STAGER (envoi = Alt+V manuel) -> aucune photo ne part toute seule dans Claude.
# Pour désactiver durablement les photos : `photos-off` (rm ~/.screenshot-watcher.photos).
say "Flux par défaut (captures + photos)"
[[ -e "$HOME/.screenshot-watcher.on" ]]     || { touch "$HOME/.screenshot-watcher.on";     ok "flux CAPTURES activé (défaut)"; }
[[ -e "$HOME/.screenshot-watcher.photos" ]] || { touch "$HOME/.screenshot-watcher.photos"; ok "flux PHOTOS activé (défaut)"; }

# Poste la notif-toggle tout de suite (point de controle des flux). Guarde : si
# termux-api absent, le script est un no-op et l'install continue.
"$BIN_DIR/watcher-toggle" show 2>/dev/null || true
ok "notif-toggle postee (si termux-api dispo)"

# Démarrage immédiat de sshd et screenshot-watcher (sans attendre reboot)
say "Démarrage immédiat des daemons (sans attendre reboot)"
if ! pgrep -x sshd >/dev/null 2>&1; then
    sshd && ok "sshd lancé" || warn "sshd n'a pas démarré (déjà actif ? port occupé ?)"
else
    ok "sshd déjà actif"
fi

if ! pgrep -f "$BOOT_DIR/screenshot-watcher" >/dev/null 2>&1; then
    nohup "$BOOT_DIR/screenshot-watcher" >/dev/null 2>&1 &
    ok "screenshot-watcher (supervisor) lancé en background"
else
    ok "screenshot-watcher (supervisor) déjà actif"
fi

# Vérifications finales
sleep 1
say "État final :"
echo "  Process screenshot-watcher :"
pgrep -af "screenshot-watcher" | sed 's/^/    /' || echo "    (aucun)"
echo "  Process sshd :"
pgrep -af "sshd" | sed 's/^/    /' || echo "    (aucun)"
echo "  ~/.termux/boot/ :"
ls -la "$BOOT_DIR" | sed 's/^/    /'

ok "Installation terminée."
echo
say "À vérifier MANUELLEMENT (le script ne peut pas) :"
echo "  1. Termux:Boot autorisé en autostart côté HyperOS :"
echo "     Réglages > Apps > Gérer les apps > Termux:Boot > Économiseur batterie = Sans restriction"
echo "     Réglages > Apps > Permissions > Autostart > activer pour Termux:Boot"
echo "  2. termux-wake-lock visible dans la notif Termux après reboot du tél"
echo "  3. ssh phone depuis le desktop fonctionne (port 8022 ouvert)"

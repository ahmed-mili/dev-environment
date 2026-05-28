#!/usr/bin/env bash
# install.sh — déploie le système clip-watcher depuis le repo vers le runtime.
#
# Cible : un desktop Windows + WSL Ubuntu où Claude Code tourne. Doit être lancé
# DEPUIS WSL (a besoin d'accéder à /mnt/c/Users/...). Idempotent : safe à
# relancer après un git pull, une réinstallation Windows, ou un reset WSL.
#
# Architecture d'autostart :
#   - Service systemd USER `clip-watcher.service` → géré par systemd-user
#   - `loginctl enable-linger` → le service démarre dès que la distro boot,
#     SANS attendre un terminal ouvert. C'est ce qui fait que le watcher
#     "survit au reboot sans action de l'user". Sans linger, le service
#     s'arrêterait à la fermeture du dernier terminal.
#
# Pourquoi PAS une Scheduled Task Windows + wsl.exe -- bash -c '...' :
#   Bug WSL confirmé 2026-05-28 — lorsque `wsl.exe -- cmd` termine, WSL kill
#   TOUS les enfants de la session (même nohup + disown). La tâche `ClipWatcher`
#   précédente retournait LastTaskResult=0 mais ne laissait aucun process vivant
#   (faux succès silencieux). On la déregistre.
#
# Démarrage effectif au logon Windows = Ubuntu.lnk dans Startup\ → wsl.exe -d
# Ubuntu → systemd init → user-session linger → clip-watcher.service → up.
#
# Désinstaller : systemctl --user disable --now clip-watcher.service

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_NAME='clip-watcher.service'
OLD_TASK_NAME='ClipWatcher'
OLD_WIN_BOOT_FILE='clip-watcher-boot.ps1'

LINUX_FILES=(
    clip-watcher.ps1
    clip-watcher-bridge
    clip-watcher-supervisor
    clip-watcher-start
)

say()  { printf '[install] %s\n' "$*"; }
ok()   { printf '[install] \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '[install] \033[33mWARN\033[0m %s\n' "$*"; }
die()  { printf '[install] \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d /mnt/c/Users ]] || die "Pas dans WSL (/mnt/c/Users absent). Lance ce script depuis WSL Ubuntu."

WIN_USER=$(/mnt/c/Windows/System32/cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n')
[[ -n "$WIN_USER" ]] || die "Impossible de déterminer l'utilisateur Windows."
WIN_HOME="/mnt/c/Users/$WIN_USER"
[[ -d "$WIN_HOME" ]] || die "Home Windows inexistant : $WIN_HOME"
say "Utilisateur Windows détecté : $WIN_USER"

# 1) Linux files -> ~/.local/bin/
say "Déploiement vers $LOCAL_BIN/"
mkdir -p "$LOCAL_BIN"
for f in "${LINUX_FILES[@]}"; do
    [[ -f "$REPO_DIR/$f" ]] || die "Manquant dans le repo : $f"
    cp -f "$REPO_DIR/$f" "$LOCAL_BIN/$f"
    chmod +x "$LOCAL_BIN/$f"
    ok "$f"
done

# 2) Cleanup ancien mécanisme (tâche Windows + .ps1 obsolète)
# La tâche `ClipWatcher` est cassée (bug WSL session-kill, cf. supra) — on la
# supprime pour éviter le faux sentiment de redondance. Idempotent : pas
# d'erreur si elle n'existe plus.
say "Cleanup ancienne tâche Windows \\$OLD_TASK_NAME (si présente)"
PS_CLEANUP=$(cat <<EOF_PS
\$ErrorActionPreference = 'SilentlyContinue'
if (Get-ScheduledTask -TaskName '$OLD_TASK_NAME' 2>\$null) {
    Unregister-ScheduledTask -TaskName '$OLD_TASK_NAME' -Confirm:\$false
    Write-Host "task-removed"
} else {
    Write-Host "task-absent"
}
Remove-Item -Path 'C:\\Users\\$WIN_USER\\$OLD_WIN_BOOT_FILE' -Force -ErrorAction SilentlyContinue
EOF_PS
)
CLEANUP_RES=$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "$PS_CLEANUP" 2>&1 | tr -d '\r')
case "$CLEANUP_RES" in
    *task-removed*) ok "tâche \\$OLD_TASK_NAME déregistrée + .ps1 supprimé" ;;
    *task-absent*)  ok "pas d'ancienne tâche à nettoyer" ;;
    *)              warn "cleanup output inattendu: $CLEANUP_RES" ;;
esac

# 3) Linger systemd-user (persistance sans terminal ouvert)
# Sans linger, systemd-user@ahmed s'arrête à la fermeture du dernier shell
# interactif → le service meurt. Avec linger, il tourne dès le boot de la
# distro. Confirmé 2026-05-28 : loginctl enable-linger accepte sans sudo
# (polkit autorise pour le user courant).
say "Activation linger systemd-user (autostart sans session)"
if [[ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" != "yes" ]]; then
    loginctl enable-linger "$USER" || die "loginctl enable-linger a échoué"
    ok "linger activé pour $USER"
else
    ok "linger déjà actif"
fi

# 4) Service systemd user
say "Déploiement service vers $SYSTEMD_USER_DIR/"
mkdir -p "$SYSTEMD_USER_DIR"
[[ -f "$REPO_DIR/$SERVICE_NAME" ]] || die "Manquant dans le repo : $SERVICE_NAME"
cp -f "$REPO_DIR/$SERVICE_NAME" "$SYSTEMD_USER_DIR/$SERVICE_NAME"
ok "$SERVICE_NAME"

# 5) Stoppe les vieux process clip-watcher (drift "code mémoire vs disque" après
# bump de version). On kill via les pid files pour éviter de matcher le shell
# courant qui contient 'clip-watcher' dans ses arguments (cf. piège pkill -f).
say "Arrêt des anciens process clip-watcher (si présents)"
systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
for pf in "$HOME/.clip-watcher.sup.pid" "$HOME/.clip-watcher.ps.pid" "$HOME/.clip-watcher.br.pid"; do
    [[ -f "$pf" ]] && p=$(cat "$pf" 2>/dev/null) && [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null || true
done
rm -f "$HOME"/.clip-watcher.{sup,ps,br}.pid
sleep 1

# 6) Reload + enable + start
say "systemctl --user daemon-reload && enable --now $SERVICE_NAME"
systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME" >/dev/null
ok "service activé et démarré"

# 7) Vérification finale
sleep 3
say "État final :"
systemctl --user is-active "$SERVICE_NAME" >/dev/null && ok "$SERVICE_NAME = active" || warn "$SERVICE_NAME = $(systemctl --user is-active "$SERVICE_NAME")"
systemctl --user is-enabled "$SERVICE_NAME" >/dev/null && ok "$SERVICE_NAME = enabled" || warn "$SERVICE_NAME = $(systemctl --user is-enabled "$SERVICE_NAME")"
ps -ef | awk '/[c]lip-watcher/ {printf "  PID %-6s  %s %s %s\n", $2, $8, $9, $10}' | head -5

ok "Installation terminée."
say "Test rapide : Win+Shift+S une capture, Alt+V dans Claude. Si bug, journalctl --user -u $SERVICE_NAME -f"

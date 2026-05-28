#!/usr/bin/env bash
# install.sh — déploie le système clip-watcher depuis le repo vers le runtime.
#
# Cible : un desktop Windows + WSL Ubuntu où Claude Code tourne. Doit être lancé
# DEPUIS WSL (a besoin d'accéder à /mnt/c/Users/...). Idempotent : safe à
# relancer après un git pull, une réinstallation Windows, ou un reset WSL.
#
# Ce qu'il fait :
#   1. Copie les 4 fichiers Linux dans ~/.local/bin/ (PS+bridge+supervisor+start)
#   2. Copie clip-watcher-boot.ps1 dans C:\Users\<winuser>\ (lu par Task Scheduler)
#   3. Enregistre ou met à jour la tâche \ClipWatcher (LogonTrigger user)
#   4. Lance le supervisor maintenant si pas déjà actif
#   5. Vérifie l'état final
#
# Désinstaller : voir uninstall.sh (à venir si besoin).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"
TASK_NAME='ClipWatcher'

LINUX_FILES=(
    clip-watcher.ps1
    clip-watcher-bridge
    clip-watcher-supervisor
    clip-watcher-start
)
WIN_BOOT_FILE='clip-watcher-boot.ps1'

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

# 2) Windows boot file -> C:\Users\<winuser>\
say "Déploiement vers $WIN_HOME/"
[[ -f "$REPO_DIR/$WIN_BOOT_FILE" ]] || die "Manquant dans le repo : $WIN_BOOT_FILE"
cp -f "$REPO_DIR/$WIN_BOOT_FILE" "$WIN_HOME/$WIN_BOOT_FILE"
ok "$WIN_BOOT_FILE -> C:\\Users\\$WIN_USER\\"

# 3) Task Scheduler : Register-ScheduledTask (.NET API, user-context, pas
# besoin d'admin). schtasks.exe /Create /F refuse "Accès refusé" même avec /F
# quand la tâche existe avec un principal différent — confirmé 2026-05-28.
# Le fichier .ps1 contient le PS — on l'invoque depuis bash via wslpath pour
# éviter la gymnastique d'échappement de backslashes au passage WSL→PowerShell.
say "Enregistrement de la tâche Windows \\$TASK_NAME (LogonTrigger user)"
WIN_BOOT_PATH="C:\\Users\\$WIN_USER\\$WIN_BOOT_FILE"
PS_REGISTER=$(cat <<EOF_PS
\$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -File ${WIN_BOOT_PATH}'
\$trigger = New-ScheduledTaskTrigger -AtLogOn -User "\$env:USERDOMAIN\\\$env:USERNAME"
\$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
\$principal = New-ScheduledTaskPrincipal -UserId "\$env:USERDOMAIN\\\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName '$TASK_NAME' -Action \$action -Trigger \$trigger -Settings \$settings -Principal \$principal -Description 'Auto-start Claude Code clipboard watcher (WSL Ubuntu)' -Force | Out-Null
EOF_PS
)
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "$PS_REGISTER" >/dev/null 2>&1 \
    && ok "tâche enregistrée/mise à jour (Register-ScheduledTask)" \
    || die "Register-ScheduledTask a échoué. Vérifie 'Get-ScheduledTask -TaskName $TASK_NAME' dans PowerShell."

# 4) Stoppe les vieux supervisors/PS/bridge AVANT de relancer
# Évite le drift "code-en-mémoire vs code-sur-disque" après une réinstall ou
# une bump de version. On kill -9 et on supprime les .pid files pour repartir
# clean. Le clip-watcher-start respawnera tout via le supervisor.
say "Arrêt des anciens process clip-watcher (si présents)"
pkill -9 -f 'clip-watcher-supervisor' 2>/dev/null || true
pkill -9 -f 'clip-watcher-bridge'     2>/dev/null || true
pkill -9 -f 'clip-watcher.ps1'        2>/dev/null || true
rm -f "$HOME/.clip-watcher.sup.pid" "$HOME/.clip-watcher.ps.pid" "$HOME/.clip-watcher.br.pid"
sleep 1

# 5) Lance le supervisor frais
say "Démarrage immédiat"
"$LOCAL_BIN/clip-watcher-start"
ok "clip-watcher-start invoqué"

# 6) Vérification finale
sleep 3
say "État final :"
ps -ef | grep -E 'clip-watcher' | grep -v grep | awk '{printf "  PID %-6s  %s\n", $2, $8" "$9" "$10}' || true
TASK_STATUS=$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "(Get-ScheduledTask -TaskName '$TASK_NAME').State" 2>/dev/null | tr -d '\r\n')
echo "  Task \\$TASK_NAME state: ${TASK_STATUS:-?}"

ok "Installation terminée."
say "Test rapide : Win+Shift+S une capture, Alt+V dans Claude. Si bug, tail -f ~/.clip-watcher.log"

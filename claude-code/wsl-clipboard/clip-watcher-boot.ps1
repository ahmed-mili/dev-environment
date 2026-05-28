# clip-watcher-boot.ps1 — lancé par Task Scheduler au démarrage de Windows.
# Démarre Ubuntu (WSL) silencieusement et lance le supervisor clip-watcher.
# Sans cette tâche, le watcher ne démarrerait qu'après ouverture d'un terminal.

# -d Ubuntu : force la distro spécifique (au cas où le défaut bouge)
# --cd ~     : démarre dans le home pour stabilité
# bash -c    : commande à exécuter dans Ubuntu

wsl.exe -d Ubuntu --cd ~ -- bash -c '$HOME/.local/bin/clip-watcher-start'

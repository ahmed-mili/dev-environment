# android/

Config Termux (Android) : bash, starship, fastfetch, hooks Claude Code, intégration SSH PC ↔ téléphone.

Migré depuis l'ancien repo [termux-config](https://github.com/ahmed-mili/termux-config) (archivé après cette fusion).

## Fichiers

| Fichier | Cible |
| --- | --- |
| `setup.sh` | Installer one-liner Termux |
| `bashrc` | `~/.bashrc` |
| `starship.toml` | `~/.config/starship.toml` |
| `fastfetch-config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| `termux.properties` | `~/.termux/termux.properties` |
| `colors.properties` | `~/.termux/colors.properties` |
| `pc-authorized_keys` | Clé publique SSH du PC à ajouter dans `~/.ssh/authorized_keys` |
| `auto-pull.sh` | Hook Claude Code SessionStart |
| `auto-push.sh` | Hook Claude Code SessionEnd |

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh | bash
```

> Le `setup.sh` clone le repo, copie les fichiers à leurs emplacements, installe les paquets Termux requis (bash, starship, fastfetch, git, openssh, etc.).

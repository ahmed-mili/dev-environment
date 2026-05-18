# android/

Config Termux (Android) : bash, starship, fastfetch, hooks Claude Code, intégration SSH PC ↔ téléphone.

## Fichiers

| Fichier | Cible |
| --- | --- |
| `setup.sh` | Installer one-liner Termux |
| `files/bashrc` | `~/.bashrc` |
| `files/starship.toml` | `~/.config/starship.toml` |
| `files/fastfetch-config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| `files/termux.properties` | `~/.termux/termux.properties` |
| `files/colors.properties` | `~/.termux/colors.properties` |
| `files/pc-authorized_keys` | Clé publique SSH du PC à ajouter dans `~/.ssh/authorized_keys` |
| `files/auto-pull.sh` | Hook Claude Code SessionStart |
| `files/auto-push.sh` | Hook Claude Code SessionEnd |

## Installation

```bash
curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; \
pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh)
```

> Le `setup.sh` clone le repo, copie les fichiers à leurs emplacements, installe les paquets Termux requis (bash, starship, fastfetch, git, openssh, etc.).
>
> Le préambule `dpkg -r libngtcp2-crypto-ossl` est un no-op sur un Termux sain — il ne se déclenche que sur les builds où la lib HTTP/3 a une ABI mismatch avec OpenSSL et casse `curl` (et `pkg install` au passage). Process-substitution `bash <(...)` plutôt que `curl ... | bash` parce que les prompts SSH/sshd/ollama du script ont besoin d'un stdin TTY.

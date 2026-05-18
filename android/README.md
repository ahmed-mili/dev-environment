# android/

Installer Termux générique : bash + Catppuccin Mocha, starship, fastfetch, Claude Code CLI, hooks auto-pull / auto-push sur `~/dev/`.

## Fichiers

| Fichier | Cible |
| --- | --- |
| `setup.sh` | Installer one-liner Termux |
| `files/bashrc` | `~/.bashrc` |
| `files/starship.toml` | `~/.config/starship.toml` |
| `files/fastfetch-config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| `files/termux.properties` | `~/.termux/termux.properties` |
| `files/colors.properties` | `~/.termux/colors.properties` |
| `files/auto-pull.sh` | Hook Claude Code SessionStart |
| `files/auto-push.sh` | Hook Claude Code SessionEnd |

## Installation

```bash
curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; \
pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh)
```

Le script installe les paquets requis, déploie les configs Catppuccin, génère une clé SSH ed25519, installe Claude Code via npm. Trois prompts opt-in : Ollama (gros download, par défaut non), sshd, Tailscale. Tout le reste est non-interactif.

À la fin tu te retrouves avec un `~/dev/` vide et Claude Code dispo : il ne te reste qu'à cloner les repos que tu veux.

> Le préambule `dpkg -r libngtcp2-crypto-ossl` est un no-op sur un Termux sain — il ne se déclenche que sur les builds où la lib HTTP/3 a une ABI mismatch avec OpenSSL et casse `curl` (et `pkg install` au passage). Process-substitution `bash <(...)` plutôt que `curl ... | bash` parce que les prompts sshd/Ollama et l'ajout de la clé SSH GitHub ont besoin d'un stdin TTY.

## Personnaliser après install

```bash
# Identité git (le script prompt aussi si manquante)
git config --global user.name  "Ton Nom"
git config --global user.email "ton@email"

# Cloner tes propres repos
mkdir -p ~/dev
for r in repo1 repo2 repo3; do
  git clone git@github.com:TON_USER/$r.git ~/dev/$r
done

# Si tu utilises sshd : ajouter ta pubkey PC
echo "ssh-ed25519 AAAA... ton-pc-comment" >> ~/.ssh/authorized_keys
```

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

Le script installe les paquets requis, déploie les configs Catppuccin, génère une clé SSH ed25519, installe Claude Code via npm. Deux prompts opt-in : sshd, Tailscale. Tout le reste est non-interactif.

À la fin tu te retrouves avec un `~/dev/` vide et Claude Code dispo : il ne te reste qu'à cloner les repos que tu veux.

> Le préambule `dpkg -r libngtcp2-crypto-ossl` est un no-op sur un Termux sain — il ne se déclenche que sur les builds où la lib HTTP/3 a une ABI mismatch avec OpenSSL et casse `curl` (et `pkg install` au passage). Process-substitution `bash <(...)` plutôt que `curl ... | bash` parce que les prompts sshd/Tailscale et l'ajout de la clé SSH GitHub ont besoin d'un stdin TTY.

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

## Workflow recommandé pour Claude Code

```bash
tmain                          # attache la session tmux "main" (la crée si absente)
cd ~/dev/mon-repo
claude                         # SessionStart hook auto-pull avant de te rendre la main
# travaille...
# Ctrl+B puis D                # detach — session continue en background
# ferme Termux, change d'app, verrouille l'écran : la session survit
# plus tard :
tmain                          # tu retrouves Claude exactement où tu l'as laissé
```

Le wake-lock est acquis automatiquement par `~/.bashrc.local` (libère avec `termux-wake-unlock` ou supprime la ligne).

## Maximiser les perfs sur Xiaomi / MIUI

Android tue agressivement les processus en background — surtout MIUI. Trois actions manuelles (1× par téléphone) qui rendent la différence visible :

**1. Exempter Termux de l'optim batterie**
Paramètres Android → Apps → Termux → Battery → "Sans restriction" / "Unrestricted".

**2. Désactiver le phantom process killer** (Xiaomi/Android 12+ tue tout enfant qui dépasse 32 processes)
Depuis un PC avec ADB :
```bash
adb shell "settings put global settings_enable_monitor_phantom_procs false"
adb shell "device_config put activity_manager max_phantom_processes 2147483647"
```
(Ces deux settings se remettent à zéro à chaque MAJ Android — re-appliquer si tmux/claude meurent.)

**3. Termux:Boot** (optionnel) — autostart tmux + sshd au démarrage du téléphone
Installer le APK Termux:Boot depuis F-Droid, puis :
```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
tmux new-session -d -s main
EOF
chmod +x ~/.termux/boot/start.sh
```

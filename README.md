# dev-environment

Configuration multi-plateforme pour mon flow Claude Code + Ollama sur **Windows** (PC) et **Android** (Termux). Un seul repo, un dossier par OS, plus un dossier pour les outils transverses.

## Structure

```
dev-environment/
├── windows/          # PC Windows : PowerShell 7, Windows Terminal, Fastfetch
│   ├── install.ps1   # one-liner installer
│   └── README.md
├── android/          # Android via Termux : bash, starship, fastfetch
│   ├── setup.sh
│   ├── bashrc, starship.toml, termux.properties, ...
│   └── README.md
├── claude-code/      # Config Claude Code (statusline + settings + hooks)
│   ├── statusline.ps1
│   ├── settings.json
│   ├── hooks/
│   └── README.md
├── ollama/           # Config Ollama (intégrations modèles cloud)
│   ├── config.json
│   └── README.md
└── LICENSE
```

## Installation

### Reproduire l'environnement complet sur une nouvelle machine

#### Windows
```powershell
# 1. Clone
git clone https://github.com/ahmed-mili/dev-environment.git C:\dev\dev-environment
cd C:\dev\dev-environment

# 2. Bundle Windows : winget (PowerShell 7, Terminal, fzf, zoxide, Nerd Font,
#    Fastfetch) + profil PS7 (PSReadLine, zoxide init, cd autocomplete C:\dev)
.\windows\install.ps1

# 3. Claude Code : statusline, settings, hooks auto-sync, 9 skills custom
.\claude-code\deploy.ps1 -Pull

# 4. Plugins marketplace : ouvrir Claude Code, lancer `/plugin`,
#    installer depuis `claude-plugins-official` :
#      - frontend-design
#      - code-review
#      - superpowers
```

Après ça, `git pull` à l'arrivée sur une machine + `git push` au départ (automatisé via les hooks auto-sync) maintient la sync entre tes machines.

#### Android (Termux)
```bash
curl -fsSL https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh | bash

# Config Claude Code (équivalents bash des hooks PS à produire — TODO)
mkdir -p ~/.claude/hooks
cp claude-code/settings.json ~/.claude/settings.json
```

### Bootstrap one-liner (Windows, sans clone)

Pour un PC où tu veux juste les paquets winget + profil PS7 sans cloner le repo :

```powershell
iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/windows/install.ps1).TrimStart([char]0xFEFF)
```

Pas de config Claude Code dans ce mode — pour ça il faut cloner.

## Statusline Claude Code (highlight)

`claude-code/statusline.ps1` affiche :
- **Path coloré** dynamiquement selon le mode permission (rose pour bypass, cyan pour plan, vert pour acceptEdits, violet pour dontAsk, orange pour auto)
- **Branche git** auto-détectée
- **Usage 5h + 7j** avec barre de progression, %, et reset time (cache 60s pour ne pas spammer l'API)
- **Plan + email** lus depuis `~/.claude/.credentials.json` et `~/.claude.json`

Endpoint utilisé pour `/usage` : `GET https://api.anthropic.com/api/oauth/usage` (privé, découvert via [codelynx.dev](https://codelynx.dev/posts/claude-code-usage-limits-statusline)).

## Sécurité

`.gitignore` exclut :
- `.credentials.json`, `auth-status-cache.json`, `usage-cache.json` (tokens / data sensibles Claude)
- `id_ed25519`, `id_ed25519.pub`, `*.pem`, `*.key` (clés SSH / privées)
- `sessions/`, `history.jsonl`, `projects/`, `stats-cache.json` (data perso Claude)

## License

[MIT](./LICENSE)

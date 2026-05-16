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

## Installation rapide

### Windows
```powershell
iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/windows/install.ps1).TrimStart([char]0xFEFF)
```

### Android (Termux)
```bash
curl -fsSL https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh | bash
```

### Claude Code (post-install après Windows ou Android)
```powershell
# Windows
Copy-Item .\claude-code\statusline.ps1 "$env:USERPROFILE\.claude\statusline.ps1"
Copy-Item .\claude-code\settings.json   "$env:USERPROFILE\.claude\settings.json"
Copy-Item .\claude-code\hooks\*.ps1     "$env:USERPROFILE\.claude\hooks\"
```

```bash
# Android (Termux)
mkdir -p ~/.claude/hooks
cp claude-code/settings.json   ~/.claude/settings.json
cp claude-code/hooks/*.sh      ~/.claude/hooks/  2>/dev/null || true
```

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

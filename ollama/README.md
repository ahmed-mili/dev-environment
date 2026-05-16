# ollama/

Config Ollama : intégrations vers modèles cloud (Claude, Openclaw, etc.).

## Fichiers

| Fichier | Rôle |
| --- | --- |
| `config.json` | Template `~/.ollama/config.json` — intégrations cloud (glm-5.1, kimi-k2.5, etc.) |

## Sécurité

Ne JAMAIS commit :
- `id_ed25519` / `id_ed25519.pub` (clés SSH d'authentification ollama.com — exclues via `.gitignore`)
- `models/` (énormes, à laisser locaux)
- `history`, `cache/`, `backup/` (data perso)

## Installation manuelle

### Windows
```powershell
$src = "$PWD\ollama\config.json"
$dst = "$env:USERPROFILE\.ollama\config.json"
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
Copy-Item $src $dst -Force
```

### Android (Termux)
```bash
mkdir -p ~/.ollama
cp ollama/config.json ~/.ollama/config.json
```

## TODO

- [ ] Script `setup-models.ps1` / `setup-models.sh` qui pull les modèles essentiels (`ollama pull <model>`)
- [ ] Templates Modelfile pour les prompts système les plus utilisés

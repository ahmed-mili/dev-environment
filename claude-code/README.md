# claude-code/

Config Claude Code partagée entre Windows et Android.

## Fichiers

| Fichier | Rôle |
| --- | --- |
| `statusline.ps1` | Status line PowerShell : path coloré (selon mode permission), branche git, usage 5h/7j avec %, plan + email |
| `settings.json` | Template `~/.claude/settings.json` (modèle, hooks, plugins, statusline) |
| `hooks/auto-pull.ps1` | Hook SessionStart : `git pull` automatique sur `~/.claude/` |
| `hooks/auto-push.ps1` | Hook SessionEnd : `git push` automatique sur `~/.claude/` |
| `hooks/resolve-sync-conflicts.ps1` | Hook SessionStart : résout les conflits de sync |

## Statusline — comment ça marche

À chaque refresh de la statusline, Claude Code envoie un JSON sur stdin (`workspace.current_dir`, `permission_mode`, `model`, etc.). Le script :

1. Lit le JSON, en dump une copie debug dans `~/.claude/statusline-last-input.json`
2. Récupère le path et le mode permission → applique une couleur ANSI true-color (RGB) au path
3. Détecte la branche git en remontant les parents jusqu'au `.git`
4. Lit l'email depuis `~/.claude.json` (`oauthAccount.emailAddress`)
5. Lit le plan depuis le cache `~/.claude/auth-status-cache.json` (TTL 1h, fallback : `claude auth status --json`)
6. Appelle l'endpoint privé `GET https://api.anthropic.com/api/oauth/usage` avec le token de `~/.claude/.credentials.json` (TTL cache 60s) pour les compteurs 5h/7j

### Couleurs par mode permission

| Mode | RGB | Aperçu |
| --- | --- | --- |
| `bypassPermissions` | 255,121,198 | rose vif |
| `plan` | 139,233,253 | cyan clair |
| `acceptEdits` | 80,250,123 | vert |
| `dontAsk` | 189,147,249 | violet |
| `auto` | 255,184,108 | orange |
| `default` / fallback | 139,233,253 | cyan clair |

### Couleurs usage selon le %

- `< 50 %` : vert (80,250,123)
- `50–80 %` : jaune (241,250,140)
- `> 80 %` : rouge (255,85,85)

## Installation manuelle (Windows)

```powershell
$src = "$PWD\claude-code"
$dst = "$env:USERPROFILE\.claude"
New-Item -ItemType Directory -Force $dst, "$dst\hooks" | Out-Null
Copy-Item "$src\statusline.ps1" "$dst\statusline.ps1" -Force
Copy-Item "$src\settings.json"  "$dst\settings.json"  -Force
Copy-Item "$src\hooks\*.ps1"    "$dst\hooks\"         -Force
```

## Crédit

Endpoint `/usage` découvert par [Melvynx (codelynx.dev)](https://codelynx.dev/posts/claude-code-usage-limits-statusline) via Proxyman.

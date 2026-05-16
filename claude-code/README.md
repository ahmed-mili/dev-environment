# claude-code/

Config Claude Code partagée entre Windows et Android. Source of truth unique.

## Contenu

| Fichier | Rôle |
| --- | --- |
| `statusline.ps1` | Status line : path coloré (selon mode permission), branche git, usage 5h/7j live, plan + email |
| `settings.json` | Config Claude Code (modèle, plugins, statusline, effort level) |
| `hooks/` | Hooks PowerShell — réservés pour usage manuel/futur, plus appelés en SessionStart/End |
| `skills/` | 9 skills custom : copy-edit, css-layout-check, edit-block, lucide-icons, release, root-cause-fix, smart-edit, sticky-column-bleed-fix, webapp-deploy |
| `deploy.ps1` | Sync bidirectionnel manuel entre ce dossier et `~/.claude/` |

## Bootstrap d'une nouvelle machine

```powershell
# Clone le repo, puis pull les configs vers ~/.claude/
git clone https://github.com/ahmed-mili/dev-environment.git C:\dev\dev-environment
C:\dev\dev-environment\claude-code\deploy.ps1 -Pull
# Relance Claude Code
```

## Workflow quotidien

Le sync entre `~/.claude/` et ce repo est **manuel** (plus de hooks auto sur SessionStart/End). Justification : éviter les conflits Syncthing/git silencieux et garder un contrôle explicite sur ce qui est commit.

### Tu as ajouté/modifié une skill ou un setting dans `~/.claude/` ?

```powershell
cd C:\dev\dev-environment
.\claude-code\deploy.ps1 -Push
git add -A ; git commit -m "<message>" ; git push
```

> ⚠️ `deploy.ps1 -Push` ne copie que les **9 skills custom whitelist** vers le repo. Les skills officielles d'Anthropic ou téléchargées via marketplace (`brand-guidelines`, `claude-api`, `docx`, etc.) ne sont jamais commit (le repo reste lean).

### Pour ajouter une nouvelle skill custom à la whitelist

Édite `deploy.ps1` ligne `$CustomSkills = @(...)` et ajoute le nom du dossier de ta skill.

## Statusline — détails techniques

Endpoint privé Claude Code pour l'usage live :
```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken depuis ~/.claude/.credentials.json>
anthropic-beta: oauth-2025-04-20
```

| Mode permission | Couleur path (RGB) |
| --- | --- |
| `bypassPermissions` | 255,121,198 (rose vif) |
| `plan` | 139,233,253 (cyan clair) |
| `acceptEdits` | 80,250,123 (vert) |
| `dontAsk` | 189,147,249 (violet) |
| `auto` | 255,184,108 (orange) |

| % usage | Couleur barre/texte |
| --- | --- |
| `< 50%` | vert (80,250,123) |
| `50–80%` | jaune (241,250,140) |
| `> 80%` | rouge (255,85,85) |

Caches : usage 60s (`~/.claude/usage-cache.json`), auth 1h (`~/.claude/auth-status-cache.json`).

## Crédit

Endpoint `/usage` découvert par [Melvynx (codelynx.dev)](https://codelynx.dev/posts/claude-code-usage-limits-statusline) via Proxyman.

# claude-code/

Config Claude Code partagée entre Windows et Android. Source of truth unique.

## Contenu

| Fichier | Rôle |
| --- | --- |
| `statusline.ps1` | Status line PowerShell : path coloré (selon mode permission), branche git, usage 5h/7j live, plan + email. Fallback portable, sans prérequis. |
| `statusline-rs/` | Source Rust de la statusline animée 9 Hz (xhigh halo magenta + max rainbow stretch). **Prérequis : SAC désactivé + claude.exe patché** — cf. section dédiée. |
| `settings.json` | Config Claude Code (modèle, plugins, statusline `.exe` à 0.112s, SessionStart hook patch-claude-exe) |
| `hooks/patch-claude-exe.ps1` | Patche `claude.exe` au démarrage de session pour lever le clamp `refreshInterval >= 1` + débounce 300ms + keep-alive idle. **Flagged `FileFix.BBA!MTB` par Defender** — exception requise. |
| `hooks/` (autres) | `auto-pull.ps1`, `auto-push.ps1`, `resolve-sync-conflicts.ps1` — réservés pour usage manuel/futur, plus appelés en SessionStart/End |
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

## Effort level — deux modes de rendu

Les 5 niveaux d'effort (`low`, `medium`, `high`, `xhigh`, `max`) ont deux rendus possibles :

| Niveau | Rendu `.ps1` (fallback) | Rendu `.exe` (Rust, 9 Hz) |
| --- | --- | --- |
| `low` | yellowBright bold | yellowBright bold |
| `medium` | greenBright bold | greenBright bold |
| `high` | blueBright bold | blueBright bold |
| `xhigh` | halo magenta gaussien centré (base `#F5C2E7` ↔ highlight `#d0b4ff`, sigma=0.9) — **statique** | halo magenta qui sweep gauche→droite à 8.93 Hz |
| `max` | palette 7-stops Catppuccin étirée sur la largeur du label (`#F38BA8` → `#A6E3A1` → `#F5C2E7`) — **statique** | palette rainbow qui cycle char-par-char à 8.93 Hz |

Le picker `/effort` interne de Claude Code anime `xhigh` et `max` à 10 Hz (Ink/React dans le binaire). La statusline `.ps1` reproduit les **couleurs** identiques mais en statique (pas de tick temporel). La version Rust + `claude.exe` patché reproduit l'animation **identique au picker** (M=112 ms, soit 8.93 Hz). Cf. section "Version animée 9 Hz (avancé)" ci-dessous pour les prérequis.

## Version animée 9 Hz (avancé)

Le rendu `.ps1` par défaut marche sans prérequis et a tous les rendus statiques visuellement corrects. **N'active la version 9 Hz que si tu veux le mouvement.**

### Prérequis (tous obligatoires)

1. **Smart App Control = Off** — sinon Windows 11 bloque l'exécution de tout binaire Rust unsigned (erreur OS 4551 sur cargo build aussi). Settings → Privacy & security → Smart App Control. ⚠️ **Désactivation définitive** : pour réactiver, il faut reset Windows. Ne le fais que si tu acceptes ce trade-off.
2. **Exception Defender pour `~/.claude/hooks/patch-claude-exe.ps1`** — ce script est flagged `Trojan:Win32/FileFix.BBA!MTB` (heuristique standard pour les patcheurs de binaires). Sans exception, Defender met le fichier en quarantaine au clone et le hook ne fire jamais. Ajoute l'exception :
   ```powershell
   # En PowerShell admin :
   Add-MpPreference -ExclusionPath "$env:USERPROFILE\.claude\hooks\patch-claude-exe.ps1"
   ```
3. **Rust toolchain** — pour compiler le binaire :
   ```powershell
   winget install Rustlang.Rustup
   ```

### Compilation

```powershell
cd C:\dev\dev-environment\claude-code\statusline-rs
.\build.ps1
```

`build.ps1` build en `--release` (LTO + strip), redirige `CARGO_TARGET_DIR` vers `%LOCALAPPDATA%\statusline-build\target` (path trusted hors de `C:\dev`, évite les blocs SAC sur les build-scripts cargo), puis copie le binaire vers `~/.claude/statusline.exe`.

### Comment marche le patch

`patch-claude-exe.ps1` est un hook `SessionStart` qui scanne `claude.exe` à chaque démarrage de session et applique 4 patches in-place (in-place = même longueur, pas de décalage de bytes) :

| Patch | Pattern remplacé | Effet |
| --- | --- | --- |
| 1 | `Math.max(1,X)*1000` → `Math.max(0,X)*1000` | Lève le clamp `refreshInterval >= 1` sur la statusline |
| 3 | `=H(()=>{F()},300)` → `=H(()=>{F()}, 50)` | Réduit le debounce 300 ms du composant statusline (sans ça, refresh < 300 ms reste bloqué) |
| 4 | `!K\|\|q===null?gZH:` → `false?gZH:       ` | Force le path actif du hook `_9` même quand `useContext(YQ)` est null (sinon freeze ~30 s en idle) |
| 5 | `K.setTimeout(Y,q)` → `Is8(Y,q)         ` (×2) | Bypass le setTimeout du RootStore Ink, utilise le setTimeout natif via `Is8` → tick continu en idle |

Les patches sont idempotents (skip si déjà appliqués via marker `~/.claude/last-patched-claude-exe.txt` basé sur la mtime) et tolérants aux variables minifiées qui changent à chaque release Anthropic (recherche par regex avec contexte).

Après une mise à jour de Claude Code, le hook re-patche automatiquement à la prochaine session et émet un `systemMessage` pour signaler que l'animation est réactivée.

## Crédit

Endpoint `/usage` découvert par [Melvynx (codelynx.dev)](https://codelynx.dev/posts/claude-code-usage-limits-statusline) via Proxyman.

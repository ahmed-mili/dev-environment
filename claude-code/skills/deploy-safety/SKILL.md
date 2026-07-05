---
name: deploy-safety
description: "Se déclenche AVANT toute synchronisation entre ~/.claude/ et le repo dev-environment/claude-code/ — deploy.ps1 -Pull ou -Push, mais aussi tout cp/robocopy/Copy-Item vers ~/.claude/ (statusline.ps1, settings.json, hooks/, skills/). -Pull écrase aveuglément le travail local plus récent (5 h perdues le 2026-05-17). Avant tout -Pull, exécuter scripts/deploy-status.ps1 ; si LOCAL NEWER → -Push d'abord. Fix ponctuelle → cp ciblé d'UN seul fichier, jamais -Pull. Triggers — « lance deploy », « sync ~/.claude », « Pull les skills », « déploie cette modif »."
---

# Deploy Safety — Anti-écrasement avant tout sync de config Claude Code

Tu es sur le point de toucher à `~/.claude/`, le dossier où vivent les configs Claude Code de l'user (statusline, settings, hooks, skills custom). C'est aussi le dossier où il **édite en direct** son travail entre les sessions. Une opération aveugle peut effacer des heures de boulot.

**Règle inviolable** : avant tout `deploy.ps1 -Pull` ou toute copie qui écrase un fichier de `~/.claude/`, faire un check préalable. Le coût d'un check (5 secondes) est mille fois inférieur à celui d'une restauration via `claude-file-recovery` (5 minutes minimum, et seulement si file-history est intact).

## Comprendre le workflow Pull / Push

L'user a 3 machines (desktop, laptop, phone Android). La synchronisation passe par GitHub :

```
~/.claude/  ←─ -Pull ─  dev-environment/claude-code/  ←→ git ←→ GitHub ←→ autres machines
            ─ -Push ─→
```

| Commande | Direction | Quand l'utiliser |
|---|---|---|
| `deploy.ps1 -Pull` | repo → `~/.claude/` | Récupérer le travail venant d'une AUTRE machine (après git pull) |
| `deploy.ps1 -Push` | `~/.claude/` → repo | Avant de quitter cette machine, propager au repo (puis git commit + push) |

**Le piège n°1** : `-Pull` est tentant à utiliser comme "déploiement local" ("j'ai édité dans le repo, je veux que `~/.claude/` voit ma fix"). C'est dangereux : si `~/.claude/` a des modifs encore plus récentes, elles sont écrasées.

### Le piège fondamental (cause de l'incident du 2026-05-17)

**L'user édite `~/.claude/` DEPUIS N'IMPORTE QUEL CWD** — pas seulement depuis le repo `dev-environment/`. C'est même le cas le plus courant : il a une session Claude Code dans `C:\Users\Ahmed\test\` (ou n'importe quel dossier de scratch) qui édite `~/.claude/statusline.ps1` en live pour itérer rapidement.

Conséquences :

1. **Le repo `dev-environment/claude-code/` peut être en retard de plusieurs HEURES ou JOURS** sur `~/.claude/` sans qu'aucune session ne soit active dans `dev-environment/`.
2. **Aucun signal visible côté `dev-environment`** : pas de `git status M`, pas de session Claude Code ouverte là-bas, pas de notification. Le repo a l'air "calme et propre".
3. **Un agent qui débarque dans `dev-environment` et lance `-Pull`** sans `deploy-status.ps1` préalable détruit potentiellement des heures de travail invisibles.

**Ne JAMAIS raisonner ainsi** :
- ❌ "Il n'y a pas de session active dans `dev-environment`, donc personne ne travaille, donc `-Pull` est safe."
- ❌ "Le `git status` du repo est clean, donc le repo est à jour."
- ❌ "Le dernier commit date d'hier, donc on peut Pull sans risque."

**Le SEUL critère fiable** : la sortie de `deploy-status.ps1`. Il compare les **mtimes/hashes des fichiers réels sur disque**, indépendamment de :
- le cwd de la session courante
- l'état git du repo
- la présence ou absence d'autres sessions Claude Code
- ce que l'user a "probablement" fait ces dernières heures

Si `deploy-status.ps1` dit `LOCAL NEWER` sur ne serait-ce qu'un fichier, le repo est en retard et `-Pull` détruira ce travail. Point.

## La procédure obligatoire avant tout `-Pull`

### Étape 1 — Exécuter `deploy-status.ps1`

Le script bundled de ce skill compare les mtimes de chaque fichier tracked :

```powershell
& ~/.claude/skills/deploy-safety/scripts/deploy-status.ps1
```

Sortie : tableau avec une ligne par fichier tracked, colonnes :
- `File` : chemin relatif (`statusline.ps1`, `hooks/auto-pull.ps1`, `skills/<X>/SKILL.md`, etc.)
- `Local Mtime` : mtime dans `~/.claude/`
- `Repo Mtime` : mtime dans le repo
- `Verdict` : un des suivants ⤵️

| Verdict | Sens | Action |
|---|---|---|
| `IDENTICAL` | Mtimes identiques OU contenu identique | `-Pull` safe (no-op) |
| `REPO NEWER` | Repo plus récent que `~/.claude/` | `-Pull` safe (apporte le travail d'une autre machine) |
| `LOCAL NEWER` | `~/.claude/` plus récent | **`-Pull` DANGEREUX** : tu écraserais le travail local |
| `LOCAL ONLY` | Existe en `~/.claude/` mais pas dans le repo | Skill custom non encore whitelisté ? À investiguer |
| `REPO ONLY` | Existe dans le repo mais pas en `~/.claude/` | `-Pull` créera le fichier — vérifier que c'est voulu |

### Étape 2 — Décider selon le verdict global

Le script retourne aussi un **exit code** :
- `0` = tous les verdicts sont safe pour Pull (`IDENTICAL`, `REPO NEWER`, ou `REPO ONLY`)
- `1` = au moins un fichier en `LOCAL NEWER` — `-Pull` est dangereux

**Si exit code = 0** : `-Pull` peut procéder.

**Si exit code = 1** : NE PAS LANCER `-Pull`. Choisir l'une des actions suivantes :

1. **Recommandé** : `deploy.ps1 -Push` d'abord pour propager le travail local au repo, **puis** `-Pull` (qui sera maintenant un no-op pour les fichiers concernés).
2. **Si tu sais que le repo a une version intentionnellement différente que tu veux récupérer** : `cp <repo-file> ~/.claude/<file>` ciblé sur ce SEUL fichier, après avoir backupé manuellement la version `~/.claude/`.
3. **Demander à l'user** : "Le fichier `<X>` dans `~/.claude/` est plus récent que dans le repo (modifié le `<date>`). Tu veux que j'écrase ou que je `-Push` d'abord ?"

### Étape 3 — Cas spécial : tu viens d'éditer un fichier dans le repo et tu veux le voir dans `~/.claude/`

C'est exactement le scénario qui a causé l'incident du 2026-05-17. **Ne PAS lancer `-Pull`** pour ça — c'est utiliser une grenade pour ouvrir une lettre.

À la place :

```powershell
# Copier UN seul fichier modifié vers ~/.claude/, sans toucher au reste
cp 'C:/dev/dev-environment/claude-code/statusline.ps1'  'C:/Users/Ahmed/.claude/statusline.ps1'
```

Si tu hésites parce que le fichier en `~/.claude/` pourrait être plus récent (= contenir du travail user que tu vas écraser), faire d'abord :

```powershell
# Comparer mtimes avant la copie
$repo  = (Get-Item 'C:/dev/dev-environment/claude-code/statusline.ps1').LastWriteTime
$local = (Get-Item 'C:/Users/Ahmed/.claude/statusline.ps1').LastWriteTime
if ($local -gt $repo) {
    Write-Warning "~/.claude/ est plus récent — vérifier avant d'écraser !"
}
```

## Procédure pour `-Push`

`-Push` est moins critique parce que `git push` détectera tout conflit côté GitHub (et l'auto-push hook fait `git pull` régulièrement). Mais il peut quand même écraser des modifs faites directement dans le repo (rare mais possible).

Recommandation : faire `git status` dans `dev-environment/` avant `-Push`. Si des fichiers tracked par `deploy.ps1` apparaissent comme `M` (modifiés non commités), c'est qu'il y a un edit-in-repo non propagé. À résoudre avant Push.

## Le bug `Copy-Item -Recurse` (corrigé mais à connaître)

`Copy-Item <dir> <existing-dir> -Recurse` ne **remplace pas** le dossier cible — il copie À L'INTÉRIEUR, créant `target/source/` au lieu de `target/`. C'est le 2ème bug du `deploy.ps1` qui créait `skills/<X>/<X>/` à chaque Pull.

**Fix appliqué** dans `deploy.ps1` (commit du 2026-05-17) : `Remove-Item $to -Recurse -Force` avant `Copy-Item` quand la cible est un dossier existant.

**Si tu fais un `Copy-Item -Recurse` manuel** : toujours `Remove-Item` la cible d'abord, ou utiliser `robocopy /MIR` qui fait un vrai mirror.

## Opérations sûres vs dangereuses (référence rapide)

### SÛR

- `cp <single-file> <single-file>` (après check mtime si la cible est précieuse)
- `deploy.ps1 -Pull` **après** `deploy-status.ps1` retourne exit 0
- `deploy.ps1 -Push` après vérification de `git status` dans le repo
- `robocopy <src> <dst> /L` (mode dry-run, n'écrit rien)
- Lire `~/.claude/` (Read, Get-Content, cat) — jamais dangereux

### DANGEREUX (refuser ou demander confirmation)

- `deploy.ps1 -Pull` sans `deploy-status.ps1` préalable
- `Copy-Item <dir> <existing-dir> -Recurse` (crée imbrication parasite)
- `robocopy /MIR` sans dry-run d'abord (efface tout ce qui n'est pas dans la source)
- `cp -r repo/* ~/.claude/` (équivalent à `-Pull` non-checké)
- `git checkout -- claude-code/<file>` puis re-déploiement (perd les modifs `~/.claude/`)
- `git clean -fd` dans le repo (efface les untracked, certains peuvent être précieux)

## Pourquoi cette discipline compte

L'user travaille **5+ heures à itérer** sur sa statusline / settings / hooks / skills. Ces fichiers vivent dans `~/.claude/` parce que c'est là que Claude Code les lit en direct (changements visibles immédiatement sans reload). L'user édite souvent dans `~/.claude/` directement et ne fait `-Push` qu'épisodiquement.

Conséquence : à n'importe quel moment, `~/.claude/` peut contenir des heures de travail non encore propagées au repo. Un agent qui Pull aveuglément efface ce travail. Même si la récupération via `claude-file-recovery` est possible (file-history sauve souvent), c'est :
- Stressant pour l'user (5 minutes d'incertitude où il croit avoir tout perdu)
- Pas garanti (file-history peut manquer le dernier Edit, comme pour notre incident — il a fallu croiser avec le JSONL)
- Évitable en 5 secondes par un check préalable

## Mantra

**Avant tout `deploy.ps1 -Pull` ou toute copie qui écrase `~/.claude/`, j'ai exécuté `deploy-status.ps1` (ou son équivalent manuel) et vérifié le verdict.**

Si ce mantra n'a pas été respecté et qu'un fichier `~/.claude/` est plus récent que le repo, **NE PAS LANCER `-Pull`**. Faire `-Push` d'abord, ou demander à l'user.

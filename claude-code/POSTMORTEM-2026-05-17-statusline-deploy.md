# Postmortem 2026-05-17 — `deploy.ps1 -Pull` écrase 5h de travail sur la statusline

## TL;DR

Un agent Claude Code a tenté de fix un bug mineur sur la statusline en re-déployant le fichier depuis le repo via `deploy.ps1 -Pull`, sans réaliser que `~/.claude/statusline.ps1` avait des modifs locales **bien plus récentes** que ce qui était dans le repo. Les modifs ont été écrasées. Tout a été récupéré via `~/.claude/file-history/` que Claude Code maintient silencieusement pour chaque fichier modifié.

**Net loss final : zéro.** Mais on a frôlé la perte de ~5h de boulot, et on a trouvé deux bugs dans `deploy.ps1` au passage.

## Timeline

| Heure (local) | Événement |
|---|---|
| Nuit du 16→17 mai | L'user bosse intensivement sur sa statusline dans `C:\Users\Ahmed\test`. **17 versions** snapshotées par Claude Code dans `~/.claude/file-history/b1d5454a-.../c3b738d7ad94fb03@v1` à `@v17`. |
| 04:10 | v17 du statusline est snapshotée. |
| 04:16 | Dernier Edit de la session : retire le label `ctx` et ajoute ` tok` à droite. **Pas de snapshot file-history pour cette modif** (Claude Code ne re-snapshote pas à chaque Edit — il y a des seuils). |
| ~04:48 | L'user lance une nouvelle session dans `C:\dev\dev-environment` pour fix un autre détail (statusbar qui ne refresh pas au `/login`). |
| 04:49 | L'agent édite `dev-environment/claude-code/statusline.ps1` (le fichier du repo, en retard de plusieurs heures vs `~/.claude/`), puis lance `deploy.ps1 -Pull`. **Écrase `~/.claude/statusline.ps1` riche avec la version repo basique.** |
| 04:50 | User signale "remet comme avant". Agent reverte l'edit dans le repo, refait `deploy.ps1 -Pull` → ré-écrase, et crée 9 sous-dossiers parasites `skills/<X>/<X>/` au passage. |
| 04:51 | Diagnostic : `~/.claude/` est un git repo avec un `.gitignore` qui exclut `statusline.ps1`. Pas récupérable via git. Mais `~/.claude/file-history/` contient 17 versions. |
| 04:55 | Restauration v10 → ne correspond pas à l'image fournie par l'user (manque le bannière cost, le format `tok`, etc.). |
| 05:10 | User partage l'image cible (`≈$20.83  Opus 4.7  0/1.0M tok`). Agent recode un statusline qui ressemble visuellement mais avec une logique simplifiée — `≈$X.XX` inline, pas de bannière dédiée, pas de cooldown 429, pas de fallback stale. |
| 05:13 | User : "c'est pas pareil". |
| 05:15 | User suggère de chercher dans les transcripts locaux. Agent trouve `~/.claude/projects/C--Users-Ahmed-test/b1d5454a-....jsonl` et identifie 17 versions file-history dans le dir associé. |
| 05:17 | v17 lue intégralement. Parse du JSONL pour extraire le dernier Edit (timestamp `02:16 UTC` = `04:16 local`, AFTER v17 snapshot). |
| 05:18 | `cp v17` + Edit final = état exact d'avant l'incident. Test live OK. |

## Cause racine

**Deux bugs distincts dans `deploy.ps1`.**

### Bug n°1 : pas de garde-fou anti-écrasement
Le script copie aveuglément `repo → ~/.claude/` sans comparer les mtimes. Le workflow attendu (cf. `CLAUDE.md`) est :
- `-Push` à la fin de chaque session qui touche `~/.claude/`
- `-Pull` au début pour récupérer ce qui a été pushé depuis d'autres machines

Mais quand un user enchaîne plusieurs sessions sans `-Push` entre deux, ou quand un agent lance `-Pull` sans savoir où en est le sync, le `-Pull` détruit le travail local plus récent.

**Aggravation contextuelle** : l'user n'éditait PAS le statusline depuis le repo `dev-environment` mais depuis `C:\Users\Ahmed\test` (un dossier de scratch). Les modifications de `~/.claude/statusline.ps1` étaient invisibles côté repo : pas de `M` dans `git status`, pas de session active dans `dev-environment`, repo "calme et propre". L'agent (moi) a logiquement supposé qu'il n'y avait rien à craindre — mauvaise hypothèse. **`~/.claude/` peut être en avance sur le repo SANS aucun signal visible côté repo.** Le mtime des fichiers est la seule vérité.

### Bug n°2 : `Copy-Item -Recurse` est traître
```powershell
Copy-Item "C:\dev\.../skills/copy-edit"  "C:\Users\Ahmed\.claude\skills\copy-edit"  -Force -Recurse
```
Quand le dossier cible existe déjà, `-Recurse` ne **remplace pas** son contenu — il copie le dossier source **À L'INTÉRIEUR**, créant `~/.claude/skills/copy-edit/copy-edit/`. Multiplié par 9 skills, ça donne 9 sous-dossiers parasites silencieux.

## Comment on a récupéré

### 1. `~/.claude/file-history/`
Claude Code maintient un historique versionné de tous les fichiers qu'il modifie via Write/Edit, dans :
```
~/.claude/file-history/<session-uuid>/<filepathhash>@vN
```
Chaque `@vN` est un snapshot complet du fichier après une modification suffisamment significative (les Edits micro ne déclenchent pas forcément un snapshot — c'est pour ça qu'il manquait le dernier Edit de notre cas).

**Comment identifier le bon snapshot** : croiser les UUID dans `~/.claude/projects/<encoded-path>/` (transcripts) avec ceux de `file-history/`. La session qui a le plus de modifs sur le fichier d'intérêt = celle qui contient les snapshots les plus récents.

### 2. Les transcripts JSONL (`projects/`)
Pour récupérer les Edits post-dernier-snapshot :
```
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
```
Chaque ligne = un message. Les `tool_use` Edit contiennent `input.old_string` et `input.new_string`. Trier par timestamp (UTC) et appliquer ceux qui sont postérieurs au mtime du dernier snapshot file-history.

**Dans notre cas** : v17 mtime = `04:10 local`. Edit final timestamp = `02:16 UTC` = `04:16 local`. → cet Edit n'était PAS dans v17, mais il était dans le transcript. Appliqué manuellement avec l'outil Edit, on obtient l'état final exact.

## Les fix appliqués

### `deploy.ps1` (commit pending)
Ajout d'un `Remove-Item $to -Recurse -Force` avant `Copy-Item` quand la cible est un dossier existant :
```powershell
if ((Test-Path $from -PathType Container) -and (Test-Path $to)) {
    Remove-Item $to -Recurse -Force
}
Copy-Item $from $to -Force -Recurse
```
Élimine définitivement le bug n°2.

### `statusline.ps1`
Restauré à l'état v17 + last edit (= état final du chat user). Présent dans `~/.claude/` ET dans le repo, synced.

### Nettoyage
9 sous-dossiers parasites `skills/<X>/<X>/` supprimés.

## Les leçons (vraies)

0. **L'user édite `~/.claude/` depuis n'importe quel cwd — pas seulement depuis le repo `dev-environment`.** Le repo peut donc être largement en retard sans aucun `M` dans `git status`, sans session active dans `dev-environment`, sans aucun signal visible. **Ne JAMAIS supposer l'état du repo via le contexte de la session ou de git.** Le mtime des fichiers réels sur disque est le SEUL critère fiable.

1. **`deploy.ps1 -Pull` n'est pas un sync sécurisé — c'est un écrasement.** À traiter avec autant de méfiance qu'un `git reset --hard`. Avant tout `-Pull`, vérifier si `~/.claude/` a des modifs locales plus récentes.

2. **`Copy-Item -Recurse` n'est PAS un sync.** Pour vraiment remplacer un dossier, soit `Remove-Item` puis `Copy-Item`, soit `robocopy /MIR` qui fait un vrai mirror.

3. **Le `file-history/` de Claude Code est un filet de sécurité silencieux et précieux.** Ne pas l'effacer (même s'il prend de la place — actuellement ~700 MB chez moi). Et savoir qu'il existe : ça vaut de l'or quand un agent fait une connerie.

4. **Les transcripts JSONL sont une source de vérité de second recours.** En cas de perte non couverte par file-history (typiquement les Edits récents non snapshotés), parser le JSONL pour récupérer les `tool_use`.

5. **Quand un agent annonce "tout est restauré, byte-identique"**, ne pas le croire sur parole. "Byte-identique au repo" ≠ "byte-identique à ce que tu avais avant" — le repo peut être en retard.

6. **Le diagnostic doit précéder l'action.** Quand un agent voit `M claude-code/statusline.ps1` dans git status au début d'une session, c'est un drapeau rouge : "il y a du travail non commité, attention à ne pas l'écraser". L'agent n'a pas tilté.

## TODOs

- [ ] **`deploy.ps1 -Pull` plus safe** : refuser le pull si un fichier de `~/.claude/` a une mtime plus récente que sa contrepartie dans le repo. Forcer `-Push` ou `-Force` explicite pour passer outre.
- [ ] **Nouveau `deploy.ps1 -Status`** : affiche un tableau `fichier | mtime ~/.claude/ | mtime repo | action recommandée`. À lancer avant `-Pull` ou `-Push`.
- [ ] **Documenter le workflow dans `CLAUDE.md`** : "toujours `-Push` à la fin de chaque session qui touche statusline/settings/hooks/skills, avant de quitter Claude Code".
- [ ] **Étudier le rythme des snapshots file-history** : pourquoi Claude Code n'a pas snapshoté l'Edit de `04:16` ? Si on comprend, on peut savoir quand faire confiance au file-history seul vs. quand croiser avec le JSONL.

## Annexe : commandes utiles pour la récupération

```powershell
# Trouver toutes les sessions qui ont touché un fichier
Get-ChildItem ~/.claude/projects -Recurse -Filter '*.jsonl' |
  Where-Object { Select-String -Path $_.FullName -Pattern 'statusline.ps1' -Quiet } |
  Sort-Object LastWriteTime -Descending

# Trouver toutes les versions file-history d'un fichier
Get-ChildItem ~/.claude/file-history -Recurse |
  Where-Object { Select-String -Path $_.FullName -Pattern 'marker-unique-au-fichier' -Quiet } |
  Sort-Object LastWriteTime -Descending

# Identifier les Edits dans un transcript
Select-String -Path 'session-id.jsonl' -Pattern '"name":"Edit"' |
  Where-Object { $_.Line -match 'statusline' }
```

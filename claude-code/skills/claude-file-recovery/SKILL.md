---
name: claude-file-recovery
description: "Se déclenche dès qu'un fichier de ~/.claude/ est perdu, écrasé ou corrompu — deploy.ps1 -Pull destructeur, Edit/Write accidentel, git checkout raté, feature disparue (statusline, settings, hooks, skills). Reconstruit l'état EXACT via file-history/ et les transcripts JSONL (projects/) — à invoquer AVANT de re-coder de mémoire ou de redemander à l'user. Triggers — « j'ai perdu », « tu as cassé », « récupère », « restore », « remet comme avant », « ça marchait avant », « deploy.ps1 a effacé »."
---

# Claude File Recovery

Tu opères en mode pompier. Un fichier que l'user a passé du temps à écrire vient de disparaître ou d'être écrasé. Ton job : le restaurer à l'état exact d'avant l'incident, pas à une approximation reconstruite de mémoire.

**Règle d'or** : avant de coder quoi que ce soit, AVANT même de te demander "qu'est-ce que l'user voulait ?", suis la procédure de ce skill. Claude Code maintient en local plusieurs sources de récupération que la plupart des gens (et des agents) ignorent.

## Les deux sources de récupération

Claude Code écrit silencieusement deux trésors sur disque à chaque modification de fichier :

### 1. `~/.claude/file-history/<session-uuid>/<filehash>@vN`

À chaque Write ou Edit qui dépasse un seuil de significativité, Claude Code snapshote le fichier complet dans ce dossier. Structure :

```
~/.claude/file-history/
├── <session-uuid-A>/           # Une session = un dir UUID
│   ├── <filehash-X>@v1         # Snapshot du fichier X, version 1
│   ├── <filehash-X>@v2         # ... version 2 (après modification)
│   ├── ...
│   ├── <filehash-X>@v17        # ... version 17 (dernière de cette session)
│   └── <filehash-Y>@v3         # Un autre fichier dans la même session
├── <session-uuid-B>/
│   └── <filehash-X>@v1         # X re-snapshoté dans une nouvelle session
```

- `<filehash>` = hash du chemin du fichier (16 hex chars). Le **même fichier** absolu garde le même hash à travers les sessions, donc tu peux suivre l'historique d'un fichier en cherchant son hash dans tous les dirs de sessions.
- `@vN` est séquentiel par session, **pas global**. v17 dans session A peut être plus ancien que v3 dans session B. Toujours trier par mtime, pas par numéro de version.
- Les Edits "micro" (1-2 chars) ne déclenchent pas forcément un snapshot. Donc le dernier snapshot peut être ancien de quelques Edits par rapport au state réel au moment de la perte.

### 2. `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`

Transcript complet de chaque session Claude Code. Format JSONL : un objet JSON par ligne, chaque ligne = un message ou un tool call. Les `tool_use` Edit/Write contiennent les arguments complets (`input.old_string`, `input.new_string`, `input.content`).

- `<encoded-cwd>` = le `cwd` de la session avec `\` → `-` et `:` → `-` (ex. `%USERPROFILE%\test` → `C--Users-Ahmed-test`).
- `<session-id>` = UUID de la session, **identique** à l'UUID utilisé dans `file-history/`.
- Une session contient TOUS les tool calls : les Edits qui n'ont PAS déclenché de snapshot file-history sont quand même là.

## La procédure de récupération (5 étapes)

### Étape 0 — Diagnostic rapide (30 secondes)

Avant tout, clarifier :

1. **Quel fichier exactement ?** Path absolu (`~/.claude/statusline.ps1` ? `~/.claude/settings.json` ? `~/.claude/skills/<X>/SKILL.md` ?)
2. **Approximativement quand a-t-il été perdu ?** (Aujourd'hui ? Cette semaine ? Permet de filtrer les snapshots par date.)
3. **Le `cwd` de la session où le fichier a été créé/modifié ?** L'user le sait souvent ("j'étais dans `%USERPROFILE%\test`"). Si non, on cherche dans toutes les sessions.
4. **Un marker unique** dans le fichier perdu (string distincte, ex. `"five_hour"` pour la statusline, `"five_hour"` n'apparaît probablement nulle part d'autre). Sert à grep efficacement dans file-history.

Si l'user ne sait pas un de ces points, **devine intelligemment** — n'arrête pas la récupération pour demander.

### Étape 1 — Scanner `file-history/` pour des snapshots

Utiliser le script bundled `scripts/find-versions.ps1` ou les one-liners PowerShell ci-dessous (section "Commandes de référence").

Objectif : obtenir une **liste triée par mtime décroissant** de tous les snapshots qui matchent le marker du fichier perdu. Le plus récent = ton candidat n°1.

```powershell
# Cherche tous les snapshots file-history contenant un marker unique
Get-ChildItem ~/.claude/file-history -Recurse -File |
  Where-Object { Select-String -Path $_.FullName -Pattern '<MARKER>' -Quiet -SimpleMatch } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 10 LastWriteTime, Length, FullName
```

**Lire entièrement** la version la plus récente avec ton outil Read. C'est ton état de base.

### Étape 2 — Identifier la session source via les UUID

Le snapshot le plus récent est dans `~/.claude/file-history/<session-uuid>/`. Cette UUID est la session qui a fait la dernière modif tracked. Identifier le transcript correspondant :

```
~/.claude/projects/<*>/<session-uuid>.jsonl
```

Le `<*>` (encoded-cwd) peut varier ; cherche le `.jsonl` portant le bon UUID :

```powershell
Get-ChildItem ~/.claude/projects -Recurse -Filter '<session-uuid>.jsonl'
```

### Étape 3 — Trouver les Edits postérieurs au dernier snapshot

C'est l'étape qu'on **rate facilement** et qui cause les "récupérations approximatives". Le dernier snapshot file-history peut dater de plusieurs minutes avant la perte ; les Edits intermédiaires sont uniquement dans le JSONL.

Extraire tous les `tool_use` Edit/Write sur le fichier perdu, triés par timestamp :

```powershell
# Trouve toutes les lignes du JSONL avec Edit sur le fichier
Select-String -Path '<session-uuid>.jsonl' -Pattern '"name":"Edit"' |
  Where-Object { $_.Line -match '<nom-fichier>' } |
  ForEach-Object {
    $obj = $_.Line | ConvertFrom-Json
    [PSCustomObject]@{
      LineNum   = $_.LineNumber
      Timestamp = $obj.timestamp
      Uuid      = $obj.uuid
    }
  } | Sort-Object Timestamp
```

Comparer les timestamps :
- Snapshot file-history mtime = T_snap (en local)
- Edits dans JSONL ont `timestamp` en **UTC** (suffixe Z). Convertir : `T_local = T_utc + offset_tz`.
- Tout Edit avec `T_local > T_snap` est **postérieur au snapshot** et doit être appliqué pour reconstruire l'état final.

### Étape 4 — Extraire les `old_string`/`new_string` des Edits post-snapshot

Pour chaque Edit identifié à l'étape 3, lire la ligne complète et extraire `input.old_string` et `input.new_string` :

```powershell
# Affiche le contenu input d'un Edit donné (par numéro de ligne)
$line = Get-Content '<session-uuid>.jsonl' | Select-Object -Index (<LineNum> - 1)
$obj = $line | ConvertFrom-Json
$obj.message.content | Where-Object { $_.type -eq 'tool_use' -and $_.name -eq 'Edit' } |
  ForEach-Object { $_.input }
```

Si le fichier .jsonl est très gros, utiliser `sed -n '<N>p' file.jsonl` (via Bash) ou `Get-Content -TotalCount` pour lire juste la ligne désirée.

### Étape 5 — Reconstruire + restaurer + valider

1. **Copier le dernier snapshot** vers le path réel du fichier :
   ```powershell
   cp '<file-history-path>/<filehash>@v<N>' '<real-file-path>'
   ```

2. **Appliquer chaque Edit post-snapshot** dans l'ordre chronologique, en utilisant ton outil Edit avec les `old_string`/`new_string` extraits. Edits avec `replace_all: true` → utiliser `replace_all`.

3. **Synchronizer aux 2 emplacements** si concerné par le workflow dev-environment :
   ```powershell
   cp '~/.claude/<file>'  'C:/dev/dev-environment/claude-code/<file>'
   ```
   Sinon le prochain `deploy.ps1 -Pull` re-écrasera.

4. **Tester** le fichier si testable (statusline : injecter le stdin réel sauvegardé dans `~/.claude/statusline-last-input.json` ; settings : check JSON valid ; hooks : exécuter avec input dummy). Pas de "ça marche probablement" — valider explicitement.

5. **Communiquer honnêtement** à l'user :
   - Quelle version a été restaurée (file-history v<N> daté du X) ?
   - Combien d'Edits post-snapshot ont été appliqués ?
   - Y a-t-il un risque qu'une modif encore plus récente n'ait pas été snapshotée NI loggée dans le JSONL ? (Rare mais possible si l'user a édité via éditeur externe — VSCode, notepad — qui ne passe pas par Claude Code.)

## Cas spéciaux

### File-history snapshote rien pour ce fichier

Possible si le fichier a été créé/édité hors Claude Code (VSCode direct, copy-paste manuel). Dans ce cas :

- **Plan B** : chercher dans `~/.claude/backups/` (Claude Code backupe `.claude.json` à chaque modif, mais pas les autres fichiers généralement).
- **Plan C** : Windows File History / Volume Shadow Copies. Nécessite **PowerShell ADMIN** :
  ```powershell
  # Lister les shadow copies disponibles (admin requis)
  vssadmin list shadows
  # Puis monter et extraire
  ```
- **Plan D** : si le fichier est tracked dans le git interne de `~/.claude/` (vérifier `~/.claude/.git/`), `git log -- <path>` puis `git show <commit>:<path>`.
- **Plan E** : demander à l'user s'il a un backup externe (OneDrive, Dropbox, Syncthing historique).

### Privilèges admin requis ?

| Source | Admin requis ? |
|---|---|
| `~/.claude/file-history/` (lecture + copie) | **Non** — c'est dans le profil user |
| `~/.claude/projects/*.jsonl` (lecture) | **Non** |
| `~/.claude/.git/` (si présent) | **Non** |
| `~/.claude/backups/` | **Non** |
| Windows Volume Shadow Copies (`vssadmin`) | **OUI — PowerShell admin obligatoire** |
| Restauration depuis File History Windows (Panneau Config) | Non si dans la home de l'user |

**Par défaut, aucune des étapes 1-5 ne demande admin.** Si tu te retrouves bloqué par une permission, c'est probablement un faux problème — vérifie le path avant de demander admin à l'user (ça l'oblige à relancer Claude Code en admin, ce qui est intrusif).

### Cas Linux / macOS

Mêmes paths mais avec `/` :
- `~/.claude/file-history/...`
- `~/.claude/projects/...`

Outils équivalents : `grep -rl`, `jq`, `find ... -newer`, `stat -c %y`. La logique de la procédure reste identique.

### Le fichier perdu est gros et a beaucoup d'Edits post-snapshot

Si tu as 20+ Edits à reproduire séquentiellement, c'est laborieux et risqué (chaque Edit peut foirer si le contexte a dérivé). Stratégie alternative :

1. Cherche dans le JSONL le **dernier Read** sur ce fichier — son résultat (`tool_result`) contient le contenu complet à ce moment-là.
2. Trier les Edits postérieurs à ce Read.
3. Tu as réduit la chaîne d'Edits à appliquer.

## Pièges à éviter

### Piège 1 : "byte-identique au repo" ≠ "byte-identique à avant"

Quand un `deploy.ps1 -Pull` écrase un fichier, le diff `~/.claude/X` vs `repo/X` devient nul. Tentant de conclure "rien perdu". **FAUX** : le repo peut être en retard de plusieurs heures vs `~/.claude/`. Toujours valider avec file-history.

### Piège 2 : Faire confiance au numéro `@vN`

`@v17` dans une session n'est pas forcément plus récent que `@v3` dans une autre. **Toujours trier par mtime.**

### Piège 3 : Oublier les Edits post-dernier-snapshot

Le dernier file-history snapshot peut être ancien de 1-15 minutes. Si tu restaures juste le snapshot sans appliquer les Edits du JSONL, tu obtiens un état approximatif, pas l'état réel. **Toujours croiser snapshot + JSONL.**

### Piège 4 : Coder "à peu près ce que l'user voulait" de mémoire

Si l'user te montre une capture d'écran et que tu codes "quelque chose qui ressemble", tu vas rater des dizaines de détails subtils (couleurs RGB exactes, ordre des sections, paddings, gestion des cas limites). **Toujours préférer la restauration exacte depuis file-history**, même si ça prend 5 minutes de plus.

### Piège 5 : Re-écraser pendant la récupération

Pendant que tu enquêtes (`deploy.ps1`, autres scripts), tu peux re-écraser le fichier ou les sources de récup. **Geler tout deploy.ps1 / sync / git pull tant que la récupération n'est pas validée.**

## Commandes de référence

### PowerShell — Trouver des snapshots par marker

```powershell
# Marker = string unique du fichier (ex. "five_hour" pour statusline, "permissions" pour settings)
$marker = 'five_hour'

Get-ChildItem ~/.claude/file-history -Recurse -File |
  Where-Object { Select-String -Path $_.FullName -Pattern $marker -Quiet -SimpleMatch } |
  Sort-Object LastWriteTime -Descending |
  Select-Object LastWriteTime, Length, FullName -First 20 |
  Format-Table -AutoSize
```

### PowerShell — Trouver les sessions qui ont touché un fichier

```powershell
$filename = 'statusline.ps1'

Get-ChildItem ~/.claude/projects -Recurse -Filter '*.jsonl' |
  ForEach-Object {
    $count = (Select-String -Path $_.FullName -Pattern $filename -SimpleMatch).Count
    if ($count -gt 0) {
      [PSCustomObject]@{
        Mtime    = $_.LastWriteTime
        RefCount = $count
        File     = $_.FullName
      }
    }
  } | Sort-Object Mtime -Descending | Format-Table -AutoSize
```

### Bash — Équivalents

```bash
# Snapshots par marker
grep -rl 'five_hour' ~/.claude/file-history/ |
  xargs ls -lt 2>/dev/null | head -20

# Sessions par fichier
for f in ~/.claude/projects/**/*.jsonl; do
  count=$(grep -c 'statusline.ps1' "$f")
  [ "$count" -gt 0 ] && echo "$count $f"
done | sort -rn
```

### Helper script bundlé

Pour automatiser les étapes 1-3 :

```powershell
# Depuis n'importe où :
& ~/.claude/skills/claude-file-recovery/scripts/find-versions.ps1 -Marker 'five_hour' -Filename 'statusline.ps1'
```

Sortie : tableau combiné snapshots + transcripts, triés par mtime. Voir `scripts/find-versions.ps1` pour les options.

## Mantra

**Avant de recoder de mémoire, j'ai cherché dans `file-history/` ET dans `projects/`.**

Si ce mantra n'a pas été respecté pendant la session, refuser de produire du code reconstruit et exécuter la procédure de récup d'abord. Sauver l'état exact prend 5 minutes ; reconstituer approximativement gaspille 30 minutes de l'user qui doit valider chaque détail visuel.

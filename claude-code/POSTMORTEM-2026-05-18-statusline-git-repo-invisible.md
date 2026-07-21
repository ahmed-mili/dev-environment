# Postmortem 2026-05-18 — La statusline disparaît silencieusement dans les git repos

## TL;DR

Sur Windows avec Defender realtime monitoring actif, chaque process git lancé est scanné → le `git fetch --quiet` async qu'on faisait depuis `statusline.exe` coûtait ~300 ms juste pour la **création** du process, même avec `DETACHED_PROCESS`. Ajouté aux ~30 ms de `git status`, ça poussait le runtime total à **370–576 ms par tick** dans les git repos, bien au-dessus du seuil d'abort silencieux de Claude Code (~100 ms). Résultat : statusline visible dans `%USERPROFILE%` et `C:\dev` (pas des git repos), invisible dans **tous** les repos GitHub du dossier `dev`.

**Fix** : déplacer le `Command::spawn()` dans un `std::thread::spawn` daemon. Avant : 370–576 ms. Après : **40–55 ms**.

## Timeline

| Heure (local) | Événement |
|---|---|
| Avant 2026-05-18 | Bug latent dans le code. Aucun signal côté user, parce que sa session active était dans `%USERPROFILE%` (pas un git repo) — statusline OK. |
| 2026-05-18 ~00:43 | Pendant un debug séparé sur la statusline, le `statusLine.command` de `~/.claude/settings.json` est temporairement remplacé par `cmd /c type statusline-replay.txt` (mode replay statique pour comparer des rendus). |
| ~00:45 | Refactor du mode replay en `replay.bat`. État resté en place par oubli. |
| ~01:00 | L'user ouvre une nouvelle session dans `%USERPROFILE%`, ne voit plus la statusline (replay.bat affiche une capture figée d'un autre cwd → contenu visiblement faux). Signale "Je voit plus mon statusbar". |
| ~01:00 | Diagnostic via `~/.claude/file-history/` (cf. `claude-file-recovery` skill) : v6 du settings = mode replay, v4 = statusline.exe normal. Restauration → statusline revient dans `%USERPROFILE%`. |
| ~01:01 | User teste dans ses repos `C:\dev\*` : **toujours pas de statusline**. Différence non triviale : la fix de settings affecte tous les cwd, donc le problème est ailleurs. |
| 01:02 | Inspection de `~/.claude/statusline-last-input.json` : `cwd = C:\dev\dev-environment`, mtime récent → le binaire **est** lancé, il écrit bien son fichier de debug, mais son stdout n'arrive pas jusqu'à CC. |
| 01:03 | Test isolé via `pwsh` + `Push-Location` + `& binary` : **8–18 ms**. Pas reproduit. |
| 01:04 | Test via `Process.Start` avec `WorkingDirectory = C:\dev\dev-environment` (= exactement ce que CC fait) : **369–576 ms**. Reproduit. |
| 01:05 | Décomposition : `git status --porcelain=v2 --branch` seul = 20–30 ms → pas le coupable. |
| 01:06 | Hypothèse : c'est le `git fetch` async qui coûte cher en **création** de process à cause de Defender. Test : touch du marker `statusline-last-fetch` pour bypass le fetch → **40–55 ms**. Hypothèse confirmée. |
| 01:08 | Fix Rust : `std::thread::spawn` autour du `Command::spawn`. Rebuild via `build.ps1`. Test post-fix avec fetch forcé : **39–54 ms**. |
| 01:09 | Commits + push vers `origin/main`. |

## Cause racine

### Pourquoi le `git fetch` était synchrone alors qu'on pensait qu'il était async

Le code original :
```rust
if needs_fetch {
    touch(&marker);
    let mut cmd = Command::new("git");
    cmd.args(["-C", dir, "fetch", "--quiet"]);
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW | 0x00000008 /* DETACHED_PROCESS */);
    let _ = cmd.spawn();
}
```

L'intention était claire : `cmd.spawn()` retourne immédiatement avec un `Child` qu'on jette, et le drapeau `DETACHED_PROCESS` détache l'enfant de la console parent. Le commentaire ailleurs dans le fichier mentionne explicitement la contrainte du seuil ~100 ms de CC, donc l'auteur savait qu'il fallait être rapide.

**Le piège** : `DETACHED_PROCESS` ne détache l'enfant **qu'une fois qu'il existe**. La création elle-même (`CreateProcess` sous le capot) reste synchrone sur la main thread. Et sur Windows avec Defender realtime monitoring, chaque `CreateProcess` qui lance `git.exe` déclenche un scan du binaire et du contexte → **~200–300 ms de latence ajoutée** à la création.

Donc :
- `git status` (synchrone, voulu) = ~30 ms
- `git fetch` *spawn* (supposé async) = ~300 ms 🔴
- Overhead binaire = ~40 ms
- **Total ~370 ms par tick**, et CC abort à ~100 ms

### Pourquoi le bug était invisible en isolation

Notre premier test était :
```powershell
Push-Location C:\dev\dev-environment
Get-Content statusline-last-input.json | & $env:USERPROFILE/.claude/statusline.exe
```
→ 8–18 ms. Apparemment OK.

Le second test, qui reproduit exactement ce que fait CC :
```powershell
$psi.FileName = '$env:USERPROFILE/.claude/statusline.exe'
$psi.WorkingDirectory = 'C:\dev\dev-environment'
[Process]::Start($psi)
```
→ 369–576 ms.

La différence : avec `Push-Location` + `&`, pwsh est déjà chargé en mémoire et son cache d'env est chaud. Avec `Process.Start`, on crée un process enfant *frais*, ce qui inclut le scan Defender du parent path. Sans cette nuance de test, on n'aurait jamais reproduit.

### Pourquoi `C:\dev` marchait et `C:\dev\dev-environment` pas

`C:\dev` n'est pas un git repo (pas de `.git/`). `compute_git()` retourne immédiatement avec `branch = None`, et la branche `if needs_fetch { ... spawn ... }` n'est jamais atteinte. Total ~15 ms.

Dès qu'on entre dans un repo (donc tout dossier `C:\dev\<projet>/`), le fetch spawn se déclenche → 300 ms ajoutés → statusline coupée.

## Comment on a diagnostiqué (les signaux qui ont aidé)

1. **`~/.claude/statusline-last-input.json`** est écrit par le binaire à chaque tick (ligne 684 du source). Si son mtime est récent dans un repo où la statusline n'apparaît pas, **le binaire tourne mais sa sortie ne passe pas**. Ça écarte d'emblée toutes les hypothèses "le binaire ne se lance pas" / "settings.json pas chargé".

2. **Comparer `pwsh & binary` vs `Process.Start`** : si les timings divergent d'un ordre de grandeur, le coût caché est dans la **création** du child process (Defender, antivirus, EDR), pas dans l'exécution.

3. **Touch du marker `.git/statusline-last-fetch`** pour bypass le fetch : si ça résout le problème, c'est le spawn fetch. Test diagnostic d'1 ligne, sans toucher au code.

## Le fix

```rust
if needs_fetch {
    // Touch d'abord pour empecher d'autres ticks de re-spawn pendant que celui-ci demarre.
    touch(&marker);
    // Le spawn lui-meme coute ~300 ms sur Windows quand Defender realtime est actif :
    // chaque creation de process git est scannee. DETACHED_PROCESS ne sauve pas ce cout,
    // il rend juste le process enfant detache une fois cree. On detache donc aussi LA CREATION
    // elle-meme dans un thread daemon, pour que la main thread retourne immediatement.
    let dir_owned = dir.to_string();
    std::thread::spawn(move || {
        let mut cmd = Command::new("git");
        cmd.args(["-C", &dir_owned, "fetch", "--quiet"]);
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW | 0x00000008 /* DETACHED_PROCESS */);
        let _ = cmd.spawn();
    });
}
```

Le thread daemon meurt naturellement à la fin de `main()` (process exit), mais entre temps il a eu le temps de spawn son `git fetch` qui, lui, est vraiment détaché et continue indépendamment. Le marker est touché *avant* de spawn le thread, donc même si le thread n'a pas le temps de finir, le tick suivant verra le marker frais et ne re-spawn pas un nouveau fetch.

Commit : `c7392d9 fix(statusline): detach git fetch spawn into a thread`.

## Les leçons

1. **`DETACHED_PROCESS` ne protège que l'enfant une fois créé, pas la création elle-même.** Sous Windows, la création de process est synchrone et coûteuse (scan Defender, hook AV/EDR, ACL checks…). Toute commande `.spawn()` Rust dans une boucle hot doit elle-même être dans un thread, sinon on bloque la main thread pour ~50–300 ms par appel.

2. **Le seuil ~100 ms de Claude Code est silencieux.** Pas de message d'erreur, pas de log, juste : statusline vide. Quand le `statusline-last-input.json` est récent mais l'écran est vide, c'est un abort timing → mesurer le binaire dans le contexte exact (Process.Start avec `WorkingDirectory`).

3. **Reproduire un perf bug demande de copier le contexte de spawn, pas juste l'invocation.** `pwsh & binary` n'est pas équivalent à `Process.Start` parce que pwsh est résident — Defender ne re-scanne pas un process déjà chargé. Pour profiler ce que CC fait, il faut `Process.Start` avec `WorkingDirectory` explicite, et idéalement plusieurs runs pour éliminer le bruit du premier cold-start.

4. **Windows Defender realtime monitoring est une variable d'environnement cachée.** Ajoute typiquement 50–300 ms à chaque process creation. Sur les autres machines de l'user (laptop, phone Android Termux), ce bug peut être invisible parce que pas de Defender realtime. **Le fix doit être appliqué à la source** (thread spawn) plutôt que de demander à l'user de configurer Defender — la portabilité prime.

5. **`statusline-last-input.json` est un excellent canary.** Le binaire l'écrit avant même de commencer à computer l'output. Si mtime récent + statusline invisible = bug **en aval** de la lecture stdin (compute_git, IO, buffer…), pas en amont (settings.json, lancement du binaire).

6. **L'optim `--porcelain=v2 --branch` n'aurait pas suffi.** Le code avait déjà fusionné `git rev-parse` + `git status` en un seul appel pour gagner ~30 ms (cf. commentaire à la ligne 280). Sans le thread spawn, on aurait quand même eu 300 ms de fetch spawn par tick — le seuil aurait été dépassé. **L'optim n°1 du runtime CC, c'est minimiser le nombre de `CreateProcess` sur la main thread**, pas la vitesse d'exécution de chaque process.

## Comment l'éviter à l'avenir

### Règle générale (binaire statusline)

**Tout `Command::spawn()` qui n'a pas besoin d'attendre le résultat doit être enveloppé dans `std::thread::spawn`.** Pas juste `DETACHED_PROCESS`. La règle :

| Use case | Pattern |
|---|---|
| J'ai besoin du résultat de la commande | `.output()` ou `.spawn().wait()` sur la main thread |
| Fire-and-forget, on n'attend rien | `std::thread::spawn(move \|\| { Command::new(...).spawn(); })` |

Le second pattern est **obligatoire** dans le hot path du statusline (~10 Hz). Le premier ne devrait pas exister dans le hot path du tout — préférer la cache à la commande synchrone.

### Règle de profiling

Quand on suspecte un timeout dans un binaire CC :

```powershell
# Mesure dans le contexte exact que CC utilise
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = '$env:USERPROFILE/.claude/statusline.exe'
$psi.WorkingDirectory = '<cwd suspect>'
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
for ($i = 1; $i -le 10; $i++) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Write('{}')
  $p.StandardInput.Close()
  $p.StandardOutput.ReadToEnd() | Out-Null
  $p.WaitForExit()
  Write-Host "$($sw.ElapsedMilliseconds)ms"
}
```

Si la médiane dépasse ~80 ms, il y a un risque d'abort dans certaines sessions CC. Cible : <60 ms steady-state.

### Test de non-régression

À chaque modif du binaire qui touche aux git operations ou aux process spawn, faire tourner le mini-bench ci-dessus dans :
- Un dossier non-git (`%USERPROFILE%`)
- Un git repo "clean" (peu de fichiers, pas de dirty)
- Un git repo "dirty" (beaucoup de modifs, beaucoup de fichiers)

Si l'un des trois dépasse 80 ms : pas mergeable.

## TODOs

- [ ] **Ajouter le mini-bench dans `build.ps1`** : après le build, lancer 5 runs avec `WorkingDirectory = C:\dev\dev-environment` et avorter le déploiement si médiane > 80 ms. Garantie qu'on ne redéploie pas une régression de timing.
- [ ] **Documenter le seuil CC dans le source rust** : ajouter une constante `const CC_ABORT_MS: u64 = 100;` près du `fn main()` avec un commentaire explicatif, pour que la prochaine modif du code sache contre quoi elle se mesure.
- [ ] **Auditer les autres `Command::spawn()` du binaire** : il n'y en a actuellement que deux (`run_git` pour status — sync OK — et le fetch — fixé). Mais à chaque ajout futur, appliquer la règle "fire-and-forget → thread".
- [ ] **Optionnel** : exclure `~/.claude/statusline.exe` et `git.exe` des scans Defender realtime. Réduit le runtime steady-state de ~50 ms supplémentaires. Trade-off sécurité minime (git.exe est signé Microsoft, statusline.exe est local et reconnu).

## Annexe : signaux à checker en priorité quand la statusline disparaît

```powershell
# 1. Le binaire est-il bien lancé ? (mtime récent = oui)
ls ~/.claude/statusline-last-input.json

# 2. Quel cwd est passé au binaire ?
cat ~/.claude/statusline-last-input.json | ConvertFrom-Json | Select-Object cwd, @{N='current_dir';E={$_.workspace.current_dir}}

# 3. Timing dans le cwd suspect (le test qui reproduit CC)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = '$env:USERPROFILE/.claude/statusline.exe'
$psi.WorkingDirectory = '<cwd suspect>'
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = [System.Diagnostics.Process]::Start($psi)
$p.StandardInput.Write('{"cwd":"<cwd suspect avec doubles backslash>"}')
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd()
$p.WaitForExit()
"$($sw.ElapsedMilliseconds)ms / $($out.Length) bytes"

# 4. Bypass fetch pour isoler : touch le marker, refaire le test
(Get-Item '<cwd>/.git/statusline-last-fetch').LastWriteTime = (Get-Date)
# → si timing chute drastiquement, c'est le fetch spawn qui coûte
```

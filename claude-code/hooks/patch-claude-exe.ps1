# Auto-patch de claude.exe au demarrage de session.
#
# Pourquoi : claude.exe applique un clamp `Math.max(1, refreshInterval) * 1000`
# (= refreshInterval >= 1 seconde) sur la cadence d'appel de la statusline
# command. Avec ce clamp, l'animation /effort xhigh/max du statusline Rust
# tourne a 1 Hz max au lieu de la cadence picker (8.93 Hz = M=112ms).
#
# Le patch remplace `Math.max(1,X)*1000` par `Math.max(0,X)*1000` (X = var
# minifiee, change a chaque release Anthropic -> on utilise un regex pour
# trouver le pattern). Same length, in-place replacement.
#
# Logique :
# 1. Skip rapide si mtime de claude.exe == mtime stockee dans le marker
#    (pas d'update depuis la derniere fois qu'on a patche).
# 2. Sinon scanner le binaire avec regex pour trouver le pattern courant,
#    appliquer le patch si nouveau, no-op si deja patche.
# 3. Mettre a jour le marker avec la nouvelle mtime.
#
# Si on a re-patche, on emet un systemMessage pour signaler a l'user qu'il
# faut redemarrer une session (la session courante a deja charge le binaire
# non patche en memoire).

$ErrorActionPreference = 'SilentlyContinue'

# Localiser claude.exe
$claudePath = $null
try { $claudePath = (Get-Command claude.exe -ErrorAction Stop).Source } catch {}
if (-not $claudePath -or -not (Test-Path -LiteralPath $claudePath)) {
    $claudePath = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
}
if (-not (Test-Path -LiteralPath $claudePath)) { exit 0 }

# Skip si mtime inchangee depuis le dernier patch
$markerPath = Join-Path $env:USERPROFILE '.claude\last-patched-claude-exe.txt'
$currentMtime = (Get-Item -LiteralPath $claudePath).LastWriteTime.Ticks.ToString()
if (Test-Path -LiteralPath $markerPath) {
    $stored = (Get-Content -Raw -LiteralPath $markerPath).Trim()
    if ($stored -eq $currentMtime) { exit 0 }
}

# Lire le binaire (220+ MB) en ASCII pour pouvoir regex.
$bytes = [System.IO.File]::ReadAllBytes($claudePath)
$text  = [System.Text.Encoding]::ASCII.GetString($bytes)

# PATCH 1 - Pattern : Math.max(1,X)*1000 ou X est un ident d'une lettre (minifie Bun).
# On exige aussi que ce soit le clamp du statusLine refreshInterval (verif
# par contexte : presence de "statusLine?.refreshInterval" dans les 300
# chars precedents) pour eviter de toucher un autre Math.max(1, ...)*1000
# eventuel.
$pattern1 = 'Math\.max\(1,([a-zA-Z_$])\)\*1000'
$matches1 = [regex]::Matches($text, $pattern1)

$applied = @()
$warnings = @()
$toApply = @()

foreach ($m in $matches1) {
    $idx = $m.Index
    $contextStart = [Math]::Max(0, $idx - 300)
    $context = $text.Substring($contextStart, $idx - $contextStart)
    if ($context -notmatch 'statusLine\?\.refreshInterval') {
        # Pas le bon Math.max(1,...) -> skip
        continue
    }
    $varName = $m.Groups[1].Value
    $newStr = "Math.max(0,$varName)*1000"
    $toApply += [PSCustomObject]@{
        Name = "refreshInterval-clamp-on-var-$varName"
        Idx  = $idx
        Len  = $m.Length
        New  = $newStr
    }
}

# PATCH 3 - Statusline debounce. Pattern : =HOOK(()=>{FN()},300)
# Le composant statusline crée R = VC(() => { p() }, 300) ou VC est un hook
# debounce (Bun-minified, renomme entre releases : etait HC, maintenant VC).
# Le pattern : =[hook](()=>{[fn]()},300) avec hook = 1-3 chars, fn = 1 char.
# On verifie le contexte (presence de "statusLine" ou "executeCommand" ou
# "onResult" dans les 600 chars precedents pour s'assurer que c'est le bon
# debounce et pas un autre dans le binaire).
#
# Le debounce de 300ms empeche refreshInterval < 300ms de fonctionner :
# _9(R, 112) arme R() toutes les 112ms, mais R() est un debouncer qui reset
# son timer a chaque appel, donc p() (le vrai spawn) n'est JAMAIS appele
# tant que R() est rearme avant 300ms. Resultat : statusline figee apres
# le mount initial.
#
# Replacement : 300 -> ` 50` (espace + 50). 3 chars = 3 chars, in-place OK.
# JavaScript ignore le whitespace -> setTimeout(fn, 50) = 50ms.
$pattern3 = '=([a-zA-Z_$]{1,3})\(\(\)=>\{([a-zA-Z_$])\(\)\},300\)'
$matches3 = [regex]::Matches($text, $pattern3)

foreach ($m in $matches3) {
    $idx = $m.Index
    $contextStart = [Math]::Max(0, $idx - 600)
    $context = $text.Substring($contextStart, $idx - $contextStart)
    if ($context -notmatch 'statusLine|executeCommand|onResult') {
        continue
    }
    $hook = $m.Groups[1].Value
    $fn = $m.Groups[2].Value
    $oldStr = "=$hook(()=>{$fn()},300)"
    $newStr = "=$hook(()=>{$fn()}, 50)"
    if ($oldStr.Length -ne $newStr.Length) {
        $warnings += "statusline-debounce: lengths differ ($($oldStr.Length) vs $($newStr.Length))"
        continue
    }
    $toApply += [PSCustomObject]@{
        Name = "statusline-debounce-on-hook-$hook-fn-$fn"
        Idx  = $idx
        Len  = $m.Length
        New  = $newStr
    }
}

# PATCH 4 & 5 - statusline tick keep-alive en idle (decouvert 2026-05-20)
#
# Le hook qui appelle R() toutes les 112ms est `function _9(H,q){...}` :
#
#   function _9(H,q){
#     let $=Wt.useRef(H);$.current=H;
#     let K=Wt.useContext(YQ);
#     let _=Wt.useMemo(()=>
#       !K||q===null?gZH:                              <-- PATTERN A
#       (f)=>{let A=!1,z;let Y=()=>{
#         if(A)return;
#         try{$.current()}
#         finally{if(!A)z=K.setTimeout(Y,q)}           <-- PATTERN B (×1)
#       };
#       return z=K.setTimeout(Y,q),                    <-- PATTERN B (×2)
#       ()=>{A=!0,z()}},
#       [K,q]);
#     Wt.useSyncExternalStore(_,Cs8);
#   }
#
# K=useContext(YQ) est le RootStore Ink, qui devient null ou suspend
# `K.setTimeout` pendant les phases idle entre 2 messages assistant. Resultat :
# R() ne fire plus, p() (le spawn statusline.exe) jamais appele -> animation
# figee ~30s entre les vagues d'activite.
#
# Verifie empiriquement le 2026-05-20 via instrumentation `~/.claude/statusline-tick-log.txt` :
# 5 gaps de ~30s consecutifs, cycle 60s actif + 30s freeze repetitif. Le picker
# /effort ne freeze pas car il utilise `q.subscribeKeepAlive` (vz function),
# different code path qui survit l'idle. La statusline statique externe utilise
# `_9` qui depend de K.setTimeout = pas idle-safe.
#
# Fix : forcer le path actif (false?gZH: au lieu de !K||q===null?gZH:) ET
# remplacer K.setTimeout par Is8 (le setTimeout natif fallback deja defini
# pres de la def de Is8). Padding avec espaces pour conserver la longueur.
# JS ignore le whitespace -> code valide.
#
# Is8 = (H,q)=>{let $=setTimeout(H,q);return()=>clearTimeout($)}
# -> retourne une cleanup function, compatible avec z() qui appelle z comme
#    fonction dans le cleanup.

# PATCH 4 : force `false?gZH:` (toujours path actif) au lieu de `!K||q===null?gZH:`
$old4 = '!K||q===null?gZH:'
$new4 = 'false?gZH:       '   # 7 espaces de padding pour conserver 17 chars
if ($old4.Length -ne $new4.Length) {
    $warnings += "tick-force-active: lengths differ ($($old4.Length) vs $($new4.Length))"
} else {
    $idx4 = $text.IndexOf($old4)
    if ($idx4 -lt 0) {
        # Verifier si deja patche
        $alreadyP4 = $text.Contains($new4)
        if (-not $alreadyP4) {
            $warnings += "tick-force-active: pattern '!K||q===null?gZH:' introuvable"
        }
    } else {
        # Verif contexte : doit etre dans la def de _9, donc dans 200 chars
        # avant on attend 'function _9(' OU 'useContext(YQ)'
        $contextStart = [Math]::Max(0, $idx4 - 250)
        $context = $text.Substring($contextStart, $idx4 - $contextStart)
        if ($context -notmatch 'function _9\(|useContext\(YQ\)') {
            $warnings += "tick-force-active: contexte non reconnu autour de offset $idx4"
        } else {
            $toApply += [PSCustomObject]@{
                Name = "tick-force-active-path"
                Idx  = $idx4
                Len  = $old4.Length
                New  = $new4
            }
        }
    }
}

# PATCH 5 : remplace `K.setTimeout(Y,q)` (×2) par `Is8(Y,q)` + padding
# Is8 retourne une cleanup function -> compatible avec le cleanup z() du _9.
$old5 = 'K.setTimeout(Y,q)'
$new5 = 'Is8(Y,q)         '   # 9 espaces de padding pour conserver 17 chars
if ($old5.Length -ne $new5.Length) {
    $warnings += "tick-native-settimeout: lengths differ ($($old5.Length) vs $($new5.Length))"
} else {
    # Trouver TOUTES les occurrences (attendu : 2, toutes dans _9)
    $idx5 = 0
    $found5 = @()
    while (($idx5 = $text.IndexOf($old5, $idx5)) -ge 0) {
        $found5 += $idx5
        $idx5++
    }
    if ($found5.Count -eq 0) {
        $alreadyP5 = $text.Contains($new5)
        if (-not $alreadyP5) {
            $warnings += "tick-native-settimeout: pattern 'K.setTimeout(Y,q)' introuvable"
        }
    } else {
        foreach ($occ in $found5) {
            # Verif contexte : doit etre proche de la def _9 (a 50KB pres)
            $contextStart = [Math]::Max(0, $occ - 300)
            $context = $text.Substring($contextStart, $occ - $contextStart)
            if ($context -notmatch '\$\.current\(\)|useSyncExternalStore|function _9\(') {
                $warnings += "tick-native-settimeout: contexte non reconnu a offset $occ, skip"
                continue
            }
            $toApply += [PSCustomObject]@{
                Name = "tick-native-settimeout-at-$occ"
                Idx  = $occ
                Len  = $old5.Length
                New  = $new5
            }
        }
    }
}

if ($toApply.Count -eq 0) {
    # Verif : peut-etre deja patche -> chercher Math.max(0,X)*1000 dans le bon contexte
    $alreadyPatched = $false
    foreach ($m in [regex]::Matches($text, 'Math\.max\(0,[a-zA-Z_$]\)\*1000')) {
        $idx = $m.Index
        $contextStart = [Math]::Max(0, $idx - 300)
        $context = $text.Substring($contextStart, $idx - $contextStart)
        if ($context -match 'statusLine\?\.refreshInterval') {
            $alreadyPatched = $true
            break
        }
    }
    $currentMtime | Set-Content -LiteralPath $markerPath -Encoding UTF8
    if (-not $alreadyPatched) {
        $msg = "[patch-claude-exe] WARN: pattern refreshInterval-clamp introuvable. Le binaire claude.exe a peut-etre change de structure -- l'animation 8.93 Hz pourrait ne plus fonctionner. Verifier manuellement avec : Select-String -Pattern 'Math.max\(1,.\)\*1000' claude.exe"
        @{ systemMessage = $msg } | ConvertTo-Json -Compress
    }
    exit 0
}

# Rename-trick pour pouvoir ecrire meme si le binaire est en cours d'execution
$tmp = "$claudePath.repatch-$([System.IO.Path]::GetRandomFileName())"
try {
    Move-Item -LiteralPath $claudePath -Destination $tmp -Force
} catch {
    @{ systemMessage = "[patch-claude-exe] ECHEC rename: $_" } | ConvertTo-Json -Compress
    exit 0
}

# Appliquer les patches in-place
$bytes = [System.IO.File]::ReadAllBytes($tmp)
foreach ($p in $toApply) {
    $newBytes = [System.Text.Encoding]::ASCII.GetBytes($p.New)
    if ($newBytes.Length -ne $p.Len) {
        # Tailles differentes = decalage de bytes = corruption. Skip.
        $warnings += "$($p.Name) : tailles old/new differentes ($($p.Len) vs $($newBytes.Length)), skip"
        continue
    }
    for ($j = 0; $j -lt $newBytes.Length; $j++) {
        $bytes[$p.Idx + $j] = $newBytes[$j]
    }
    $applied += $p.Name
}

try {
    [System.IO.File]::WriteAllBytes($claudePath, $bytes)
} catch {
    # Rollback en cas d'echec d'ecriture
    Move-Item -LiteralPath $tmp -Destination $claudePath -Force
    @{ systemMessage = "[patch-claude-exe] ECHEC ecriture: $_" } | ConvertTo-Json -Compress
    exit 0
}

# Cleanup
Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue

# Marker = nouvelle mtime du fichier patche
(Get-Item -LiteralPath $claudePath).LastWriteTime.Ticks.ToString() |
    Set-Content -LiteralPath $markerPath -Encoding UTF8

$msg = "[patch-claude-exe] Re-patches appliques apres update Claude Code: $($applied -join ', '). Redemarre une nouvelle session terminal pour activer l'animation 8.93 Hz du statusline."
if ($warnings.Count -gt 0) {
    $msg += " WARN: $($warnings -join '; ')"
}
@{ systemMessage = $msg } | ConvertTo-Json -Compress

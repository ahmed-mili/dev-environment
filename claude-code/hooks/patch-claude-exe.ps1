# Auto-patch de claude.exe au demarrage de session.
#
# Pourquoi : claude.exe applique un clamp `Math.max(1, refreshInterval) * 1000`
# (= refreshInterval >= 1 seconde) sur la cadence d'appel de la statusline
# command. Avec ce clamp, l'animation /effort xhigh/max du statusline Rust
# tourne a 1 Hz max au lieu de la cadence picker (8.93 Hz = M=112ms). De plus,
# le composant statusline est wrappe dans un debouncer 300ms qui empeche
# 112ms < 300ms de faire fire le spawn. On corrige les deux.
#
# Patches actifs (2) :
#   1. refreshInterval-clamp : Math.max(1,X)*1000 -> Math.max(0,X)*1000
#   2. statusline-debounce   : =H(()=>{F()},300)  -> =H(()=>{F()}, 50)
# X, H, F sont des vars minifiees Bun qui changent a chaque release Anthropic.
# Les patches sont regex-based avec verification de contexte pour rester
# robustes aux re-minifications.
#
# Historique (pour reference si le bug idle ressurgit) :
# Sur claude.exe v2.1.145, le tick statusline freezait ~30s entre les vagues
# d'activite a cause d'une garde `!K||q===null?gZH:` qui short-circuitait
# vers une fn no-op pendant l'idle (K=useContext(YQ) devenait null entre
# 2 messages assistant). On appliquait alors 2 patches additionnels
# (tick-force-active + tick-native-settimeout) pour forcer le path actif.
# Anthropic a refactor le code dans v2.1.147 : le tick utilise maintenant
# `let M=!1,O,j=()=>{...O=_.setTimeout(j,q)},return O=_.setTimeout(j,q)` sans
# garde idle -> path toujours actif par construction. Patches obsoletes,
# retires. Le bootstrap force `claude update` apres install pour garantir
# v2.1.147+ partout.
#
# Logique :
# 1. Skip rapide si mtime de claude.exe == mtime stockee dans le marker
#    (pas d'update depuis la derniere fois qu'on a patche).
# 2. Sinon scanner le binaire avec regex pour trouver les patterns courants,
#    appliquer les patches si nouveaux, no-op si deja patche.
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

$applied = @()
$warnings = @()
$toApply = @()

# PATCH 1 - refreshInterval clamp. Pattern : Math.max(1,X)*1000 ou X est un
# ident d'une lettre (minifie Bun). On exige aussi que ce soit le clamp du
# statusLine refreshInterval (verif par contexte : presence de
# "statusLine?.refreshInterval" dans les 300 chars precedents) pour eviter
# de toucher un autre Math.max(1, ...)*1000 eventuel.
$pattern1 = 'Math\.max\(1,([a-zA-Z_$])\)\*1000'
$matches1 = [regex]::Matches($text, $pattern1)

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

# PATCH 2 - Statusline debounce. Pattern : =HOOK(()=>{FN()},300)
# Le composant statusline cree R = VC(() => { p() }, 300) ou VC est un hook
# debounce (Bun-minified, renomme entre releases : etait HC, puis VC, puis
# Kb...). Le pattern : =[hook](()=>{[fn]()},300) avec hook = 1-3 chars,
# fn = 1 char. On verifie le contexte (presence de "statusLine" ou
# "executeCommand" ou "onResult" dans les 600 chars precedents pour
# s'assurer que c'est le bon debounce et pas un autre dans le binaire).
#
# Replacement : 300 -> ` 50` (espace + 50). 3 chars = 3 chars, in-place OK.
# JavaScript ignore le whitespace -> setTimeout(fn, 50) = 50ms.
$pattern2 = '=([a-zA-Z_$]{1,3})\(\(\)=>\{([a-zA-Z_$])\(\)\},300\)'
$matches2 = [regex]::Matches($text, $pattern2)

foreach ($m in $matches2) {
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

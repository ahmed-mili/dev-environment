# Auto-patch de claude.exe au demarrage de session.
#
# Pourquoi : chaque auto-update de Claude Code remplace claude.exe par un
# binaire frais qui n'a plus les 3 patches qui rendent l'animation 10 Hz
# possible (cf. memory project `claude-exe-statusline-patch`). Sans ces
# patches, refreshInterval=0.1 dans settings.json est rejete par le Zod
# schema -> aucun re-render automatique -> statusline figee.
#
# Logique :
# 1. Skip rapide si mtime de claude.exe == mtime stockee dans le marker
#    (pas d'update depuis la derniere fois qu'on a patche).
# 2. Sinon scanner le binaire pour les 3 strings cibles, appliquer ce qui
#    manque (idempotent, ne touche pas un binaire deja patche).
# 3. Mettre a jour le marker avec la nouvelle mtime.
#
# Si on a re-patche quoi que ce soit, on emet un systemMessage pour signaler
# a l'user qu'il faut redemarrer une session (la session courante a deja
# charge le binaire non patche en memoire).

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

# Lire le binaire (250+ MB) et le decoder en ASCII pour IndexOf.
# Encoding.ASCII remplace les bytes > 127 par '?' (0x3F), mais la longueur
# du string reste = longueur du buffer => les offsets IndexOf sont valides
# pour indexer directement dans $bytes.
$bytes = [System.IO.File]::ReadAllBytes($claudePath)
$text  = [System.Text.Encoding]::ASCII.GetString($bytes)

# Definition des 3 patches. Tous ont same length(old) == length(new) =>
# replacement in-place sans decalage.
$patches = @(
    [PSCustomObject]@{
        Name = 'refreshInterval-runtime-clamp'
        Old  = 'Math.max(1,p)*1000'
        New  = 'Math.max(0,p)*1000'
    },
    [PSCustomObject]@{
        Name = 'refreshInterval-Zod-schema'
        Old  = 'refreshInterval:h.number().min(1).optional()'
        New  = 'refreshInterval:h.number().min(0).optional()'
    },
    [PSCustomObject]@{
        Name = 'statusline-debounce'
        Old  = 'm=HC(()=>{I()},300)'
        New  = 'm=HC(()=>{I()}, 50)'
    }
)

$applied = @()
$warnings = @()
$toApply = @()

foreach ($p in $patches) {
    if ($text.IndexOf($p.New) -ge 0) {
        # Deja patche
        continue
    }
    $idx = $text.IndexOf($p.Old)
    if ($idx -lt 0) {
        # Ni l'original ni le patche -> structure du binaire a change
        $warnings += "$($p.Name) : pattern introuvable"
        continue
    }
    $toApply += [PSCustomObject]@{ Name = $p.Name; Idx = $idx; New = $p.New }
}

if ($toApply.Count -eq 0) {
    # Rien a patcher : mettre a jour le marker pour eviter de rescanner
    $currentMtime | Set-Content -LiteralPath $markerPath -Encoding UTF8
    if ($warnings.Count -gt 0) {
        $msg = "[patch-claude-exe] WARN: $($warnings -join '; '). Le binaire claude.exe a peut-etre change de structure -- l'animation 10 Hz pourrait ne plus fonctionner."
        @{ systemMessage = $msg } | ConvertTo-Json -Compress
    }
    exit 0
}

# Rename-trick pour pouvoir ecrire meme si le binaire est en cours d'execution
# (la session courante de claude.exe tient un handle sur le fichier).
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

# Cleanup : le fichier renomme peut etre supprime maintenant (sessions
# concurrentes tiennent toujours leur handle sur l'ancien fichier mais
# Windows libere a la fermeture). Si echec, pas grave, c'est juste un
# fichier orphelin dans ~/.local/bin/ a nettoyer manuellement.
Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue

# Marker = nouvelle mtime du fichier patche
(Get-Item -LiteralPath $claudePath).LastWriteTime.Ticks.ToString() |
    Set-Content -LiteralPath $markerPath -Encoding UTF8

$msg = "[patch-claude-exe] Re-patches appliques apres update Claude Code: $($applied -join ', '). Redemarre une nouvelle session terminal pour activer l'animation 10 Hz du statusline."
if ($warnings.Count -gt 0) {
    $msg += " WARN: $($warnings -join '; ')"
}
@{ systemMessage = $msg } | ConvertTo-Json -Compress

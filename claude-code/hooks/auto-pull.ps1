# Auto-pull on Claude Code SessionStart, scoped to repos under C:\dev
# et au dossier ~/.claude (qui est lui-même un repo git).
# Fails loud on conflict (no auto-merge). Silent no-op otherwise.

$ErrorActionPreference = 'SilentlyContinue'

$repoRoot = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { exit 0 }

$repoRootNorm = ($repoRoot -replace '/', '\').ToLower()
$userClaude = (($env:USERPROFILE -replace '/', '\').ToLower()) + '\.claude'
$inScope = $repoRootNorm.StartsWith("c:\dev\") -or $repoRootNorm -eq $userClaude
if (-not $inScope) { exit 0 }

$remotes = & git -C $repoRoot remote
if (-not $remotes) { exit 0 }

$output = & git -C $repoRoot pull --ff-only 2>&1 | Out-String
$exitCode = $LASTEXITCODE
$msg = $output.Trim()
$repoName = Split-Path $repoRoot -Leaf

if ($exitCode -eq 0) {
    if ($msg -and $msg -notmatch "Already up to date" -and $msg -notmatch "Deja a jour") {
        @{ systemMessage = "[auto-pull $repoName] $msg" } | ConvertTo-Json -Compress
    }
} else {
    $warning = "[auto-pull $repoName] ECHEC: $msg`n--> Une autre machine a poussé des commits incompatibles avec ton état local. Résous avant de continuer."
    @{ systemMessage = $warning } | ConvertTo-Json -Compress
}

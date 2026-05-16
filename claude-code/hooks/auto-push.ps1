# Auto-commit + push on Claude Code SessionEnd, scoped to repos under C:\dev
# et au dossier ~/.claude (qui est lui-même un repo git).
# Commits any working-tree changes as "wip auto-sync (<host> <date>)" then pushes.

$ErrorActionPreference = 'SilentlyContinue'

$repoRoot = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { exit 0 }

$repoRootNorm = ($repoRoot -replace '/', '\').ToLower()
$userClaude = (($env:USERPROFILE -replace '/', '\').ToLower()) + '\.claude'
$inScope = $repoRootNorm.StartsWith("c:\dev\") -or $repoRootNorm -eq $userClaude
if (-not $inScope) { exit 0 }

$remotes = & git -C $repoRoot remote
if (-not $remotes) { exit 0 }

$status = & git -C $repoRoot status --porcelain
if ($status) {
    & git -C $repoRoot add -A | Out-Null
    $hostname = $env:COMPUTERNAME.ToLower()
    $dateStr = Get-Date -Format "yyyy-MM-dd HH:mm"
    & git -C $repoRoot commit -m "wip auto-sync ($hostname $dateStr)" 2>&1 | Out-Null
}

$pushOutput = & git -C $repoRoot push 2>&1 | Out-String
$pushExit = $LASTEXITCODE
$repoName = Split-Path $repoRoot -Leaf

if ($pushExit -ne 0) {
    @{ systemMessage = "[auto-push $repoName] ECHEC: $($pushOutput.Trim())" } | ConvertTo-Json -Compress
}

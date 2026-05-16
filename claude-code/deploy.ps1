# Sync bidirectionnel entre dev-environment/claude-code/ et ~/.claude/
#
# Usage :
#   .\deploy.ps1 -Pull    # depuis le repo vers ~/.claude/  (bootstrap ou réinit)
#   .\deploy.ps1 -Push    # depuis ~/.claude/ vers le repo  (avant git commit/push)
#
# Ne touche QUE aux fichiers trackés du repo : statusline.ps1, settings.json,
# hooks/, skills/. Le reste de ~/.claude/ (sessions, history, plugins officiels,
# credentials) est laissé intact.

[CmdletBinding(DefaultParameterSetName='Pull')]
param(
    [Parameter(ParameterSetName='Pull')] [switch]$Pull,
    [Parameter(ParameterSetName='Push')] [switch]$Push
)

if (-not $Pull -and -not $Push) {
    Write-Host "Usage : .\deploy.ps1 -Pull   |   .\deploy.ps1 -Push" -ForegroundColor Yellow
    exit 1
}

$ErrorActionPreference = 'Stop'
$RepoClaude = Split-Path -Parent $PSCommandPath          # ...\dev-environment\claude-code
$HomeClaude = "$env:USERPROFILE\.claude"

# Custom skills tracked dans le repo (whitelist explicite)
$CustomSkills = @(
    'copy-edit', 'css-layout-check', 'edit-block', 'lucide-icons',
    'release', 'root-cause-fix', 'smart-edit', 'sticky-column-bleed-fix',
    'webapp-deploy'
)

function Copy-One($from, $to) {
    if (-not (Test-Path $from)) {
        Write-Host "  ✗ skip $from (absent)" -ForegroundColor DarkGray
        return
    }
    $parent = Split-Path -Parent $to
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    Copy-Item $from $to -Force -Recurse
    Write-Host "  ✓ $(Split-Path -Leaf $from)" -ForegroundColor Green
}

if ($Pull) {
    Write-Host "=== Pull : $RepoClaude → $HomeClaude ===" -ForegroundColor Cyan
    Copy-One "$RepoClaude\statusline.ps1" "$HomeClaude\statusline.ps1"
    Copy-One "$RepoClaude\settings.json"  "$HomeClaude\settings.json"

    Write-Host "Hooks :" -ForegroundColor Cyan
    if (Test-Path "$RepoClaude\hooks") {
        New-Item -ItemType Directory -Force "$HomeClaude\hooks" | Out-Null
        Get-ChildItem "$RepoClaude\hooks" -File | ForEach-Object {
            Copy-One $_.FullName "$HomeClaude\hooks\$($_.Name)"
        }
    }

    Write-Host "Skills :" -ForegroundColor Cyan
    foreach ($s in $CustomSkills) {
        Copy-One "$RepoClaude\skills\$s" "$HomeClaude\skills\$s"
    }

    Write-Host "`nFait. Relance Claude Code pour que les nouvelles skills/settings soient pris en compte." -ForegroundColor Yellow
}

if ($Push) {
    Write-Host "=== Push : $HomeClaude → $RepoClaude ===" -ForegroundColor Cyan
    Copy-One "$HomeClaude\statusline.ps1" "$RepoClaude\statusline.ps1"
    Copy-One "$HomeClaude\settings.json"  "$RepoClaude\settings.json"

    Write-Host "Hooks :" -ForegroundColor Cyan
    if (Test-Path "$HomeClaude\hooks") {
        New-Item -ItemType Directory -Force "$RepoClaude\hooks" | Out-Null
        Get-ChildItem "$HomeClaude\hooks" -File | ForEach-Object {
            Copy-One $_.FullName "$RepoClaude\hooks\$($_.Name)"
        }
    }

    Write-Host "Skills (whitelist 9 custom uniquement) :" -ForegroundColor Cyan
    foreach ($s in $CustomSkills) {
        Copy-One "$HomeClaude\skills\$s" "$RepoClaude\skills\$s"
    }

    Write-Host "`nFait. N'oublie pas : cd dev-environment ; git add -A ; git commit ; git push" -ForegroundColor Yellow
}

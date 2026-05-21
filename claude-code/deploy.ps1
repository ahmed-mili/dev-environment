# Bidirectional sync between dev-environment/claude-code/ and ~/.claude/
#
# Usage :
#   .\deploy.ps1 -Pull    # from repo to ~/.claude/  (bootstrap or reinit)
#   .\deploy.ps1 -Push    # from ~/.claude/ to repo  (before git commit/push)
#
# Touches ONLY the repo-tracked files: statusline.ps1, settings.json,
# hooks/, skills/. The rest of ~/.claude/ (sessions, history, official
# plugins, credentials) is left intact.
#
# ---------------------------------------------------------------------------
# ASCII-only source - DO NOT add non-ASCII chars to this file.
# Reason: Windows PowerShell 5.1 reads .ps1 files from disk in CP-1252 when
# no UTF-8 BOM is present. Multi-byte UTF-8 sequences for glyphs like check
# marks or arrows decode to smart-quote bytes in CP-1252, which PS 5.1
# treats as string delimiters -> parser breaks far from the offending char.
# Stay ASCII-only. See windows/install.ps1 commit 58f9da3 for full analysis.
# ---------------------------------------------------------------------------

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

# Custom skills tracked in the repo (explicit whitelist)
$CustomSkills = @(
    'claude-file-recovery', 'copy-edit', 'css-layout-check', 'deploy-safety',
    'edit-block', 'lucide-icons', 'release', 'root-cause-fix', 'smart-edit',
    'sticky-column-bleed-fix', 'webapp-deploy'
)

# Local-only hooks : present in ~/.claude/hooks/ but never pushed to the
# public repo. Empty since we started publishing patch-claude-exe.ps1
# (see README for SAC + Defender exception prereqs).
$LocalOnlyHooks = @()

function Copy-One($from, $to) {
    if (-not (Test-Path $from)) {
        Write-Host "  x skip $from (missing)" -ForegroundColor DarkGray
        return
    }
    $parent = Split-Path -Parent $to
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    # PowerShell gotcha : `Copy-Item <dir> <existing-dir> -Recurse` copies
    # INSIDE instead of replacing, producing skills/X/X/ parasite. So we
    # wipe the target dir first. For files, -Force is enough.
    if ((Test-Path $from -PathType Container) -and (Test-Path $to)) {
        Remove-Item $to -Recurse -Force
    }
    Copy-Item $from $to -Force -Recurse
    Write-Host "  + $(Split-Path -Leaf $from)" -ForegroundColor Green
}

if ($Pull) {
    Write-Host "=== Pull : $RepoClaude -> $HomeClaude ===" -ForegroundColor Cyan
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

    Write-Host "`nDone. Restart Claude Code so the new skills/settings are picked up." -ForegroundColor Yellow
}

if ($Push) {
    Write-Host "=== Push : $HomeClaude -> $RepoClaude ===" -ForegroundColor Cyan
    Copy-One "$HomeClaude\statusline.ps1" "$RepoClaude\statusline.ps1"
    Copy-One "$HomeClaude\settings.json"  "$RepoClaude\settings.json"

    Write-Host "Hooks :" -ForegroundColor Cyan
    if (Test-Path "$HomeClaude\hooks") {
        New-Item -ItemType Directory -Force "$RepoClaude\hooks" | Out-Null
        Get-ChildItem "$HomeClaude\hooks" -File | ForEach-Object {
            if ($LocalOnlyHooks -contains $_.Name) {
                Write-Host "  o skip $($_.Name) (local-only)" -ForegroundColor DarkYellow
                return
            }
            Copy-One $_.FullName "$RepoClaude\hooks\$($_.Name)"
        }
    }

    Write-Host "Skills (custom whitelist only) :" -ForegroundColor Cyan
    foreach ($s in $CustomSkills) {
        Copy-One "$HomeClaude\skills\$s" "$RepoClaude\skills\$s"
    }

    Write-Host "`nDone. Reminder : cd dev-environment ; git add -A ; git commit ; git push" -ForegroundColor Yellow
}

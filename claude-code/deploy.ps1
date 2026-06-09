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
# public repo. Currently empty -- all hooks in ~/.claude/hooks/ are
# committed.
$LocalOnlyHooks = @()

# ---------------------------------------------------------------------------
# Copy primitive : returns a status string instead of printing, so the caller
# can format the result inside a table row.
# ---------------------------------------------------------------------------
function Copy-One($from, $to) {
    if (-not (Test-Path $from)) { return 'SKIP' }
    $parent = Split-Path -Parent $to
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    # PowerShell gotcha : `Copy-Item <dir> <existing-dir> -Recurse` copies
    # INSIDE instead of replacing, producing skills/X/X/ parasite. So we
    # wipe the target dir first. For files, -Force is enough.
    if ((Test-Path $from -PathType Container) -and (Test-Path $to)) {
        Remove-Item $to -Recurse -Force
    }
    Copy-Item $from $to -Force -Recurse
    return 'OK'
}

# ---------------------------------------------------------------------------
# ASCII table helpers : +---+---+ style. Status column is fixed width 6
# (max of 'Status' header / 'OK' / 'SKIP' / 'LOCAL' = 6 chars).
# ---------------------------------------------------------------------------
$StatusColW = 6

function New-TableBorder($nameWidth) {
    return '+' + ('-' * ($nameWidth + 2)) + '+' + ('-' * ($StatusColW + 2)) + '+'
}

function Write-TableHeader($title, $count, $nameWidth) {
    $border = New-TableBorder $nameWidth
    Write-Host ''
    Write-Host ("{0} ({1}) :" -f $title, $count) -ForegroundColor Cyan
    Write-Host ("  " + $border) -ForegroundColor DarkGray
    Write-Host ("  | " + ('Name'.PadRight($nameWidth)) + " | " + ('Status'.PadRight($StatusColW)) + " |")
    Write-Host ("  " + $border) -ForegroundColor DarkGray
}

function Write-TableRow($name, $status, $nameWidth) {
    $color = switch ($status) {
        'OK'    { 'Green' }
        'SKIP'  { 'DarkGray' }
        'LOCAL' { 'DarkYellow' }
        default { 'Red' }
    }
    $pipe = '|'
    Write-Host ("  " + $pipe + " ") -NoNewline -ForegroundColor DarkGray
    Write-Host ($name.PadRight($nameWidth)) -NoNewline
    Write-Host (" " + $pipe + " ") -NoNewline -ForegroundColor DarkGray
    Write-Host ($status.PadRight($StatusColW)) -NoNewline -ForegroundColor $color
    Write-Host (" " + $pipe) -ForegroundColor DarkGray
}

function Write-TableFooter($nameWidth) {
    Write-Host ("  " + (New-TableBorder $nameWidth)) -ForegroundColor DarkGray
}

function Get-NameWidth($names) {
    $maxName = ($names | Measure-Object -Maximum -Property Length).Maximum
    if ($maxName -lt 4) { $maxName = 4 }   # 'Name' header is 4 chars
    return $maxName
}

# ---------------------------------------------------------------------------
# Pull : repo -> ~/.claude/
# ---------------------------------------------------------------------------
if ($Pull) {
    Write-Host ("=== Pull : {0} -> {1} ===" -f $RepoClaude, $HomeClaude) -ForegroundColor Cyan

    # Top-level files
    $files = @('statusline.ps1', 'settings.json')
    $fileW = Get-NameWidth $files
    Write-TableHeader 'Files' $files.Count $fileW
    foreach ($f in $files) {
        $st = Copy-One "$RepoClaude\$f" "$HomeClaude\$f"
        Write-TableRow $f $st $fileW
    }
    Write-TableFooter $fileW

    # Hooks
    if (Test-Path "$RepoClaude\hooks") {
        New-Item -ItemType Directory -Force "$HomeClaude\hooks" | Out-Null
        $hooks = @(Get-ChildItem "$RepoClaude\hooks" -File | Sort-Object Name)
        $hookNames = @($hooks | ForEach-Object { $_.Name })
        $hookW = Get-NameWidth $hookNames
        Write-TableHeader 'Hooks' $hooks.Count $hookW
        foreach ($h in $hooks) {
            $st = Copy-One $h.FullName "$HomeClaude\hooks\$($h.Name)"
            Write-TableRow $h.Name $st $hookW
        }
        Write-TableFooter $hookW
    }

    # Skills
    $sortedSkills = $CustomSkills | Sort-Object
    $skillW = Get-NameWidth $sortedSkills
    Write-TableHeader 'Skills' $sortedSkills.Count $skillW
    foreach ($s in $sortedSkills) {
        $st = Copy-One "$RepoClaude\skills\$s" "$HomeClaude\skills\$s"
        Write-TableRow $s $st $skillW
    }
    Write-TableFooter $skillW

    # Device context
    $dcName = 'device-context'
    $dcW = Get-NameWidth @($dcName)
    Write-TableHeader 'Device context' 1 $dcW
    $st = Copy-One "$RepoClaude\device-context" "$HomeClaude\device-context"
    Write-TableRow $dcName $st $dcW
    Write-TableFooter $dcW

    Write-Host "`nDone. Restart Claude Code so the new skills/settings are picked up." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Push : ~/.claude/ -> repo
# ---------------------------------------------------------------------------
if ($Push) {
    Write-Host ("=== Push : {0} -> {1} ===" -f $HomeClaude, $RepoClaude) -ForegroundColor Cyan

    $files = @('statusline.ps1', 'settings.json')
    $fileW = Get-NameWidth $files
    Write-TableHeader 'Files' $files.Count $fileW
    foreach ($f in $files) {
        $st = Copy-One "$HomeClaude\$f" "$RepoClaude\$f"
        Write-TableRow $f $st $fileW
    }
    Write-TableFooter $fileW

    if (Test-Path "$HomeClaude\hooks") {
        New-Item -ItemType Directory -Force "$RepoClaude\hooks" | Out-Null
        $hooks = @(Get-ChildItem "$HomeClaude\hooks" -File | Sort-Object Name)
        $hookNames = @($hooks | ForEach-Object { $_.Name })
        $hookW = Get-NameWidth $hookNames
        Write-TableHeader 'Hooks' $hooks.Count $hookW
        foreach ($h in $hooks) {
            if ($LocalOnlyHooks -contains $h.Name) {
                Write-TableRow $h.Name 'LOCAL' $hookW
                continue
            }
            $st = Copy-One $h.FullName "$RepoClaude\hooks\$($h.Name)"
            Write-TableRow $h.Name $st $hookW
        }
        Write-TableFooter $hookW
    }

    $sortedSkills = $CustomSkills | Sort-Object
    $skillW = Get-NameWidth $sortedSkills
    Write-TableHeader 'Skills' $sortedSkills.Count $skillW
    foreach ($s in $sortedSkills) {
        $st = Copy-One "$HomeClaude\skills\$s" "$RepoClaude\skills\$s"
        Write-TableRow $s $st $skillW
    }
    Write-TableFooter $skillW

    # Device context
    $dcName = 'device-context'
    $dcW = Get-NameWidth @($dcName)
    Write-TableHeader 'Device context' 1 $dcW
    $st = Copy-One "$HomeClaude\device-context" "$RepoClaude\device-context"
    Write-TableRow $dcName $st $dcW
    Write-TableFooter $dcW

    Write-Host "`nDone. Reminder : cd dev-environment ; git add -A ; git commit ; git push" -ForegroundColor Yellow
}

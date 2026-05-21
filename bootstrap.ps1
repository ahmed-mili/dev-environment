#Requires -Version 5.1
<#
.SYNOPSIS
    One-liner bootstrap: clone dev-environment, install Windows bundle, build
    statusline Rust binary, patch claude.exe for 9 Hz animation, deploy Claude
    Code config.

.DESCRIPTION
    Hard prereqs (script will abort otherwise):
    - Smart App Control DISABLED. Otherwise Windows blocks the unsigned
      statusline Rust binary at runtime AND some cargo build-scripts fail
      under SAC. Toggle off in Settings > Privacy & security > Smart App
      Control. WARNING: disabling SAC is permanent (requires full Windows
      reset to re-enable).
    - ELEVATED PowerShell session (admin). Needed to add a Microsoft Defender
      exception on patch-claude-exe.ps1, otherwise flagged
      Trojan:Win32/FileFix.BBA!MTB and quarantined at clone time.

.EXAMPLE
    # From an elevated PowerShell:
    $b="$env:TEMP\dev-env-bootstrap.ps1"; irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1 -OutFile $b; Unblock-File $b; & $b
#>

# ---------------------------------------------------------------------------
# ASCII-only source - DO NOT introduce non-ASCII chars in this file.
# Reason: Windows PowerShell 5.1 reads .ps1 files from disk in CP-1252 when
# no UTF-8 BOM is present (the no-bom CI check enforces no BOM, because BOM
# breaks `iex (irm ...)`). Multi-byte UTF-8 bytes 0x91-0x94 decode to smart
# quotes (U+2018-U+201D) in CP-1252, which PS 5.1 treats as string
# delimiters -> parser breaks far from the offending char. Stay ASCII-only.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$RepoUrl  = 'https://github.com/ahmed-mili/dev-environment.git'
$RepoPath = 'C:\dev\dev-environment'

# ---------------------------------------------------------------------------
# Output helpers - style aligned with popular installers (Homebrew, oh-my-zsh,
# starship). Color-coded, succinct, step-numbered.
# ---------------------------------------------------------------------------

$script:StepNum   = 0
$script:StepTotal = 7
$script:T0        = Get-Date

function Write-Step {
    param([string]$msg)
    $script:StepNum++
    Write-Host ''
    Write-Host ("==> [{0}/{1}] {2}" -f $script:StepNum, $script:StepTotal, $msg) -ForegroundColor Cyan
}
function Write-Ok   { param([string]$msg) Write-Host '    + ' -ForegroundColor Green   -NoNewline; Write-Host $msg }
function Write-Info { param([string]$msg) Write-Host '    - ' -ForegroundColor Gray    -NoNewline; Write-Host $msg }
function Write-Warn { param([string]$msg) Write-Host '    ! ' -ForegroundColor Yellow  -NoNewline; Write-Host $msg }
function Write-Err  { param([string]$msg) Write-Host '    X ' -ForegroundColor Red     -NoNewline; Write-Host $msg }
function Write-Hint { param([string]$msg) Write-Host ('      ' + $msg) -ForegroundColor DarkGray }

function Format-Elapsed {
    param([TimeSpan]$ts)
    if ($ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}.{1:D2}s' -f $ts.Seconds, [int]($ts.Milliseconds / 10))
}

# ---------------------------------------------------------------------------
# Header (informative, like `brew install` and `starship init`)
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  dev-environment  ::  one-liner installer' -ForegroundColor Cyan
Write-Host '  https://github.com/ahmed-mili/dev-environment' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  This will install / configure:'
Write-Host '    - Microsoft Defender exclusion for patch-claude-exe.ps1'
Write-Host '    - Git (via winget, if missing)'
Write-Host ('    - dev-environment repo at {0}' -f $RepoPath)
Write-Host '    - Windows bundle: PowerShell 7, Windows Terminal, fzf, fastfetch, Rust'
Write-Host '    - Custom Rust statusline binary (~/.claude/statusline.exe, 9 Hz animated)'
Write-Host '    - Claude Code config: settings + hooks + skills'
Write-Host ''
Write-Host '  First run takes about 10-15 min. Re-runs are idempotent (about 1-2 min).'
Write-Host ''

if ((Get-ExecutionPolicy -Scope Process) -notin 'Bypass','Unrestricted') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# ---------------------------------------------------------------------------
# Step 1/7 : pre-flight - Smart App Control state
# ---------------------------------------------------------------------------
# SAC blocks unsigned binaries at runtime (statusline.exe is unsigned and
# low-reputation when freshly built) and some cargo build-scripts also fail
# under SAC. The registry key VerifiedAndReputablePolicyState is :
# 0 = Off, 1 = Evaluation, 2 = On. Accept Off + Evaluation, refuse On.

Write-Step 'Pre-flight: Smart App Control state'
$sacState = 0
try {
    $sacState = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
                                  -Name VerifiedAndReputablePolicyState `
                                  -ErrorAction Stop).VerifiedAndReputablePolicyState
} catch {
    # SAC absent (Windows < 11 or edition without SAC) - treat as Off.
    $sacState = 0
}
if ($sacState -eq 2) {
    Write-Err 'Smart App Control is ON.'
    Write-Hint ''
    Write-Hint 'To continue, disable SAC:'
    Write-Hint '  Settings > Privacy & security > Smart App Control > Off'
    Write-Hint 'Then re-run this bootstrap.'
    Write-Hint ''
    Write-Hint 'WARNING: disabling SAC is permanent. Re-enabling it requires'
    Write-Hint 'a full Windows reset.'
    exit 1
}
Write-Ok "OK (state=$sacState)"

# ---------------------------------------------------------------------------
# Step 2/7 : pre-flight - elevation
# ---------------------------------------------------------------------------

Write-Step 'Pre-flight: elevation'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err 'Not running as administrator.'
    Write-Hint ''
    Write-Hint 'Re-run from an elevated PowerShell (Windows Terminal as Admin).'
    Write-Hint 'Needed to add a Defender exception on patch-claude-exe.ps1.'
    exit 1
}
Write-Ok 'OK'

# ---------------------------------------------------------------------------
# Step 3/7 : Defender exclusions (must run BEFORE git clone)
# ---------------------------------------------------------------------------
# patch-claude-exe.ps1 is flagged Trojan:Win32/FileFix.BBA!MTB (standard
# heuristic for binary patchers : ReadAllBytes + IndexOf + WriteAllBytes on
# a .exe). Without a pre-existing exclusion, Defender quarantines the file
# as soon as it lands on disk -> git clone "succeeds" but the file silently
# disappears -> the SessionStart hook never fires.
#
# Add-MpPreference accepts paths that don't exist yet : the exclusion is
# armed BEFORE the file is written, so Defender skips it on arrival.
#
# Two exclusions because the file lives in two places after deploy.ps1 -Pull:
# 1. In the cloned repo (read by Claude Code via the absolute path in settings.json)
# 2. In ~/.claude/hooks/ (where deploy.ps1 -Pull copies it for consistency)

Write-Step 'Adding Defender exclusions for patch-claude-exe.ps1'
$exclusions = @(
    (Join-Path $RepoPath 'claude-code\hooks\patch-claude-exe.ps1'),
    (Join-Path $env:USERPROFILE '.claude\hooks\patch-claude-exe.ps1')
)
foreach ($p in $exclusions) {
    try {
        Add-MpPreference -ExclusionPath $p -ErrorAction Stop
        Write-Ok $p
    } catch {
        Write-Warn ("Could not add exclusion for {0} : {1}" -f $p, $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Step 4/7 : Git + clone
# ---------------------------------------------------------------------------

Write-Step 'Git + repo'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Info 'Installing Git via winget...'
    winget install --id Git.Git --exact --source winget --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw 'Git install failed' }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
} else {
    Write-Ok 'git already installed'
}

if (Test-Path (Join-Path $RepoPath '.git')) {
    Write-Info "Updating $RepoPath"
    git -C $RepoPath pull --ff-only
} else {
    Write-Info "Cloning into $RepoPath"
    $parent = Split-Path $RepoPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    git clone $RepoUrl $RepoPath
}

# ---------------------------------------------------------------------------
# Step 5/7 : Windows bundle (delegates to windows\install.ps1)
# ---------------------------------------------------------------------------

Write-Step 'Windows bundle (winget packages + PS profiles + Terminal + Fastfetch + Rust)'
& (Join-Path $RepoPath 'windows\install.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Windows bundle install failed' }

# ---------------------------------------------------------------------------
# Step 6/7 : Build statusline Rust binary
# ---------------------------------------------------------------------------
# build.ps1 redirects CARGO_TARGET_DIR to %LOCALAPPDATA% (trusted zone,
# away from C:\dev under Smart App Control), auto-falls-back to the
# stable-gnu toolchain if VS Build Tools are absent, builds --release,
# and copies the binary to ~/.claude/statusline.exe.
# Refresh PATH first so cargo is visible if Rust was just installed.

Write-Step 'Building statusline Rust binary'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + (Join-Path $env:USERPROFILE '.cargo\bin')
& (Join-Path $RepoPath 'claude-code\statusline-rs\build.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Statusline build failed' }

# ---------------------------------------------------------------------------
# Step 7/7 : Deploy Claude Code config
# ---------------------------------------------------------------------------

Write-Step 'Claude Code config (statusline + settings + hooks + skills)'
& (Join-Path $RepoPath 'claude-code\deploy.ps1') -Pull
if ($LASTEXITCODE -ne 0) { throw 'Claude Code config deploy failed' }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$elapsed = (Get-Date) - $script:T0
Write-Host ''
Write-Host '  +-------------------------------------------------------------+' -ForegroundColor Green
Write-Host ('  |  All done in {0,-46} |' -f (Format-Elapsed $elapsed))         -ForegroundColor Green
Write-Host '  +-------------------------------------------------------------+' -ForegroundColor Green
Write-Host ''
Write-Host '  Next steps:'
Write-Host '    1. Restart Windows Terminal to load the new profiles.'
Write-Host '    2. Open Claude Code and run /plugin to install frontend-design,'
Write-Host '       code-review, and superpowers plugins.'
Write-Host '    3. claude.exe will be patched automatically by the SessionStart'
Write-Host '       hook at the next Claude Code session.'
Write-Host ''
Write-Host '  Docs:  https://github.com/ahmed-mili/dev-environment' -ForegroundColor DarkGray
Write-Host ''

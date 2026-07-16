#Requires -Version 5.1
<#
.SYNOPSIS
    One-liner bootstrap: clone dev-environment, install Windows bundle, build
    statusline Rust binary, deploy Claude Code config.

.DESCRIPTION
    Hard prereq (script will abort otherwise): Smart App Control DISABLED.
    Otherwise Windows blocks the unsigned statusline Rust binary at runtime
    AND some cargo build-scripts fail under SAC. Toggle off in Settings >
    Privacy & security > Smart App Control. WARNING: disabling SAC is
    permanent (requires full Windows reset to re-enable).

.EXAMPLE
    irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/install.ps1 | iex

.EXAMPLE
    # Equivalent manual form (what install.ps1 automates):
    $b="$env:TEMP\dev-env-bootstrap.ps1"; irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1 -OutFile $b; Unblock-File $b; & $b
#>

# ---------------------------------------------------------------------------
# ASCII-only source - DO NOT add non-ASCII chars to this file.
# Reason: Windows PowerShell 5.1 reads .ps1 files from disk in CP-1252 when
# no UTF-8 BOM is present (no-bom CI check enforces no BOM, because BOM
# breaks `iex (irm ...)`). Multi-byte UTF-8 bytes 0x91-0x94 decode to smart
# quotes (U+2018-U+201D) in CP-1252, which PS 5.1 treats as string
# delimiters -> parser breaks far from the offending char. Stay ASCII-only.
# Unicode glyphs in OUTPUT are fine: they're constructed via [char]0x...
# at runtime, which only ever puts ASCII codepoints in the source.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$RepoUrl  = 'https://github.com/ahmed-mili/dev-environment.git'
$RepoPath = 'C:\dev\dev-environment'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
# Visual style synthesizes the patterns of the most popular installer
# scripts on GitHub:
#   - Section header  "==> " (BOLD BLUE) + message (BOLD WHITE)   [Homebrew]
#   - Success         " V " (GREEN) + message                     [starship]
#   - Info            " > " (BOLD DARKGRAY) + message             [starship]
#   - Warning         " ! " (YELLOW) + message                    [starship]
#   - Error           " x " (RED) + message                       [starship]
#   - Hint            "   " (DARKGRAY)                            [Homebrew]
#
# Unicode check-mark (U+2713) is built at runtime from its codepoint so the
# source file stays ASCII (see header comment). UTF-8 output encoding is
# set so Windows Terminal renders the glyph correctly.

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$GLYPH_OK = [char]0x2713  # check mark

$script:T0        = Get-Date
$script:StepIdx   = 0
$script:StepTotal = 9   # 1.Checks 2.Git 3.GitConfig 4.Clone 5.Bundle 6.Build 7.Deploy 8.UpdateClaude+Plugins 9.PluginCheck

function Write-Step {
    param([string]$msg)
    $script:StepIdx++
    Write-Host ''
    Write-Host '==> ' -ForegroundColor Blue -NoNewline
    Write-Host ('[{0}/{1}] ' -f $script:StepIdx, $script:StepTotal) -ForegroundColor DarkGray -NoNewline
    Write-Host $msg -ForegroundColor White
}
function Write-Ok {
    param([string]$msg)
    Write-Host ('  ' + $GLYPH_OK + ' ') -ForegroundColor Green -NoNewline
    Write-Host $msg
}
function Write-Info {
    param([string]$msg)
    Write-Host '  > ' -ForegroundColor DarkGray -NoNewline
    Write-Host $msg
}
function Write-Warn {
    param([string]$msg)
    Write-Host ('  ! ' + $msg) -ForegroundColor Yellow
}
function Write-Err {
    param([string]$msg)
    Write-Host ('  x ' + $msg) -ForegroundColor Red
}
function Write-Hint {
    param([string]$msg)
    Write-Host ('    ' + $msg) -ForegroundColor DarkGray
}

function Format-Elapsed {
    param([TimeSpan]$ts)
    if ($ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}.{1:D2}s' -f $ts.Seconds, [int]($ts.Milliseconds / 10))
}

# ---------------------------------------------------------------------------
# Header (Homebrew-style: name + URL, then a flat "this will install" list)
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  dev-environment '       -ForegroundColor Cyan     -NoNewline
Write-Host '::'                       -ForegroundColor DarkGray -NoNewline
Write-Host ' one-liner installer'     -ForegroundColor Cyan
Write-Host '  https://github.com/ahmed-mili/dev-environment' -ForegroundColor DarkGray
Write-Host ''
Write-Host '==> ' -ForegroundColor Blue -NoNewline
Write-Host 'This script will install / configure:' -ForegroundColor White
Write-Host '    Git (via winget, if missing) + git user.name/email (prompted if unset)'
Write-Host ('    dev-environment repo at {0}' -f $RepoPath)
Write-Host '    PowerShell 7, Windows Terminal, fzf, zoxide, fastfetch, Rust (via winget)'
Write-Host '    Claude Code (via winget, official Anthropic.ClaudeCode package)'
Write-Host '    WinLibs/MinGW (via winget, only if MSVC Build Tools are missing)'
Write-Host '    Custom Rust statusline binary (~/.claude/statusline.exe)'
Write-Host '    Claude Code config: settings + hooks + skills'
Write-Host '    Claude Code plugins (frontend-design, code-review, superpowers, rust-analyzer-lsp)'
Write-Host ''
Write-Host '    First run: about 10-15 min. Re-runs are idempotent (~1-2 min).' -ForegroundColor DarkGray
Write-Host ''

if ((Get-ExecutionPolicy -Scope Process) -notin 'Bypass','Unrestricted') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# ---------------------------------------------------------------------------
# Pre-flight checks (Homebrew style: one section, multiple sub-checks)
# ---------------------------------------------------------------------------
# SAC state registry key VerifiedAndReputablePolicyState : 0=Off, 1=Eval, 2=On.
# Accept 0/1, refuse 2.

Write-Step 'Checking prerequisites'

$sacState = 0
try {
    $sacState = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
                                  -Name VerifiedAndReputablePolicyState `
                                  -ErrorAction Stop).VerifiedAndReputablePolicyState
} catch {
    $sacState = 0   # SAC absent on older Windows / non-Pro editions -> treat as Off
}
if ($sacState -eq 2) {
    Write-Err 'Smart App Control is ON'
    Write-Hint ''
    Write-Hint 'To continue, disable SAC:'
    Write-Hint '  Settings > Privacy & security > Smart App Control > Off'
    Write-Hint 'Then re-run this bootstrap.'
    Write-Hint ''
    Write-Hint 'WARNING: disabling SAC is permanent. Re-enabling requires a full Windows reset.'
    exit 1
}
Write-Ok ("Smart App Control: off (state={0})" -f $sacState)

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------

Write-Step 'Installing Git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Info 'not found - installing via winget'
    winget install --id Git.Git --exact --source winget --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw 'Git install failed' }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    Write-Ok 'installed'
} else {
    Write-Ok 'git already installed'
}

# ---------------------------------------------------------------------------
# Git identity (idempotent)
# ---------------------------------------------------------------------------
# user.name + user.email are mandatory for commit authorship. If unset,
# prompt for them once; if set, leave alone (so re-runs are silent).

Write-Step 'Configuring Git identity'
$gitName  = (& git config --global user.name)  2>$null
$gitEmail = (& git config --global user.email) 2>$null
if ($gitName -and $gitEmail) {
    Write-Ok ("name='{0}' email='{1}' (already set)" -f $gitName, $gitEmail)
} else {
    Write-Info 'Git needs user.name + user.email for commit authorship.'
    if (-not $gitName) {
        $gitName = Read-Host '    Enter your full name (e.g., Ada Lovelace)'
        if ([string]::IsNullOrWhiteSpace($gitName)) { throw 'Empty name; aborting.' }
        & git config --global user.name $gitName
        if ($LASTEXITCODE -ne 0) { throw 'git config user.name failed' }
    }
    if (-not $gitEmail) {
        $gitEmail = Read-Host '    Enter your email (e.g., ada@example.com)'
        if ([string]::IsNullOrWhiteSpace($gitEmail)) { throw 'Empty email; aborting.' }
        & git config --global user.email $gitEmail
        if ($LASTEXITCODE -ne 0) { throw 'git config user.email failed' }
    }
    Write-Ok ("set: name='{0}' email='{1}'" -f $gitName, $gitEmail)
}

# ---------------------------------------------------------------------------
# Clone / update repo
# ---------------------------------------------------------------------------

if (Test-Path (Join-Path $RepoPath '.git')) {
    Write-Step ("Updating {0}" -f $RepoPath)
    git -C $RepoPath pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed' }
    Write-Ok 'up to date'
} else {
    Write-Step ("Cloning into {0}" -f $RepoPath)
    $parent = Split-Path $RepoPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    git clone $RepoUrl $RepoPath
    if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
    Write-Ok 'cloned'
}

# ---------------------------------------------------------------------------
# Windows bundle (delegated to windows\install.ps1)
# ---------------------------------------------------------------------------

Write-Step 'Installing Windows bundle (PowerShell 7, Terminal, fzf, zoxide, fastfetch, Rust, Claude Code)'
& (Join-Path $RepoPath 'windows\install.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Windows bundle install failed' }

# ---------------------------------------------------------------------------
# Build statusline Rust binary
# ---------------------------------------------------------------------------
# build.ps1 redirects CARGO_TARGET_DIR to %LOCALAPPDATA% (trusted zone, away
# from C:\dev under Smart App Control), auto-falls-back to stable-gnu plus
# WinLibs/MinGW if VS Build Tools are absent (WinLibs provides gcc.exe for
# ring/rustls), builds --release, and copies the binary to
# ~/.claude/statusline.exe.
# Refresh PATH first so cargo is visible if Rust was just installed.

Write-Step 'Building statusline Rust binary'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + (Join-Path $env:USERPROFILE '.cargo\bin')
& (Join-Path $RepoPath 'claude-code\statusline-rs\build.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Statusline build failed' }

# ---------------------------------------------------------------------------
# Deploy Claude Code config
# ---------------------------------------------------------------------------

Write-Step 'Deploying Claude Code config (statusline + settings + hooks + skills)'
& (Join-Path $RepoPath 'claude-code\deploy.ps1') -Pull
if ($LASTEXITCODE -ne 0) { throw 'Claude Code config deploy failed' }

# ---------------------------------------------------------------------------
# Claude Code plugins (idempotent CLI install)
# ---------------------------------------------------------------------------
# enabledPlugins in settings.json declares which plugins are active, but
# Claude Code does NOT auto-install them from that field -- it just refuses
# to load what's not in ~/.claude/plugins/cache/. So we drive the install
# explicitly here via `claude plugin install`, which:
#   - is a non-interactive CLI subcommand,
#   - is idempotent (prints "already installed" and exit 0 on re-run).
# `claude-plugins-official` is pre-registered in claude.exe (no `marketplace
# add` needed), but its catalog cache is NOT auto-populated on a fresh
# install -- without a `marketplace update`, `plugin install` fails with
# "Plugin X not found in marketplace ... Your local copy may be out of
# date". So we always run `marketplace update` first to seed the cache.
# Source-of-truth for the plugin list is settings.json -> enabledPlugins,
# so this list stays in sync automatically.

Write-Step 'Updating Claude Code + installing plugins'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    Write-Warn 'claude.exe not on PATH yet; skipping update + plugin install.'
    Write-Hint 'Restart your shell, then run `claude update`, `claude plugin marketplace update claude-plugins-official`, and `claude plugin install <name>@claude-plugins-official`.'
} else {
    # `claude update` upgrades to the latest Anthropic release. winget's
    # Anthropic.ClaudeCode package can lag by a release or two; this
    # catches us up to current.
    Write-Info 'claude update (catch up to latest Anthropic release)'
    & $claudeCmd.Source update 2>&1 | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Write-Warn ("claude update returned {0}" -f $LASTEXITCODE) }

    # Seed the marketplace catalog cache. Without this, fresh installs hit:
    #   Failed to install plugin "X": Plugin "X" not found in marketplace
    #   "claude-plugins-official". Your local copy may be out of date --
    #   try `claude plugin marketplace update claude-plugins-official`.
    # The marketplace itself is registered by default, but its cache is
    # empty until the first `marketplace update`.
    Write-Info 'syncing claude-plugins-official marketplace'
    & $claudeCmd.Source plugin marketplace update claude-plugins-official 2>&1 | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Write-Warn ("claude plugin marketplace update returned {0}" -f $LASTEXITCODE) }

    $settings = Get-Content (Join-Path $RepoPath 'claude-code\settings.json') -Raw | ConvertFrom-Json
    $plugins = @($settings.enabledPlugins.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Name })
    foreach ($p in $plugins) {
        Write-Info ("installing {0}" -f $p)
        & $claudeCmd.Source plugin install $p --scope user 2>&1 | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { Write-Warn ("claude plugin install {0} returned {1}" -f $p, $LASTEXITCODE) }
    }
    Write-Ok ("{0} plugin(s) processed" -f $plugins.Count)
}

# ---------------------------------------------------------------------------
# 9. Plugin integrity check - ensure all enabledPlugins are actually installed
# ---------------------------------------------------------------------------
Write-Step 'Checking plugin integrity'
$checkScript = Join-Path $RepoPath 'claude-code\scripts\check-plugins.ps1'
if (Test-Path $checkScript) {
    & $checkScript -Fix 2>$null | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkGray }
    Write-Ok 'plugin integrity check complete'
} else {
    Write-Warn 'check-plugins.ps1 not found - skipping'
}

# ---------------------------------------------------------------------------
# Done (Homebrew-style: "==> Installation successful!" + next steps)
# ---------------------------------------------------------------------------

$elapsed = Format-Elapsed ((Get-Date) - $script:T0)

Write-Host ''
Write-Host '==> ' -ForegroundColor Blue  -NoNewline
Write-Host 'Installation successful! ' -ForegroundColor White    -NoNewline
Write-Host ('(' + $elapsed + ')')      -ForegroundColor DarkGray
Write-Host ''
Write-Host '==> ' -ForegroundColor Blue -NoNewline
Write-Host 'Next steps:' -ForegroundColor White
Write-Host '  1. Restart Windows Terminal so PATH picks up ' -NoNewline
Write-Host 'claude' -ForegroundColor Cyan -NoNewline
Write-Host ' + new profiles.'
Write-Host '  2. Run ' -NoNewline
Write-Host 'claude' -ForegroundColor Cyan -NoNewline
Write-Host ' -- statusline, settings, hooks, skills, and plugins are ready.'
Write-Host ''
Write-Host '==> ' -ForegroundColor Blue -NoNewline
Write-Host 'Docs: ' -ForegroundColor White -NoNewline
Write-Host 'https://github.com/ahmed-mili/dev-environment' -ForegroundColor Cyan
Write-Host ''

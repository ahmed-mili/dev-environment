#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Terminal + PowerShell config bundle -- single-file installer.

.DESCRIPTION
    Installs PowerShell 7 and Windows Terminal via winget (if missing),
    then deploys PS5 + PS7 profiles and the Windows Terminal settings.json
    for the current user. All payloads are embedded in this single script.

.PARAMETER SkipWinget
    Skip the winget installation step (PowerShell 7 + Windows Terminal).
    Use this if Windows Terminal has never been launched on this machine:
    launch WT once so its LocalState folder is created, then re-run with -SkipWinget.

.LINK
    https://github.com/ahmed-mili/terminal-config-bundle

.EXAMPLE
    # From a local clone:
    .\install.ps1

.EXAMPLE
    # One-liner (no clone required):
    iwr https://raw.githubusercontent.com/ahmed-mili/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
#>

[CmdletBinding()]
param(
    [switch]$SkipWinget
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK : $msg" -ForegroundColor Green }
function Write-Note($msg) { Write-Host "    !! $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Embedded payloads
# ---------------------------------------------------------------------------

$ps7Profile = @'
function isadmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- PSReadLine: modern predictions + smart Tab + Catppuccin Mocha colors ----
# - InlineView by default (grey ghost text). F2 toggles to ListView (dropdown).
# - Tab accepts the inline prediction if one is visible, else MenuComplete.
# - Right Arrow / Ctrl+RightArrow also accept (standard PSReadLine behavior).
# - Syntax-highlight colors aligned with the Catppuccin Mocha palette.
if (Get-Module -Name PSReadLine -ListAvailable) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
    Set-PSReadLineOption -Colors @{
        Command            = '#89B4FA'  # Blue
        Parameter          = '#F5C2E7'  # Pink
        Variable           = '#F5C2E7'  # Pink
        String             = '#A6E3A1'  # Green
        Number             = '#FAB387'  # Peach
        Type               = '#F9E2AF'  # Yellow
        Keyword            = '#CBA6F7'  # Mauve
        Comment            = '#6C7086'  # Overlay0
        Operator           = '#89DCEB'  # Sky
        Member             = '#94E2D5'  # Teal
        Error              = '#F38BA8'  # Red
        Emphasis           = '#F38BA8'  # Red
        InlinePrediction   = '#6C7086'  # Overlay0 (dimmed ghost text)
        Default            = '#CDD6F4'  # Text
        ContinuationPrompt = '#A6ADC8'  # Subtext0
    } -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key F2 -Function SwitchPredictionView
    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock {
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptSuggestion()
        $newLine = $null; $newCursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$newLine, [ref]$newCursor)
        if ($line -eq $newLine) {
            [Microsoft.PowerShell.PSConsoleReadLine]::MenuComplete()
        }
    }
}

# ---- CompletionPredictor: smart predictions beyond shell history
# (cmdlet parameters, git branches, file paths, etc.) ----
if (Get-Module -ListAvailable -Name CompletionPredictor) {
    Import-Module CompletionPredictor -ErrorAction SilentlyContinue
}

# ---- Terminal-Icons: Nerd Font icons in Get-ChildItem (`ls`) output ----
if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue
}

# ---- PSFzf: Ctrl+R fuzzy reverse-history, Ctrl+T fuzzy file/dir picker ----
# Only loaded when fzf.exe is available on PATH.
if ((Get-Module -ListAvailable -Name PSFzf) -and (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Import-Module PSFzf -ErrorAction SilentlyContinue
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r' -ErrorAction SilentlyContinue
}

# ---- Fastfetch splash (Arch logo + system info) ----
# Runs only in interactive sessions to avoid polluting scripted/piped pwsh calls.
if ((-not [System.Console]::IsOutputRedirected) -and (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
    fastfetch
}
'@

$ps5Profile = @'
function prompt { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }

# Force Windows PowerShell to UTF-8 on every startup.
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
chcp 65001 > $null

# Neutralize the default blue background of Windows PowerShell.
$Host.UI.RawUI.BackgroundColor = 'Black'
$Host.UI.RawUI.ForegroundColor = 'Gray'

function isadmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
'@

$wtSettings = @'
{
    "$help": "https://aka.ms/terminal-documentation",
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "actions": [],
    "copyFormatting": "none",
    "copyOnSelect": false,
    "defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",
    "keybindings":
    [
        { "id": "Terminal.CopyToClipboard",     "keys": "ctrl+c" },
        { "id": "Terminal.PasteFromClipboard",  "keys": "ctrl+v" },
        { "id": "Terminal.DuplicatePaneAuto",   "keys": "alt+shift+d" }
    ],
    "newTabMenu":
    [
        { "type": "remainingProfiles" }
    ],
    "profiles":
    {
        "defaults":
        {
            "colorScheme": "Catppuccin Mocha",
            "font":
            {
                "face": "JetBrainsMono Nerd Font",
                "size": 11
            },
            "opacity": 85,
            "useAcrylic": true
        },
        "list":
        [
            {
                "commandline": "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
                "hidden": true,
                "name": "Windows PowerShell"
            },
            {
                "commandline": "%SystemRoot%\\System32\\cmd.exe",
                "guid": "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}",
                "hidden": false,
                "name": "Command Prompt"
            },
            {
                "guid": "{b453ae62-4e3d-5e58-b989-0a998ec441b8}",
                "hidden": false,
                "name": "Azure Cloud Shell",
                "source": "Windows.Terminal.Azure"
            },
            {
                "guid": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",
                "hidden": false,
                "name": "PowerShell",
                "source": "Windows.Terminal.PowershellCore"
            }
        ]
    },
    "schemes":
    [
        {
            "name": "Catppuccin Mocha",
            "cursorColor": "#F5E0DC",
            "selectionBackground": "#585B70",
            "background": "#1E1E2E",
            "foreground": "#CDD6F4",
            "black": "#45475A",
            "red": "#F38BA8",
            "green": "#A6E3A1",
            "yellow": "#F9E2AF",
            "blue": "#89B4FA",
            "purple": "#F5C2E7",
            "cyan": "#94E2D5",
            "white": "#BAC2DE",
            "brightBlack": "#585B70",
            "brightRed": "#F38BA8",
            "brightGreen": "#A6E3A1",
            "brightYellow": "#F9E2AF",
            "brightBlue": "#89B4FA",
            "brightPurple": "#F5C2E7",
            "brightCyan": "#94E2D5",
            "brightWhite": "#A6ADC8"
        }
    ],
    "theme": "dark",
    "themes": []
}
'@

# Fastfetch JSONC config: minimalist single-icon-per-line layout.
# Icons are simple Unicode geometric chars (no Nerd Font required):
#   U+25A6 OS | U+25CF CPU | U+25B6 GPU | U+25E2 Memory | U+26C1 Disk
$fastfetchConfig = @'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": { "source": "windows11_small", "padding": { "top": 1, "right": 3 } },
    "display": { "separator": "  " },
    "modules": [
        "break",
        { "type": "title", "format": "{user-name-colored}@{host-name-colored}" },
        "break",
        { "type": "os",     "key": "▦", "keyColor": "blue" },
        { "type": "cpu",    "key": "●", "keyColor": "red" },
        { "type": "gpu",    "key": "▶", "keyColor": "magenta" },
        { "type": "memory", "key": "◢", "keyColor": "green" },
        { "type": "disk",   "key": "⛁", "keyColor": "yellow" },
        "break",
        { "type": "colors", "paddingLeft": 2, "symbol": "circle" }
    ]
}
'@

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Backup-IfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$Path.bak-$stamp"
        Copy-Item $Path $backup -Force
        Write-Note "backed up existing -> $backup"
    }
}

# Writes a file with explicit UTF-8 encoding.
# BOM is recommended for .ps1 profiles so Windows PowerShell 5.1 parses
# accented chars correctly. No BOM for JSON, to keep parsers happy.
function Write-Utf8File {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Content,
        [bool]$WithBom = $true
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Backup-IfExists $Path
    $encoding = New-Object System.Text.UTF8Encoding($WithBom)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Install-WingetPackage {
    param([string]$Id, [string]$DisplayName)
    if ($SkipWinget) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Note "winget not found -- install $DisplayName manually from the Microsoft Store."
        return
    }
    $installed = winget list --id $Id --exact --source winget 2>$null | Select-String $Id
    if ($installed) {
        Write-Ok "$DisplayName already installed."
        return
    }
    Write-Step "Installing $DisplayName via winget..."
    winget install --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements
}

# ---------------------------------------------------------------------------
# Bootstrap: execution policy + unblock self
# ---------------------------------------------------------------------------

Write-Step 'Bootstrap'

# Process scope: always permissive so the rest of this script runs.
if ((Get-ExecutionPolicy -Scope Process) -notin 'Bypass','Unrestricted') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# CurrentUser scope: persistent fix so deployed profiles can load in future sessions.
$current = Get-ExecutionPolicy -Scope CurrentUser
if ($current -notin 'RemoteSigned','Unrestricted','Bypass') {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    Write-Ok "CurrentUser execution policy: $current -> RemoteSigned"
} else {
    Write-Ok "CurrentUser execution policy already permissive ($current)"
}

# If this script was downloaded to disk (clone, ZIP, OneDrive...), unblock it
# so a subsequent dot-source doesn't trip on the Zone.Identifier ADS.
# When invoked via `iwr | iex`, $PSCommandPath is empty -- skip silently.
if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    try { Unblock-File $PSCommandPath -ErrorAction Stop } catch {}
}

# ---------------------------------------------------------------------------
# 1) Prerequisites: PowerShell 7 + Windows Terminal
# ---------------------------------------------------------------------------

Write-Step 'Prerequisites'
Install-WingetPackage -Id 'Microsoft.PowerShell'          -DisplayName 'PowerShell 7'
Install-WingetPackage -Id 'Microsoft.WindowsTerminal'     -DisplayName 'Windows Terminal'
Install-WingetPackage -Id 'junegunn.fzf'                  -DisplayName 'fzf'
Install-WingetPackage -Id 'DEVCOM.JetBrainsMonoNerdFont'  -DisplayName 'JetBrains Mono Nerd Font'
Install-WingetPackage -Id 'Fastfetch-cli.Fastfetch'       -DisplayName 'Fastfetch'

# ---------------------------------------------------------------------------
# 2) PowerShell 7 profile
# ---------------------------------------------------------------------------

Write-Step 'PowerShell 7 profile'
$ps7Path = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
Write-Utf8File -Path $ps7Path -Content $ps7Profile -WithBom $true
Unblock-File $ps7Path
Write-Ok $ps7Path

# ---------------------------------------------------------------------------
# 3) Windows PowerShell 5 profile
# ---------------------------------------------------------------------------

Write-Step 'Windows PowerShell 5 profile'
$ps5Path = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
Write-Utf8File -Path $ps5Path -Content $ps5Profile -WithBom $true
Unblock-File $ps5Path
Write-Ok $ps5Path

# ---------------------------------------------------------------------------
# 4) Windows Terminal settings.json
# ---------------------------------------------------------------------------

Write-Step 'Windows Terminal settings'
$wtDir    = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
$wtTarget = Join-Path $wtDir 'settings.json'
if (-not (Test-Path $wtDir)) {
    Write-Note "Windows Terminal LocalState not found -- launch WT once, then re-run with -SkipWinget."
} else {
    Write-Utf8File -Path $wtTarget -Content $wtSettings -WithBom $false
    Write-Ok $wtTarget
}

# ---------------------------------------------------------------------------
# 5) Fastfetch config (~/.config/fastfetch/config.jsonc)
# ---------------------------------------------------------------------------

Write-Step 'Fastfetch config'
$ffDir    = Join-Path $env:USERPROFILE '.config\fastfetch'
$ffTarget = Join-Path $ffDir 'config.jsonc'
Write-Utf8File -Path $ffTarget -Content $fastfetchConfig -WithBom $false
Write-Ok $ffTarget

# ---------------------------------------------------------------------------
# 6) PowerShell 7 modules: CompletionPredictor + PSFzf
# ---------------------------------------------------------------------------

Write-Step 'PowerShell 7 modules'

function Get-PwshExe {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Install-PS7Module {
    param([string]$Name)
    $pwsh = Get-PwshExe
    if (-not $pwsh) {
        Write-Note "pwsh.exe not on PATH yet; skipping $Name. Re-run this script after a shell restart."
        return
    }
    $check = & $pwsh -NoProfile -NoLogo -Command "if (Get-Module -ListAvailable -Name '$Name') { 'yes' } else { 'no' }"
    if ($check -eq 'yes') {
        Write-Ok "$Name already installed (PS7 module)."
        return
    }
    Write-Step "Installing PS7 module: $Name"
    & $pwsh -NoProfile -NoLogo -Command "if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }; Install-Module -Name '$Name' -Scope CurrentUser -Force -AcceptLicense"
    if ($LASTEXITCODE -eq 0) { Write-Ok $Name } else { Write-Note "$Name install failed (exit $LASTEXITCODE)" }
}

Install-PS7Module -Name CompletionPredictor
Install-PS7Module -Name PSFzf
Install-PS7Module -Name Terminal-Icons

Write-Host ''
Write-Host 'Done. CLOSE Windows Terminal and reopen it so the new PATH (fzf) and profiles take effect.' -ForegroundColor Green
Write-Host 'Keybindings in PS 7:' -ForegroundColor Green
Write-Host '  - F2          : toggle inline / list prediction view' -ForegroundColor Green
Write-Host '  - Tab / Right : accept the grey suggestion (or open the completion menu)' -ForegroundColor Green
Write-Host '  - Ctrl+R      : fuzzy reverse history search (fzf)' -ForegroundColor Green
Write-Host '  - Ctrl+T      : fuzzy file/directory picker (fzf)' -ForegroundColor Green

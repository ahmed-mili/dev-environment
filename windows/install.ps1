#Requires -Version 5.1
<#
.SYNOPSIS
    Windows + PowerShell config bundle -- single-file installer.

.DESCRIPTION
    Installs PowerShell 7, Windows Terminal, fzf, JetBrainsMono Nerd Font and
    Fastfetch via winget (skipped if already present), then deploys:
      - PowerShell 7 profile (UTF-8, Catppuccin PSReadLine, predictions,
        Terminal-Icons, PSFzf, fastfetch splash with WMI-detected RAM and a
        per-character gradient USER@HOST header)
      - Windows PowerShell 5 profile (UTF-8 + isadmin helper)
      - Windows Terminal settings.json (Catppuccin Mocha scheme, JetBrainsMono
        Nerd Font 11pt, acrylic, PowerShell 7 default with
        `pwsh.exe -NoLogo -NoProfileLoadTime`)
      - Fastfetch config (cool-tone Catppuccin gradient across header,
        divider and module rows -- no Linux-style 8-color palette footer)
    Les payloads (profils PS, config Terminal, config Fastfetch) vivent dans
    `windows/files/` comme fichiers normaux et sont copies tels quels vers
    leurs destinations -- pas de base64 inline (qui faisait flagger install.ps1
    par Defender comme `Trojan:Win32/ClickFix.AAC!MTB` -- le pattern decode
    base64 + write-to-disk est la signature heuristique standard d'un stager).

.PARAMETER SkipWinget
    Skip the winget installation step.

.LINK
    https://github.com/ahmed-mili/dev-environment

.EXAMPLE
    # One-liner (no clone required):
    iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/windows/install.ps1).TrimStart([char]0xFEFF)

.EXAMPLE
    # From a local clone:
    .\install.ps1
#>

param(
    [switch]$SkipWinget
)

$ErrorActionPreference = 'Stop'

# UTF-8 output so the Unicode check-mark glyph below renders correctly in
# Windows Terminal. The glyph is built at runtime from its codepoint
# ([char]0x2713) so the source file stays pure ASCII (PS 5.1 reads unBOMed
# .ps1 in CP-1252 -> UTF-8 bytes 0x91-0x94 would decode to smart quotes
# which break the parser).
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$GLYPH_OK = [char]0x2713  # check mark

function Write-Step($msg) { Write-Host "  ==> $msg" -ForegroundColor Blue }
function Write-Ok($msg)   { Write-Host ("      " + $GLYPH_OK + " ") -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Note($msg) { Write-Host "      ! " -ForegroundColor Yellow -NoNewline; Write-Host $msg }

function Short-Path([string]$p) {
    if ($p.StartsWith($env:USERPROFILE)) { "~" + $p.Substring($env:USERPROFILE.Length) }
    else { $p }
}

# ---------------------------------------------------------------------------
# Payloads externes (windows/files/)
# ---------------------------------------------------------------------------
#
# Plus de base64 inline (qui faisait flagger ce script par Defender comme
# `Trojan:Win32/ClickFix.AAC!MTB` -- la signature heuristique standard
# pour 'decode base64 + write-to-disk', alias staging de payload).
#
# Les fichiers sont lus en UTF-8 explicite (PS 5.1 default-encode est ANSI,
# donc Get-Content sans -Encoding casse les caracteres non-ASCII des
# configs Fastfetch / WT settings).

$FilesDir = Join-Path $PSScriptRoot 'files'
function Read-Utf8File([string]$Path) {
    [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

$ps7Profile      = Read-Utf8File (Join-Path $FilesDir 'ps7-profile.ps1')
$ps5Profile      = Read-Utf8File (Join-Path $FilesDir 'ps5-profile.ps1')
$wtSettings      = Read-Utf8File (Join-Path $FilesDir 'wt-settings.json')
$fastfetchConfig = Read-Utf8File (Join-Path $FilesDir 'fastfetch-config.jsonc')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Backup-IfExists {
    # Silent: the .bak-<timestamp> file is created so a re-run never destroys
    # existing config, but we don't print a line for each one. They pile up
    # on disk only when there was something to back up, and are easy to find
    # with `Get-ChildItem -Recurse -Filter '*.bak-*'` if needed.
    param([string]$Path)
    if (Test-Path $Path) {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $Path "$Path.bak-$stamp" -Force
    }
}

# UTF-8 write. PS profile .ps1 files get a BOM so Windows PowerShell 5.1 parses
# accented chars correctly. JSON / JSONC get no BOM to keep parsers happy.
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
        Write-Ok $DisplayName
        return
    }
    Write-Step "Installing $DisplayName..."
    winget install --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements
}

# ---------------------------------------------------------------------------
# Bootstrap: execution policy + unblock self
# ---------------------------------------------------------------------------

Write-Step 'Bootstrap'

if ((Get-ExecutionPolicy -Scope Process) -notin 'Bypass','Unrestricted') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# Prefer the *effective* policy: a machine/user GPO may already grant Bypass
# even when CurrentUser is Undefined, in which case Set-ExecutionPolicy emits
# a non-terminating warning that ErrorActionPreference=Stop would promote to
# a hard failure for no real reason. So: skip when effectively permissive,
# and ignore the override warning when we do set.
$effective = Get-ExecutionPolicy
if ($effective -in 'RemoteSigned','Unrestricted','Bypass') {
    Write-Ok "execution policy ($effective)"
} else {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        Write-Ok "execution policy -> RemoteSigned"
    } catch {
        Write-Note "Could not set CurrentUser policy ($($_.Exception.Message.Split([Environment]::NewLine)[0])). Continuing anyway."
    }
}

if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    try { Unblock-File $PSCommandPath -ErrorAction Stop } catch {}
}

# ---------------------------------------------------------------------------
# 1) Prerequisites: PowerShell 7 + Windows Terminal + fzf + Nerd Font + Fastfetch
# ---------------------------------------------------------------------------

Write-Step 'Prerequisites'
Install-WingetPackage -Id 'Microsoft.PowerShell'          -DisplayName 'PowerShell 7'
Install-WingetPackage -Id 'Microsoft.WindowsTerminal'     -DisplayName 'Windows Terminal'
Install-WingetPackage -Id 'junegunn.fzf'                  -DisplayName 'fzf'
Install-WingetPackage -Id 'ajeetdsouza.zoxide'            -DisplayName 'zoxide'
Install-WingetPackage -Id 'DEVCOM.JetBrainsMonoNerdFont'  -DisplayName 'JetBrainsMono Nerd Font'
Install-WingetPackage -Id 'Fastfetch-cli.Fastfetch'       -DisplayName 'Fastfetch'
# Rust toolchain : requis pour compiler claude-code/statusline-rs/ -> statusline.exe (9 Hz animation).
Install-WingetPackage -Id 'Rustlang.Rustup'               -DisplayName 'Rust toolchain (rustup)'

# ---------------------------------------------------------------------------
# 2) PowerShell 7 profile
# ---------------------------------------------------------------------------

Write-Step 'PowerShell 7 profile'
$ps7Path = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
Write-Utf8File -Path $ps7Path -Content $ps7Profile -WithBom $true
Unblock-File $ps7Path
Write-Ok (Short-Path $ps7Path)

# ---------------------------------------------------------------------------
# 3) Windows PowerShell 5 profile
# ---------------------------------------------------------------------------

Write-Step 'Windows PowerShell 5 profile'
$ps5Path = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
Write-Utf8File -Path $ps5Path -Content $ps5Profile -WithBom $true
Unblock-File $ps5Path
Write-Ok (Short-Path $ps5Path)

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
    Write-Ok (Short-Path $wtTarget)
}

# ---------------------------------------------------------------------------
# 5) Fastfetch config (~/.config/fastfetch/config.jsonc)
# ---------------------------------------------------------------------------

Write-Step 'Fastfetch config'
$ffDir        = Join-Path $env:USERPROFILE '.config\fastfetch'
$ffConfigPath = Join-Path $ffDir 'config.jsonc'

# Decide whether this is a laptop or a desktop, so the "Board" row in
# fastfetch can be relabelled "Laptop" (with the laptop icon) on portables.
#
# Two independent signals are combined because each one fails on some
# hardware:
#  1) Win32_SystemEnclosure.ChassisTypes  (SMBIOS)
#     Some OEMs ship laptops with this field set to "Desktop" (3) or
#     "Unknown" (2), so on its own it can miss real laptops.
#  2) Win32_Battery presence
#     Desktops never have an internal battery exposed via WMI, laptops
#     always do. Far more reliable in practice than ChassisTypes.
#
# Portable SMBIOS chassis types we accept: 8 Portable, 9 Laptop,
# 10 Notebook, 11 Hand Held, 14 Sub Notebook, 30 Tablet, 31 Convertible,
# 32 Detachable. (12 Docking Station, 18 Expansion, 21 Peripheral are NOT
# laptops and were dropped from the previous list.)
$laptopChassisTypes = @(8,9,10,11,14,30,31,32)
$isLaptop = $false
$reason   = ''
try {
    $chassis = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
    foreach ($c in $chassis) {
        if ($c -in $laptopChassisTypes) { $isLaptop = $true; $reason = "ChassisTypes=$c"; break }
    }
} catch {}
if (-not $isLaptop) {
    try {
        if (Get-CimInstance Win32_Battery -ErrorAction Stop) {
            $isLaptop = $true
            $reason   = 'battery present'
        }
    } catch {}
}

if ($isLaptop) {
    # The JSON file stores ESC as the 6-char escape ''; the icon glyph
    # is a 4-byte UTF-8 supplementary-plane char, built here via
    # ConvertFromUtf32 so this .ps1 source stays free of raw 4-byte chars.
    # U+F0697 = nf-md-developer_board (desktops)
    # U+F0322 = nf-md-laptop          (laptops)
    $boardIcon  = [char]::ConvertFromUtf32(0xF0697)
    $laptopIcon = [char]::ConvertFromUtf32(0xF0322)
    $boardKey   = $boardIcon  + '  Board'
    $laptopKey  = $laptopIcon + '  Laptop'

    $before = $fastfetchConfig
    $fastfetchConfig = $fastfetchConfig.Replace($boardKey, $laptopKey)
    if ($fastfetchConfig -eq $before) {
        Write-Note "Laptop detected ($reason) but the board key was not found in the embedded config -- icon NOT swapped."
    } else {
        Write-Ok "laptop ($reason) -> icon + label ""Laptop"""
    }
} else {
    Write-Ok 'desktop -> keeping "Board"'
}
Write-Utf8File -Path $ffConfigPath -Content $fastfetchConfig -WithBom $false
Write-Ok (Short-Path $ffConfigPath)

# ---------------------------------------------------------------------------
# 6) PowerShell 7 modules: CompletionPredictor + PSFzf + Terminal-Icons
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
        Write-Ok $Name
        return
    }
    Write-Step "Installing PS7 module: $Name"
    & $pwsh -NoProfile -NoLogo -Command "if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }; Install-Module -Name '$Name' -Scope CurrentUser -Force -AcceptLicense"
    if ($LASTEXITCODE -eq 0) { Write-Ok $Name } else { Write-Note "$Name install failed (exit $LASTEXITCODE)" }
}

Install-PS7Module -Name CompletionPredictor
Install-PS7Module -Name PSFzf
Install-PS7Module -Name Terminal-Icons

# ---------------------------------------------------------------------------
# 7) Desktop shortcut: Ctrl+Alt+T opens Windows Terminal as Administrator
# ---------------------------------------------------------------------------

Write-Step 'Desktop shortcut (Ctrl+Alt+T = Terminal Admin)'
$wtExe = Get-Command wt.exe -ErrorAction SilentlyContinue
if (-not $wtExe) {
    Write-Note 'wt.exe not on PATH yet. Re-run after restarting the shell to create the shortcut.'
} else {
    $lnkPath  = [IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'Terminal Admin.lnk')
    $shell    = New-Object -ComObject WScript.Shell
    $lnk      = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = $wtExe.Source
    $lnk.HotKey     = 'Ctrl+Alt+T'
    $lnk.Save()

    # Flip the "Run as administrator" bit (byte 21, bit 0x20) in the .lnk
    $bytes = [IO.File]::ReadAllBytes($lnkPath)
    $bytes[21] = $bytes[21] -bor 0x20
    [IO.File]::WriteAllBytes($lnkPath, $bytes)

    Write-Ok (Short-Path $lnkPath)
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host '  Restart Windows Terminal for all changes to take effect.'
Write-Host ''
Write-Host '  Keybindings & docs' -ForegroundColor Blue
Write-Host '    https://github.com/ahmed-mili/dev-environment/blob/main/windows/README.md#keybindings'

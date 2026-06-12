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

# Resolve the download URL of the first matching asset in a GitHub repo's latest
# release. Unauthenticated API requests are rate-limited to 60/hour per IP -- ample
# for a one-time install.
function Get-LatestGithubReleaseAsset {
    param(
        [Parameter(Mandatory)] [string]$Repo,         # e.g. 'JetBrains/JetBrainsMono'
        [Parameter(Mandatory)] [string]$NamePattern   # wildcard like 'JetBrainsMono-*.zip'
    )
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
    $asset   = $release.assets | Where-Object { $_.name -like $NamePattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$NamePattern' in latest release of $Repo." }
    return $asset.browser_download_url
}

# User-scope font install (no admin required). Accepts either a .zip URL
# (extracted, then TTFs matching $FilePattern are picked up) or a direct .ttf
# URL (downloaded as-is). Each TTF is copied to %LOCALAPPDATA%\Microsoft\
# Windows\Fonts and registered under HKCU so apps see it without re-login.
# Idempotent: skips if $MarkerFile already exists in the user fonts dir.
function Install-UserFont {
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$Url,           # .zip or .ttf
        [string]$FilePattern,                          # required for .zip; ignored for .ttf
        [Parameter(Mandatory)] [string]$MarkerFile     # e.g. 'JetBrainsMono-Regular.ttf' or 'NotoColorEmoji.ttf'
    )
    if ($SkipWinget) { return }
    $userFontsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (Test-Path (Join-Path $userFontsDir $MarkerFile)) {
        Write-Ok $DisplayName
        return
    }

    Write-Step "Installing $DisplayName"
    $tmpRoot = Join-Path $env:TEMP ("font-" + [guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    try {
        $isZip = $Url -match '\.zip(\?.*)?$'
        if ($isZip) {
            $tmpZip     = Join-Path $tmpRoot 'archive.zip'
            $tmpExtract = Join-Path $tmpRoot 'extract'
            Invoke-WebRequest -Uri $Url -OutFile $tmpZip -UseBasicParsing
            Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
            $ttfs = @(Get-ChildItem -Path $tmpExtract -Recurse -Filter $FilePattern)
        } else {
            # Direct .ttf/.otf download. The downloaded file is named after the
            # marker so the destination filename in the user fonts dir matches
            # the idempotence check exactly.
            $tmpFile = Join-Path $tmpRoot $MarkerFile
            Invoke-WebRequest -Uri $Url -OutFile $tmpFile -UseBasicParsing
            $ttfs = @(Get-Item $tmpFile)
        }

        if ($ttfs.Count -eq 0) {
            Write-Note "No fonts matching '$FilePattern' in $DisplayName archive."
            return
        }

        if (-not (Test-Path $userFontsDir)) {
            New-Item -ItemType Directory -Path $userFontsDir -Force | Out-Null
        }
        $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

        $installed = @()
        foreach ($ttf in $ttfs) {
            $dest    = Join-Path $userFontsDir $ttf.Name
            Copy-Item -Path $ttf.FullName -Destination $dest -Force
            $regName = "$([IO.Path]::GetFileNameWithoutExtension($ttf.Name)) (TrueType)"
            New-ItemProperty -Path $regPath -Name $regName -Value $dest -PropertyType String -Force | Out-Null
            $installed += $dest
        }

        # Make the new faces usable in the *current* session without a reboot or
        # re-login. Registering in HKCU alone is not enough: GDI/DirectWrite font
        # collections are cached per-session, so a running Windows Terminal would
        # still report the family as missing. AddFontResource + a WM_FONTCHANGE
        # broadcast forces every running app to refresh its font list.
        foreach ($f in $installed) { [void][FontBroadcast]::AddFontResource($f) }
        $res = [IntPtr]::Zero
        [void][FontBroadcast]::SendMessageTimeout([IntPtr]0xFFFF, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0, 1000, [ref]$res)

        Write-Ok "$DisplayName ($($ttfs.Count) faces)"
    } finally {
        Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Win32 interop for live font registration (see Install-UserFont). Defined once
# here so Add-Type is not called on every invocation.
if (-not ('FontBroadcast' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FontBroadcast {
    [DllImport("gdi32.dll", CharSet=CharSet.Unicode)]
    public static extern int AddFontResource(string lpFileName);
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
}
'@
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
# Fonts : on installe en trio plutot que la Nerd Font patchee fourre-tout, car
# cette derniere remplace les codepoints emoji BMP (U+2705 CHECK, U+274C CROSS, U+26A0 WARNING
# etc.) par des glyphes monochromes qui ecrasent le fallback Segoe UI Emoji
# colore. Resultat avec la Nerd Font seule : tableaux et docs avec emojis BMP
# illisibles en noir et blanc. Le combo recommande par Nerd Fonts eux-memes,
# plus Noto Naskh Arabic pour un fallback arabe lisible :
#   1) JetBrains Mono vanille  : base + ligatures de code, ne touche pas aux
#      codepoints emoji.
#   2) Noto Naskh Arabic      : ecriture arabe en style naskh, type Droid.
#   3) Symbols Nerd Font Mono  : icones uniquement (PUA U+E000-F8FF + plans
#      supplementaires U+F0000+), aucun caractere de base, aucun patch emoji.
#   4) Segoe UI Emoji          : natif Windows, gere tous les emojis colores.
# Chaque police s'occupe de SON domaine de codepoints -- zero collision. Voir
# wt-settings.json -> profiles.defaults.font.face pour la chaine de fallback.
$jbmZipUrl = Get-LatestGithubReleaseAsset -Repo 'JetBrains/JetBrainsMono' -NamePattern 'JetBrainsMono-*.zip'
Install-UserFont -DisplayName 'JetBrains Mono (vanilla)' `
    -Url         $jbmZipUrl `
    -FilePattern 'JetBrainsMono-*.ttf' `
    -MarkerFile  'JetBrainsMono-Regular.ttf'
Install-UserFont -DisplayName 'Noto Naskh Arabic' `
    -Url         'https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoNaskhArabic/hinted/ttf/NotoNaskhArabic-Regular.ttf' `
    -MarkerFile  'NotoNaskhArabic-Regular.ttf'
Install-UserFont -DisplayName 'Noto Naskh Arabic Bold' `
    -Url         'https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoNaskhArabic/hinted/ttf/NotoNaskhArabic-Bold.ttf' `
    -MarkerFile  'NotoNaskhArabic-Bold.ttf'
Install-UserFont -DisplayName 'Symbols Nerd Font Mono' `
    -Url         'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip' `
    -FilePattern 'SymbolsNerdFontMono-*.ttf' `
    -MarkerFile  'SymbolsNerdFontMono-Regular.ttf'
# Noto Color Emoji : la police emoji native Android (Google/Xiaomi/MIUI). On
# la prefere a Segoe UI Emoji parce que (1) elle gere les drapeaux pays
# (Windows affiche 'FR' au lieu du drapeau FR -- decision politique MS) et (2) le
# style match exactement les emojis du telephone de l'user (coherence
# cross-device).
#
# /!\ On telecharge la variante *COLRv1* (Noto-COLRv1.ttf), PAS le
# NotoColorEmoji.ttf par defaut. Ce dernier est au format bitmap CBDT/CBLC
# (heritage Android) que DirectWrite -- donc Windows Terminal -- ne sait PAS
# rendre : la police s'installe et apparait dans Windows, mais WT affiche une
# pop-up "Impossible de trouver les polices : Noto Color Emoji" au demarrage
# et retombe en silence sur Segoe UI Emoji. La variante COLRv1 est vectorielle
# (tables COLR + CPAL), nativement rendue par DirectWrite. Les deux fichiers
# exposent la meme famille "Noto Color Emoji", donc la chaine font.face dans
# wt-settings.json reste valable.
Install-UserFont -DisplayName 'Noto Color Emoji (Android-style, COLRv1)' `
    -Url         'https://raw.githubusercontent.com/googlefonts/noto-emoji/main/fonts/Noto-COLRv1.ttf' `
    -MarkerFile  'NotoColorEmoji-COLRv1.ttf'
Install-WingetPackage -Id 'Fastfetch-cli.Fastfetch'       -DisplayName 'Fastfetch'
# Rust toolchain : requis pour compiler claude-code/statusline-rs/ -> statusline.exe.
Install-WingetPackage -Id 'Rustlang.Rustup'               -DisplayName 'Rust toolchain (rustup)'
# Claude Code itself : the one-liner's whole point is to bootstrap a working
# `claude` install. Native installer would work but uses `irm | iex` which
# Defender flags (ClickFix.DAI!MTB) -- winget is the safe path.
Install-WingetPackage -Id 'Anthropic.ClaudeCode'          -DisplayName 'Claude Code'

# ---------------------------------------------------------------------------
# 2) PowerShell 7 profile
# ---------------------------------------------------------------------------

Write-Step 'PowerShell 7 profile'
$ps7Path = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
Write-Utf8File -Path $ps7Path -Content $ps7Profile -WithBom $true
Unblock-File $ps7Path
Write-Ok (Short-Path $ps7Path)

# ---------------------------------------------------------------------------
# 2b) img-clip-watcher (clipboard natif pour Claude Code pwsh)
# ---------------------------------------------------------------------------
# Le wrapper claude() du profil PS7 lance ce watcher, qui pousse chaque image
# deposee par le telephone (%USERPROFILE%\.claude-images en natif, ou ancien
# depot WSL en fallback) dans le presse-papiers de la window station du claude
# appelant (le presse-papiers Windows est PAR window station : il est
# impossible de l'alimenter depuis une autre connexion SSH -- cf.
# claude-code/windows-clipboard/img-clip-watcher.ps1 pour la root cause).
# Source dans claude-code/ (machinerie Claude), pas dans windows/files/ -- on
# ne le deploie que depuis un clone local ; en mode one-liner (irm) on skip
# avec une note, le wrapper claude() degrade proprement (Test-Path).

Write-Step 'img-clip-watcher (Claude Code clipboard)'
$watcherSrc  = Join-Path $PSScriptRoot '..\claude-code\windows-clipboard\img-clip-watcher.ps1'
$watcherDest = Join-Path $env:USERPROFILE '.local\bin\img-clip-watcher.ps1'
if (Test-Path $watcherSrc) {
    # BOM : le watcher tourne sous PS 5.1 (lecture CP-1252 sans BOM). Le fichier
    # est 100% ASCII par contrat, le BOM est une defense en profondeur gratuite.
    Write-Utf8File -Path $watcherDest -Content (Read-Utf8File $watcherSrc) -WithBom $true
    Unblock-File $watcherDest
    Write-Ok (Short-Path $watcherDest)
} else {
    Write-Note 'source absente (install one-liner sans clone) -- deployer depuis un clone : claude-code/windows-clipboard/img-clip-watcher.ps1 -> ~/.local/bin/'
}

# ---------------------------------------------------------------------------
# 2c) Zellij web server -- sessions telephone natives bureau
# ---------------------------------------------------------------------------
# La tache tourne AU LOGON dans la session interactive : les sessions zellij
# creees via le web server (port 8082) naissent donc dans cette logon session
# et restent joignables depuis le bureau (F2). Ne JAMAIS demarrer ce serveur
# depuis un contexte ssh (Session 0) -- c'est le bug du 2026-06-12 (session
# fantome injoignable, freeze de l'attach F2).

Write-Step 'Zellij web server (logon task)'
$zellijExe = Join-Path $env:LOCALAPPDATA 'Zellij\zellij.exe'
if (Test-Path $zellijExe) {
    $webArgs = 'web --daemonize --ip 127.0.0.1 --port 8082'
    $action   = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -Command `"& '$zellijExe' $webArgs`""
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'zellij-web-server' -Action $action `
        -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Ok "scheduled task 'zellij-web-server' registered (at logon)"
} else {
    Write-Note 'zellij.exe introuvable -- tache zellij-web-server non creee'
}

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

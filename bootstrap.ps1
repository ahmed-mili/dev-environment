#Requires -Version 5.1
<#
.SYNOPSIS
    One-liner bootstrap: clone dev-environment, install Windows bundle, build
    statusline Rust binary, patch claude.exe for 9 Hz animation, deploy Claude
    Code config.

.DESCRIPTION
    Prérequis durs (sinon abort) :
    - Smart App Control DÉSACTIVÉ (sinon Windows bloque l'exécution du
      statusline Rust unsigned + certains build-scripts cargo). SAC se
      désactive dans Settings > Privacy & security. ⚠️ Désactivation
      définitive : pour réactiver il faut reset Windows.
    - Session PowerShell ÉLEVÉE (admin). Nécessaire pour ajouter une exception
      Microsoft Defender sur le hook patch-claude-exe.ps1, qui est sinon
      flagged Trojan:Win32/FileFix.BBA!MTB et mis en quarantaine au clone.

.EXAMPLE
    # One-liner depuis une PowerShell admin :
    $b="$env:TEMP\dev-env-bootstrap.ps1"; irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1 -OutFile $b; Unblock-File $b; & $b
#>

$ErrorActionPreference = 'Stop'

$RepoUrl  = 'https://github.com/ahmed-mili/dev-environment.git'
$RepoPath = 'C:\dev\dev-environment'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "    ! $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "    X $msg" -ForegroundColor Red }

if ((Get-ExecutionPolicy -Scope Process) -notin 'Bypass','Unrestricted') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# ---------------------------------------------------------------------------
# Prérequis 1/2 : Smart App Control doit être OFF
# ---------------------------------------------------------------------------
# SAC bloque l'exécution du statusline.exe (unsigned, low reputation) au
# runtime, et certains build-scripts cargo échouent OS 4551 sous SAC. La
# clé registre VerifiedAndReputablePolicyState vaut : 0=Off, 1=Evaluation,
# 2=On. On accepte Off + Evaluation, on refuse On.

Write-Step 'Checking Smart App Control state'
$sacState = 0
try {
    $sacState = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
                                  -Name VerifiedAndReputablePolicyState `
                                  -ErrorAction Stop).VerifiedAndReputablePolicyState
} catch {
    # SAC absent (Windows < 11 ou edition sans SAC) -> traité comme Off
    $sacState = 0
}
if ($sacState -eq 2) {
    Write-Err 'Smart App Control is ON.'
    Write-Host ''
    Write-Host '    Pour continuer, désactive SAC :' -ForegroundColor Yellow
    Write-Host '      Settings > Privacy & security > Smart App Control > Off' -ForegroundColor Yellow
    Write-Host '    Puis relance ce bootstrap.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '    ATTENTION : la désactivation est permanente. Pour réactiver SAC,' -ForegroundColor DarkYellow
    Write-Host '    il faut reset Windows entièrement.' -ForegroundColor DarkYellow
    exit 1
}
Write-Host "    OK (state=$sacState)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Prérequis 2/2 : session élevée (pour Add-MpPreference)
# ---------------------------------------------------------------------------

Write-Step 'Checking elevation'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err 'Not running as administrator.'
    Write-Host ''
    Write-Host '    Re-run from an elevated PowerShell session (Windows Terminal as Admin),' -ForegroundColor Yellow
    Write-Host '    needed to add a Defender exception on patch-claude-exe.ps1.' -ForegroundColor Yellow
    exit 1
}
Write-Host '    OK' -ForegroundColor Green

# ---------------------------------------------------------------------------
# Defender exception (avant git clone)
# ---------------------------------------------------------------------------
# patch-claude-exe.ps1 est flagged Trojan:Win32/FileFix.BBA!MTB (heuristique
# standard pour les binaires patchers : ReadAllBytes + IndexOf + WriteAllBytes
# sur un .exe). Sans exclusion préalable, Defender quarantaine le fichier dès
# qu'il atterrit sur disque -> git clone "réussit" mais le fichier disparaît
# silencieusement -> le SessionStart hook ne fire jamais.
#
# Add-MpPreference accepte des paths qui n'existent pas encore : l'exception
# est armée AVANT que le fichier soit écrit, donc Defender le skip à l'arrivée.
#
# Deux exclusions car le fichier vit à deux endroits après deploy.ps1 -Pull :
# 1. Dans le repo cloné (lu par Claude Code via le path absolu dans settings.json)
# 2. Dans ~/.claude/hooks/ (où deploy.ps1 -Pull le copie pour cohérence)

Write-Step 'Adding Defender exclusions for patch-claude-exe.ps1'
$exclusions = @(
    (Join-Path $RepoPath 'claude-code\hooks\patch-claude-exe.ps1'),
    (Join-Path $env:USERPROFILE '.claude\hooks\patch-claude-exe.ps1')
)
foreach ($p in $exclusions) {
    try {
        Add-MpPreference -ExclusionPath $p -ErrorAction Stop
        Write-Host "    + $p" -ForegroundColor Green
    } catch {
        Write-Warn "Could not add exclusion for $p : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Git + clone du repo
# ---------------------------------------------------------------------------

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing Git via winget'
    winget install --id Git.Git --exact --source winget --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

if (Test-Path (Join-Path $RepoPath '.git')) {
    Write-Step "Updating $RepoPath"
    git -C $RepoPath pull --ff-only
} else {
    Write-Step "Cloning into $RepoPath"
    $parent = Split-Path $RepoPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    git clone $RepoUrl $RepoPath
}

# ---------------------------------------------------------------------------
# Windows bundle (PS7, Terminal, Fastfetch, Rust)
# ---------------------------------------------------------------------------

Write-Step 'Windows bundle (winget packages + PS profiles + Terminal + Fastfetch + Rust)'
& (Join-Path $RepoPath 'windows\install.ps1')

# ---------------------------------------------------------------------------
# Build du statusline Rust
# ---------------------------------------------------------------------------
# build.ps1 redirige CARGO_TARGET_DIR vers %LOCALAPPDATA% (trusted zone hors
# de C:\dev), build en --release, et copie le binaire vers ~/.claude/statusline.exe.
# Refresh PATH d'abord pour que cargo soit visible si Rust vient d'être installé.

Write-Step 'Building statusline Rust binary'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + (Join-Path $env:USERPROFILE '.cargo\bin')
& (Join-Path $RepoPath 'claude-code\statusline-rs\build.ps1')

# ---------------------------------------------------------------------------
# Deploy Claude Code config
# ---------------------------------------------------------------------------

Write-Step 'Claude Code config (statusline + settings + hooks + skills)'
& (Join-Path $RepoPath 'claude-code\deploy.ps1') -Pull

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host '  Optional: open Claude Code and run `/plugin` to install frontend-design, code-review, superpowers.'
Write-Host '  Note: claude.exe will be patched automatically by the SessionStart hook at next session start.'

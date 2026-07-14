#Requires -Version 5.1
<#
.SYNOPSIS
    Serveur SSH Windows (OpenSSH) pour joindre ce PC depuis le telephone.

.DESCRIPTION
    Installe et configure OpenSSH Server : ecoute sur le port 2222, cle publique
    uniquement, pare-feu restreint au reseau Tailscale. C'est ce que les fonctions
    `pwsh` / `dev` / `sleep-pc` du bashrc Termux (android/files/bashrc) attendent
    pour ouvrir des sessions natives sur le bureau.

    NECESSITE DES DROITS ADMINISTRATEUR (contrairement a windows/install.ps1, qui
    tourne sans UAC). C'est la raison pour laquelle ce script est separe du bundle.

    Idempotent : relancable a volonte.

    Cette etape manquait au depot. Apres la reinstallation de Windows du
    2026-07-14, tout est remonte du repo SAUF le serveur SSH, qui avait ete monte
    a la main : le telephone ne joignait plus le PC. D'ou ce script.

.PARAMETER PublicKey
    Cle publique du client (le telephone). Contenu de ~/.ssh/id_ed25519.pub sur
    le Termux. Sans elle, le script configure le serveur mais n'autorise personne.

.PARAMETER Port
    Port d'ecoute. 2222 par defaut, valeur attendue par le bashrc Termux
    (PC_DESKTOP_SSH_PORT).

.EXAMPLE
    # Depuis un PowerShell ADMINISTRATEUR :
    .\install-sshd.ps1 -PublicKey "ssh-ed25519 <cle-publique-du-telephone>"

.EXAMPLE
    # Recuperer la cle depuis le telephone, puis installer :
    $k = ssh phone "cat ~/.ssh/id_ed25519.pub"
    .\install-sshd.ps1 -PublicKey $k
#>
[CmdletBinding()]
param(
    [string]$PublicKey = '',
    [int]$Port = 2222
)

$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Write-Note($m) { Write-Host "  $m" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  Serveur SSH Windows (OpenSSH)' -ForegroundColor White
Write-Host '  -----------------------------' -ForegroundColor DarkGray

# --- Garde-fou : administrateur -----------------------------------------------

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ce script exige des droits administrateur (installation d'une capacite Windows, service, pare-feu)."
}

# --- 1. Installation de la capacite OpenSSH Server ----------------------------
# Add-WindowsCapability echoue avec "Classe non enregistree" quand il est appele
# depuis PowerShell 7 : le module DISM n'y est pas charge nativement. On delegue
# donc systematiquement a Windows PowerShell 5.1, present sur toute machine.

Write-Step 'Installation de la capacite OpenSSH Server...'
if (Test-Path "$env:WINDIR\System32\OpenSSH\sshd.exe") {
    Write-Ok 'deja installee'
} else {
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps51 -NoProfile -Command "Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null"
    if (-not (Test-Path "$env:WINDIR\System32\OpenSSH\sshd.exe")) {
        throw "Echec de l'installation d'OpenSSH Server."
    }
    Write-Ok 'installee'
}

# --- 2. Premier demarrage : genere sshd_config et les cles d'hote --------------

Write-Step 'Service sshd...'
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Write-Ok "demarrage automatique, etat $((Get-Service sshd).Status)"

# --- 3. Configuration : port et authentification par cle -----------------------
# PasswordAuthentication no : la seule facon d'entrer est la cle du telephone.
# Aucun mot de passe n'est accepte, donc aucune attaque par force brute possible.

Write-Step "Configuration (port $Port, cle uniquement)..."
$cfgPath = Join-Path $env:ProgramData 'ssh\sshd_config'
$cfg     = Get-Content $cfgPath

# Idempotent : on remplace la directive si elle existe (commentee ou non).
$cfg = $cfg -replace '^\s*#?\s*Port\s+\d+\s*$',                    "Port $Port"
$cfg = $cfg -replace '^\s*#?\s*PasswordAuthentication\s+\w+\s*$',   'PasswordAuthentication no'
if (-not ($cfg -match '^\s*Port\s')) { $cfg += "Port $Port" }
if (-not ($cfg -match '^\s*PasswordAuthentication\s')) { $cfg += 'PasswordAuthentication no' }

# sshd ne lit pas un fichier avec BOM.
[IO.File]::WriteAllLines($cfgPath, $cfg, (New-Object Text.UTF8Encoding($false)))
Write-Ok (Split-Path $cfgPath -Leaf)

# --- 4. Cle publique autorisee ------------------------------------------------
# Piege classique : pour un compte MEMBRE DU GROUPE ADMINISTRATEURS, sshd ne lit
# PAS ~/.ssh/authorized_keys mais __PROGRAMDATA__/ssh/administrators_authorized_keys
# (voir le bloc "Match Group administrators" en fin de sshd_config). Une cle
# deposee au mauvais endroit est ignoree en silence : l'authentification echoue
# sans le moindre message utile.

if ($PublicKey.Trim()) {
    Write-Step 'Autorisation de la cle publique...'

    $isAdminUser = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdminUser) {
        $keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    } else {
        $keyFile = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
        New-Item -ItemType Directory -Force -Path (Split-Path $keyFile -Parent) | Out-Null
    }

    $keys = @()
    if (Test-Path $keyFile) { $keys = @(Get-Content $keyFile | Where-Object { $_.Trim() }) }
    if ($keys -notcontains $PublicKey.Trim()) { $keys += $PublicKey.Trim() }
    [IO.File]::WriteAllLines($keyFile, $keys, (New-Object Text.UTF8Encoding($false)))

    if ($isAdminUser) {
        # ACL obligatoires : Administrateurs + SYSTEM seuls, sans heritage. Sinon
        # sshd (StrictModes) ignore le fichier. On passe par les SID, car les noms
        # de groupes sont localises ("Administrateurs", "SYSTEME" en francais) et
        # icacls echoue alors sur un Windows non anglais.
        icacls $keyFile /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F' | Out-Null
    }
    Write-Ok (Split-Path $keyFile -Leaf)
} else {
    Write-Note 'aucune -PublicKey fournie : le serveur tourne mais n autorise personne.'
    Write-Note 'Relancer avec : -PublicKey (ssh phone "cat ~/.ssh/id_ed25519.pub")'
}

# --- 5. Pare-feu : Tailscale uniquement ---------------------------------------
# Le port n'est PAS ouvert sur le LAN ni sur un Wi-Fi public : seule la plage
# CGNAT de Tailscale (100.64.0.0/10) peut l'atteindre. La regle par defaut
# d'OpenSSH ouvre le port 22 a tout le monde : on la desactive.

Write-Step 'Pare-feu...'
Get-NetFirewallRule -DisplayName 'OpenSSH*' -ErrorAction SilentlyContinue | ForEach-Object {
    Disable-NetFirewallRule -Name $_.Name
    Write-Note "regle par defaut desactivee : $($_.DisplayName)"
}

$ruleName = "SSH entrant (Tailscale, port $Port)"
Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
    -RemoteAddress 100.64.0.0/10 -Profile Any `
    -Program (Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe') | Out-Null
Write-Ok $ruleName

# --- 6. Application et verification -------------------------------------------

Restart-Service sshd
Start-Sleep -Seconds 2

$listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
               Where-Object LocalPort -eq $Port)
if (-not $listening) { throw "sshd ne repond pas sur le port $Port." }

Write-Host ''
Write-Ok "sshd ecoute sur le port $Port."
Write-Host ''
Write-Note "Cote telephone, ~/.ssh/config doit pointer sur l'IP Tailscale de CE PC :"
Write-Note ''
Write-Note '    Host desktop'
Write-Note '        HostName <ip-tailscale-du-pc>'
Write-Note "        User $env:USERNAME"
Write-Note "        Port $Port"
Write-Note '        StrictHostKeyChecking accept-new'
Write-Note ''
Write-Note "IP Tailscale de ce PC : tailscale ip -4"
Write-Note "Une reinstallation de Windows cree un NOUVEAU noeud Tailscale (nouvelle IP) :"
Write-Note "l'ancienne entree du telephone pointe alors dans le vide. C'est le piege."
Write-Host ''

#Requires -Version 5.1
<#
.SYNOPSIS
    Cote CLIENT SSH : cle locale + entrees ~/.ssh/config vers les autres machines.

.DESCRIPTION
    Pendant de windows/install-sshd.ps1 (qui, lui, monte le SERVEUR). Ici on
    prepare la machine a JOINDRE les autres :

      1. genere ~/.ssh/id_ed25519 s'il n'existe pas (sans passphrase)
      2. ecrit un bloc Host par pair dans ~/.ssh/config, de facon idempotente
      3. affiche la cle publique a autoriser sur les machines distantes

    Aucune valeur personnelle n'est codee ici : hostnames, ports et noms
    d'utilisateur arrivent par -Peer. Sur un parc Tailscale, passer le nom
    MagicDNS plutot qu'une IP evite le piege de la reinstallation (nouveau
    noeud = nouvelle IP, l'entree pointe alors dans le vide).

    Idempotent : un bloc deja present est remplace, pas duplique. Un bloc
    "Host <alias>" ecrit a la main avant ce script est repris aussi (ssh
    retient la PREMIERE occurrence d'un alias, un doublon serait un piege).

.PARAMETER Peer
    Un ou plusieurs pairs au format "alias=user@hote[:port]" (port 22 par
    defaut). L'alias est ce que l'on tape : "ssh <alias>". Plusieurs pairs se
    passent en LISTE separee par des virgules -- repeter -Peer echoue
    ("parameter specified more than once").

.PARAMETER NoKeygen
    N'genere aucune cle ; se contente d'ecrire les entrees de config.

.EXAMPLE
    # Depuis le laptop : joindre le PC fixe (sshd sur 2222) et le telephone
    # (Termux, sshd sur 8022).
    .\setup-ssh-peers.ps1 -Peer "desktop=<user-windows>@<nom-tailscale-du-pc>:2222",
                                "phone=<user-termux>@<nom-tailscale-du-tel>:8022"

.EXAMPLE
    # Les noms et IP Tailscale disponibles :
    tailscale status
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Peer,
    [switch]$NoKeygen
)

$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Write-Note($m) { Write-Host "  $m" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  Client SSH : cle + pairs connus' -ForegroundColor White
Write-Host '  -------------------------------' -ForegroundColor DarkGray

$sshDir     = Join-Path $env:USERPROFILE '.ssh'
$configPath = Join-Path $sshDir 'config'
$keyPath    = Join-Path $sshDir 'id_ed25519'

New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

# --- 1. Client OpenSSH present ? ----------------------------------------------
# Livre par defaut sur Windows 10/11, mais desinstallable. Meme delegation a
# Windows PowerShell 5.1 que dans install-sshd.ps1 : sous PowerShell 7,
# Add-WindowsCapability echoue avec "Classe non enregistree" (module DISM
# absent de cette edition).

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Write-Step 'Installation du client OpenSSH...'
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps51 -NoProfile -Command "Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null"
    $env:Path += ";$(Join-Path $env:WINDIR 'System32\OpenSSH')"
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw "Client OpenSSH introuvable apres installation (ssh-keygen absent du PATH)."
    }
    Write-Ok 'installe'
}

# --- 2. Cle privee locale ------------------------------------------------------

if (-not $NoKeygen) {
    Write-Step 'Cle locale...'
    if (Test-Path $keyPath) {
        Write-Ok 'id_ed25519 deja present'
    } else {
        # Passphrase vide passee via cmd.exe et non directement : Windows
        # PowerShell 5.1 SUPPRIME un argument '' de la ligne de commande d'un
        # exe natif, et ssh-keygen bascule alors en saisie interactive (le
        # script se fige). cmd transmet -N "" litteralement.
        $comment = "$env:USERNAME@$env:COMPUTERNAME"
        & $env:ComSpec /c "ssh-keygen -t ed25519 -q -C `"$comment`" -f `"$keyPath`" -N `"`""
        if (-not (Test-Path $keyPath)) { throw "Echec de la generation de $keyPath." }
        Write-Ok "genere ($comment)"
    }
}

# --- 3. Entrees ~/.ssh/config --------------------------------------------------

$lines = @()
if (Test-Path $configPath) { $lines = @(Get-Content $configPath) }

function Remove-HostBlock {
    # Retire toute definition existante de l'alias : le bloc balise de ce
    # script, ET un "Host <alias>" ecrit a la main (jusqu'au prochain Host ou
    # a la fin du fichier).
    param([string[]]$Content, [string]$Alias)

    $out    = New-Object System.Collections.Generic.List[string]
    $inMine = $false
    $inRaw  = $false
    $begin  = "# >>> dev-environment: $Alias"
    $end    = "# <<< dev-environment: $Alias"

    foreach ($line in $Content) {
        if ($line -eq $begin) { $inMine = $true;  continue }
        if ($line -eq $end)   { $inMine = $false; continue }
        if ($inMine) { continue }

        if ($line -match '^\s*Host\s+(.+?)\s*$') {
            $aliases = $Matches[1] -split '\s+'
            $inRaw   = ($aliases -contains $Alias)
            if ($inRaw) { continue }
        }
        elseif ($inRaw) {
            # Un bloc brut court jusqu'a la prochaine ligne ecrite en colonne 0 :
            # ses options sont indentees. Ne s'arreter qu'a un "Host" mangerait
            # les commentaires et les blocs Match qui suivent.
            if (-not $line.Trim() -or $line -match '^[ \t]') { continue }
            $inRaw = $false
        }

        $out.Add($line)
    }
    return $out.ToArray()
}

foreach ($spec in $Peer) {
    if ($spec -notmatch '^\s*([^=\s]+)\s*=\s*([^@\s]+)@([^:\s]+)(?::(\d+))?\s*$') {
        throw "Pair invalide : '$spec'. Format attendu : alias=user@hote[:port]"
    }
    $alias    = $Matches[1]
    $user     = $Matches[2]
    $hostName = $Matches[3]
    $port     = if ($Matches[4]) { $Matches[4] } else { '22' }

    Write-Step "Pair '$alias' -> $user@${hostName}:$port"

    $lines = Remove-HostBlock -Content $lines -Alias $alias
    # Une ligne vide de separation, sauf en tete de fichier. Passage par une
    # liste : $a[0..($a.Count-2)] se retourne contre nous a un seul element
    # ($a[0..-1] renvoie tout le tableau au lieu du vide attendu).
    $buf = New-Object System.Collections.Generic.List[string]
    $buf.AddRange([string[]]$lines)
    while ($buf.Count -gt 0 -and -not $buf[$buf.Count - 1].Trim()) {
        $buf.RemoveAt($buf.Count - 1)
    }
    if ($buf.Count -gt 0) { $buf.Add('') }
    $lines = $buf.ToArray()

    $lines += "# >>> dev-environment: $alias"
    $lines += "Host $alias"
    $lines += "    HostName $hostName"
    $lines += "    Port $port"
    $lines += "    User $user"
    # accept-new : accepte une empreinte inconnue au premier contact, mais
    # refuse toujours une empreinte QUI CHANGE (contrairement a "no", qui
    # avalerait une attaque par interposition en silence).
    $lines += '    StrictHostKeyChecking accept-new'
    # Sessions longues derriere un NAT mobile : sans keepalive applicatif, le
    # tunnel meurt en silence et la session parait figee.
    $lines += '    ServerAliveInterval 60'
    $lines += '    ServerAliveCountMax 3'
    $lines += "# <<< dev-environment: $alias"

    Write-Ok "ssh $alias"
}

# Normalisation : retirer un bloc laisse un trou, et sans ce menage le fichier
# gagnerait une ligne vide a chaque execution (l'idempotence n'est pas seulement
# "pas de doublon", c'est "meme entree = meme fichier").
$clean = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
    $empty = -not $line.Trim()
    if ($empty -and ($clean.Count -eq 0 -or -not $clean[$clean.Count - 1].Trim())) { continue }
    $clean.Add($line)
}
while ($clean.Count -gt 0 -and -not $clean[$clean.Count - 1].Trim()) {
    $clean.RemoveAt($clean.Count - 1)
}
$lines = $clean.ToArray()

# ssh refuse un config avec BOM (il le lit comme un mot-cle inconnu).
[IO.File]::WriteAllLines($configPath, $lines, (New-Object Text.UTF8Encoding($false)))
Write-Note (Split-Path $configPath -Parent | Join-Path -ChildPath 'config')

# --- 4. Cle publique a autoriser en face --------------------------------------

Write-Host ''
if (Test-Path "$keyPath.pub") {
    Write-Ok 'Cle publique de CETTE machine, a autoriser sur les pairs :'
    Write-Host ''
    Write-Host "    $(Get-Content "$keyPath.pub")" -ForegroundColor Yellow
    Write-Host ''
    Write-Note 'Sur un pair Windows (PowerShell administrateur) :'
    Write-Note '    .\install-sshd.ps1 -PublicKey "<la cle ci-dessus>"'
    Write-Note 'Sur un pair Termux :'
    Write-Note '    echo "<la cle ci-dessus>" >> ~/.ssh/authorized_keys'
}
Write-Host ''

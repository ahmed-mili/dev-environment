# img-clip-watcher.ps1 -- alimente le presse-papiers de SA logon session avec
# chaque nouvelle image deposee par le telephone dans ~/.claude-images (WSL).
#
# ENCODAGE : ce fichier doit rester 100% ASCII. Il est execute par Windows
# PowerShell 5.1, qui lit les .ps1 SANS BOM en CP-1252 : tout caractere UTF-8
# multi-octets (accent, tiret long) y devient des octets parasites -- et le
# tiret long U+2014 se decode en smart-quote 0x94 qui CASSE le parse des
# chaines (vecu 2026-06-10, premiere version de ce script).
#
# POURQUOI ce watcher existe (root cause prouvee 2026-06-10) :
# Le presse-papiers Windows est PAR WINDOW STATION, et chaque connexion SSH
# entrante (sshd :2222) recoit sa PROPRE window station (Service-0x0-<LUID>$),
# detruite a la deconnexion. Un `ssh -p 2222 ... powershell SetImage` lance par
# img2claude depuis le tel ecrit donc dans un presse-papiers FANTOME : le
# SetImage renvoie exit 0 (succes... dans sa window station ephemere), mais le
# Claude pwsh natif -- qui vit dans une AUTRE logon session, celle du serveur
# zellij cree par la connexion SSH de l'user -- ne le voit JAMAIS.
# Repro de la preuve : SetText('MARKER') via ssh :2222 -> REMOTE-READBACK ok,
# winsta Service-0x0-1a409f8c$ ; relecture depuis la session zellij (winsta
# Service-0x0-cf9df44$) -> clipboard VIDE.
#
# => Le SEUL design qui marche par construction : executer SetImage DEPUIS la
# logon session du lecteur. Ce watcher est lance par les wrappers claude() /
# ollama() du profil pwsh et par les launchers Bash de Claude ; il herite donc
# de la logon session du pane zellij (= celle du serveur zellij = celle de
# claude.exe) et son SetImage est visible par le Alt+V de CE claude.
# claude.exe lit le clipboard en spawnant
# `powershell [Clipboard]::ContainsImage()/GetImage()` (meme logon session).
#
# Cycle de vie :
#   - Mutex `Local\img-clip-watcher-<winsta>` : scope par WINDOW STATION (le
#     perimetre exact du clipboard) -> 1 watcher par window station, peu importe
#     combien de claude/panes y tournent. Les surnumeraires sortent aussitot.
#     (PAS un `Local\` nu : Local\ = par session Windows, soit la session 0
#     entiere en SSH -> bloquait les watchers des autres window stations.)
#   - Ancre de vie : le serveur zellij trouve dans la chaine de parente du
#     -CallerPid (cas SSH -> panes zellij), sinon le -CallerPid lui-meme (cas
#     pwsh interactif au PC). Quand l'ancre meurt, le watcher sort -- pas de
#     process fantome qui s'accumule.
#
# Limites connues :
#   - .webp : GDI+ (System.Drawing) ne decode pas WebP -> log + skip. La voie
#     WSL (wl-copy/sharp) le gere, la voie pwsh natif non. Captures MIUI = jpg.
#   - Si WSL est arrete, l'UNC \\wsl.localhost est indisponible -> le watcher
#     reessaie silencieusement (log une seule fois par episode).

param(
    [int]$CallerPid = 0,
    [string]$ImagesDir = '',
    [string]$Distro = 'Ubuntu',
    [int]$PollMs = 1000,
    [int]$FreshWindowMin = 10
)

$ErrorActionPreference = 'Stop'

# --- Log minimal (depannage) -------------------------------------------------
$LogFile = Join-Path $env:TEMP 'img-clip-watcher.log'
try {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) {
        Remove-Item $LogFile -Force
    }
} catch {}
function Write-Log([string]$msg) {
    try { Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg" } catch {}
}

# --- Single-instance par WINDOW STATION -----------------------------------------
# PIEGE (vecu 2026-06-10) : `Local\` est scope par SESSION Windows (session 0
# entiere pour tout ce qui arrive par SSH), PAS par logon session. Un mutex
# `Local\img-clip-watcher` nu bloquait donc TOUS les watchers de la session 0,
# meme ceux destines a d'autres window stations. Le bon scope = la window
# station (c'est le perimetre du clipboard) -> son nom fait partie du nom du
# mutex : 1 watcher par window station = 1 watcher par clipboard.
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinStaInfo {
    [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformationW(IntPtr h, int i, StringBuilder s, int l, out int o);
    public static string Name() {
        var sb = new StringBuilder(256); int len;
        GetUserObjectInformationW(GetProcessWindowStation(), 2, sb, 256, out len);
        return sb.ToString();
    }
}
'@
$winsta = [WinStaInfo]::Name()
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\img-clip-watcher-$winsta", [ref]$created)
if (-not $created) {
    Write-Log "instance surnumeraire (pid=$PID winsta=$winsta) : mutex deja tenu pour cette window station, sortie"
    exit 0
}

# --- Ancre de vie --------------------------------------------------------------
# Remonte la chaine de parente du caller jusqu'au serveur zellij (`zellij
# --server`) : c'est LUI le proprietaire de la logon session des panes (il
# survit aux deconnexions SSH ; les claude relances s'y rattachent). Sans
# zellij dans la chaine (pwsh interactif), l'ancre = le caller.
if ($CallerPid -le 0) {
    $CallerPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
}
$AnchorPid = $CallerPid
try {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$CallerPid"
    while ($p) {
        if ($p.Name -ieq 'zellij.exe' -and $p.CommandLine -match '--server') {
            $AnchorPid = $p.ProcessId
            break
        }
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
    }
} catch {}

# --- Resolution du dossier d'images -------------------------------------------
# Pas de chemin personnel en dur : le home WSL est resolu via wsl.exe. Fallback
# UNC glob si wsl.exe rechigne (rare). Reessaye dans la boucle si WSL est down.
function Resolve-ImagesDir {
    if ($script:ImagesDir) {
        try {
            if (Test-Path $script:ImagesDir) { return $script:ImagesDir }
        } catch {
            $script:ImagesDir = ''
        }
    }
    try {
        $wslHome = (& "$env:SystemRoot\System32\wsl.exe" -d $Distro -e sh -c 'echo $HOME' 2>$null | Select-Object -First 1)
        if ($wslHome) { $wslHome = $wslHome.Trim() }
        if ($wslHome) {
            $candidate = "\\wsl.localhost\$Distro$($wslHome -replace '/', '\')\.claude-images"
            if (Test-Path $candidate) { $script:ImagesDir = $candidate; return $candidate }
        }
    } catch {}
    try {
        $candidate = Get-ChildItem "\\wsl.localhost\$Distro\home" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName '.claude-images' } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($candidate) { $script:ImagesDir = $candidate; return $candidate }
    } catch {}
    return $null
}

function Get-LatestImage([string]$dir) {
    # Dotfiles exclus : rsync ecrit son temporaire en `.img-....XXXX` puis
    # renomme atomiquement -> on ne voit que des fichiers complets de sa part.
    Get-ChildItem $dir -File -ErrorAction Stop |
        Where-Object { $_.Name -notlike '.*' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Push-ToClipboard($file) {
    $img = $null
    try {
        $img = [System.Drawing.Image]::FromFile($file.FullName)
        [System.Windows.Forms.Clipboard]::SetImage($img)
        Write-Log "SetImage OK : $($file.Name) ($($file.Length) o)"
        return $true
    } catch {
        Write-Log "SetImage ECHEC : $($file.Name) : $($_.Exception.Message)"
        return $false
    } finally {
        if ($img) { $img.Dispose() }
    }
}

try {
    Write-Log "demarrage (caller=$CallerPid anchor=$AnchorPid pid=$PID winsta=$winsta)"

    # --- Etat initial : staging immediat d'une image fraiche --------------------
    # Si l'user a envoye une photo AVANT d'ouvrir claude (< FreshWindowMin), elle
    # doit etre collable tout de suite. Plus vieille -> simple baseline (ne pas
    # re-coller l'historique).
    $lastSeen = ''   # cle "FullName|Ticks|Length" de la derniere image traitee
    $uncWarned = $false
    $loopErrorWarned = $false
    try {
        $dir = Resolve-ImagesDir
        if ($dir) {
            $latest = Get-LatestImage $dir
            if ($latest) {
                $key = '{0}|{1}|{2}' -f $latest.FullName, $latest.LastWriteTimeUtc.Ticks, $latest.Length
                if (((Get-Date) - $latest.LastWriteTime).TotalMinutes -lt $FreshWindowMin) {
                    [void](Push-ToClipboard $latest)
                }
                $lastSeen = $key
            }
        } else {
            Write-Log 'dossier images introuvable au demarrage (WSL down ?) : retries en boucle'
        }
    } catch { Write-Log "scan initial impossible : $($_.Exception.Message)" }

    # --- Boucle principale ------------------------------------------------------
    while ($true) {
        try {
            Start-Sleep -Milliseconds $PollMs

            # Ancre morte -> on sort (et on libere le mutex pour un futur watcher).
            if (-not (Get-Process -Id $AnchorPid -ErrorAction SilentlyContinue)) {
                Write-Log "ancre $AnchorPid morte : sortie"
                break
            }

            $dir = Resolve-ImagesDir
            if (-not $dir) {
                if (-not $uncWarned) { Write-Log 'dossier images inaccessible : attente'; $uncWarned = $true }
                continue
            }

            try {
                $latest = Get-LatestImage $dir
            } catch {
                if (-not $uncWarned) { Write-Log "scan impossible : $($_.Exception.Message)"; $uncWarned = $true }
                continue
            }
            $uncWarned = $false
            $loopErrorWarned = $false
            if (-not $latest) { continue }

            $key = '{0}|{1}|{2}' -f $latest.FullName, $latest.LastWriteTimeUtc.Ticks, $latest.Length
            if ($key -eq $lastSeen) { continue }

            # Stabilite : scp (fallback sans rsync) ecrit le fichier final en place.
            # On exige une taille inchangee sur ~300 ms avant de pousser ; sinon on
            # retentera au prochain tour (la cle inclut Length -> changement re-detecte).
            Start-Sleep -Milliseconds 300
            try { $again = Get-Item $latest.FullName -ErrorAction Stop } catch { continue }
            if ($again.Length -ne $latest.Length -or $again.LastWriteTimeUtc -ne $latest.LastWriteTimeUtc) { continue }

            [void](Push-ToClipboard $latest)
            $lastSeen = $key
        } catch {
            if (-not $loopErrorWarned) {
                Write-Log "erreur transitoire boucle : $($_.Exception.Message)"
                $loopErrorWarned = $true
            }
        }
    }
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
}

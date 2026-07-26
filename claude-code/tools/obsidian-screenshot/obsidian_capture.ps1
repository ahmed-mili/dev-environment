<#
  obsidian_capture.ps1 — capture du rendu reel d'Obsidian sur Windows.

  Photographie la fenetre Obsidian via Win32 PrintWindow(PW_RENDERFULLCONTENT),
  donc SANS la mettre au premier plan et meme si elle est minimisee. Rafraichir
  et faire defiler passent par le CLI officiel d'Obsidian (deja sur le PATH),
  donc la aussi sans voler le focus.

  100 % PowerShell natif : P/Invoke user32/dwmapi + System.Drawing. Aucune
  dependance a installer, volontairement — l'ancienne chaine Python/pywin32
  cassait des qu'un interpreteur ou un package bougeait.

  Point d'entree : obsidian_tools.cmd (fixe l'encodage UTF-8). Ne pas appeler
  ce .ps1 en direct.
#>

[CmdletBinding()]
param(
  [string]$Vault,
  [switch]$Find,
  [switch]$Capture,
  [string]$Output,
  [switch]$Refresh,
  [switch]$HardReload,
  [switch]$ScrollCapture,
  [string]$ScrollDir,
  [int]$MaxShots = 12
)

$ErrorActionPreference = 'Stop'

# Les erreurs attendues (Obsidian ferme, vault absent, plusieurs vaults) sont des
# messages a lire, pas des stack traces PowerShell a decoder.
trap {
  Write-Output $_.Exception.Message
  exit 1
}

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class ObsCap {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# SW_SHOWNOACTIVATE : reaffiche une fenetre minimisee SANS lui donner le focus.
$SW_SHOWNOACTIVATE = 4
$SW_MINIMIZE       = 6
# DWMWA_EXTENDED_FRAME_BOUNDS : bornes reelles de la fenetre, sans l'ombre portee.
$DWMWA_EXTENDED_FRAME_BOUNDS = 9
# PW_RENDERFULLCONTENT : demande a Chromium de rendre tout le contenu, meme en
# arriere-plan. Sans ce flag, une fenetre non focalisee ressort vide.
$PW_RENDERFULLCONTENT = 2

# ---------------------------------------------------------------- fenetres

function Get-ObsidianWindow {
  $found = New-Object System.Collections.ArrayList
  $cb = [ObsCap+EnumWindowsProc] {
    param($hWnd, $lParam)
    if ([ObsCap]::IsWindowVisible($hWnd) -or [ObsCap]::IsIconic($hWnd)) {
      $len = [ObsCap]::GetWindowTextLength($hWnd)
      if ($len -gt 0) {
        $sb = New-Object System.Text.StringBuilder ($len + 1)
        [void][ObsCap]::GetWindowText($hWnd, $sb, $sb.Capacity)
        $title = $sb.ToString()
        # Titre type : "<note> - <Vault> - Obsidian 1.12.7". Le vault est donc
        # l'avant-dernier segment, quel que soit le nombre de " - " dans le nom
        # de la note.
        if ($title -match ' - Obsidian v?\d') {
          $parts = $title -split ' - '
          $vaultName = if ($parts.Count -ge 2) { $parts[$parts.Count - 2] } else { '?' }
          [void]$found.Add([pscustomobject]@{
            Hwnd      = $hWnd
            Vault     = $vaultName
            Title     = $title
            Minimized = [ObsCap]::IsIconic($hWnd)
          })
        }
      }
    }
    return $true
  }
  [void][ObsCap]::EnumWindows($cb, [IntPtr]::Zero)
  return $found
}

function Resolve-ObsidianWindow {
  param([string]$WantedVault)

  $windows = Get-ObsidianWindow
  if ($windows.Count -eq 0) {
    throw "Aucune fenetre Obsidian detectee. Verifie qu'Obsidian est lance."
  }

  if ($WantedVault) {
    $hit = $windows | Where-Object { $_.Vault -eq $WantedVault }
    if (-not $hit) {
      $hit = $windows | Where-Object { $_.Title -like "*$WantedVault*" }
    }
    if (-not $hit) {
      $liste = ($windows | ForEach-Object { $_.Vault }) -join ', '
      throw "Vault '$WantedVault' introuvable. Vaults ouverts : $liste"
    }
    return @($hit)[0]
  }

  # Pas de -Vault : on ne devine QUE s'il n'y a aucune ambiguite. Capturer la
  # mauvaise fenetre en silence coute une session entiere de debug fantome.
  if ($windows.Count -gt 1) {
    $liste = ($windows | ForEach-Object { $_.Vault }) -join ', '
    throw "Plusieurs vaults ouverts ($liste) : precise -Vault <nom>."
  }
  return $windows[0]
}

# ------------------------------------------------------------- CLI Obsidian

function Invoke-ObsidianEval {
  param([string]$TargetVault, [string]$Code)

  $cli = Get-Command obsidian -ErrorAction SilentlyContinue
  if (-not $cli) {
    throw "CLI Obsidian introuvable sur le PATH (Obsidian.com, bundle avec l'app desktop)."
  }
  $cliArgs = @()
  if ($TargetVault) { $cliArgs += "vault=$TargetVault" }
  $cliArgs += 'eval'
  $cliArgs += "code=$Code"
  return (& $cli.Source @cliArgs 2>&1 | Out-String).Trim()
}

# ---------------------------------------------------------------- capture

function Save-WindowCapture {
  param([IntPtr]$Hwnd, [bool]$WasMinimized, [string]$Path)

  $rect = New-Object ObsCap+RECT
  [void][ObsCap]::DwmGetWindowAttribute($Hwnd, $DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$rect, 16)
  $w = $rect.Right - $rect.Left
  $h = $rect.Bottom - $rect.Top
  if ($w -le 0 -or $h -le 0) { throw "Dimensions de fenetre invalides ($w x $h)." }

  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $ok = [ObsCap]::PrintWindow($Hwnd, $hdc, $PW_RENDERFULLCONTENT)
  $g.ReleaseHdc($hdc)
  $g.Dispose()

  # Capture noire : bug connu de PrintWindow sur certains rendus GPU. On
  # echantillonne plutot que de tout parcourir (une image 4K = 8M pixels).
  $dark = 0
  for ($i = 0; $i -lt 40; $i++) {
    $px = $bmp.GetPixel([int]($w * (($i * 37) % 100) / 100), [int]($h * (($i * 61) % 100) / 100))
    if ($px.R -lt 8 -and $px.G -lt 8 -and $px.B -lt 8) { $dark++ }
  }

  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  if (-not $ok) { Write-Warning "PrintWindow a renvoye false : l'image peut etre incomplete." }
  if ($dark -ge 36) {
    Write-Warning "Capture quasi noire ($dark/40 points sombres) : bug GPU de PrintWindow. Passe Obsidian en fenetre (pas en plein ecran exclusif) et reessaie."
  }
  return [pscustomobject]@{ Path = $Path; Width = $w; Height = $h; Dark = $dark }
}

function New-TempCapturePath {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  return (Join-Path $env:TEMP "obsidian-capture-$stamp.png")
}

# ------------------------------------------------------------------ actions

if ($Find) {
  $windows = Get-ObsidianWindow
  if ($windows.Count -eq 0) {
    Write-Output "Aucune fenetre Obsidian detectee. Verifie qu'Obsidian est lance."
    exit 1
  }
  $windows | Format-Table -AutoSize Hwnd, Vault, Minimized, Title
  exit 0
}

if ($Refresh) {
  $win = Resolve-ObsidianWindow -WantedVault $Vault
  # requestLoadSnippets relit les .css depuis le disque et reapplique le style
  # au DOM en place : la note reste ouverte, le scroll ne bouge pas.
  $res = Invoke-ObsidianEval -TargetVault $win.Vault -Code "app.customCss.requestLoadSnippets(); 'ok'"
  Write-Output "Snippets CSS recharges sur '$($win.Vault)' ($res)"
  exit 0
}

if ($HardReload) {
  $win = Resolve-ObsidianWindow -WantedVault $Vault
  # Le reload tue le contexte JS : on le differe pour que l'eval reponde avant.
  $res = Invoke-ObsidianEval -TargetVault $win.Vault -Code "setTimeout(function(){location.reload()},80); 'reload lance'"
  Write-Output "Reload complet demande sur '$($win.Vault)' ($res). Attendre ~5 s, puis reouvrir la note voulue : le workspace est restaure et la feuille active peut changer."
  exit 0
}

if ($ScrollCapture) {
  $win = Resolve-ObsidianWindow -WantedVault $Vault
  if (-not $ScrollDir) { $ScrollDir = Join-Path $env:TEMP ("obsidian-scroll-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
  if (-not (Test-Path $ScrollDir)) { New-Item -ItemType Directory -Force -Path $ScrollDir | Out-Null }

  $wasMin = $win.Minimized
  if ($wasMin) { [void][ObsCap]::ShowWindow($win.Hwnd, $SW_SHOWNOACTIVATE); Start-Sleep -Milliseconds 700 }

  # Chromium suspend le repaint d'une fenetre en arriere-plan : PrintWindow
  # resservirait le frame precedent a chaque palier. On coupe le throttling le
  # temps du defilement. L'API a bouge selon les versions d'Electron, d'ou le
  # try/catch cote JS — un echec n'est pas bloquant, il rend juste les frames
  # plus fragiles.
  $throttleOff = "(function(){try{require('electron').remote.getCurrentWebContents().setBackgroundThrottling(false);return 'off'}catch(e){return 'indisponible'}})()"
  $throttleOn  = "(function(){try{require('electron').remote.getCurrentWebContents().setBackgroundThrottling(true);return 'on'}catch(e){return 'indisponible'}})()"
  $throttleState = Invoke-ObsidianEval -TargetVault $win.Vault -Code $throttleOff

  # Remonte en haut du document avant la premiere capture.
  $jsTop = "(function(){var l=app.workspace.getMostRecentLeaf();var el=l&&l.view&&l.view.containerEl&&l.view.containerEl.querySelector('.markdown-preview-view');if(!el)return 'no-preview';el.scrollTop=0;return JSON.stringify({top:0,max:el.scrollHeight-el.clientHeight})})()"
  $state = Invoke-ObsidianEval -TargetVault $win.Vault -Code $jsTop
  if ($state -match 'no-preview') {
    Write-Warning "Pas de vue Lecture active : -ScrollCapture ne peut pas defiler. Bascule la note en mode Lecture."
  }

  $shots = @()
  for ($i = 1; $i -le $MaxShots; $i++) {
    Start-Sleep -Milliseconds 450
    $path = Join-Path $ScrollDir ('scroll_{0:D3}.png' -f $i)
    $shot = Save-WindowCapture -Hwnd $win.Hwnd -WasMinimized $false -Path $path
    $shots += $shot.Path
    Write-Output $shot.Path

    # Defilement d'un ecran moins un chevauchement, pour ne rien couper entre
    # deux images. On lit la position APRES le scroll : si elle n'a pas bouge,
    # on est en bas du document.
    $jsNext = "(function(){var l=app.workspace.getMostRecentLeaf();var el=l&&l.view&&l.view.containerEl&&l.view.containerEl.querySelector('.markdown-preview-view');if(!el)return 'no-preview';var before=el.scrollTop;el.scrollTop=before+el.clientHeight-80;return JSON.stringify({before:before,top:el.scrollTop,max:el.scrollHeight-el.clientHeight})})()"
    $raw = Invoke-ObsidianEval -TargetVault $win.Vault -Code $jsNext
    $json = $raw -replace '^=>\s*', ''
    try { $pos = $json | ConvertFrom-Json } catch { break }
    if ($null -eq $pos -or $pos.top -le $pos.before) { break }
  }

  if ($throttleState -eq 'off' -or $throttleState -match 'off') {
    [void](Invoke-ObsidianEval -TargetVault $win.Vault -Code $throttleOn)
  }
  if ($wasMin) { [void][ObsCap]::ShowWindow($win.Hwnd, $SW_MINIMIZE) }

  Write-Output "$($shots.Count) capture(s) dans $ScrollDir"
  exit 0
}

# -Capture est l'action par defaut : appeler le script sans switch capture.
$win = Resolve-ObsidianWindow -WantedVault $Vault
if (-not $Output) { $Output = New-TempCapturePath }

$wasMin = $win.Minimized
if ($wasMin) { [void][ObsCap]::ShowWindow($win.Hwnd, $SW_SHOWNOACTIVATE); Start-Sleep -Milliseconds 700 }
$shot = Save-WindowCapture -Hwnd $win.Hwnd -WasMinimized $wasMin -Path $Output
if ($wasMin) { [void][ObsCap]::ShowWindow($win.Hwnd, $SW_MINIMIZE) }

Write-Output "vault=$($win.Vault) | taille=$($shot.Width)x$($shot.Height) | points sombres=$($shot.Dark)/40"
Write-Output $shot.Path

<#
.SYNOPSIS
  Trouve le screenshot le plus recent et met son chemin absolu dans le presse-papiers.
  Option -Paste : simule Ctrl+V pour coller le chemin dans la fenetre active (Claude Code).
.DESCRIPTION
  Cherche l'image la plus recente (LastWriteTime) dans C:\Users\<user>\Pictures\Screenshots
  (Win+PrtScn) et quelques fallbacks (OneDrive, Videos\Captures). Copie le chemin dans le
  clipboard. Avec -Paste, envoie Ctrl+V pour l'inserer dans le prompt Claude Code, qui
  l'analysera ensuite via kimi-vision.ps1 (delegation vision glm -> kimi).
  A lancer via un raccourci clavier (.lnk Shortcut key ou AutoHotkey).
.PARAMETER Paste
  Si present, simule Ctrl+V apres avoir copie le chemin dans le clipboard.
.EXAMPLE
  pwsh -NoProfile -File latest-screenshot.ps1
  pwsh -NoProfile -File latest-screenshot.ps1 -Paste
#>
param([switch]$Paste)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$dirs = @(
  "$env:USERPROFILE\Pictures\Screenshots",
  "$env:USERPROFILE\OneDrive\Pictures\Screenshots",
  "$env:USERPROFILE\OneDrive - Personal\Pictures\Screenshots",
  "$env:USERPROFILE\Videos\Captures",
  "$env:USERPROFILE\Pictures"
)
$exts = @('.png','.jpg','.jpeg','.webp','.bmp')
$latest = $null
foreach ($d in $dirs) {
  if (Test-Path $d) {
    $f = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
         Where-Object { $exts -contains $_.Extension.ToLower() } |
         Sort-Object LastWriteTime -Descending |
         Select-Object -First 1
    if ($f -and (-not $latest -or $f.LastWriteTime -gt $latest.LastWriteTime)) {
      $latest = $f
    }
  }
}

if (-not $latest) {
  [Console]::Error.WriteLine("Aucun screenshot trouve dans : $($dirs -join ', ')")
  exit 1
}

Set-Clipboard -Value $latest.FullName
[Console]::Error.WriteLine("Chemin copie dans le presse-papiers : $($latest.FullName)")

if ($Paste) {
  Add-Type -AssemblyName System.Windows.Forms
  Start-Sleep -Milliseconds 80
  [System.Windows.Forms.SendKeys]::SendWait("^v")
}
exit 0
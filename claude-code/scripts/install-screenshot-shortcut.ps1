<#
.SYNOPSIS
  Bootstrap the Alt+V image-path shortcut (AutoHotkey v2 + Startup .lnk).
.DESCRIPTION
  Idempotent installer for the Alt+V image-path shortcut used by Claude Code
  in Windows terminals, including Warp. Steps:
    1. Ensure AutoHotkey v2 is installed (winget --scope user, no UAC).
    2. Ensure screenshot-shortcut.ahk is present in ~/.claude/scripts/
       (run claude-code/deploy.ps1 -Pull first if missing).
    3. Create a .lnk in the Windows Startup folder so AHK relaunches at boot.
    4. Launch the .ahk now (hidden) so the hotkey is active without a reboot.
  Re-run safely anytime; #SingleInstance Force in the .ahk prevents duplicates.
  ASCII-only source: PowerShell 5.1 reads .ps1 as CP-1252 without a UTF-8 BOM,
  so non-ASCII glyphs break the parser far from the offending char. Keep ASCII.
.PARAMETER Uninstall
  Remove the Startup .lnk and kill the running AHK process. Leaves AutoHotkey
  itself and the .ahk file in place (re-runnable any time).
.EXAMPLE
  pwsh -NoProfile -File install-screenshot-shortcut.ps1
  pwsh -NoProfile -File install-screenshot-shortcut.ps1 -Uninstall
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$HomeClaude = "$env:USERPROFILE\.claude"
$AhkScript  = "$HomeClaude\scripts\screenshot-shortcut.ahk"
$StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$Lnk        = Join-Path $StartupDir 'screenshot-shortcut.lnk'

# --- 1. Locate AutoHotkey v2 (install if missing) ---
$cands = @(
  "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
  "$env:LOCALAPPDATA\Programs\AutoHotkey\AutoHotkey64.exe",
  "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
  "C:\Program Files\AutoHotkey\AutoHotkey64.exe"
)
$ahkExe = $null
foreach ($c in $cands) { if (Test-Path $c) { $ahkExe = $c; break } }

if ($Uninstall) {
  if (Test-Path $Lnk) { Remove-Item $Lnk -Force; Write-Host "Removed Startup .lnk: $Lnk" }
  Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force; Write-Host "Killed AHK PID $($_.Id)"
  }
  Write-Host "Uninstall done. AutoHotkey itself and the .ahk file are left in place."
  exit 0
}

if (-not $ahkExe) {
  Write-Host "AutoHotkey v2 not found. Installing via winget (scope user, no UAC)..."
  winget install --id AutoHotkey.AutoHotkey -e --accept-package-agreements --accept-source-agreements --scope user
  foreach ($c in $cands) { if (Test-Path $c) { $ahkExe = $c; break } }
}
if (-not $ahkExe) { throw "AutoHotkey v2 install failed or exe not found in expected paths." }
Write-Host "AutoHotkey exe: $ahkExe"

# --- 2. Ensure the .ahk is deployed ---
if (-not (Test-Path $AhkScript)) {
  throw "Missing $AhkScript. Run C:\dev\dev-environment\claude-code\deploy.ps1 -Pull first."
}

# --- 3. Create the Startup .lnk ---
if (-not (Test-Path $StartupDir)) { New-Item -ItemType Directory -Force $StartupDir | Out-Null }
$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($Lnk)
$s.TargetPath = $ahkExe
$s.Arguments = '"' + $AhkScript + '"'
$s.WorkingDirectory = Split-Path $AhkScript -Parent
$s.WindowStyle = 7
$s.Description = 'Alt+V : insert path of latest screenshot (Claude Code + kimi-vision)'
$s.Save()
Write-Host "Startup .lnk created: $Lnk"

# --- 4. Launch the .ahk now (hidden) so Alt+V is active immediately ---
Start-Process -FilePath $ahkExe -ArgumentList ('"' + $AhkScript + '"') -WindowStyle Hidden
Start-Sleep -Milliseconds 700
$proc = Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue
if ($proc) { Write-Host "AHK running: PID=$($proc.Id -join ',')" }
else { Write-Warning "AHK did not start. Check $AhkScript for syntax errors." }

Write-Host ""
Write-Host "Done. Alt+V now inserts an image file path into the active window"
Write-Host "(including Claude Code in Warp). Relaunches at boot via Startup."
exit 0

# Build le statusline Rust et le deploie dans ~/.claude/statusline.exe.
#
# Pourquoi CARGO_TARGET_DIR pointe hors de C:\dev :
# Windows 11 Smart App Control bloque l'execution des build-scripts cargo
# dans certains paths (cf. erreur OS 4551). On redirige vers %LOCALAPPDATA%
# qui est en zone "trusted".

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetDir   = Join-Path $env:LOCALAPPDATA 'statusline-build\target'
$Dest        = Join-Path $env:USERPROFILE '.claude\statusline.exe'
$CargoBin    = Join-Path $env:USERPROFILE '.cargo\bin'

# Resolve cargo : prefer the rustup-installed user-local one,
# fall back to whatever's in PATH already.
$Cargo = Join-Path $CargoBin 'cargo.exe'
if (-not (Test-Path -LiteralPath $Cargo)) {
    $Cargo = (Get-Command cargo -ErrorAction SilentlyContinue).Source
}
if (-not $Cargo -or -not (Test-Path -LiteralPath $Cargo)) {
    throw "cargo introuvable. Installer Rust : winget install Rustlang.Rustup, puis relancer."
}

Write-Host "==> Building (target=$TargetDir)..."
$env:CARGO_TARGET_DIR = $TargetDir
& $Cargo build --release --manifest-path (Join-Path $ProjectRoot 'Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$BuiltExe = Join-Path $TargetDir 'release\statusline.exe'
if (-not (Test-Path $BuiltExe)) { throw "Binary not found at $BuiltExe" }

Write-Host "==> Copying to $Dest..."
Copy-Item -LiteralPath $BuiltExe -Destination $Dest -Force

Write-Host "==> Done. Size: $((Get-Item $Dest).Length / 1MB) MB"
Write-Host ""
Write-Host "Statusline binaire installe. Redemarre une session Claude Code pour le voir."

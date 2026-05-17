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
# Une session Claude Code en cours tient un handle sur statusline.exe (le
# binaire est spawne 10 fois par seconde). Windows refuse de l'ecraser, mais
# autorise le rename meme avec handle ouvert -> on rename l'ancien puis on
# ecrit le nouveau. Les sessions deja en cours continuent avec l'ancien
# binaire (leurs handles suivent le fichier renomme), les nouveaux spawns
# utilisent le nouveau.
if (Test-Path -LiteralPath $Dest) {
    $StaleOld = "$Dest.old-locked"
    # Si on a deja un ancien renomme qui n'est plus tenu par personne, on peut le degager
    if (Test-Path -LiteralPath $StaleOld) {
        try { Remove-Item -LiteralPath $StaleOld -Force -ErrorAction Stop } catch {}
    }
    if (Test-Path -LiteralPath $StaleOld) {
        # Encore tenu, on prend un nom unique
        $StaleOld = "$Dest.old-$([System.IO.Path]::GetRandomFileName())"
    }
    Move-Item -LiteralPath $Dest -Destination $StaleOld -Force
}
Copy-Item -LiteralPath $BuiltExe -Destination $Dest -Force

Write-Host "==> Done. Size: $((Get-Item $Dest).Length / 1MB) MB"
Write-Host ""
Write-Host "Statusline binaire installe. Redemarre une session Claude Code pour le voir."

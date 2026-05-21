# Build the statusline Rust binary and deploy it to ~/.claude/statusline.exe.
#
# Why CARGO_TARGET_DIR points outside C:\dev :
# Windows 11 Smart App Control blocks cargo build-scripts in certain paths
# (OS error 4551). We redirect target/ to %LOCALAPPDATA%, which is in the
# "trusted" zone.
#
# Toolchain selection :
# Rust on Windows defaults to the x86_64-pc-windows-msvc target, which needs
# link.exe from Visual Studio Build Tools (~1.5 GB install). On a fresh
# Windows 11, Build Tools are absent and the build fails with
#   error: linker `link.exe` not found
# We detect this up-front via vswhere and, if Build Tools are absent, install
# the stable-gnu toolchain plus WinLibs/MinGW via winget. WinLibs provides
# gcc.exe, which the cc crate needs to compile ring (rustls' crypto backend)
# from its C/asm sources. The produced binary is equivalent for this use
# case (statusline is a small stdin/stdout program).

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetDir   = Join-Path $env:LOCALAPPDATA 'statusline-build\target'
$Dest        = Join-Path $env:USERPROFILE '.claude\statusline.exe'
$CargoBin    = Join-Path $env:USERPROFILE '.cargo\bin'
$GnuTarget   = 'x86_64-pc-windows-gnu'
$WinLibsId   = 'BrechtSanders.WinLibs.POSIX.UCRT'

# Resolve cargo + rustup : prefer the rustup-installed user-local ones,
# fall back to PATH.
$Cargo  = Join-Path $CargoBin 'cargo.exe'
$Rustup = Join-Path $CargoBin 'rustup.exe'
if (-not (Test-Path -LiteralPath $Cargo))  { $Cargo  = (Get-Command cargo  -ErrorAction SilentlyContinue).Source }
if (-not (Test-Path -LiteralPath $Rustup)) { $Rustup = (Get-Command rustup -ErrorAction SilentlyContinue).Source }
if (-not $Cargo -or -not (Test-Path -LiteralPath $Cargo)) {
    throw "cargo not found. Install Rust first: winget install Rustlang.Rustup, then re-run."
}

function Test-MsvcLinker {
    # Canonical detection via vswhere (ships with any VS 2017+ installation).
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vcPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($vcPath -and (Test-Path -LiteralPath $vcPath)) { return $true }
    }
    # Fallback : link.exe already on PATH (rare; happens in VS dev cmd).
    if (Get-Command link.exe -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Update-ProcessPath {
    # Re-read PATH from registry (Machine + User) so a freshly-installed
    # winget package becomes visible in the current process without restart.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
                $CargoBin
}

function Test-GnuBuildTools {
    # ring (rustls' crypto backend) is built via the cc crate, which looks
    # for gcc.exe on PATH for target x86_64-pc-windows-gnu. dlltool.exe is
    # used by the linker for import-lib generation on some deps.
    return [bool]((Get-Command gcc.exe -ErrorAction SilentlyContinue) -and
                  (Get-Command dlltool.exe -ErrorAction SilentlyContinue))
}

function Ensure-GnuBuildTools {
    Update-ProcessPath
    if (Test-GnuBuildTools) { return }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "gcc.exe/dlltool.exe not found and winget is unavailable. Install WinLibs manually, then re-run."
    }

    Write-Host "==> Installing WinLibs/MinGW (gcc + dlltool) via winget..."
    & $winget.Source install --id $WinLibsId --exact --source winget --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install $WinLibsId failed" }

    Update-ProcessPath
    if (-not (Test-GnuBuildTools)) {
        throw "WinLibs installed, but gcc.exe or dlltool.exe is still not visible on PATH. Restart the shell and re-run."
    }
}

$useGnu = -not (Test-MsvcLinker)
if ($useGnu) {
    Write-Host "==> MSVC linker (link.exe) absent - using stable-gnu toolchain instead." -ForegroundColor Yellow
    Write-Host "    Visual Studio install avoided; WinLibs/MinGW provides gcc.exe and dlltool.exe."
    if (-not $Rustup -or -not (Test-Path -LiteralPath $Rustup)) {
        throw "rustup not found - cannot install stable-gnu toolchain"
    }
    # Idempotent : rustup is a no-op if stable-gnu is already installed.
    & $Rustup toolchain install stable-gnu --no-self-update --profile minimal
    if ($LASTEXITCODE -ne 0) { throw "rustup toolchain install stable-gnu failed" }
    Ensure-GnuBuildTools
}

$env:CARGO_TARGET_DIR = $TargetDir
$manifest = Join-Path $ProjectRoot 'Cargo.toml'
$cargoArgs = if ($useGnu) { @('+stable-gnu', 'build', '--release', '--manifest-path', $manifest, '--target', $GnuTarget) }
             else         { @('build', '--release', '--manifest-path', $manifest) }

$toolchainLabel = if ($useGnu) { 'stable-gnu' } else { 'stable-msvc' }
Write-Host "==> Building (target=$TargetDir, toolchain=$toolchainLabel)..."
& $Cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

# Locate the produced binary. Prefer the exact path for the selected build,
# then probe legacy paths as a fallback.
$ExpectedBuiltExe = if ($useGnu) { Join-Path $TargetDir 'x86_64-pc-windows-gnu\release\statusline.exe' }
                    else         { Join-Path $TargetDir 'release\statusline.exe' }
$candidates = @(
    $ExpectedBuiltExe,
    (Join-Path $TargetDir 'release\statusline.exe'),
    (Join-Path $TargetDir 'x86_64-pc-windows-gnu\release\statusline.exe'),
    (Join-Path $TargetDir 'x86_64-pc-windows-msvc\release\statusline.exe')
)
$BuiltExe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $BuiltExe) { throw "statusline.exe not found in any expected target subdir" }

Write-Host "==> Copying to $Dest..."
# A running Claude Code session keeps a handle on statusline.exe (the binary
# is spawned 10x per second). Windows refuses to overwrite it but allows
# rename-with-open-handle -> we rename the old one then write the new one.
# In-flight sessions keep using the renamed file via their open handles;
# new spawns pick up the new file.
$destDir = Split-Path -Parent $Dest
if (-not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
}
if (Test-Path -LiteralPath $Dest) {
    $StaleOld = "$Dest.old-locked"
    if (Test-Path -LiteralPath $StaleOld) {
        try { Remove-Item -LiteralPath $StaleOld -Force -ErrorAction Stop } catch {}
    }
    if (Test-Path -LiteralPath $StaleOld) {
        # Old name still held by something; pick a unique one.
        $StaleOld = "$Dest.old-$([System.IO.Path]::GetRandomFileName())"
    }
    Move-Item -LiteralPath $Dest -Destination $StaleOld -Force
}
Copy-Item -LiteralPath $BuiltExe -Destination $Dest -Force

$sizeMb = [math]::Round((Get-Item -LiteralPath $Dest).Length / 1MB, 2)
Write-Host "==> Done. Size: $sizeMb MB"
Write-Host ""
Write-Host "Statusline binary installed at $Dest"
Write-Host "Restart any Claude Code session to pick it up."

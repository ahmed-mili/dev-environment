# dev-environment :: web installer stub (Windows)
#
# Usage (one-liner, copy-paste into any PowerShell):
#   irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/install.ps1 | iex
#
# Piped into iex there is no script file on disk, hence no MOTW and no
# ExecutionPolicy gate -- so this stub stays trivial ON PURPOSE. It only
# downloads bootstrap.ps1 to a real file (inspectable, Unblock-File'd) and
# runs it: the exact pattern the README used to ask users to type manually.
# Defender's ClickFix heuristics (Trojan:Win32/ClickFix.DAI!MTB) target
# in-memory `iex (irm <raw payload>)` chains; here the actual installer
# always lands on disk first.
#
# ASCII-only source (see bootstrap.ps1 header for the CP-1252 rationale).
& {
    $ErrorActionPreference = 'Stop'
    $b = Join-Path $env:TEMP 'dev-env-bootstrap.ps1'
    Invoke-RestMethod 'https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1' -OutFile $b
    Unblock-File $b
    & $b
}

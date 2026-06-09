# Check that all plugins listed in ~/.claude/settings.json are actually installed.
# Install any missing ones with `claude plugin install`.
#
# Usage:
#   .\check-plugins.ps1        # dry-run: list missing plugins
#   .\check-plugins.ps1 -Fix   # install missing plugins
#
# This script is meant to be run after deploy/bootstrap or whenever
# the Skill Registry looks incomplete.

param([switch]$Fix)

$ErrorActionPreference = 'Stop'
$Settings = "$env:USERPROFILE\.claude\settings.json"

if (-not (Test-Path $Settings)) {
    Write-Error "Settings file not found: $Settings"
    exit 1
}

# Parse enabledPlugins from JSON
$enabled = (Get-Content $Settings -Raw | ConvertFrom-Json).enabledPlugins
$wanted = @($enabled.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Name })

if ($wanted.Count -eq 0) {
    Write-Host "No plugins enabled in $Settings"
    exit 0
}

# Check which ones are actually installed
# Format: "  ❯ name@marketplace"  (lines with the bullet marker)
$installed = @(claude plugin list 2>$null | Where-Object { $_ -match '❯\s+(.+)' } | ForEach-Object { $matches[1].Trim() })
$missing = @($wanted | Where-Object {
    $name = ($_ -split '@')[0]
    $pluginName = ($_ -split '@')[0] + '@' + ($_ -split '@')[1]
    $pluginName -notin $installed
})

if ($missing.Count -eq 0) {
    Write-Host "All $($wanted.Count) plugins are installed." -ForegroundColor Green
    exit 0
}

Write-Host "MISSING plugins ($($missing.Count)/$($wanted.Count)):" -ForegroundColor Yellow
foreach ($p in $missing) { Write-Host "  - $p" }

if ($Fix) {
    Write-Host ""
    Write-Host "Installing missing plugins..." -ForegroundColor Cyan
    foreach ($p in $missing) {
        Write-Host "  -> claude plugin install $p --scope user"
        try {
            claude plugin install $p --scope user
        } catch {
            Write-Warning "Failed to install $p : $_"
        }
    }
    Write-Host "Done. Restart Claude Code so new plugins are loaded." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Run with -Fix to install them automatically." -ForegroundColor Yellow
    exit 1
}

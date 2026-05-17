#Requires -Version 5.1
<#
.SYNOPSIS
    One-liner bootstrap: clone dev-environment, install Windows bundle, deploy Claude Code config.

.EXAMPLE
    iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1).TrimStart([char]0xFEFF)
#>

$ErrorActionPreference = 'Stop'

$RepoUrl  = 'https://github.com/ahmed-mili/dev-environment.git'
$RepoPath = 'C:\dev\dev-environment'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

if ((Get-ExecutionPolicy -Scope Process) -notin 'Bypass','Unrestricted') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing Git via winget'
    winget install --id Git.Git --exact --source winget --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

if (Test-Path (Join-Path $RepoPath '.git')) {
    Write-Step "Updating $RepoPath"
    git -C $RepoPath pull --ff-only
} else {
    Write-Step "Cloning into $RepoPath"
    $parent = Split-Path $RepoPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    git clone $RepoUrl $RepoPath
}

Write-Step 'Windows bundle (winget packages + PS profiles + Terminal + Fastfetch)'
& (Join-Path $RepoPath 'windows\install.ps1')

Write-Step 'Claude Code config (statusline + settings + hooks + skills)'
& (Join-Path $RepoPath 'claude-code\deploy.ps1') -Pull

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host '  Optional: open Claude Code and run `/plugin` to install frontend-design, code-review, superpowers.'

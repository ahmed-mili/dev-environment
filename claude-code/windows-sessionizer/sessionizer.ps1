# sessionizer.ps1 -- menu fzf natif Windows : sessions zellij / projets C:\dev / vaults Obsidian.
# Portage 1:1 de claude-code/tmux-sessionizer.sh (post-migration WSL -> natif, 2026-06-10).
# Lance par : (a) Invoke-Sessionizer (handler PSReadLine F2 du profil pwsh, terminal courant),
#             (b) keybind F2 de la config zellij Windows (pane flottant -> ouvre via wt.exe).
#
# Hooks de test (parite .sh) :
#   -List           : imprime le menu genere (TSV colore) puis sort
#   -Pick "t`tt`tn`tl" : bypass fzf avec un choix force (type<TAB>name<TAB>label)
#   -Key  ctrl-n    : simule une touche --expect (avec -Pick)
#   -DryRun         : imprime les commandes au lieu de les executer
#   -View all|dev|vaults : perimetre (defaut all)
param(
    [switch]$List,
    [string]$Pick = '',
    [string]$Key = '',
    [switch]$DryRun,
    [ValidateSet('all','dev','vaults')][string]$View = 'all'
)

$ErrorActionPreference = 'Stop'

# UTF-8 de bout en bout : lance en -NoProfile, on ne peut PAS compter sur le profil.
# Sans ca, le vault arabe (C:\obsidian-vaults\<nom arabe>) casse dans les pipes fzf.
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

$DevDir    = if ($env:PC_DEV_DIR)    { $env:PC_DEV_DIR }    else { 'C:\dev' }
$VaultsDir = if ($env:PC_VAULTS_WIN) { $env:PC_VAULTS_WIN } else { 'C:\obsidian-vaults' }

# --- Collecte -----------------------------------------------------------------
# Sessions zellij actives, DEUX sources (parite zj_actives_win du .sh) :
#   1. zellij ls -ns          : sessions joignables depuis CETTE window station
#   2. dossiers IPC + cache   : sessions des AUTRES logon sessions (ssh :2222 du tel)
function Get-ActiveSessions {
    $names = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($l in (& zellij ls -ns 2>$null)) {
        if ($l -and $l.Trim()) { [void]$names.Add($l.Trim()) }
    }
    Get-ChildItem "$env:TEMP\zellij\contract_version_*" -Directory -ErrorAction SilentlyContinue |
        Get-ChildItem -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$names.Add($_.Name) }
    Get-ChildItem "$env:LOCALAPPDATA\Zellij\cache\contract_version_*\session_info" -Directory -ErrorAction SilentlyContinue |
        Get-ChildItem -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'session-metadata.kdl') } |
        ForEach-Object { [void]$names.Add($_.Name) }
    return @($names)
}

function Get-Projects {
    @(Get-ChildItem $DevDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -ExpandProperty Name)
}

# Vault = sous-dossier contenant un .obsidian/ (distingue un vrai vault d'un dossier).
function Get-Vaults {
    @(Get-ChildItem $VaultsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '.obsidian') } |
        Sort-Object Name | Select-Object -ExpandProperty Name)
}

$projects = Get-Projects
$vaults   = Get-Vaults
switch ($View) {
    'dev'    { $vaults = @();   $actives = Get-ActiveSessions }
    'vaults' { $projects = @(); $actives = Get-ActiveSessions }
    default  {                  $actives = Get-ActiveSessions }
}

# Orphelins = sessions actives qui ne sont NI un projet NI un vault (creees via Ctrl-N).
$orphans = @($actives | Where-Object { ($projects -notcontains $_) -and ($vaults -notcontains $_) })

if ($List) {
    Write-Output "actives: $($actives -join ', ')"
    Write-Output "projects: $($projects -join ', ')"
    Write-Output "vaults: $($vaults -join ', ')"
    Write-Output "orphans: $($orphans -join ', ')"
    exit 0
}

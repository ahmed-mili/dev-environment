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

# --- Menu (TSV: type <TAB> name <TAB> label affiche) ----------------------------
# type 'sep' = titre decoratif : les fleches le sautent (binds Task 4), un clic
# dessus rouvre le menu -> non selectionnable. Parite build_menu du .sh.
$e = [char]27
$G = "$e[32m"; $D = "$e[90m"; $R = "$e[0m"; $M = "$e[38;5;141m"   # M = violet (vaults)
$T = [char]9

function Build-Menu {
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($orphans.Count) {
        $lines.Add("sep$T$T$D──────  $R◆ Sessions$D  ──────$R")
        foreach ($s in $orphans) {
            $lines.Add("active$T$s$T$G●$R $s  $G(active)$R")
        }
    }
    if ($projects.Count) {
        $lines.Add("sep$T$T$D──────  $R◆ Projects$D  ──────$R")
        foreach ($p in $projects) {
            if ($actives -contains $p) {
                $lines.Add("active$T$p$T$G●$R $p  $G(active)$R")
            } else {
                $lines.Add("project$T$p$T$D○$R $p")
            }
        }
    }
    if ($vaults.Count) {
        $lines.Add("sep$T$T$D──────  $M◆ Obsidian Vaults$D  ──────$R")
        foreach ($v in $vaults) {
            if ($actives -contains $v) {
                $lines.Add("active$T$v$T$G●$R $v  $G(active)$R")
            } else {
                $lines.Add("vault$T$v$T$M○$R $v")
            }
        }
    }
    return $lines
}

if ($List) { Build-Menu | Write-Output; exit 0 }

# --- Actions --------------------------------------------------------------------
# Creation SANS commande injectee : zellij ouvre le shell par defaut (pwsh, profil
# charge), l'utilisateur tape `claude` lui-meme (parite .sh). `attach -c` =
# attach-or-create. Toujours `options --on-force-close detach` : une fermeture
# brutale du terminal DETACHE (ne tue pas la session).
#
# Routage : DANS zellij ($env:ZELLIJ pose), un `zellij attach` imbrique est
# interdit -> on ouvre un NOUVEL onglet Windows Terminal (wt.exe) qui porte la
# session. HORS zellij : attach direct dans le terminal courant (il le remplace,
# equivalent du exec bash). NB : le detour wt.exe systematique du .sh pour les
# vaults etait un artefact du monde WSL->Windows ; en natif, vaults et projets
# suivent le MEME chemin (uniforme).
$InZellij = [bool]$env:ZELLIJ

function Invoke-Step {   # commande de SETUP (equivalent step() du .sh)
    param([string[]]$Argv)
    if ($DryRun) { Write-Output ("DRYRUN: " + ($Argv -join ' ')) }
    else { & $Argv[0] @($Argv | Select-Object -Skip 1) }
}

function Invoke-Run {    # commande FINALE (equivalent run()/exec du .sh)
    param([string[]]$Argv)
    if ($DryRun) { Write-Output ("DRYRUN: " + ($Argv -join ' ')); exit 0 }
    & $Argv[0] @($Argv | Select-Object -Skip 1)
    exit $LASTEXITCODE
}

# Attache (ou cree) la session $Name avec $Dir pour cwd.
function Open-Session {
    param([string]$Name, [string]$Dir)
    if ($InZellij) {
        # -w 0 : fenetre WT existante ; nt : new tab ; -p : profil (titre/icone) ;
        # -d : repertoire de depart. La session zellij vit dans l'onglet.
        Invoke-Run @('wt.exe', '-w', '0', 'nt', '-p', 'PowerShell', '-d', $Dir,
                     'pwsh', '-NoProfile', '-NoExit', '-Command',
                     "zellij attach -c $Name options --on-force-close detach")
    } else {
        if ($Dir -and (Test-Path $Dir)) { Invoke-Step @('Set-Location', $Dir) }
        Invoke-Run @('zellij', 'attach', '-c', $Name, 'options', '--on-force-close', 'detach')
    }
}

# Rejoint une session ACTIVE. Pour un nom de vault dont la session a ete ouverte
# par le telephone (autre logon session), l'attach echouera : zellij affichera son
# erreur, comportement assume (parite .sh : delegation impossible cote desktop).
function Join-ActiveSession {
    param([string]$Name)
    $dir = if ($vaults -contains $Name) { Join-Path $VaultsDir $Name }
           elseif ($projects -contains $Name) { Join-Path $DevDir $Name }
           else { $null }
    Open-Session -Name $Name -Dir $dir
}

# Premier caractere Esc -> $null (annulation). Enter seul -> ''. Sinon la ligne.
function Read-OrCancel {
    try { $first = [Console]::ReadKey($true) } catch { return $null }
    if ($first.Key -eq 'Escape') { [Console]::Error.WriteLine(); return $null }
    if ($first.Key -eq 'Enter')  { [Console]::Error.WriteLine(); return '' }
    [Console]::Error.Write($first.KeyChar)
    $rest = [Console]::In.ReadLine()
    if ($null -eq $rest) { $rest = '' }
    return "$($first.KeyChar)$rest"
}

# --- Selection -------------------------------------------------------------------
if ($Pick) {
    $key = $Key
    $choice = $Pick
} else {
    Write-Error 'mode interactif branche en Task 4 (utiliser -Pick/-List en attendant)'
    exit 1
}

# --- Dispatch ----------------------------------------------------------------------
if ($key -eq 'ctrl-n') { $type = 'new'; $name = '' }
elseif (-not $choice)  { exit 0 }
else {
    $f = $choice -split "`t"
    $type = $f[0]; $name = $f[1]
}

switch ($type) {
    'sep'     { if ($DryRun -or $Pick) { exit 0 }; & $PSCommandPath -View $View; exit $LASTEXITCODE }
    'active'  { Join-ActiveSession -Name $name }
    'project' { Open-Session -Name $name -Dir (Join-Path $DevDir $name) }
    'vault'   { Open-Session -Name $name -Dir (Join-Path $VaultsDir $name) }
    'new'     {
        if (-not $name) {
            [Console]::Error.Write('Session name: ')
            $name = Read-OrCancel
            if (-not $name) { if ($DryRun -or $Pick) { exit 0 }; & $PSCommandPath -View $View; exit $LASTEXITCODE }
        }
        $start = Join-Path $DevDir $name
        if (-not (Test-Path $start)) { $start = $HOME }
        Open-Session -Name $name -Dir $start
    }
    default   { Write-Error "unknown choice: $type"; exit 1 }
}

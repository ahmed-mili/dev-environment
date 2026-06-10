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
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Error 'fzf introuvable - winget install junegunn.fzf'
        exit 1
    }
    $menu = Build-Menu

    # Positions 1-based (layout reverse, liste NON filtree) des titres et des
    # premiers items, pour les binds de navigation. Parite .sh, MAIS : fzf Windows
    # execute les transform via `cmd /s/c` -> pas d'arithmetique runtime possible
    # en batch one-liner (pas de delayed expansion). On PRE-CALCULE donc tout :
    #   down : saute si FZF_POS+1 est un titre  <=> FZF_POS dans (seps - 1)
    #   up   : saute si FZF_POS-1 est un titre  <=> FZF_POS dans (seps + 1)
    #          (cas special titre en position 1 : ignore, on ne remonte pas dessus)
    #   clic : bounce si FZF_POS est un titre   <=> FZF_POS dans seps
    $ssep = 0; $psep = 0; $vsep = 0; $pfirst = 0; $vfirst = 0; $pos = 0
    if ($orphans.Count)  { $ssep = $pos + 1; $pos += 1 + $orphans.Count }
    if ($projects.Count) { $psep = $pos + 1; $pfirst = $psep + 1; $pos += 1 + $projects.Count }
    if ($vaults.Count)   { $vsep = $pos + 1; $vfirst = $vsep + 1; $pos += 1 + $vaults.Count }
    $cursor0 = if ($ssep) { $ssep + 1 } elseif ($pfirst) { $pfirst } elseif ($vfirst) { $vfirst } else { 1 }
    $seps = @($ssep, $psep, $vsep) | Where-Object { $_ -gt 0 }

    # Genere une chaine batch `if "%FZF_POS%"=="a" (echo ACTION) else if ... (echo DEFAULT)`.
    function New-PosBind {
        param([int[]]$Positions, [string]$Action, [string]$Default)
        if (-not $Positions -or $Positions.Count -eq 0) { return "echo $Default" }
        $expr = "echo $Default"
        foreach ($p in $Positions) {
            $expr = "if `"%FZF_POS%`"==`"$p`" (echo $Action) else ($expr)"
        }
        return $expr
    }

    # Garde « filtre tape » : {q} est substitue PAR FZF avec quotes (query vide -> "").
    # Une fois filtree, les positions absolues ne veulent plus rien dire -> action de base.
    $downBatch  = "if {q}==`"`" ($(New-PosBind -Positions @($seps | ForEach-Object { $_ - 1 }) -Action 'down+down' -Default 'down')) else (echo down)"
    $upPositions = @($seps | ForEach-Object { $_ + 1 })
    $upInner = New-PosBind -Positions $upPositions -Action 'up+up' -Default 'up'
    if ($seps -contains 1) {
        # le titre est en position 1 : depuis la position 2, ne pas remonter dessus
        $upInner = "if `"%FZF_POS%`"==`"2`" (echo ignore) else ($upInner)"
    }
    $upBatch    = "if {q}==`"`" ($upInner) else (echo up)"
    $clickBatch = "if not {q}==`"`" (echo ignore) else ($(New-PosBind -Positions $seps -Action 'down' -Default 'ignore'))"
    $dblBatch   = "if not {q}==`"`" (echo accept) else ($(New-PosBind -Positions $seps -Action 'down' -Default 'accept'))"

    # Tab toggle projets <-> vaults (uniquement si les DEUX sections existent).
    # IMPORTANT : calcule AVANT $ctrlGBatch, qui fige $hdrFull dans sa chaine batch.
    $tabBatch = $null
    $hdrMin  = 'Ctrl+G  help'
    $hdrFull = 'Up/Down move - Enter open - Ctrl+N new - Ctrl+R rename - Ctrl+X kill - Ctrl+G hide'
    if ($projects.Count -and $vaults.Count) {
        $tabBatch = "if not {q}==`"`" (echo ignore) else (if %FZF_POS% LSS $vfirst (echo pos^($vfirst^)) else (echo pos^($pfirst^)))"
        $hdrFull  = 'Up/Down move - Tab switch category - Enter open - Ctrl+N new - Ctrl+R rename - Ctrl+X kill - Ctrl+G hide'
    }

    # Aide toggleable Ctrl+G. ASCII PUR : ces echo passent par cmd (codepage OEM),
    # tout glyphe Unicode y devient du mojibake (piege n°3). L'etat min/full est
    # porte par l'existence d'un fichier temoin.
    $hstate = Join-Path $env:TEMP 'pc-sessionizer-hdr-full'
    Remove-Item $hstate -Force -ErrorAction SilentlyContinue
    $ctrlGBatch = "if exist `"$hstate`" (del `"$hstate`" & echo $hdrMin) else (type nul > `"$hstate`" & echo $hdrFull)"

    $fzfArgs = @(
        '--ansi', '--delimiter', "`t", '--with-nth=3',
        '--layout=reverse', '--no-multi',
        '--color=pointer:8',
        '--prompt', 'pc ❯ ',
        '--header', $hdrMin,
        '--expect=ctrl-n,ctrl-x,ctrl-r',
        '--bind', "load:pos($cursor0)",
        '--bind', "down:transform:$downBatch",
        '--bind', "up:transform:$upBatch",
        '--bind', "left-click:transform:$clickBatch",
        '--bind', "double-click:transform:$dblBatch",
        '--bind', "ctrl-g:transform-header:$ctrlGBatch"
    )
    if ($tabBatch) {
        $fzfArgs += @('--bind', "tab:transform:$tabBatch")
    }

    $out = @($menu | & fzf @fzfArgs)
    if ($LASTEXITCODE -ne 0 -and $out.Count -eq 0) { exit 0 }   # Esc / Ctrl-C (130) = annulation propre
    $key    = if ($out.Count -ge 1) { $out[0] } else { '' }
    $choice = if ($out.Count -ge 2) { $out[1] } else { '' }
}

# --- Meta-actions (--expect) sur une session ACTIVE : ^X kill, ^R rename ----------
# Parite .sh : kill != delete (une session projet/vault killee reste listee ○ ;
# une session jetable disparait). Rename d'une session detachee : impossible en
# CLI zellij -> no-op documente. Apres l'action on REOUVRE le menu (recursion).
function Restart-Menu {
    if ($DryRun -or $Pick) { exit 0 }   # pas de boucle en mode test
    & $PSCommandPath -View $View
    exit $LASTEXITCODE
}

if ($key -eq 'ctrl-x') {
    if ($choice) {
        $f = $choice -split "`t"
        if ($f[0] -eq 'active') {
            $name = $f[1]
            if (($projects -contains $name) -or ($vaults -contains $name)) {
                [Console]::Error.Write("Kill '$name'? Stays listed as o inactive. [y/N] ")
            } else {
                [Console]::Error.Write("Kill '$name'? Disposable - disappears from the list. [y/N] ")
            }
            $ans = Read-OrCancel
            if ($ans -match '^[yY]') {
                Invoke-Step @('zellij', 'kill-session', $name)
            }
        }
    }
    Restart-Menu
}
if ($key -eq 'ctrl-r') {
    if ($choice) {
        $f = $choice -split "`t"
        if ($f[0] -eq 'active') {
            [Console]::Error.Write("New name for '$($f[1])': ")
            $ans = Read-OrCancel
            if ($ans) {
                [Console]::Error.WriteLine('(rename via the menu is not supported with Zellij yet - skipped)')
            }
        }
    }
    Restart-Menu
}

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

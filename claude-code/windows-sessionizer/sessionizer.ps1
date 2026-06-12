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
# Sessions zellij actives, deux sources vivantes :
#   1. zellij ls -ns              : sessions joignables depuis cette logon session
#   2. zellij.exe --server <path> : sessions d'autres logon sessions (tel/web)
# Ne pas relire les dossiers IPC/cache directement : ils survivent au reboot et
# produisent de faux "active - tel/web" alors que le serveur n'existe plus.
$JoinableSessions = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
function Get-ZellijServerSessions {
    $names = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    Get-CimInstance Win32_Process -Filter "Name = 'zellij.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '(?i)(^|\s)--server\s+' } |
        ForEach-Object {
            $serverPath = $null
            if ($_.CommandLine -match '(?i)--server\s+"([^"]+)"') {
                $serverPath = $Matches[1]
            } elseif ($_.CommandLine -match '(?i)--server\s+(\S+)') {
                $serverPath = $Matches[1]
            }
            if ($serverPath) {
                $name = Split-Path -Leaf $serverPath
                if ($name -and $name -ne 'web_server_bus') { [void]$names.Add($name) }
            }
        }
    return @($names)
}

# Source 3 (vecu 2026-06-12) : named pipes Windows. Un serveur zellij d'une autre
# logon session (tel/SSH = session 0) peut etre invisible des DEUX sources ci-dessus
# (CommandLine WMI protege + marqueur disque absent de contract_version_1), mais son
# pipe nomme \\.\pipe\<TEMP>\zellij\contract_version_1\<name> reste visible globalement.
# Sans cette source, le menu affiche la session comme inactive (o), `attach -c` tente
# de la CREER, collisionne avec le pipe cross-logon et FIGE le client apres le rendu.
function Get-ZellijPipeSessions {
    $names = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $prefix = Join-Path $env:TEMP 'zellij\contract_version_1\'
    $pipes = try { [System.IO.Directory]::GetFiles('\\.\pipe\') } catch { @() }
    foreach ($p in $pipes) {
        $rel = $p -replace '^\\\\\.\\pipe\\', ''
        if ($rel.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $name = Split-Path -Leaf $rel
            if ($name -and $name -notlike '*-reply' -and $name -ne 'web_server_bus') {
                [void]$names.Add($name)
            }
        }
    }
    return @($names)
}

function Get-ActiveSessions {
    foreach ($l in (& zellij ls -ns 2>$null)) {
        if ($l -and $l.Trim()) { [void]$JoinableSessions.Add($l.Trim()) }
    }
    $names = [System.Collections.Generic.SortedSet[string]]::new($JoinableSessions, [StringComparer]::Ordinal)
    foreach ($s in Get-ZellijServerSessions) { [void]$names.Add($s) }
    foreach ($s in Get-ZellijPipeSessions)   { [void]$names.Add($s) }
    # Fallback : zellij ls connait aussi les sessions d'autres logon sessions (cache IPC).
    # Get-ZellijServerSessions peut rater un processus dont le CommandLine WMI est
    # protege (ex: session SSH depuis le telephone). Risque : sessions fantomes post-reboot.
    # zellij ls colore sa sortie meme hors TTY : strip ANSI sinon le nom pollue
    # (\e[32;1mfoo\e[0m) cree un DOUBLON du nom propre venant de ls -ns.
    foreach ($l in (& zellij ls 2>$null)) {
        if ($l -and $l.Trim()) {
            $l = $l -replace "$([char]27)\[[0-9;]*m", ''
            $firstToken = ($l.Trim() -split '\s+')[0]
            if ($firstToken -and $firstToken -ne 'web_server_bus') { [void]$names.Add($firstToken) }
        }
    }
    return @($names | Where-Object { $_ -ne 'web_server_bus' })
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
    'dev'    { $vaults = @();   $actives = @(Get-ActiveSessions | Where-Object { $projects -contains $_ }) }
    'vaults' { $projects = @(); $actives = @(Get-ActiveSessions | Where-Object { $vaults -contains $_ }) }
    default  {                  $actives = Get-ActiveSessions }
}

# Orphelins = sessions actives qui ne sont NI un projet NI un vault (creees via Ctrl-N).
$orphans = @($actives | Where-Object { ($projects -notcontains $_) -and ($vaults -notcontains $_) })

# --- Menu (TSV: type <TAB> name <TAB> label affiche) ----------------------------
# type 'sep' = titre decoratif : les fleches le sautent (binds Task 4), un clic
# dessus rouvre le menu -> non selectionnable. Parite build_menu du .sh.
$e = [char]27
$G = "$e[32m"; $D = "$e[90m"; $R = "$e[0m"; $M = "$e[38;5;141m"   # M = violet (vaults)
$Y = "$e[33m"                                                     # Y = jaune (tel/web)
$T = [char]9

# Ligne menu d'une session active : verte si joignable d'ici, jaune + suffixe
# "(tel/web)" si elle vit dans une autre logon session (attach impossible).
function Get-ActiveLine {
    param([string]$Name)
    if ($JoinableSessions.Contains($Name)) {
        return "active$T$Name$T$G●$R $Name  $G(active)$R"
    }
    return "active$T$Name$T$Y●$R $Name  $Y(active - tel/web)$R"
}

function Build-Menu {
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($orphans.Count) {
        $lines.Add("sep$T$T$D──────  $R◆ Sessions$D  ──────$R")
        foreach ($s in $orphans) {
            $lines.Add((Get-ActiveLine $s))
        }
    }
    if ($projects.Count) {
        $lines.Add("sep$T$T$D──────  $R◆ Projects$D  ──────$R")
        foreach ($p in $projects) {
            if ($actives -contains $p) {
                $lines.Add((Get-ActiveLine $p))
            } else {
                $lines.Add("project$T$p$T$D○$R $p")
            }
        }
    }
    if ($vaults.Count) {
        $lines.Add("sep$T$T$D──────  $M◆ Obsidian Vaults$D  ──────$R")
        foreach ($v in $vaults) {
            if ($actives -contains $v) {
                $lines.Add((Get-ActiveLine $v))
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

# PIEGE (vecu 2026-06-12) : `& $cmd @(pipeline)` ne splatte PAS -- l'expression
# inline passe le tableau comme UN argument (Object[] -> -Path de Set-Location
# explose). Le splatting n'opere que sur une VARIABLE (@rest).
function Invoke-Step {   # commande de SETUP (equivalent step() du .sh)
    param([string[]]$Argv)
    if ($DryRun) { Write-Output ("DRYRUN: " + ($Argv -join ' ')); return }
    $cmd  = $Argv[0]
    $rest = @($Argv | Select-Object -Skip 1)
    if ($rest.Count) { & $cmd @rest } else { & $cmd }
}

function Invoke-Run {    # commande FINALE (equivalent run()/exec du .sh)
    param([string[]]$Argv)
    if ($DryRun) { Write-Output ("DRYRUN: " + ($Argv -join ' ')); exit 0 }
    $cmd  = $Argv[0]
    $rest = @($Argv | Select-Object -Skip 1)
    if ($rest.Count) { & $cmd @rest } else { & $cmd }
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

# Rejoint une session ACTIVE. GARDE anti-panic (vecu 2026-06-12) : une session
# d'une autre logon session (tel/web) est INJOIGNABLE d'ici -- l'attach faisait
# paniquer le serveur zellij ("Acces refuse" sur le pipe nomme) et `attach -c`
# creait un doublon du meme nom. Message clair + retour menu a la place.
function Join-ActiveSession {
    param([string]$Name)
    if (-not $JoinableSessions.Contains($Name)) {
        [Console]::Error.WriteLine("'$Name' est ouverte dans une AUTRE logon session Windows (tel/web).")
        [Console]::Error.WriteLine("Attach impossible depuis ce terminal. Options : la fermer depuis le tel,")
        [Console]::Error.WriteLine("ou Ctrl+X dessus pour tenter un kill (best effort).")
        [Console]::Error.Write('Appuie sur une touche pour revenir au menu...')
        try { [void][Console]::ReadKey($true) } catch {}
        [Console]::Error.WriteLine()
        Restart-Menu
    }
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

    # Habillage : bordure arrondie + label, compteur masque (bruit), couleurs
    # accordees au theme (violet 141 = vaults/accents, vert 108 = sessions
    # actives, gris 240/245 = chrome). gutter:-1 = pas de colonne fantome.
    $fzfArgs = @(
        '--ansi', '--delimiter', "`t", '--with-nth=3',
        '--layout=reverse', '--no-multi',
        '--border=rounded', '--border-label', ' ◆ Sessionizer ', '--border-label-pos=3',
        '--padding=0,1', '--info=hidden', '--ellipsis=…',
        '--color=pointer:141,bg+:237,fg+:255,hl:141,hl+:141,header:245,prompt:108,border:240,label:141,gutter:-1',
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
            if (-not $JoinableSessions.Contains($name)) {
                [Console]::Error.Write("Kill '$name'? Session tel/web (autre logon session) - le kill peut echouer d'ici. [y/N] ")
            } elseif (($projects -contains $name) -or ($vaults -contains $name)) {
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

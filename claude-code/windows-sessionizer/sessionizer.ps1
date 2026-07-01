# sessionizer.ps1 -- menu fzf natif Windows : sessions zellij / projets C:\dev / vaults Obsidian.
# Menu principal : sessions zellij / projets C:\dev / vaults Obsidian.
# Lance par : (a) Invoke-Sessionizer (handler PSReadLine F2 du profil pwsh, terminal courant),
#             (b) keybind F2 de la config zellij Windows (pane flottant -> ouvre via wt.exe).
#
# Hooks de test (parite .sh) :
#   -List           : imprime le menu genere (TSV colore) puis sort
#   -Pick "t`tt`tn`tl" : bypass fzf avec un choix force (type<TAB>name<TAB>label)
#   -Key  ctrl-n    : simule une touche --expect (avec -Pick)
#   -DryRun         : imprime les commandes au lieu de les executer
#   -View all|dev|vaults : perimetre (defaut all)
#   -Shape "texte"  : imprime le pre-shaping arabe du texte puis sort
#                     (teste par test-arabic-display.ps1)
#   -FakeActives "a;b" : hook de TEST -- court-circuite la detection live de
#                     zellij (Get-ActiveSessions) avec une liste forcee de noms
#                     de session joignables. Permet de tester la reconciliation
#                     pre-shape <-> brut sans session zellij reelle.
param(
    [switch]$List,
    [string]$Pick = '',
    [string]$Key = '',
    [switch]$DryRun,
    [ValidateSet('all','dev','vaults')][string]$View = 'all',
    [string]$Shape = '',
    [string]$FakeActives = ''
)

$ErrorActionPreference = 'Stop'

# UTF-8 de bout en bout : lance en -NoProfile, on ne peut PAS compter sur le profil.
# Sans ca, le vault arabe (C:\obsidian-vaults\<nom arabe>) casse dans les pipes fzf.
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

# --- Pre-shaping arabe pour terminaux sans BiDi ---------------------------------
# Windows Terminal (microsoft/terminal#538), Termux (termux-app#2953) et xterm.js
# (zellij web) n'appliquent NI l'algorithme bidirectionnel Unicode NI le shaping
# contextuel complet : ils posent les codepoints dans l'ordre logique, gauche a
# droite -> un nom arabe sort inverse ET deconnecte (illisible). La police n'y
# change rien (Noto Naskh Arabic est deja en fallback dans wt-settings.json).
# Parade standard (equivalent du mode terminal de fribidi) : convertir les runs
# arabes du LABEL AFFICHE en formes de presentation Unicode (U+FExx, glyphes
# contextuels figes) posees en ORDRE VISUEL (inverse). Chaque cellule recoit
# alors le bon glyphe, l'oeil lit de droite a gauche un mot correct, et le
# rendu utilise la police naskh du fallback (WT) ou du systeme (Android).
# Le NOM technique (champ 2 du TSV : chemins, noms de session zellij) reste
# l'original -- seul le label (champ 3, --with-nth=3) est transforme.
# Limites assumees : la recherche fzf matche le label transforme (taper de
# l'arabe dans un terminal sans BiDi est de toute facon deja casse) ; noms
# mixtes arabe+latin traites run par run (pas d'UBA complet).
#
# Table : codepoint -> @(isolated, final, initial, medial), 0 = forme absente.
# Lettres right-joining : isolated+final seules ; hamza : isolated seule ;
# tatweel U+0640 : dual, inchange dans toutes les formes.
$script:ArForms = @{
    0x0621 = 0xFE80,0,0,0;                0x0622 = 0xFE81,0xFE82,0,0
    0x0623 = 0xFE83,0xFE84,0,0;           0x0624 = 0xFE85,0xFE86,0,0
    0x0625 = 0xFE87,0xFE88,0,0;           0x0626 = 0xFE89,0xFE8A,0xFE8B,0xFE8C
    0x0627 = 0xFE8D,0xFE8E,0,0;           0x0628 = 0xFE8F,0xFE90,0xFE91,0xFE92
    0x0629 = 0xFE93,0xFE94,0,0;           0x062A = 0xFE95,0xFE96,0xFE97,0xFE98
    0x062B = 0xFE99,0xFE9A,0xFE9B,0xFE9C; 0x062C = 0xFE9D,0xFE9E,0xFE9F,0xFEA0
    0x062D = 0xFEA1,0xFEA2,0xFEA3,0xFEA4; 0x062E = 0xFEA5,0xFEA6,0xFEA7,0xFEA8
    0x062F = 0xFEA9,0xFEAA,0,0;           0x0630 = 0xFEAB,0xFEAC,0,0
    0x0631 = 0xFEAD,0xFEAE,0,0;           0x0632 = 0xFEAF,0xFEB0,0,0
    0x0633 = 0xFEB1,0xFEB2,0xFEB3,0xFEB4; 0x0634 = 0xFEB5,0xFEB6,0xFEB7,0xFEB8
    0x0635 = 0xFEB9,0xFEBA,0xFEBB,0xFEBC; 0x0636 = 0xFEBD,0xFEBE,0xFEBF,0xFEC0
    0x0637 = 0xFEC1,0xFEC2,0xFEC3,0xFEC4; 0x0638 = 0xFEC5,0xFEC6,0xFEC7,0xFEC8
    0x0639 = 0xFEC9,0xFECA,0xFECB,0xFECC; 0x063A = 0xFECD,0xFECE,0xFECF,0xFED0
    0x0640 = 0x0640,0x0640,0x0640,0x0640; 0x0641 = 0xFED1,0xFED2,0xFED3,0xFED4
    0x0642 = 0xFED5,0xFED6,0xFED7,0xFED8; 0x0643 = 0xFED9,0xFEDA,0xFEDB,0xFEDC
    0x0644 = 0xFEDD,0xFEDE,0xFEDF,0xFEE0; 0x0645 = 0xFEE1,0xFEE2,0xFEE3,0xFEE4
    0x0646 = 0xFEE5,0xFEE6,0xFEE7,0xFEE8; 0x0647 = 0xFEE9,0xFEEA,0xFEEB,0xFEEC
    0x0648 = 0xFEED,0xFEEE,0,0;           0x0649 = 0xFEEF,0xFEF0,0,0
    0x064A = 0xFEF1,0xFEF2,0xFEF3,0xFEF4
}
# Ligatures lam-alef OBLIGATOIRES (lam + alef variantes) : forme isolee ;
# forme finale = isolee + 1 dans le bloc U+FEF5-U+FEFC.
$script:ArLamAlef = @{ 0x0622 = 0xFEF5; 0x0623 = 0xFEF7; 0x0625 = 0xFEF9; 0x0627 = 0xFEFB }

# Diacritique combinant (harakat etc.) : transparent pour la liaison, et reste
# attache a sa lettre de base lors de l'inversion (cluster indivisible).
function Test-ArDiacritic([int]$Cp) {
    ($Cp -ge 0x064B -and $Cp -le 0x065F) -or $Cp -eq 0x0670
}

function ConvertTo-ArabicDisplay {
    param([string]$Text)
    # Fast path : aucune lettre arabe shapeable -> retour direct (labels
    # latins, et idempotence : les U+FExx deja convertis ne rematchent pas).
    # \uXXXX est interprete par le moteur regex .NET : le script reste ASCII.
    if ($Text -notmatch '[\u0621-\u064A]') { return $Text }

    $out = [System.Text.StringBuilder]::new($Text.Length)
    $n = $Text.Length
    $i = 0
    while ($i -lt $n) {
        $cp = [int]$Text[$i]
        if (-not ($script:ArForms.ContainsKey($cp) -or (Test-ArDiacritic $cp))) {
            [void]$out.Append($Text[$i]); $i++; continue
        }

        # Collecte du run arabe en clusters { Base ; Marks } : une lettre et ses
        # diacritiques suiveurs. Un diacritique orphelin (debut de run) forme un
        # cluster sans base. Tout autre caractere (chiffres arabes-indiens
        # U+0660-0669 inclus : lecture LTR) termine le run et reste en place.
        $clusters = [System.Collections.Generic.List[hashtable]]::new()
        while ($i -lt $n) {
            $cp = [int]$Text[$i]
            if ($script:ArForms.ContainsKey($cp)) {
                $clusters.Add(@{ Base = $cp; Marks = [System.Collections.Generic.List[int]]::new() })
            } elseif (Test-ArDiacritic $cp) {
                if ($clusters.Count) { $clusters[$clusters.Count - 1].Marks.Add($cp) }
                else {
                    $m = [System.Collections.Generic.List[int]]::new(); $m.Add($cp)
                    $clusters.Add(@{ Base = 0; Marks = $m })
                }
            } else { break }
            $i++
        }

        # Liaison entre bases adjacentes : pair(P, L) = P possede une forme
        # initiale (dual-joining) ET L une forme finale. Les clusters sans base
        # (diacritique orphelin) ne se lient pas.
        $count = $clusters.Count
        $linksPrev = [bool[]]::new($count)
        for ($k = 1; $k -lt $count; $k++) {
            $p = $clusters[$k - 1].Base; $b = $clusters[$k].Base
            $linksPrev[$k] = $p -and $b -and $script:ArForms[$p][2] -and $script:ArForms[$b][1]
        }

        # Emission en ordre logique : forme contextuelle par cluster, ligatures
        # lam-alef fusionnees (les diacritiques des deux lettres suivent la
        # ligature). Puis inversion de l'ordre des clusters = ordre visuel.
        $visual = [System.Collections.Generic.List[string]]::new()
        for ($k = 0; $k -lt $count; $k++) {
            $b = $clusters[$k].Base
            $piece = [System.Text.StringBuilder]::new(4)
            if ($b -eq 0x0644 -and ($k + 1) -lt $count -and $script:ArLamAlef.ContainsKey($clusters[$k + 1].Base)) {
                $lig = $script:ArLamAlef[$clusters[$k + 1].Base]
                if ($linksPrev[$k]) { $lig++ }   # forme finale de la ligature
                [void]$piece.Append([char]$lig)
                foreach ($m in $clusters[$k].Marks)     { [void]$piece.Append([char]$m) }
                foreach ($m in $clusters[$k + 1].Marks) { [void]$piece.Append([char]$m) }
                $k++
            } elseif ($b) {
                $f = $script:ArForms[$b]
                $linkN = ($k + 1) -lt $count -and $f[2] -and $clusters[$k + 1].Base -and $script:ArForms[$clusters[$k + 1].Base][1]
                $form = if ($linksPrev[$k] -and $linkN) { $f[3] }
                        elseif ($linksPrev[$k])         { $f[1] }
                        elseif ($linkN)                 { $f[2] }
                        else                            { $f[0] }
                [void]$piece.Append([char]$form)
                foreach ($m in $clusters[$k].Marks) { [void]$piece.Append([char]$m) }
            } else {
                foreach ($m in $clusters[$k].Marks) { [void]$piece.Append([char]$m) }
            }
            $visual.Add($piece.ToString())
        }
        $visual.Reverse()
        foreach ($piece in $visual) { [void]$out.Append($piece) }
    }
    return $out.ToString()
}

if ($Shape) { Write-Output (ConvertTo-ArabicDisplay $Shape); exit 0 }

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
            # Enfants DIRECTS uniquement : les pipes internes du web server vivent
            # en sous-dossier (web_server_bus\<id>) et ne sont pas des sessions.
            $name = $rel.Substring($prefix.Length)
            if ($name.Contains('\')) { continue }
            if ($name -and $name -notlike '*-reply' -and $name -ne 'web_server_bus') {
                [void]$names.Add($name)
            }
        }
    }
    return @($names)
}

function Get-ActiveSessions {
    # Hook de test : liste forcee, toutes joignables, sans appeler zellij.
    if ($FakeActives) {
        $forced = @($FakeActives -split ';' | Where-Object { $_ })
        foreach ($n in $forced) { [void]$JoinableSessions.Add($n) }
        return $forced
    }
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

# --- Reconciliation nom-de-session zellij <-> nom de dossier --------------------
# Les sessions de vaults arabes sont nommees en forme PRE-SHAPEE (U+FExx) pour
# que zellij les affiche correctement partout sans BiDi : label "Zellij (nom)"
# de la tab-bar, nom de tab, titre d'onglet WT, et sortie de `zellij ls`. Le
# dossier sur disque, lui, garde son nom arabe BRUT (cle technique, auto-cd).
# ConvertTo-ArabicDisplay est l'IDENTITE sur l'ASCII : projets et vaults latins
# ne sont pas affectes. On ne deshape JAMAIS (transform inverse fragile) : on
# compare toujours en avant via cette map pre-shape -> brut.
$ShapedToRaw = @{}
foreach ($n in (@($projects) + @($vaults))) { $ShapedToRaw[(ConvertTo-ArabicDisplay $n)] = $n }

# Nom de dossier brut (cle de matching / dir) pour un nom de session zellij reel.
function Get-CanonicalName([string]$Actual) {
    if ($ShapedToRaw.ContainsKey($Actual)) { return $ShapedToRaw[$Actual] }
    return $Actual
}

switch ($View) {
    'dev'    { $vaults = @();   $actives = @(Get-ActiveSessions | Where-Object { $projects -contains (Get-CanonicalName $_) }) }
    'vaults' { $projects = @(); $actives = @(Get-ActiveSessions | Where-Object { $vaults   -contains (Get-CanonicalName $_) }) }
    default  {                  $actives = @(Get-ActiveSessions) }
}

# Vue canonique (noms de dossier bruts) pour les tests d'appartenance ; $actives
# garde les noms REELS de session zellij (pour attach/kill et l'affichage des
# orphelins).
$activesCanon = @($actives | ForEach-Object { Get-CanonicalName $_ })

# Nom de session zellij REEL pour un dossier $Raw : la forme pre-shapee si une
# telle session tourne deja, sinon le nom brut (session legacy brute, ASCII, ou
# session a CREER -- celles-ci sont creees pre-shapees par les actions plus bas).
# Evite de creer un DOUBLON quand une session legacy brute existe encore.
function Get-ActualName([string]$Raw) {
    $shaped = ConvertTo-ArabicDisplay $Raw
    if ($actives -contains $shaped) { return $shaped }
    return $Raw
}

# Orphelins = sessions actives qui ne sont NI un projet NI un vault (creees via Ctrl-N).
# Comparaison sur le nom CANONIQUE : une session de vault arabe pre-shapee se
# resout vers son dossier brut connu -> ce n'est donc PAS un orphelin.
$orphans = @($actives | Where-Object { ($projects -notcontains (Get-CanonicalName $_)) -and ($vaults -notcontains (Get-CanonicalName $_)) })

# --- Menu (TSV: type <TAB> name <TAB> label affiche) ----------------------------
# type 'sep' = titre decoratif : les fleches le sautent (binds Task 4), un clic
# dessus rouvre le menu -> non selectionnable. Parite build_menu du .sh.
$e = [char]27
$G = "$e[32m"; $D = "$e[90m"; $R = "$e[0m"; $M = "$e[38;5;141m"   # M = violet (vaults)
$Y = "$e[33m"                                                     # Y = jaune (tel/web)
$F = "$e[38;2;249;226;175m"                                      # F = folder yellow (projects)
$T = [char]9
$BulletOn  = [char]0x25CF
$BulletOff = [char]0x25CB
$Diamond   = [char]0x25C6
$Rule      = ([string][char]0x2500) * 6
$TreeLine  = [char]0x258C
$ItemPrefix = "$TreeLine "

# Ligne menu d'une session active : verte si joignable d'ici, jaune + suffixe
# "(tel/web)" si elle vit dans une autre logon session (attach impossible).
# Champ 2 = nom BRUT (identifiant zellij/chemin), label = pre-shaping arabe.
function Get-ActiveLine {
    param([string]$Name)
    $disp = ConvertTo-ArabicDisplay $Name
    if ($JoinableSessions.Contains($Name)) {
        return "active$T$Name$T$ItemPrefix$G$BulletOn$R $disp  $G(active)$R$T$Name"
    }
    return "active$T$Name$T$ItemPrefix$G$BulletOn$R $disp  $Y(active - tel/web)$R$T$Name"
}

function Build-Menu {
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($orphans.Count) {
        $lines.Add("sep${T}__sep_sessions$T$D$Rule  $R$Diamond Sessions$D  $Rule$R")
        foreach ($s in $orphans) {
            $lines.Add((Get-ActiveLine $s))
        }
    }
    if ($projects.Count) {
        $lines.Add("sep${T}__gap_projects${T}${T}")
        $lines.Add("sep${T}__sep_projects$T$D$Rule  $F$Diamond Projects$D  $Rule$R$T")
        foreach ($p in $projects) {
            if ($activesCanon -contains $p) {
                $lines.Add((Get-ActiveLine (Get-ActualName $p)))
            } else {
                $lines.Add("project$T$p$T$ItemPrefix$BulletOff $(ConvertTo-ArabicDisplay $p)$T$p")
            }
        }
    }
    if ($vaults.Count) {
        $lines.Add("sep${T}__sep_vaults$T$D$Rule  $M$Diamond Obsidian Vaults$D  $Rule$R$T")
        foreach ($v in $vaults) {
            if ($activesCanon -contains $v) {
                $lines.Add((Get-ActiveLine (Get-ActualName $v)))
            } else {
                $lines.Add("vault$T$v$T$ItemPrefix$BulletOff $(ConvertTo-ArabicDisplay $v)$T$v")
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
# vaults et projets suivent le MEME chemin natif (uniforme).
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

# Attache (ou cree) la session $Name avec $Dir pour cwd. $Name est le nom zellij
# FINAL : forme pre-shapee pour un vault arabe a creer, ou nom REEL d'une session
# active (Get-ActualName). $Dir reste le chemin BRUT du dossier sur disque.
function Open-Session {
    param([string]$Name, [string]$Dir)
    # --web-sharing on : OBLIGATOIRE pour que le telephone puisse attacher cette
    # session via le web server zellij. Defaut zellij = "off" -> une session creee
    # par F2 sans ce flag n'est PAS partagee au web server, et un attach web depuis
    # le tel sort aussitot ("Bye from Zellij") -- vecu 2026-06-14. Les sessions
    # creees DEPUIS le tel naissent deja partagees (via le web server), d'ou
    # l'asymetrie. Le web server reste local (127.0.0.1 + token) : pas d'exposition.
    if ($InZellij) {
        # -w 0 : fenetre WT existante ; nt : new tab ; -p : profil (titre/icone) ;
        # -d : repertoire de depart. La session zellij vit dans l'onglet.
        Invoke-Run @('wt.exe', '-w', '0', 'nt', '-p', 'PowerShell', '-d', $Dir,
                     'pwsh', '-NoProfile', '-NoExit', '-Command',
                     "zellij attach -c $Name options --on-force-close detach --web-sharing on")
    } else {
        if ($Dir -and (Test-Path $Dir)) { Invoke-Step @('Set-Location', $Dir) }
        Invoke-Run @('zellij', 'attach', '-c', $Name, 'options', '--on-force-close', 'detach', '--web-sharing', 'on')
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
    # $Name est le nom REEL de session (pre-shape pour un vault arabe) : on le
    # ramene au nom de dossier brut pour resoudre le cwd.
    $canon = Get-CanonicalName $Name
    $dir = if ($vaults -contains $canon) { Join-Path $VaultsDir $canon }
           elseif ($projects -contains $canon) { Join-Path $DevDir $canon }
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

# Confirmation a une touche : Enter -> $true (confirme). Tout le reste (Esc
# compris) -> $false (annule). Remplace l'ancien "[y/N]" + ligne complete :
# une seule touche suffit, marche pareil sur pwsh natif et sur pwsh via SSH
# depuis Termux (meme lecteur [Console]::ReadKey).
function Read-KillConfirm {
    try { $key = [Console]::ReadKey($true) } catch { return $false }
    [Console]::Error.WriteLine()
    return $key.Key -eq 'Enter'
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

    # Positions 1-based (layout reverse, liste NON filtree) des lignes non
    # selectionnables, pour les binds de navigation. Parite .sh, MAIS : fzf Windows
    # execute les transform via `cmd /s/c` -> pas d'arithmetique runtime possible
    # en batch one-liner (pas de delayed expansion). On PRE-CALCULE donc tout
    # depuis le TSV reel pour supporter les gaps decoratifs avant les titres.
    $seps = [System.Collections.Generic.List[int]]::new()
    $cursor0 = 1
    $cursorFound = $false
    $psep = 0; $vsep = 0; $pfirst = 0; $vfirst = 0
    for ($idx = 0; $idx -lt $menu.Count; $idx++) {
        $fields = $menu[$idx] -split "`t", 3
        $pos1 = $idx + 1
        if ($fields[0] -eq 'sep') {
            $seps.Add($pos1)
            if ($fields.Count -ge 2 -and $fields[1] -eq '__sep_projects') { $psep = $pos1 }
            if ($fields.Count -ge 2 -and $fields[1] -eq '__sep_vaults')   { $vsep = $pos1 }
        } elseif (-not $cursorFound) {
            $cursor0 = $pos1
            $cursorFound = $true
        }
    }
    function Get-FirstSelectableAfter {
        param([int]$After)
        if (-not $After) { return 0 }
        for ($idx = $After; $idx -lt $menu.Count; $idx++) {
            $fields = $menu[$idx] -split "`t", 2
            if ($fields[0] -ne 'sep') { return ($idx + 1) }
        }
        return 0
    }
    $pfirst = Get-FirstSelectableAfter $psep
    $vfirst = Get-FirstSelectableAfter $vsep

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
    function New-RepeatAction {
        param([string]$Action, [int]$Count)
        if ($Count -le 0) { return 'ignore' }
        return (@($Action) * $Count) -join '+'
    }
    function New-SkipDownBind {
        $expr = 'echo down'
        for ($pos1 = $menu.Count; $pos1 -ge 1; $pos1--) {
            $target = $pos1 + 1
            while ($seps -contains $target) { $target++ }
            if ($target -ne ($pos1 + 1) -and $target -le $menu.Count) {
                $action = New-RepeatAction 'down' ($target - $pos1)
                $expr = "if `"%FZF_POS%`"==`"$pos1`" (echo $action) else ($expr)"
            }
        }
        return $expr
    }
    function New-SkipUpBind {
        $expr = 'echo up'
        for ($pos1 = 1; $pos1 -le $menu.Count; $pos1++) {
            $target = $pos1 - 1
            while ($seps -contains $target) { $target-- }
            if ($target -ne ($pos1 - 1)) {
                if ($target -lt 1) { $action = 'ignore' }
                else { $action = New-RepeatAction 'up' ($pos1 - $target) }
                $expr = "if `"%FZF_POS%`"==`"$pos1`" (echo $action) else ($expr)"
            }
        }
        return $expr
    }

    # Garde "filtre tape" : {q} est substitue PAR FZF avec quotes (query vide -> "").
    # Une fois filtree, les positions absolues ne veulent plus rien dire -> action de base.
    $downBatch  = "if {q}==`"`" ($(New-SkipDownBind)) else (echo down)"
    $upInner = New-SkipUpBind
    $upBatch    = "if {q}==`"`" ($upInner) else (echo up)"
    # Les titres restent visibles pendant le filtre, donc on les ejecte aussi via
    # le type TSV courant ({1}) quand les positions absolues ne sont plus fiables.
    # PIEGE (vecu 2026-06-13) : fzf quote DEJA les placeholders de champ -> {1}
    # devient "sep" (avec guillemets). Les entourer a la main ("{1}") produit
    # ""sep"" qui, sous le wrapper `cmd /s/c "..."` de fzf, casse le if et ne
    # renvoie RIEN -> transform sans action -> Enter/clic morts. Les binds {q}
    # (down/up) marchent justement parce qu'ils n'ajoutent pas de guillemets.
    # Donc {1} NU, jamais "{1}".
    $enterBatch = 'if {1}=="sep" (echo down) else (echo accept)'
    $clickBatch = 'if {1}=="sep" (echo down) else (echo ignore)'
    $dblBatch   = $enterBatch

    # Tab toggle projets <-> vaults (uniquement si les DEUX sections existent).
    # Header complet, TOUJOURS affiche : pas de toggle Ctrl+G (le gap entre
    # sections aere deja l'affichage, masquer l'aide n'apportait rien).
    $tabBatch = $null
    $hdr = 'Up/Down move - Enter open - Ctrl+F search - Ctrl+N new - Ctrl+R rename - Ctrl+X kill'
    if ($projects.Count -and $vaults.Count) {
        $tabBatch = "if not {q}==`"`" (echo ignore) else (if %FZF_POS% LSS $vfirst (echo pos^($vfirst^)) else (echo pos^($pfirst^)))"
        $hdr  = 'Up/Down move - Tab switch category - Enter open - Ctrl+F search - Ctrl+N new - Ctrl+R rename - Ctrl+X kill'
    }

    $rowsPath = Join-Path $env:TEMP ("pc-sessionizer-rows-{0}.tsv" -f ([guid]::NewGuid().ToString('N')))
    $filterPath = Join-Path $env:TEMP ("pc-sessionizer-filter-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    $menu | Set-Content -LiteralPath $rowsPath -Encoding utf8
    @'
param([string]$RowsPath, [string]$Query = '')
function Test-Fuzzy {
    param([string]$Needle, [string]$Haystack)
    if ([string]::IsNullOrEmpty($Needle)) { return $true }
    if ([string]::IsNullOrEmpty($Haystack)) { return $false }
    $pos = 0
    foreach ($ch in $Needle.ToCharArray()) {
        $found = $false
        while ($pos -lt $Haystack.Length) {
            if ([char]::ToLowerInvariant($Haystack[$pos]) -eq [char]::ToLowerInvariant($ch)) {
                $found = $true
                $pos++
                break
            }
            $pos++
        }
        if (-not $found) { return $false }
    }
    return $true
}
$rows = Get-Content -LiteralPath $RowsPath -Encoding utf8
if ([string]::IsNullOrWhiteSpace($Query)) {
    $rows
    exit 0
}
$terms = @($Query -split '\s+' | Where-Object { $_ })
$matches = [System.Collections.Generic.List[object]]::new()
$rowIndex = 0
foreach ($row in $rows) {
    $rowIndex++
    $fields = $row -split "`t", 4
    if ($fields.Count -lt 4 -or $fields[0] -eq 'sep') { continue }
    $ok = $true
    $exact = $true
    foreach ($term in $terms) {
        if ($fields[3].IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $exact = $false
        }
        if (-not (Test-Fuzzy $term $fields[3])) {
            $ok = $false
            break
        }
    }
    if ($ok) {
        $score = if ($exact) { 0 } else { 1 }
        $matches.Add([pscustomobject]@{ Score = $score; Index = $rowIndex; Line = $row })
    }
}
$matches | Sort-Object Score, Index | ForEach-Object { $_.Line }
'@ | Set-Content -LiteralPath $filterPath -Encoding ascii
    $filterCmd = "pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$filterPath`" `"$rowsPath`" {q}"

    # Input : petite loupe + ghost text "Search..." dans une vraie bordure fzf.
    # Les glyphes sont construits par code Unicode pour garder le fichier .ps1
    # ASCII-only (regle projet).
    $SearchIcon = [char]0x2315
    $fzfPrompt  = "$SearchIcon "
    $fzfGhost   = 'Search...'
    $Ellipsis   = [char]0x2026
    $focusBatch = 'if {1}=="sep" (echo down) else (echo ignore)'

    # Habillage : bordure arrondie + label, compteur masque (bruit), couleurs
    # accordees au theme (bleu #89b4fa = chrome/input, violet 141 reserve aux
    # vaults Obsidian dans les labels de lignes). gutter:-1 = pas de colonne fantome.
    $fzfArgs = @(
        '--ansi', '--delimiter', "`t", '--with-nth=3',
        '--layout=reverse', '--no-multi', '--disabled', '--track', '--id-nth=2',
        '--border=rounded',
        '--input-border=rounded', '--ghost', $fzfGhost,
        '--padding=0,1', '--info=hidden', '--no-scrollbar', '--scrollbar', '',
        '--pointer', '', '--marker', '', '--ellipsis', $Ellipsis,
        '--color=bg:-1,bg+:#202942,current-bg:#202942,selected-bg:#202942,fg:#bac2de,fg+:#89b4fa,current-fg:#89b4fa,selected-fg:#89b4fa,hl:#89b4fa,hl+:#89b4fa,header:#a6adc8,prompt:#a6adc8,query:#cdd6f4,ghost:#a6adc8,border:#6c7086,input-border:#89b4fa,label:#89b4fa,pointer:#89b4fa,gutter:-1',
        '--prompt', $fzfPrompt,
        '--header', $hdr,
        '--expect=ctrl-n,ctrl-x,ctrl-r',
        '--bind', "load:pos($cursor0)",
        # Champ de saisie cache par defaut : il n'y a alors AUCUN curseur d'input
        # a reveler -> ni un spawn cmd (binds transform) ni l'activite souris (mode
        # mouse de WT) ne fait clignoter de curseur. Ctrl+F bascule la recherche.
        '--bind', "start:hide-input",
        '--bind', "ctrl-f:toggle-input",
        '--bind', "change:reload($filterCmd)",
        '--bind', "down:transform:$downBatch",
        '--bind', "up:transform:$upBatch",
        # Molette : meme skip DIRECTIONNEL que les fleches (scroll-up/scroll-down
        # sont des evenements distincts de up/down). Sinon la molette bouge en
        # natif, tombe sur un separateur, et le bind focus (echo down) renvoie
        # toujours vers le bas -> blocage en scroll vers le haut (vecu 2026-06-14).
        '--bind', "scroll-up:transform:$upBatch",
        '--bind', "scroll-down:transform:$downBatch",
        '--bind', "focus:transform:$focusBatch",
        '--bind', "enter:transform:$enterBatch",
        '--bind', "left-click:transform:$clickBatch",
        '--bind', "double-click:transform:$dblBatch"
    )
    if ($tabBatch) {
        $fzfArgs += @('--bind', "tab:transform:$tabBatch")
    }

    $out = @($menu | & fzf @fzfArgs)
    Remove-Item $rowsPath, $filterPath -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0 -and $out.Count -eq 0) { exit 0 }   # Esc / Ctrl-C (130) = annulation propre
    $key    = if ($out.Count -ge 1) { $out[0] } else { '' }
    $choice = if ($out.Count -ge 2) { $out[1] } else { '' }
}

# --- Meta-actions (--expect) sur une session ACTIVE : ^X kill, ^R rename ----------
# Parite .sh : kill != delete (une session projet/vault killee reste listee o ;
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
                [Console]::Error.Write("Kill '$name'? Session tel/web (autre logon session) - le kill peut echouer d'ici. [Enter=kill / Esc=cancel] ")
            } elseif (($projects -contains (Get-CanonicalName $name)) -or ($vaults -contains (Get-CanonicalName $name))) {
                [Console]::Error.Write("Kill '$name'? Stays listed as inactive. [Enter=kill / Esc=cancel] ")
            } else {
                [Console]::Error.Write("Kill '$name'? Disposable - disappears from the list. [Enter=kill / Esc=cancel] ")
            }
            if (Read-KillConfirm) {
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
    'project' { Open-Session -Name (ConvertTo-ArabicDisplay $name) -Dir (Join-Path $DevDir $name) }
    'vault'   { Open-Session -Name (ConvertTo-ArabicDisplay $name) -Dir (Join-Path $VaultsDir $name) }
    'new'     {
        if (-not $name) {
            [Console]::Error.Write('Session name: ')
            $name = Read-OrCancel
            if (-not $name) { if ($DryRun -or $Pick) { exit 0 }; & $PSCommandPath -View $View; exit $LASTEXITCODE }
        }
        $start = Join-Path $DevDir $name
        if (-not (Test-Path $start)) { $start = $HOME }
        # Nom tape par l'utilisateur : pre-shape si arabe (cree la session avec le
        # nom affichable correct). $start garde le nom brut pour le dossier.
        Open-Session -Name (ConvertTo-ArabicDisplay $name) -Dir $start
    }
    default   { Write-Error "unknown choice: $type"; exit 1 }
}

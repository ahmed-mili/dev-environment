# Force the console to UTF-8 so non-ASCII output (Fastfetch icons, Nerd Font
# glyphs, accents in directory names) renders correctly instead of mojibake.
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding           = [System.Text.UTF8Encoding]::new()
$script:PowerShellArgs = @([Environment]::GetCommandLineArgs() | ForEach-Object { $_.ToLowerInvariant() })
$script:RunsCommandOrFile = [bool]($script:PowerShellArgs | Where-Object {
    $_ -in @('-command', '-c', '-encodedcommand', '-e', '-file', '-f', '-noninteractive')
})
$script:HasInteractiveConsole = (-not $script:RunsCommandOrFile) -and (-not [System.Console]::IsInputRedirected) -and (-not [System.Console]::IsOutputRedirected)

function isadmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function dev { Set-Location C:\dev }

# Pre-shaping arabe (terminaux sans BiDi : WT/Zellij). Source canonique partagee
# avec le sessionizer : ~/.local/bin/arabic-shaping.ps1. Expose
# ConvertTo-ArabicDisplay (idempotent, identite sur l'ASCII). Fallback
# pass-through si le module n'est pas (encore) deploye : l'arabe s'affiche brut,
# jamais d'erreur.
$script:ArabicShaping = "$env:USERPROFILE\.local\bin\arabic-shaping.ps1"
if (Test-Path -LiteralPath $script:ArabicShaping) {
    . $script:ArabicShaping
} elseif (-not (Get-Command ConvertTo-ArabicDisplay -ErrorAction SilentlyContinue)) {
    function ConvertTo-ArabicDisplay { param([string]$Text) $Text }
}

# Prompt : pre-shape les runs arabes du chemin AFFICHE (WT sans BiDi -> un dossier
# arabe sortirait inverse/deconnecte). Le repertoire courant REEL garde son nom
# brut (git, Tab-completion, outils intacts) ; seul l'affichage est transforme.
# Format = prompt pwsh par defaut.
function prompt {
    $loc = $executionContext.SessionState.Path.CurrentLocation.Path
    "PS $(ConvertTo-ArabicDisplay $loc)$('>' * ($nestedPromptLevel + 1)) "
}

# Zellij web/direct sessions are created by session name. If the session name
# matches a known Windows project/vault, land in that folder automatically.
# Machine-specific roots can override PC_DEV_DIR / PC_VAULTS_WIN locally.
if ($env:ZELLIJ_SESSION_NAME) {
    # Nom de dossier BRUT (logique) de la session, resolu par l'auto-cd ci-dessous.
    # Sert au titre d'onglet WT (UI Windows = BiDi+shaping comme Explorer -> brut).
    # Defaut = nom de session (ASCII ou legacy deja brut).
    $resolvedRaw = $env:ZELLIJ_SESSION_NAME
    try {
        $devRoot = if ($env:PC_DEV_DIR) { $env:PC_DEV_DIR } else { 'C:\dev' }
        $vaultRoot = if ($env:PC_VAULTS_WIN) { $env:PC_VAULTS_WIN } else { 'C:\obsidian-vaults' }
        $landed = $false
        foreach ($root in @($devRoot, $vaultRoot)) {
            $candidate = Join-Path $root $env:ZELLIJ_SESSION_NAME
            if (Test-Path -LiteralPath $candidate) {
                Set-Location -LiteralPath $candidate
                $landed = $true
                break
            }
        }
        # Session de vault arabe : le nom de session est PRE-SHAPE (U+FExx) et ne
        # correspond pas au nom de dossier brut. On retrouve le dossier dont la
        # forme pre-shapee egale le nom de session (comparaison en avant, jamais
        # de deshaping). Le garde U+FE70-FEFF evite le scan disque pour l'ASCII.
        if (-not $landed -and [bool]($env:ZELLIJ_SESSION_NAME.ToCharArray() | Where-Object { [int]$_ -ge 0xFE70 -and [int]$_ -le 0xFEFF })) {
            foreach ($root in @($devRoot, $vaultRoot)) {
                $hit = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                       Where-Object { (ConvertTo-ArabicDisplay $_.Name) -eq $env:ZELLIJ_SESSION_NAME } |
                       Select-Object -First 1
                if ($hit) { Set-Location -LiteralPath $hit.FullName; $resolvedRaw = $hit.Name; break }
            }
        }
    } catch {}

    # TROIS renderers, trois besoins pour le nom de session arabe :
    #  - label "Zellij (nom)" de la tab-bar : rendu par ZELLIJ (pas de BiDi) ->
    #    nom de session PRE-SHAPE (ordre visuel U+FExx).
    #  - titre d'onglet Windows Terminal : rendu par l'UI de WT (DirectWrite =
    #    BiDi + shaping, comme Explorer) -> nom BRUT (logique). Le pre-shape y
    #    serait re-inverse -> casse (capture du 2026-06-13).
    try {
        $zellijName = $env:ZELLIJ_SESSION_NAME
        $disp = ConvertTo-ArabicDisplay $zellijName
        $isArabic = [bool]($zellijName.ToCharArray() | Where-Object { ([int]$_ -ge 0x0600 -and [int]$_ -le 0x06FF) -or ([int]$_ -ge 0xFE70 -and [int]$_ -le 0xFEFF) })
        if ($isArabic) {
            # Label "Zellij (nom)" : nom de session PRE-SHAPE (visuel). Migration
            # legacy (brut -> pre-shape) si besoin ; no-op si deja pre-shape.
            if ($disp -ne $zellijName) { $null = & zellij action rename-session $disp 2>$null }
            # On NE renomme PAS la tab (la fleche garde "Tab #1", non redondant).
            # Titre d'onglet WT (OSC 0) = nom BRUT : l'UI de WT fait le BiDi+shaping.
            [Console]::Write("$([char]27)]0;$resolvedRaw$([char]7)")
        }
    } catch {}
}

# Zellij web server de secours : la tache planifiee 'zellij-web-server' (install.ps1)
# le lance au logon ; si elle manque ou a crashe, on le relance ici. UNIQUEMENT
# depuis un shell interactif local : un demarrage via ssh (Session 0) recreerait
# des sessions injoignables depuis le bureau (bug du 2026-06-12, session fantome
# dev-environment qui figeait l'attach F2).
if ($script:HasInteractiveConsole -and -not $env:SSH_CONNECTION -and -not $env:SSH_CLIENT) {
    try {
        $zellijExe = Join-Path $env:LOCALAPPDATA 'Zellij\zellij.exe'
        if (Test-Path $zellijExe) {
            # TcpClient direct (~20 ms) : Get-NetTCPConnection charge le module
            # CIM (~1 s) -- inacceptable a chaque ouverture de shell.
            $tcp = [System.Net.Sockets.TcpClient]::new()
            try { $tcp.Connect('127.0.0.1', 8082); $webOnline = $true } catch { $webOnline = $false }
            $tcp.Dispose()
            if (-not $webOnline) {
                Start-Process -FilePath $zellijExe -WindowStyle Hidden `
                    -ArgumentList 'web','--daemonize','--ip','127.0.0.1','--port','8082' | Out-Null
            }
        }
    } catch {}
}

# Invoke-Sessionizer : menu fzf natif (sessions zellij/projets/vaults) ; lie a F2 plus bas.
# Execute comme une vraie commande (Insert+AcceptLine, pas dans le ScriptBlock) pour que
# le TUI long-vivant (zellij attach) recoive le TTY.
# PROPRETE : AcceptLine vient d'imprimer "PS> Invoke-Sessionizer" ; on remonte d'UNE
# ligne et on l'efface AVANT de lancer le menu (curseur colonne 0). A la sortie, le
# prompt suivant s'ecrit a la place de la ligne effacee -> aucune trace, scrollback
# preserve. (L'ancienne version effacait APRES coup : fragile des que le sessionizer
# sortait du texte ou echouait -- c'etait le bug de la ligne residuelle.)
function Invoke-Sessionizer {
    $ESC = [char]27
    [Console]::Write("$ESC[1A$ESC[2K$ESC[G")
    & "$env:USERPROFILE\.local\bin\sessionizer.ps1" -View all
}

# ---- PSReadLine: modern predictions + smart Tab + Catppuccin Mocha colors ----
# - InlineView by default (grey ghost text). F3 toggles to ListView; F2 = sessionizer menu.
# - Tab accepts the inline prediction if one is visible, else MenuComplete.
# - Right Arrow / Ctrl+RightArrow also accept (standard PSReadLine behavior).
# - Syntax-highlight colors aligned with the Catppuccin Mocha palette.
if ($script:HasInteractiveConsole -and (Get-Module -Name PSReadLine -ListAvailable)) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
    Set-PSReadLineOption -Colors @{
        Command            = '#89B4FA'  # Blue
        Parameter          = '#F5C2E7'  # Pink
        Variable           = '#F5C2E7'  # Pink
        String             = '#A6E3A1'  # Green
        Number             = '#FAB387'  # Peach
        Type               = '#F9E2AF'  # Yellow
        Keyword            = '#CBA6F7'  # Mauve
        Comment            = '#6C7086'  # Overlay0
        Operator           = '#89DCEB'  # Sky
        Member             = '#94E2D5'  # Teal
        Error              = '#F38BA8'  # Red
        Emphasis           = '#F38BA8'  # Red
        InlinePrediction   = '#6C7086'  # Overlay0 (dimmed ghost text)
        Default            = '#CDD6F4'  # Text
        ContinuationPrompt = '#A6ADC8'  # Subtext0
    } -ErrorAction SilentlyContinue
    # F3 : bascule InlineView <-> ListView (deplace de F2 pour liberer F2).
    Set-PSReadLineKeyHandler -Key F3 -Function SwitchPredictionView
    # F2 : menu sessionizer - sessions/projets/vaults.
    #      On INSERE `Invoke-Sessionizer` + AcceptLine (l'execute comme une vraie ligne) : lancer
    #      un TUI plein ecran DANS le ScriptBlock ne lui passe pas le TTY -> fzf reste fige.
    Set-PSReadLineKeyHandler -Key F2 -BriefDescription 'Sessionizer' -LongDescription 'Menu sessions/projets/vaults' -ScriptBlock {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert('Invoke-Sessionizer')
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock {
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptSuggestion()
        $newLine = $null; $newCursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$newLine, [ref]$newCursor)
        if ($line -eq $newLine) {
            [Microsoft.PowerShell.PSConsoleReadLine]::MenuComplete()
        }
    }
}

# ---- CompletionPredictor: smart predictions beyond shell history
# (cmdlet parameters, git branches, file paths, etc.) ----
# HasInteractiveConsole obligatoire : un predicteur ne sert qu'a la saisie, et
# son Import-Module FIGE indefiniment un pwsh demarre sans console (`pwsh
# -Command ...`, donc tout `ssh desktop "commande"` depuis que le DefaultShell
# OpenSSH est pwsh). Meme garde que PSReadLine et PSFzf ci-dessus.
if ($script:HasInteractiveConsole -and (Get-Module -ListAvailable -Name CompletionPredictor)) {
    Import-Module CompletionPredictor -ErrorAction SilentlyContinue
}

# ---- zoxide: smart `cd` based on frecency. After visiting a dir once,
# `cd <fuzzy-name>` jumps there from anywhere (e.g. `cd dev-env` ->
# C:\dev\dev-environment). Original literal `cd ./path` still works first.
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) })
}

# ---- Argument completer for `cd`: surfaces every subdir of C:\dev\ as a
# completion candidate, so `cd dev-env<Tab>` shows `dev-environment` even
# from a brand-new shell that hasn't visited the path yet. Complements
# zoxide (which only knows dirs after the first manual visit).
Register-ArgumentCompleter -CommandName cd, Set-Location, sl -ParameterName Path -ScriptBlock {
    param($cmd, $param, $word, $ast, $bound)
    $w = $word.Trim("'", '"')
    if (-not (Test-Path 'C:\dev')) { return }
    Get-ChildItem 'C:\dev' -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not $w -or $_.Name -like "*$w*" } |
        ForEach-Object {
            $p = $_.FullName
            [System.Management.Automation.CompletionResult]::new("'$p'", $_.Name, 'ParameterValue', $p)
        }
}

# ---- Terminal-Icons: Nerd Font icons in Get-ChildItem (`ls`) output ----
if (Get-Module -ListAvailable -Name Terminal-Icons) {
    $terminalIconsDir = Join-Path $env:APPDATA 'powershell\Community\Terminal-Icons'
    if (Test-Path $terminalIconsDir) {
        Get-ChildItem $terminalIconsDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $themeFile = $_.FullName
            try {
                $null = Import-Clixml -LiteralPath $themeFile -ErrorAction Stop
            } catch {
                $badPath = "$themeFile.bad-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Move-Item -LiteralPath $themeFile -Destination $badPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    try { Import-Module Terminal-Icons -ErrorAction Stop } catch {}
}

# ---- PSFzf: Ctrl+R fuzzy reverse-history, Ctrl+T fuzzy file/dir picker ----
# Only loaded when fzf.exe is available on PATH.
if ($script:HasInteractiveConsole -and (Get-Module -ListAvailable -Name PSFzf) -and (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Import-Module PSFzf -ErrorAction SilentlyContinue
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r' -ErrorAction SilentlyContinue
}

# ---- Fastfetch splash (Windows logo + system info) ----
# Uses the config at ~/.config/fastfetch/config.jsonc deployed by this bundle.
# Runs only in interactive sessions to avoid polluting scripted/piped pwsh calls.
if ($script:HasInteractiveConsole -and (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
    # Aggregate physical-memory info via WMI (portable across any Windows PC) and
    # expose as $env:FF_RAM so fastfetch's `command` module can echo it cheaply
    # instead of paying CIM cost on every fastfetch invocation.
    try {
        $m = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
        $typeMap = @{ 20='DDR'; 21='DDR2'; 24='DDR3'; 26='DDR4'; 34='DDR5' }
        $types = $m.SMBIOSMemoryType | Sort-Object -Unique
        $speeds = $m.Speed | Sort-Object -Unique
        $sizes = $m.Capacity | Sort-Object -Unique
        $vendors = ($m.Manufacturer | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Sort-Object -Unique
        if ($types.Count -eq 1 -and $speeds.Count -eq 1 -and $sizes.Count -eq 1) {
            $t = $typeMap[[int]$types[0]]; if (-not $t) { $t = 'DRAM' }
            $sizeEach = [Math]::Round($sizes[0] / 1GB, 2)
            $vendor = if ($vendors) { " ($($vendors -join '/'))" } else { '' }
            $env:FF_RAM = "$($m.Count) $([char]0x00D7) $sizeEach GiB $t-$($speeds[0])$vendor"
        } else {
            $totalGiB = [Math]::Round((($m | Measure-Object Capacity -Sum).Sum) / 1GB, 2)
            $t = $typeMap[[int]$types[0]]; if (-not $t) { $t = 'DRAM' }
            $env:FF_RAM = "$($m.Count) sticks, $totalGiB GiB $t (mixed)"
        }
    } catch {
        $env:FF_RAM = ''
    }

    # Print a per-character gradient USER@HOST header before fastfetch.
    # The gradient walks the same 5 Catppuccin stops as the rest of the splash
    # (Flamingo -> Pink -> Mauve -> Lavender -> Sapphire) so the whole header is a
    # single continuous palette ribbon.
    $titleText = "$env:USERNAME@$env:COMPUTERNAME"
    # Restricted gradient for the title - uses only the cool-side trio:
    # the exact colors of the RAM, Drive and Display rows of the splash.
    $stops = @(
        @(192, 178, 250),  # RAM     (lerp Mauve->Lavender)
        @(180, 190, 254),  # Drive   (Lavender)
        @(148, 194, 245)   # Display (lerp Lavender->Sapphire)
    )
    $segCount = $stops.Count - 1
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("`n")
    $n = $titleText.Length
    for ($i = 0; $i -lt $n; $i++) {
        $u = if ($n -gt 1) { ($i / ($n - 1)) * $segCount } else { 0 }
        $seg = [Math]::Min([int][Math]::Floor($u), $segCount - 1)
        $t = $u - $seg
        $a = $stops[$seg]; $b = $stops[$seg + 1]
        $r = [int][Math]::Round($a[0] + ($b[0] - $a[0]) * $t)
        $g = [int][Math]::Round($a[1] + ($b[1] - $a[1]) * $t)
        $bb = [int][Math]::Round($a[2] + ($b[2] - $a[2]) * $t)
        [void]$sb.Append("$([char]27)[1;38;2;$r;$g;${bb}m$($titleText[$i])")
    }
    [void]$sb.Append("$([char]27)[0m")
    [Console]::Out.WriteLine($sb.ToString())

    fastfetch
}

# ---- Claude Code clipboard watcher ----------------------------------------
# Pushes every new phone image (img2clip -> Windows ~/.claude-images)
# into the clipboard of THIS window station. Called by both
# `claude` and `ollama launch claude`; the watcher mutex keeps one instance per
# clipboard, so extra starts are cheap no-ops.
function Start-ClaudeClipboardWatcher {
    param([switch]$Fast)
    $watcher = "$env:USERPROFILE\.local\bin\img-clip-watcher.ps1"
    if (Test-Path $watcher) {
        $args = @(
            '-Sta', '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', $watcher, '-CallerPid', $PID
        )
        if ($Fast) {
            try {
                Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
            } catch {}
            return
        }
        # Invoke-CimMethod (PAS Start-Process) : le process est cree par le
        # service WMI, donc HORS du job ConPTY du pane zellij (qui tue toute
        # son arborescence a la fermeture du pane), mais avec le token de
        # l'appelant -> la bonne logon session. Le watcher ne meurt qu'avec
        # son ancre (serveur zellij / shell), pas avec ce pane.
        $cmd = "powershell.exe -Sta -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`" -CallerPid $PID"
        try {
            # Keep WMI detachment, but avoid a visible Windows Terminal window.
            $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
            Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
                CommandLine = $cmd
                ProcessStartupInformation = $startup
            } | Out-Null
        } catch {
            # Degrade gracefully : clipboard phone->pwsh may be unavailable, but
            # Claude itself must still start.
            try {
                Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
            } catch {}
        }
    }
}
# ---- Claude Code wrapper : device-context detection ------------------------
# Calls the detector before launching the real claude binary, so the assistant
# knows which machine/shell/context it is talking to. The detector writes a
# JSON file at ~/.claude/.device-context that the assistant reads.
# Recursion is avoided by calling the binary via its full path.
function claude {
    $detectScript = "$env:USERPROFILE\.claude\device-context\detect.ps1"
    if (Test-Path $detectScript) {
        & $detectScript 2>$null
    }
    Start-ClaudeClipboardWatcher
    # Select-Object -First 1 : Get-Command renvoie UNE entree PAR emplacement du
    # PATH ou l'exe existe. Avec deux claude.exe (installeur natif dans
    # ~\.local\bin ET shim winget dans WinGet\Links), .Source devient un TABLEAU
    # que `&` aplatit en une seule chaine "chemin1 chemin2" -> "The term '...'
    # is not recognized". -First 1 prend celui que le PATH aurait choisi.
    $claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    if (-not $claudeCmd) {
        Write-Error "claude not found on PATH"
        return
    }
    & $claudeCmd.Source @args
}

# `ollama launch claude` bypasses the `claude()` function above, so wrap the
# application command too and start the same clipboard watcher for that path.
function ollama {
    if ($args.Count -ge 2 -and $args[0] -eq 'launch' -and $args[1] -eq 'claude') {
        Start-ClaudeClipboardWatcher
    }
    $ollamaCmd = Get-Command ollama -CommandType Application -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    if (-not $ollamaCmd) {
        Write-Error "ollama not found on PATH"
        return
    }
    & $ollamaCmd.Source @args
}

# Force the console to UTF-8 so non-ASCII output (Fastfetch icons, Nerd Font
# glyphs, accents in directory names) renders correctly instead of mojibake.
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding           = [System.Text.UTF8Encoding]::new()

function isadmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function dev { Set-Location C:\dev }

# ---- PSReadLine: modern predictions + smart Tab + Catppuccin Mocha colors ----
# - InlineView by default (grey ghost text). F2 toggles to ListView (dropdown).
# - Tab accepts the inline prediction if one is visible, else MenuComplete.
# - Right Arrow / Ctrl+RightArrow also accept (standard PSReadLine behavior).
# - Syntax-highlight colors aligned with the Catppuccin Mocha palette.
if (Get-Module -Name PSReadLine -ListAvailable) {
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
    Set-PSReadLineKeyHandler -Key F2 -Function SwitchPredictionView
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
if (Get-Module -ListAvailable -Name CompletionPredictor) {
    Import-Module CompletionPredictor -ErrorAction SilentlyContinue
}

# ---- zoxide: smart `cd` based on frecency. After visiting a dir once,
# `cd <fuzzy-name>` jumps there from anywhere (e.g. `cd dev-env` →
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
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue
}

# ---- PSFzf: Ctrl+R fuzzy reverse-history, Ctrl+T fuzzy file/dir picker ----
# Only loaded when fzf.exe is available on PATH.
if ((Get-Module -ListAvailable -Name PSFzf) -and (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Import-Module PSFzf -ErrorAction SilentlyContinue
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r' -ErrorAction SilentlyContinue
}

# ---- Fastfetch splash (Windows logo + system info) ----
# Uses the config at ~/.config/fastfetch/config.jsonc deployed by this bundle.
# Runs only in interactive sessions to avoid polluting scripted/piped pwsh calls,
# and is skipped inside Zellij ($env:ZELLIJ) — vault panes go straight to `claude`,
# no slow WMI/fastfetch splash on every session.
if ((-not [System.Console]::IsOutputRedirected) -and (-not $env:ZELLIJ) -and (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
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
    # (Flamingo → Pink → Mauve → Lavender → Sapphire) so the whole header is a
    # single continuous palette ribbon.
    $titleText = "$env:USERNAME@$env:COMPUTERNAME"
    # Restricted gradient for the title — uses only the cool-side trio:
    # the exact colors of the RAM, Drive and Display rows of the splash.
    $stops = @(
        @(192, 178, 250),  # RAM     (lerp Mauve→Lavender)
        @(180, 190, 254),  # Drive   (Lavender)
        @(148, 194, 245)   # Display (lerp Lavender→Sapphire)
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
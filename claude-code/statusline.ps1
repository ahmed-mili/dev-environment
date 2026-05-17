# Status line Claude Code (Windows / PowerShell 7+)
# Affiche :
#   <path coloré selon permission_mode>  (branch)
#   │  5h ▰▰░░░ 6%  ·  7d ▰▰▰░░ 35% (reset 2h14m)
#   │  pro @ email
#
# Source des données usage : endpoint privé Claude Code
#   GET https://api.anthropic.com/api/oauth/usage
#   Authorization: Bearer <accessToken depuis ~/.claude/.credentials.json>
#   anthropic-beta: oauth-2025-04-20
# Découvert par Melvynx (https://codelynx.dev/posts/claude-code-usage-limits-statusline)
#
# Caches (pour éviter de spammer l'API à chaque refresh) :
#   - usage-cache.json     : 10s  (dashboard Claude.ai rafraîchit ~60s,
#                                  on est donc 6x plus frais qu'eux)
#   - auth-status-cache.json : 1h (plan ne change pas souvent)

$ErrorActionPreference = 'SilentlyContinue'

# Force UTF-8 sur stdin/stdout : Claude Code lit notre stdout dans son propre
# terminal, et sans ça les chars non-ASCII (barres █░, séparateurs ·) tombent
# en `?` quand la console hérite du codepage OEM (CP850/CP1252).
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# ============================== HELPERS ==============================

$esc = [char]27
function RGB([int]$r,[int]$g,[int]$b) { "$esc[38;2;$r;$g;${b}m" }   # foreground truecolor
function BG ([int]$r,[int]$g,[int]$b) { "$esc[48;2;$r;$g;${b}m" }   # background truecolor
$reset  = "$esc[0m"
$dim    = "$esc[2m"

function Get-UsageColor([double]$pct, [bool]$stale = $false) {
    # Quand $stale est vrai (l'API a echoue, on affiche un vieux cache), on rend
    # les couleurs visiblement plus desaturees/pales : signal subtil que l'info
    # date un peu sans rendre la status bar illisible.
    if ($stale) {
        if ($pct -lt 50)  { return (RGB 130 175 145) }   # vert pale
        if ($pct -lt 70)  { return (RGB 195 195 165) }   # jaune pale
        if ($pct -lt 85)  { return (RGB 200 170 145) }   # orange pale
        return (RGB 195 130 130)                          # rouge pale
    }
    if ($pct -lt 50)  { return (RGB 80  250 123) }   # vert
    if ($pct -lt 70)  { return (RGB 241 250 140) }   # jaune
    if ($pct -lt 85)  { return (RGB 255 184 108) }   # orange
    return (RGB 255 85 85)                            # rouge
}

function Format-Tokens([long]$n) {
    # Force la culture invariante : sinon en locale fr-FR on récupère "1,0M"
    # (virgule) au lieu de "1.0M" — moins lisible et casse l'attendu international.
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($n -lt 1000) { return "$n" }
    if ($n -lt 1000000) { return ([int][Math]::Round($n / 1000.0)).ToString($inv) + "k" }
    return ([Math]::Round($n / 1000000.0, 1)).ToString('0.0', $inv) + "M"
}

function Format-Bar([double]$pct, [string]$col, [int]$width = 14) {
    # Rectangles ▬ (U+25AC) au lieu de blocs pleins █ : occupent moins de hauteur
    # dans la cellule terminal, donc la ligne paraît moins épaisse verticalement.
    # Arrondi à l'entier (pas de cellule partielle) : plus lisible et cohérent.
    $filled = [int][Math]::Round($pct / 100.0 * $width)
    if ($filled -gt $width) { $filled = $width }
    if ($filled -lt 0)      { $filled = 0 }
    $empty  = $width - $filled
    $colRail = RGB 80 80 95   # gris-bleu sombre pour la partie vide (rail)
    return "${col}$('▬' * $filled)${colRail}$('▬' * $empty)${reset}"
}

function Format-Reset($resetAt, $referenceTime = $null) {
    # Convention identique au dashboard Claude.ai :
    #   < 1h         → "Xm"          (ex. 47m)
    #   < 24h        → "XhYYm"       (ex. 4h23m)
    #   >= 24h       → "mer. 07:00"  (jour fr + heure locale)
    # Accepte un [DateTime] (ConvertFrom-Json convertit auto les dates ISO) ou une string.
    # $referenceTime : si fourni (mode stale), le compte a rebours est calcule depuis
    # ce moment au lieu de Now() -> reste fige a la valeur du moment du cache, ce qui
    # permet de mesurer la fraicheur de l'info au coup d'oeil.
    if (-not $resetAt) { return $null }
    try {
        if ($resetAt -is [DateTime]) {
            $resetUtc = $resetAt.ToUniversalTime()
        } else {
            $resetUtc = [DateTime]::Parse([string]$resetAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        }
        $now   = if ($null -ne $referenceTime) { $referenceTime } else { [DateTime]::UtcNow }
        $delta = $resetUtc - $now
        if ($delta.TotalSeconds -le 0) { return 'now' }
        # [int] en PowerShell fait du banker's rounding (23.98→24), donc on prend
        # explicitement Floor pour ne jamais sur-arrondir le temps restant.
        if ($delta.TotalMinutes -lt 60) { return ("{0}m" -f [int][Math]::Floor($delta.TotalMinutes)) }
        if ($delta.TotalHours -lt 24) {
            return ("{0}h{1:D2}m" -f [int][Math]::Floor($delta.TotalHours), $delta.Minutes)
        }
        # Format absolu : jour de la semaine (fr) + HH:mm dans la timezone locale.
        $resetLocal = $resetUtc.ToLocalTime()
        $dayMap = @{ 0='dim'; 1='lun'; 2='mar'; 3='mer'; 4='jeu'; 5='ven'; 6='sam' }
        $dayAbbr = $dayMap[[int]$resetLocal.DayOfWeek]
        return "$dayAbbr. $($resetLocal.ToString('HH:mm'))"
    } catch { return $null }
}

# ============================== INPUT STDIN ==============================

$raw = [Console]::In.ReadToEnd()
$data = $null
try { $data = $raw | ConvertFrom-Json } catch {}

# Debug : conserver le dernier JSON reçu pour inspection
try { Set-Content -Path "$env:USERPROFILE\.claude\statusline-last-input.json" -Value $raw -Encoding UTF8 } catch {}

# Dossier courant
$dir = $null
if ($data) {
    if ($data.workspace -and $data.workspace.current_dir) { $dir = $data.workspace.current_dir }
    elseif ($data.cwd) { $dir = $data.cwd }
}
if (-not $dir) { $dir = (Get-Location).Path }

# Permission mode (gère plusieurs conventions)
$mode = $null
if ($data) {
    foreach ($k in @('permission_mode','permissionMode')) {
        if ($data.PSObject.Properties.Name -contains $k -and $data.$k) { $mode = $data.$k; break }
    }
    if (-not $mode -and $data.session -and $data.session.permission_mode) { $mode = $data.session.permission_mode }
}

# Modèle (display name si dispo)
$modelName = $null
if ($data -and $data.model) {
    if ($data.model.display_name) { $modelName = $data.model.display_name }
    elseif ($data.model.id) { $modelName = $data.model.id }
}

# ============================== COULEURS PATH ==============================

# Pour les modes "safety" (bypass/plan/accept/dontAsk/auto) on garde un fond UNI
# distinctif — c'est ce qui permet de reconnaître un mode dangereux d'un coup d'œil.
# Pour le mode par défaut on applique un DÉGRADÉ Catppuccin per-character
# (Lavender → Blue → Sapphire) ancré sur le Blue #89B4FA — exactement la teinte
# utilisée par PSReadLine pour les commandes (mkdir, claude) et le même style
# que le header USER@HOST du splash fastfetch.
$gradStops = $null
switch ($mode) {
    'bypassPermissions' { $pR=255; $pG=121; $pB=198 }   # rose vif
    'plan'              { $pR=139; $pG=233; $pB=253 }   # cyan clair
    'acceptEdits'       { $pR=80;  $pG=250; $pB=123 }   # vert
    'dontAsk'           { $pR=189; $pG=147; $pB=249 }   # violet
    'auto'              { $pR=255; $pG=184; $pB=108 }   # orange
    default {
        $gradStops = @(
            @(180, 190, 254),  # Catppuccin Lavender (#B4BEFE)
            @(137, 180, 250),  # Catppuccin Blue    (#89B4FA) — ancre
            @(116, 199, 236)   # Catppuccin Sapphire (#74C7EC)
        )
        # Couleur du chevron de fin de bannière = dernier stop du dégradé,
        # ainsi la pointe prolonge visuellement la fin du dégradé.
        $pR = $gradStops[-1][0]; $pG = $gradStops[-1][1]; $pB = $gradStops[-1][2]
    }
}
$pathFG = RGB $pR $pG $pB
$pathBG = BG  $pR $pG $pB

# ============================== BRANCHE GIT ==============================

$branch = $null
$gitAhead = 0     # commits locaux pas encore push vers upstream
$gitBehind = 0    # commits upstream pas encore pull en local
$gitDirty = $false  # working tree contient des modifs non commit (tracked ou untracked)
$probe = $dir
while ($probe -and -not (Test-Path -LiteralPath (Join-Path $probe '.git'))) {
    $parent = Split-Path -Parent $probe
    if (-not $parent -or $parent -eq $probe) { $probe = $null; break }
    $probe = $parent
}
if ($probe) {
    $branch = & git -C $dir rev-parse --abbrev-ref HEAD 2>$null
    if ($branch) {
        # `--porcelain=v2 --branch` regroupe ahead/behind ET working tree en un seul
        # appel git -> minimise le coût (la status bar est refresh à chaque keystroke).
        # ahead/behind sont basés sur l'état git LOCAL : pas de fetch implicite —
        # c'est le hook auto-pull qui rafraîchit la ref upstream au démarrage de session.
        $statusLines = & git -C $dir status --porcelain=v2 --branch 2>$null
        foreach ($line in $statusLines) {
            if ($line -match '^# branch\.ab \+(\d+) -(\d+)') {
                $gitAhead  = [int]$matches[1]
                $gitBehind = [int]$matches[2]
            }
            elseif ($line -match '^[12?u] ') {
                # Premier char : 1=changé, 2=renommé/copié, ?=untracked, u=unmerged
                $gitDirty = $true
            }
        }
    }
}

# ============================== COMPTE (email) ==============================

$email = $null
try {
    $cfg = Get-Content -Raw "$env:USERPROFILE\.claude.json" | ConvertFrom-Json -AsHashtable
    if ($cfg.oauthAccount -and $cfg.oauthAccount.emailAddress) { $email = $cfg.oauthAccount.emailAddress }
} catch {}

# Plan : cache 1h depuis claude auth status --json (ou .credentials.json en fallback)
$plan = $null
$authCache = "$env:USERPROFILE\.claude\auth-status-cache.json"
$authValid = (Test-Path $authCache) -and ((Get-Date) - (Get-Item $authCache).LastWriteTime).TotalHours -lt 1
if ($authValid) {
    try { $plan = (Get-Content -Raw $authCache | ConvertFrom-Json).subscriptionType } catch {}
}
if (-not $plan) {
    try {
        $json = & claude auth status --json 2>$null
        if ($json) {
            Set-Content -Path $authCache -Value $json -Encoding UTF8
            $plan = ($json | ConvertFrom-Json).subscriptionType
        }
    } catch {}
}
# Fallback ultime : lire subscriptionType directement dans .credentials.json
if (-not $plan) {
    try {
        $creds = Get-Content -Raw "$env:USERPROFILE\.claude\.credentials.json" | ConvertFrom-Json
        if ($creds.claudeAiOauth.subscriptionType) { $plan = $creds.claudeAiOauth.subscriptionType }
    } catch {}
}

# ============================== USAGE (5h + 7j) ==============================

# Cache 60s : meme cadence que claude.ai dashboard. L'historique TTL=7s causait
# des 429 systematiques en usage interactif (la status bar etant rafraichie a
# chaque keystroke). 60s elimine la pression sur l'API tout en gardant l'info
# frais a la minute pres.
$usageCache = "$env:USERPROFILE\.claude\usage-cache.json"
$usageValid = (Test-Path $usageCache) -and ((Get-Date) - (Get-Item $usageCache).LastWriteTime).TotalSeconds -lt 60
$usage = $null
if ($usageValid) {
    try { $usage = Get-Content -Raw $usageCache | ConvertFrom-Json } catch {}
}

# Cooldown post-429 : si on s'est pris un rate-limit recemment, on n'essaie meme
# pas l'API (sinon on l'aggrave). 5 min de cooldown : le rate-limit Anthropic
# semble s'etendre sur plusieurs minutes, retenter plus tot agrave le probleme.
$rateLimitFile = "$env:USERPROFILE\.claude\usage-ratelimit.txt"
$inCooldown = $false
if ((-not $usage) -and (Test-Path $rateLimitFile)) {
    try {
        $lastRL = [DateTime]::Parse((Get-Content -Raw $rateLimitFile).Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        if (((Get-Date) - $lastRL).TotalSeconds -lt 300) { $inCooldown = $true }
    } catch {}
}

if ((-not $usage) -and (-not $inCooldown)) {
    try {
        $creds = Get-Content -Raw "$env:USERPROFILE\.claude\.credentials.json" | ConvertFrom-Json
        $token = $creds.claudeAiOauth.accessToken
        if ($token) {
            $headers = @{
                'Authorization'   = "Bearer $token"
                'anthropic-beta'  = 'oauth-2025-04-20'
                'User-Agent'      = 'claude-code/2.0.32'
                'Accept'          = 'application/json, text/plain, */*'
                'Content-Type'    = 'application/json'
            }
            $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -Method Get -TimeoutSec 4
            if ($resp) {
                $usage = $resp
                $resp | ConvertTo-Json -Depth 6 | Set-Content -Path $usageCache -Encoding UTF8
                # Succes -> nettoyer un eventuel cooldown precedent
                if (Test-Path $rateLimitFile) { Remove-Item $rateLimitFile -Force -ErrorAction SilentlyContinue }
            }
        }
    } catch {
        # Detecter 429 specifiquement et armer le cooldown
        $status = $null
        try { $status = $_.Exception.Response.StatusCode.value__ } catch {}
        if ($status -eq 429) {
            (Get-Date).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) | Set-Content -Path $rateLimitFile -Encoding UTF8
        }
    }
}

# Fallback stale : si l'API a echoue (timeout, rate-limit, reseau, etc.) et qu'on n'a
# pas pu rafraichir le cache, on reutilise le dernier cache connu meme s'il est vieux.
# Eviter que la ligne 5h/7d disparaisse est plus important que la fraicheur a la seconde.
# Le flag $usageStale est utilise plus bas pour desaturer les couleurs ET figer le
# compte a rebours a la valeur du moment du cache (= permet de mesurer la fraicheur
# au coup d'oeil : si on voit (3h07m) alors qu'on devrait etre a (3h00m), l'info
# date de ~7 min).
$usageStale = $false
$usageReferenceTime = $null   # null = utiliser Now() (cache frais)
if (-not $usage -and (Test-Path $usageCache)) {
    try {
        $usage = Get-Content -Raw $usageCache | ConvertFrom-Json
        $usageStale = $true
        $usageReferenceTime = (Get-Item $usageCache).LastWriteTime.ToUniversalTime()
    } catch {}
}

# ============================== CONTEXTE (stdin Claude Code) ==============================

# Source : context_window dans le JSON stdin (déjà fourni, pas d'appel API)
$ctxPct = $null; $ctxTokens = $null; $ctxSize = $null
if ($data -and $data.context_window) {
    if ($null -ne $data.context_window.used_percentage) { $ctxPct = [double]$data.context_window.used_percentage }
    if ($null -ne $data.context_window.total_input_tokens) { $ctxTokens = [long]$data.context_window.total_input_tokens }
    if ($null -ne $data.context_window.context_window_size) { $ctxSize = [long]$data.context_window.context_window_size }
}

# ============================== ASSEMBLAGE ==============================

# === STYLE BANNER POWERLINE ===
# Inspiré du style "tag avec fond coloré + chevron de transition" :
# chaque section a un background coloré, et le chevron U+E0B0 entre deux
# sections a FG = couleur de la section précédente, BG = couleur de la
# suivante, ce qui crée l'illusion d'un drapeau qui se prolonge en pointe.
$ch = ([char]0xE0B0).ToString()   # ▶ Powerline RIGHT TRIANGLE SOLID (banner-end)
$sep = " $(RGB 220 220 220)·$reset "   # middle dot gris très clair — même teinte que "Opus 4.7 ctx"

# Section cost ($/h) : background gris-vert foncé (money vibe), texte vert Catppuccin
$sCostR = 45; $sCostG = 55; $sCostB = 45
$sCost_bg = BG  $sCostR $sCostG $sCostB
$sCost_fg = RGB 166 227 161   # Catppuccin Green

# Section 2 (model + ctx) : background gris-bleu foncé, texte clair
$s2R = 60; $s2G = 64; $s2B = 80
$s2_bg = BG  $s2R $s2G $s2B
$s2_fg = RGB 220 220 220

# Texte foncé pour le banner path (lisible sur les fonds vifs : rose, cyan, vert...)
$pathTextFG = RGB 25 28 42

# --- BANNER 1 : path ---
# Contenu de la bannière construit en segments (texte, FG) — permet d'appliquer
# soit un fond UNI (modes safety) soit un dégradé per-character (mode par défaut)
# sans dupliquer la logique de mise en page.
$bannerSegs = @(
    @{ text = " $dir";       fg = $pathTextFG }
)
if ($branch) {
    # Indicateurs de sync vs upstream :
    #   ↑N = N commits locaux pas encore push (à `git push`)
    #   ↓N = N commits upstream pas encore pull (à `git pull`)
    #   *  = working tree dirty (modifs / untracked / unmerged non commit)
    # Apparaissent seulement si > 0 — sinon la branche s'affiche normalement.
    $branchText = " ($branch"
    if ($gitAhead -gt 0)  { $branchText += " ↑$gitAhead" }
    if ($gitBehind -gt 0) { $branchText += " ↓$gitBehind" }
    if ($gitDirty)        { $branchText += ' *' }
    $branchText += ')'
    $bannerSegs += @{ text = $branchText; fg = (RGB 60 65 80) }
}
$bannerSegs += @{ text = ' '; fg = $pathTextFG }

if ($gradStops) {
    # Dégradé per-character : interpole linéairement entre les stops selon
    # la position du caractère dans la bannière complète.
    $totalLen = ($bannerSegs | ForEach-Object { $_.text.Length } | Measure-Object -Sum).Sum
    $segCount = $gradStops.Count - 1
    $sb = [System.Text.StringBuilder]::new()
    $idx = 0
    foreach ($s in $bannerSegs) {
        foreach ($c in $s.text.ToCharArray()) {
            $u = if ($totalLen -gt 1) { ($idx / ($totalLen - 1)) * $segCount } else { 0 }
            $seg = [Math]::Min([int][Math]::Floor($u), $segCount - 1)
            $tFrac = $u - $seg
            $a = $gradStops[$seg]; $b = $gradStops[$seg + 1]
            $r  = [int][Math]::Round($a[0] + ($b[0] - $a[0]) * $tFrac)
            $g  = [int][Math]::Round($a[1] + ($b[1] - $a[1]) * $tFrac)
            $bb = [int][Math]::Round($a[2] + ($b[2] - $a[2]) * $tFrac)
            [void]$sb.Append("$esc[48;2;$r;$g;${bb}m$($s.fg)$c")
            $idx++
        }
    }
    $line1 = $sb.ToString() + $reset
} else {
    # Fond uni (modes safety) — couleur distinctive par mode pour reconnaissance rapide.
    $line1 = ''
    foreach ($s in $bannerSegs) {
        $line1 += "$pathBG$($s.fg)$($s.text)"
    }
    $line1 += $reset
}

# --- BANNER COST — entité distincte du modèle, intercalée entre path et model+ctx ---
# Source : data.cost.total_cost_usd déjà fourni dans stdin (cumul session, monotone croissant).
# Préfixe "≈" (approximately equal) : pour les plans Pro/Max ce n'est PAS ce que
# l'utilisateur paye, c'est l'équivalent au tarif API direct. Le symbole
# mathématique lève l'ambiguïté de manière universelle et compacte.
$costStr = $null
if ($data -and $data.cost -and $null -ne $data.cost.total_cost_usd) {
    $totalCost = [double]$data.cost.total_cost_usd
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $costStr = [char]0x2248 + '$' + $totalCost.ToString('0.00', $inv)
}

if ($costStr) {
    # CHEVRON 1 : path → cost banner (pointe path qui perfore le fond vert sombre)
    $line1 += "$pathFG$sCost_bg$ch"
    # Contenu bannière cost
    $line1 += "$sCost_fg $costStr "
    # CHEVRON 2 : cost → model+ctx (pointe verte qui perfore le fond gris-bleu)
    $line1 += "$(RGB $sCostR $sCostG $sCostB)$s2_bg$ch"
} else {
    # Pas de donnée cost → on garde le rendu d'origine (path → model+ctx direct)
    $line1 += "$pathFG$s2_bg$ch"
}

# --- BANNER 2 : modèle + ctx, sur fond s2_bg ---
$line1 += "$s2_fg "
if ($modelName) {
    $line1 += "$modelName  "
}

# Contexte affiche en permanence : sert de repere pour anticiper /clear.
# Format "valeur unite" (convention SI : 5 GB, 2.4 kg, 243k tok) plutot que
# "label valeur" qui melangeait semantique (ctx) et valeur (243k/1.0M).
# Le suffixe "tok" est l'abreviation standard dans l'ecosysteme AI (OpenAI,
# Anthropic). La valeur est en couleur dynamique (vert/jaune/rouge selon usage),
# le label "tok" reste en couleur de base (subtil).
$ctxPctSafe = if ($null -ne $ctxPct) { [double]$ctxPct } else { 0 }
$col = Get-UsageColor $ctxPctSafe
if ($null -ne $ctxTokens -and $null -ne $ctxSize) {
    $tokStr = "$(Format-Tokens $ctxTokens)/$(Format-Tokens $ctxSize)"
    $line1 += "$col$tokStr$s2_fg tok"
} else {
    # Fallback : tokens absolus indisponibles, on garde l'ancien format
    $line1 += "ctx $col$([int]$ctxPctSafe)%$s2_fg"
}
$line1 += " "

# --- CHEVRON 2 : sec2 → terminal default ---
$line1 += "$reset$(RGB $s2R $s2G $s2B)$ch$reset"

# Section account retirée du statusline → disponible via /account

# Ligne 2 : usage 5h + 7d (+ opus si Max) — fusionnés sur la même ligne, séparés par $sep
# Gain : -1 ligne verticale = plus d'espace pour le terminal réel.
# Couleur des compteurs (3h02m) et (ven. 19:00) : RGB explicite plutot que $dim ANSI
# qui devient trop sombre sur fond Catppuccin Mocha (#1E1E2E) et se confond avec.
$resetCol = RGB 140 145 165   # gris-bleu clair, lisible sur tout theme dark
$usageSegments = @()
if ($usage) {
    if ($usage.five_hour -and $null -ne $usage.five_hour.utilization) {
        $pct  = [double]$usage.five_hour.utilization
        $col  = Get-UsageColor $pct $usageStale
        $bar  = Format-Bar $pct $col
        $rst  = Format-Reset $usage.five_hour.resets_at $usageReferenceTime
        $seg  = "${col}5h$reset $bar ${col}$([int]$pct)%$reset"
        if ($rst) { $seg += " $resetCol($rst)$reset" }
        $usageSegments += $seg
    }

    if ($usage.seven_day -and $null -ne $usage.seven_day.utilization) {
        $pct  = [double]$usage.seven_day.utilization
        $col  = Get-UsageColor $pct $usageStale
        $bar  = Format-Bar $pct $col
        $rst  = Format-Reset $usage.seven_day.resets_at $usageReferenceTime
        $seg  = "${col}7d$reset $bar ${col}$([int]$pct)%$reset"
        if ($rst) { $seg += " $resetCol($rst)$reset" }
        $usageSegments += $seg
    }

    # Opus dédié (plan Max uniquement, sinon utilization = 0 et resets_at = null)
    if ($usage.seven_day_opus -and $usage.seven_day_opus.utilization -gt 0 -and $usage.seven_day_opus.resets_at) {
        $pct  = [double]$usage.seven_day_opus.utilization
        $col  = Get-UsageColor $pct $usageStale
        $bar  = Format-Bar $pct $col
        $rst  = Format-Reset $usage.seven_day_opus.resets_at $usageReferenceTime
        $seg  = "${col}opus$reset $bar ${col}$([int]$pct)%$reset"
        if ($rst) { $seg += " $resetCol($rst)$reset" }
        $usageSegments += $seg
    }
}
$line2 = ""
if ($usageSegments.Count -gt 0) { $line2 = $usageSegments -join $sep }

$out = $line1
if ($line2) { $out += "`n`n$line2" }

Write-Host -NoNewline $out

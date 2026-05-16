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
#   - usage-cache.json     : 60s  (utilisation 5h/7j change rapidement)
#   - auth-status-cache.json : 1h (plan ne change pas souvent)

$ErrorActionPreference = 'SilentlyContinue'

# ============================== HELPERS ==============================

$esc = [char]27
function RGB([int]$r,[int]$g,[int]$b) { "$esc[38;2;$r;$g;${b}m" }
$reset  = "$esc[0m"
$dim    = "$esc[2m"

function Get-UsageColor([double]$pct) {
    if ($pct -lt 50)  { return (RGB 80  250 123) }   # vert
    if ($pct -lt 80)  { return (RGB 241 250 140) }   # jaune
    return (RGB 255 85 85)                            # rouge
}

function Format-Bar([double]$pct, [int]$width = 6) {
    # Barre Unicode block elements, 6 segments par défaut
    $filled = [Math]::Floor($pct / 100 * $width)
    if ($filled -gt $width) { $filled = $width }
    $empty  = $width - $filled
    return ('▰' * $filled) + ('▱' * $empty)
}

function Format-Reset($resetAt) {
    # Accepte un [DateTime] (ConvertFrom-Json convertit auto les dates ISO) ou une string
    if (-not $resetAt) { return $null }
    try {
        if ($resetAt -is [DateTime]) {
            $resetUtc = $resetAt.ToUniversalTime()
        } else {
            $resetUtc = [DateTime]::Parse([string]$resetAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        }
        $now   = [DateTime]::UtcNow
        $delta = $resetUtc - $now
        if ($delta.TotalSeconds -le 0) { return 'now' }
        if ($delta.TotalMinutes -lt 60) { return ("{0}m" -f [int]$delta.TotalMinutes) }
        if ($delta.TotalHours -lt 24) {
            return ("{0}h{1:D2}m" -f [int]$delta.TotalHours, $delta.Minutes)
        }
        return ("{0}d{1}h" -f [int]$delta.TotalDays, $delta.Hours)
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

switch ($mode) {
    'bypassPermissions' { $pathColor = RGB 255 121 198 }   # rose vif
    'plan'              { $pathColor = RGB 139 233 253 }   # cyan clair
    'acceptEdits'       { $pathColor = RGB 80  250 123 }   # vert
    'dontAsk'           { $pathColor = RGB 189 147 249 }   # violet
    'auto'              { $pathColor = RGB 255 184 108 }   # orange
    default             { $pathColor = RGB 139 233 253 }   # cyan clair (default)
}

# ============================== BRANCHE GIT ==============================

$branch = $null
$probe = $dir
while ($probe -and -not (Test-Path -LiteralPath (Join-Path $probe '.git'))) {
    $parent = Split-Path -Parent $probe
    if (-not $parent -or $parent -eq $probe) { $probe = $null; break }
    $probe = $parent
}
if ($probe) { $branch = & git -C $dir rev-parse --abbrev-ref HEAD 2>$null }

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

# Cache 60s pour ne pas spammer l'API à chaque refresh statusline
$usageCache = "$env:USERPROFILE\.claude\usage-cache.json"
$usageValid = (Test-Path $usageCache) -and ((Get-Date) - (Get-Item $usageCache).LastWriteTime).TotalSeconds -lt 60
$usage = $null
if ($usageValid) {
    try { $usage = Get-Content -Raw $usageCache | ConvertFrom-Json } catch {}
}
if (-not $usage) {
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
            }
        }
    } catch {}
}

# ============================== ASSEMBLAGE ==============================

$out = "$pathColor$dir$reset"

if ($branch) {
    $out += "  $dim($((RGB 241 250 140))$branch$dim)$reset"
}

if ($usage) {
    $segments = @()

    if ($usage.five_hour -and $null -ne $usage.five_hour.utilization) {
        $pct  = [double]$usage.five_hour.utilization
        $col  = Get-UsageColor $pct
        $bar  = Format-Bar $pct
        $rst  = Format-Reset $usage.five_hour.resets_at
        $seg  = "$dim 5h$reset $col$bar $([int]$pct)%$reset"
        if ($rst) { $seg += " $dim($rst)$reset" }
        $segments += $seg
    }

    if ($usage.seven_day -and $null -ne $usage.seven_day.utilization) {
        $pct  = [double]$usage.seven_day.utilization
        $col  = Get-UsageColor $pct
        $bar  = Format-Bar $pct
        $rst  = Format-Reset $usage.seven_day.resets_at
        $seg  = "$dim 7d$reset $col$bar $([int]$pct)%$reset"
        if ($rst) { $seg += " $dim($rst)$reset" }
        $segments += $seg
    }

    # Opus dédié (plan Max uniquement, sinon utilization = 0 et resets_at = null)
    if ($usage.seven_day_opus -and $usage.seven_day_opus.utilization -gt 0 -and $usage.seven_day_opus.resets_at) {
        $pct  = [double]$usage.seven_day_opus.utilization
        $col  = Get-UsageColor $pct
        $bar  = Format-Bar $pct
        $rst  = Format-Reset $usage.seven_day_opus.resets_at
        $seg  = "$dim opus$reset $col$bar $([int]$pct)%$reset"
        if ($rst) { $seg += " $dim($rst)$reset" }
        $segments += $seg
    }

    if ($segments.Count -gt 0) {
        $out += "  $dim|$reset" + ($segments -join " $dim·$reset")
    }
}

# Compte + plan
$accountPart = @()
if ($plan)  { $accountPart += $plan }
if ($email) { $accountPart += "@ $email" }
if ($accountPart.Count -gt 0) {
    $out += "  $dim|$reset  $($accountPart -join ' ')"
}

Write-Host -NoNewline $out

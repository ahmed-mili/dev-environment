# Check Syncthing sync status + resolve .sync-conflict-* files in .claude.
# Runs as a Claude Code SessionStart hook (after auto-pull).
#
# Part 1: Queries Syncthing REST API for the claude-config folder:
#         folder state (idle/syncing/paused/error), pending items,
#         per-device completion with pending details.
# Part 2: Resolves conflict files (MEMORY.md merge, .md longest wins, .json local wins).

$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ANSI color codes (rendered by Claude Code dark-ansi theme)
$cReset  = "`e[0m"
$cBold   = "`e[1m"
$cDim    = "`e[2m"
$cRed    = "`e[31m"
$cGreen  = "`e[32m"
$cYellow = "`e[33m"
$cBlue   = "`e[34m"
$cCyan   = "`e[36m"
$cGray   = "`e[90m"
$cTag    = "`e[38;5;111m"  # soft blue for [syncthing] tag
$cFolder = "`e[35m"        # magenta for folder name

$claudeDir = "$env:USERPROFILE\.claude"
$folderId = "claude-config"

# --- Part 1: Syncthing status ---
$apiKey = ""
$configPath = $null
$configCandidates = @(
    "$env:LOCALAPPDATA\Syncthing\config.xml",
    "$env:APPDATA\Syncthing\config.xml",
    "$env:PROGRAMDATA\Syncthing\config.xml",
    "$env:USERPROFILE\AppData\Local\Syncthing\config.xml"
)
foreach ($p in $configCandidates) {
    if (Test-Path $p) { $configPath = $p; break }
}

$baseUrl = "http://127.0.0.1:8384"
$irmExtra = @{}
if ($configPath) {
    $config = [xml](Get-Content $configPath -Raw -Encoding UTF8)
    $apiKey = $config.configuration.gui.apikey
    $gui = $config.configuration.gui
    $scheme = if ($gui.tls -eq 'true') { 'https' } else { 'http' }
    $guiAddr = if ($gui.address) { $gui.address } else { '127.0.0.1:8384' }
    $baseUrl = "${scheme}://${guiAddr}"
    if ($scheme -eq 'https') { $irmExtra.SkipCertificateCheck = $true }
}

$lines = @()
$folderLine = $null
$diagMsg = $null

if (-not $configPath) {
    $diagMsg = "config.xml introuvable (cherché dans LOCALAPPDATA, APPDATA, PROGRAMDATA). Syncthing installé ?"
} elseif (-not $apiKey) {
    $diagMsg = "API key vide dans $configPath"
} else {
    $headers = @{ "X-API-Key" = $apiKey }

    # Get local device ID
    $myId = $null
    $apiReachable = $false
    try {
        $sysStatus = Invoke-RestMethod -Uri "$baseUrl/rest/system/status" -Headers $headers -TimeoutSec 5 @irmExtra
        $myId = $sysStatus.myID
        $apiReachable = $true
    } catch {}

    if (-not $apiReachable) {
        $diagMsg = "API $baseUrl injoignable. Syncthing lancé ?"
    } else {
        # Get folder config (paused state)
        $folderResp = $null
        $folderPaused = $false
        try {
            $folderResp = Invoke-RestMethod -Uri "$baseUrl/rest/config/folders/$folderId" -Headers $headers -TimeoutSec 5 @irmExtra
            $folderPaused = $folderResp.paused
        } catch {}

        # Get folder db status (state, need items)
        $dbStatus = $null
        $folderState = $null
        try {
            $dbStatus = Invoke-RestMethod -Uri "$baseUrl/rest/db/status?folder=$folderId" -Headers $headers -TimeoutSec 5 @irmExtra
            $folderState = $dbStatus.state
        } catch {}

        # Helper: format bytes
        function Format-Bytes([long]$b) {
            if ($b -ge 1GB) { "{0:N1} Go" -f ($b / 1GB) }
            elseif ($b -ge 1MB) { "{0:N1} Mo" -f ($b / 1MB) }
            elseif ($b -ge 1KB) { "{0:N1} Ko" -f ($b / 1KB) }
            else { "$b o" }
        }

        # Build folder-level status line
        if ($folderPaused) {
            $folderLine = "Folder ${cFolder}.claude${cReset} : ${cRed}PAUSED${cReset}"
        } elseif ($null -ne $folderState) {
            $stateLabels = @{
                'idle'         = "${cGreen}up to date${cReset}"
                'scanning'     = "${cYellow}scanning...${cReset}"
                'syncing'      = "${cYellow}syncing...${cReset}"
                'sync-waiting' = "${cYellow}waiting${cReset}"
                'error'        = "${cRed}${cBold}! FAILED${cReset}"
                'scan-waiting' = "${cYellow}waiting (scan)${cReset}"
            }
            $label = if ($stateLabels[$folderState]) { $stateLabels[$folderState] } else { $folderState }
            $folderLine = "Folder ${cFolder}.claude${cReset} : $label"

            # Pending local items
            if ($null -ne $dbStatus) {
                $pend = @()
                if ($dbStatus.needTotalItems -gt 0) {
                    $pend += "${cYellow}$($dbStatus.needTotalItems) to receive${cReset}"
                }
                if ($dbStatus.needDeletes -gt 0) {
                    $pend += "${cYellow}$($dbStatus.needDeletes) deletions${cReset}"
                }
                if ($dbStatus.needBytes -gt 0) {
                    $pend += "${cYellow}$(Format-Bytes $dbStatus.needBytes)${cReset}"
                }
                if ($dbStatus.pullErrors -gt 0) {
                    $pend += "${cRed}${cBold}! $($dbStatus.pullErrors) errors${cReset}"
                }
                if ($pend.Count -gt 0) {
                    $lines += "  ${cDim}Pending :${cReset} $($pend -join ', ')"
                }
            }
        } else {
            $folderLine = "Folder ${cFolder}.claude${cReset} : ${cYellow}statut inconnu (folder '$folderId' configuré ?)${cReset}"
        }

        # Get device names + paused from config
        $deviceNames = @{}
        $devicePaused = @{}
        try {
            $devices = Invoke-RestMethod -Uri "$baseUrl/rest/config/devices" -Headers $headers -TimeoutSec 5 @irmExtra
            foreach ($d in $devices) {
                $deviceNames[$d.deviceID] = $d.name
                $devicePaused[$d.deviceID] = $d.paused
            }
        } catch {}

        # Get current connections
        $connections = $null
        try {
            $connections = Invoke-RestMethod -Uri "$baseUrl/rest/system/connections" -Headers $headers -TimeoutSec 5 @irmExtra
        } catch {}

        # Per-device status for claude-config
        if ($null -ne $folderResp -and $null -ne $connections) {
            foreach ($device in $folderResp.devices) {
                $id = $device.deviceID
                if ($id -eq $myId) { continue }

                $name = if ($deviceNames[$id]) { $deviceNames[$id] } else { $id.Substring(0, 7) + "..." }
                $nameC = "${cCyan}$name${cReset}"

                # Device paused
                if ($devicePaused[$id]) {
                    $lines += "  $nameC : ${cGray}paused${cReset}"
                    continue
                }

                $isConnected = $false
                $connInfo = $null
                if ($connections.connections.PSObject.Properties.Name -contains $id) {
                    $connInfo = $connections.connections.$id
                    $isConnected = $connInfo.connected
                }

                if (-not $isConnected) {
                    $lines += "  $nameC : ${cGray}offline${cReset}"
                    continue
                }

                # Build connection detail
                $connDetail = ""
                if ($null -ne $connInfo -and $connInfo.PSObject.Properties.Name -contains 'startedAt') {
                    $started = [DateTime]$connInfo.startedAt
                    $ago = (Get-Date) - $started
                    if ($ago.TotalHours -ge 1) {
                        $connDetail = " ${cDim}(connected $([math]::Floor($ago.TotalHours))h$($ago.Minutes)m)${cReset}"
                    } elseif ($ago.TotalMinutes -ge 1) {
                        $connDetail = " ${cDim}(connected $([math]::Floor($ago.TotalMinutes))m)${cReset}"
                    } else {
                        $connDetail = " ${cDim}(just connected)${cReset}"
                    }
                }

                # Connected: get completion
                $compResp = $null
                try {
                    $compResp = Invoke-RestMethod -Uri "$baseUrl/rest/db/completion?device=$id&folder=$folderId" -Headers $headers -TimeoutSec 5 @irmExtra
                } catch {}

                if ($null -ne $compResp) {
                    $pct = [math]::Round($compResp.completion, 1)
                    $needBytes = $compResp.needBytes
                    if ($pct -eq 100 -and $needBytes -eq 0) {
                        $lines += "  $nameC : ${cGreen}synced${cReset}$connDetail"
                    } else {
                        $pend = @()
                        if ($compResp.needItems -and $compResp.needItems -gt 0) {
                            $pend += "$($compResp.needItems) items"
                        }
                        if ($compResp.needDeletes -and $compResp.needDeletes -gt 0) {
                            $pend += "$($compResp.needDeletes) deletions"
                        }
                        if ($needBytes -gt 0) {
                            $pend += Format-Bytes $needBytes
                        }
                        $pctC = "${cYellow}${pct}%${cReset}"
                        if ($pend.Count -gt 0) {
                            $lines += "  $nameC : $pctC ${cDim}—${cReset} ${cYellow}$($pend -join ', ')${cReset}$connDetail"
                        } else {
                            $lines += "  $nameC : $pctC$connDetail"
                        }
                    }
                } else {
                    $lines += "  $nameC : ${cBlue}online${cReset}$connDetail"
                }
            }
        }
    }
}

# Build syncthing message
$tag = "${cTag}[syncthing]${cReset}"
$syncMsg = ""
if ($diagMsg) {
    $syncMsg = "$tag ${cRed}$diagMsg${cReset}"
} elseif ($folderLine) {
    $syncMsg = "$tag $folderLine"
    if ($lines.Count -gt 0) {
        $syncMsg += "`n" + ($lines -join "`n")
    }
}

# --- Part 2: Resolve sync conflicts ---
$conflitFiles = Get-ChildItem -Path $claudeDir -Recurse -Filter "*.sync-conflict-*"
$resolved = 0
$kept = 0
$details = @()

foreach ($conflict in $conflitFiles) {
    $conflictName = $conflict.Name

    if ($conflictName -match '^(.+)\.sync-conflict-\d{8}-\d{6}-\w+\.(.+)$') {
        $originalName = "$($Matches[1]).$($Matches[2])"
    } elseif ($conflictName -match '^(.+)\.sync-conflict-\d{8}-\d{6}-\w+$') {
        $originalName = $Matches[1]
    } else {
        continue
    }

    $originalPath = Join-Path $conflict.DirectoryName $originalName

    if (-not (Test-Path $originalPath)) {
        Move-Item $conflict.FullName $originalPath -Force
        $resolved++
        $details += "$originalName (promoted)"
        continue
    }

    # MEMORY.md: merge entries
    if ($originalName -eq 'MEMORY.md') {
        $localLines = Get-Content $originalPath -ErrorAction SilentlyContinue
        $conflictLines = Get-Content $conflict.FullName -ErrorAction SilentlyContinue

        $merged = [System.Collections.Specialized.OrderedDictionary]::new()

        foreach ($line in $localLines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\- \[.+?\]\((.+?)\)') {
                $key = $Matches[1]
                if (-not $merged.Contains($key)) {
                    $merged[$key] = $trimmed
                }
            }
        }
        foreach ($line in $conflictLines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\- \[.+?\]\((.+?)\)') {
                $key = $Matches[1]
                if (-not $merged.Contains($key)) {
                    $merged[$key] = $trimmed
                }
            }
        }

        $newContent = ($merged.Values -join "`n") + "`n"
        Set-Content -Path $originalPath -Value $newContent -NoNewline
        Remove-Item $conflict.FullName
        $resolved++
        $details += "$originalName (merged, $($merged.Count) entries)"
        continue
    }

    # .json: keep local
    if ($originalName -match '\.json$') {
        Remove-Item $conflict.FullName
        $kept++
        $details += "$originalName (kept local)"
        continue
    }

    # Other .md: keep longer
    if ($originalName -match '\.md$') {
        $localLen = (Get-Content $originalPath -Raw -ErrorAction SilentlyContinue).Length
        $conflictLen = (Get-Content $conflict.FullName -Raw -ErrorAction SilentlyContinue).Length

        if ($conflictLen -gt $localLen) {
            Copy-Item $conflict.FullName $originalPath -Force
            $resolved++
            $details += "$originalName (kept longer version)"
        } else {
            $resolved++
            $details += "$originalName (kept local)"
        }
        Remove-Item $conflict.FullName
        continue
    }

    # Unknown: keep local
    Remove-Item $conflict.FullName
    $kept++
    $details += "$originalName (kept local)"
}

# --- Output ---
$messages = @()
if ($syncMsg) { $messages += $syncMsg }
if ($resolved -gt 0 -or $kept -gt 0) {
    $messages += "$tag conflicts: ${cGreen}$resolved merged${cReset}, ${cYellow}$kept kept local${cReset}. ${cDim}" + ($details -join '; ') + "${cReset}"
}

if ($messages.Count -gt 0) {
    @{ systemMessage = ($messages -join ' | ') } | ConvertTo-Json -Compress
}

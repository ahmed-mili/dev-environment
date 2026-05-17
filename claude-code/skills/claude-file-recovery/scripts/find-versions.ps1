# find-versions.ps1 — Helper pour le skill claude-file-recovery
#
# Scanne ~/.claude/file-history/ et ~/.claude/projects/ pour localiser les sources
# de récupération d'un fichier perdu/écrasé dans ~/.claude/.
#
# Usage :
#   .\find-versions.ps1 -Marker 'five_hour' -Filename 'statusline.ps1'
#   .\find-versions.ps1 -Marker 'permissions' -Filename 'settings.json' -MaxResults 5
#
# Paramètres :
#   -Marker     : string unique au contenu du fichier perdu (ex. "five_hour" pour la
#                 statusline). Sert à grep dans file-history/. Choisir un marker stable
#                 que les versions intermédiaires partagent toutes.
#   -Filename   : nom du fichier perdu (ex. "statusline.ps1"). Sert à matcher dans les
#                 transcripts JSONL.
#   -MaxResults : nombre max de résultats par catégorie. Défaut 10.
#   -HomeDir    : override du dossier ~/.claude/. Défaut $env:USERPROFILE\.claude.
#
# Sortie :
#   Section 1 — Snapshots file-history triés par mtime décroissant (le 1er = candidat n°1
#   à restaurer comme base).
#   Section 2 — Sessions transcripts qui ont touché le fichier, triées par mtime. Le
#   transcript le plus récent contient probablement les Edits post-dernier-snapshot
#   à appliquer après la restauration de la base.
#
# Pas de privilèges admin requis : tout est dans le profil user.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Marker,

    [Parameter(Mandatory=$true)]
    [string]$Filename,

    [int]$MaxResults = 10,

    [string]$HomeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'

# UTF-8 stdout pour que les accents français (è é à ô) s'affichent correctement
# dans Windows Terminal / pwsh (sinon CP850/CP1252 → "é" devient "�").
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

if (-not (Test-Path $HomeDir)) {
    Write-Error "HomeDir introuvable : $HomeDir"
    exit 1
}

$fileHistoryDir = Join-Path $HomeDir 'file-history'
$projectsDir    = Join-Path $HomeDir 'projects'

# ============================== SNAPSHOTS FILE-HISTORY ==============================

Write-Host ""
Write-Host "=== SNAPSHOTS file-history contenant '$Marker' ===" -ForegroundColor Cyan
Write-Host "  (le candidat n°1 à restaurer est celui en haut)" -ForegroundColor DarkGray
Write-Host ""

if (-not (Test-Path $fileHistoryDir)) {
    Write-Host "  (file-history dir absent — pas de snapshots disponibles)" -ForegroundColor Yellow
} else {
    $snapshots = Get-ChildItem $fileHistoryDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            # SimpleMatch évite l'interprétation regex du marker. -Quiet pour perf.
            Select-String -Path $_.FullName -Pattern $Marker -Quiet -SimpleMatch -ErrorAction SilentlyContinue
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxResults

    if (-not $snapshots) {
        Write-Host "  AUCUN snapshot trouvé contenant '$Marker'." -ForegroundColor Yellow
        Write-Host "  → Vérifier l'orthographe du marker, ou essayer un marker différent." -ForegroundColor DarkGray
        Write-Host "  → Si toujours rien : voir 'Cas spéciaux' du SKILL.md (file-history vide, etc.)." -ForegroundColor DarkGray
    } else {
        $snapshots | ForEach-Object {
            # Extraire l'UUID de session (= nom du dossier parent direct)
            $sessionUuid = Split-Path -Leaf (Split-Path -Parent $_.FullName)
            [PSCustomObject]@{
                Mtime       = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                Size        = "$([Math]::Round($_.Length / 1KB, 1)) KB"
                Version     = $_.Name
                SessionUuid = $sessionUuid
                Path        = $_.FullName
            }
        } | Format-Table Mtime, Size, Version, SessionUuid -AutoSize
    }
}

# ============================== TRANSCRIPTS PROJECTS ==============================

Write-Host ""
Write-Host "=== TRANSCRIPTS qui mentionnent '$Filename' ===" -ForegroundColor Cyan
Write-Host "  (le plus récent contient probablement les Edits post-dernier-snapshot)" -ForegroundColor DarkGray
Write-Host ""

if (-not (Test-Path $projectsDir)) {
    Write-Host "  (projects dir absent — pas de transcripts disponibles)" -ForegroundColor Yellow
} else {
    $transcripts = Get-ChildItem $projectsDir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        ForEach-Object {
            # Count = nombre de refs au filename. Un fichier intensivement modifié a beaucoup de refs.
            $count = 0
            try {
                $count = (Select-String -Path $_.FullName -Pattern $Filename -SimpleMatch -ErrorAction SilentlyContinue).Count
            } catch {}
            if ($count -gt 0) {
                [PSCustomObject]@{
                    Mtime    = $_.LastWriteTime
                    RefCount = $count
                    Session  = $_.BaseName    # = UUID sans .jsonl
                    Path     = $_.FullName
                }
            }
        } |
        Sort-Object Mtime -Descending |
        Select-Object -First $MaxResults

    if (-not $transcripts) {
        Write-Host "  AUCUN transcript ne mentionne '$Filename'." -ForegroundColor Yellow
        Write-Host "  → Le fichier n'a peut-être jamais été touché par Claude Code (édité via éditeur externe)." -ForegroundColor DarkGray
        Write-Host "  → Voir 'Cas spéciaux' du SKILL.md (Windows File History, etc.)." -ForegroundColor DarkGray
    } else {
        $transcripts | ForEach-Object {
            [PSCustomObject]@{
                Mtime    = $_.Mtime.ToString('yyyy-MM-dd HH:mm:ss')
                RefCount = $_.RefCount
                Session  = $_.Session
            }
        } | Format-Table -AutoSize
    }
}

# ============================== CROSS-REFERENCE ==============================

if ($snapshots -and $transcripts) {
    Write-Host ""
    Write-Host "=== CROSS-REFERENCE snapshot ↔ transcript ===" -ForegroundColor Cyan
    Write-Host ""

    $topSnapSession = (Split-Path -Leaf (Split-Path -Parent $snapshots[0].FullName))
    $topTransSession = $transcripts[0].Session

    if ($topSnapSession -eq $topTransSession) {
        Write-Host "  Le snapshot le plus récent ET le transcript le plus récent partagent la même session :" -ForegroundColor Green
        Write-Host "    UUID : $topSnapSession" -ForegroundColor Green
        Write-Host "  → Lire le snapshot, puis chercher dans ce transcript les Edits postérieurs à $($snapshots[0].LastWriteTime)." -ForegroundColor Green
    } else {
        Write-Host "  Snapshot le plus récent dans session : $topSnapSession" -ForegroundColor Yellow
        Write-Host "  Transcript le plus récent           : $topTransSession" -ForegroundColor Yellow
        Write-Host "  → Sessions différentes. Vérifier les DEUX transcripts pour les Edits post-snapshot." -ForegroundColor Yellow
    }
}

# ============================== NEXT STEPS ==============================

Write-Host ""
Write-Host "=== PROCHAINES ÉTAPES ===" -ForegroundColor Cyan
Write-Host "  1. Lire le snapshot file-history le plus récent (Read complet)" -ForegroundColor White
Write-Host "  2. Dans le transcript correspondant, chercher les Edits postérieurs au mtime du snapshot :" -ForegroundColor White
Write-Host "     Select-String -Path <transcript.jsonl> -Pattern '`"name`":`"Edit`"' | Where-Object { `$_.Line -match '$Filename' }" -ForegroundColor DarkGray
Write-Host "  3. Extraire old_string/new_string de chaque Edit, les appliquer dans l'ordre chronologique" -ForegroundColor White
Write-Host "  4. cp vers le path réel + sync vers le repo dev-environment si applicable" -ForegroundColor White
Write-Host "  5. Tester le fichier reconstruit" -ForegroundColor White
Write-Host ""

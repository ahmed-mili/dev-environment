# deploy-status.ps1 — Helper pour le skill deploy-safety
#
# Compare la fraîcheur (mtime + contenu) de chaque fichier tracked par deploy.ps1
# entre ~/.claude/ et C:\dev\dev-environment\claude-code\. Sert à éviter qu'un
# `deploy.ps1 -Pull` n'écrase du travail local plus récent que le repo.
#
# Usage :
#   .\deploy-status.ps1                  # check standard, tableau coloré
#   .\deploy-status.ps1 -Detailed        # affiche aussi les hashes
#   .\deploy-status.ps1 -RepoRoot <path> # override le path du repo
#
# Exit codes :
#   0 = Tous les verdicts sont safe pour -Pull (IDENTICAL, REPO NEWER, REPO ONLY).
#   1 = Au moins un fichier en LOCAL NEWER → -Pull dangereux. Faire -Push d'abord.
#   2 = Erreur de configuration (repo introuvable, etc.).
#
# Pas de privilèges admin requis.

[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\dev\dev-environment\claude-code',
    [string]$HomeDir  = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

if (-not (Test-Path $RepoRoot)) {
    Write-Error "Repo introuvable : $RepoRoot"
    exit 2
}
if (-not (Test-Path $HomeDir)) {
    Write-Error "HomeDir introuvable : $HomeDir"
    exit 2
}

# Liste des fichiers tracked par deploy.ps1 (extraite manuellement du script).
# Si deploy.ps1 évolue, mettre à jour cette liste — ou mieux, parser deploy.ps1.
$CustomSkills = @(
    'claude-file-recovery', 'copy-edit', 'css-layout-check', 'deploy-safety',
    'edit-block', 'lucide-icons', 'release', 'root-cause-fix', 'smart-edit',
    'sticky-column-bleed-fix', 'webapp-deploy'
)

# Construire la liste des paires à comparer
$pairs = [System.Collections.Generic.List[object]]::new()

# Fichiers single
foreach ($f in @('statusline.ps1', 'settings.json')) {
    $pairs.Add(@{
        Relative = $f
        Repo     = Join-Path $RepoRoot $f
        Local    = Join-Path $HomeDir  $f
        Kind     = 'File'
    })
}

# Hooks (tous les fichiers du dossier hooks/ du repo)
$repoHooks = Join-Path $RepoRoot 'hooks'
if (Test-Path $repoHooks) {
    foreach ($hookFile in Get-ChildItem $repoHooks -File -ErrorAction SilentlyContinue) {
        $rel = "hooks/$($hookFile.Name)"
        $pairs.Add(@{
            Relative = $rel
            Repo     = $hookFile.FullName
            Local    = Join-Path $HomeDir $rel
            Kind     = 'File'
        })
    }
}

# Skills custom (dossier entier, on compare le SKILL.md comme proxy + on signale
# si d'autres fichiers ont changé dedans)
foreach ($s in $CustomSkills) {
    $repoSkillMd  = Join-Path $RepoRoot "skills/$s/SKILL.md"
    $localSkillMd = Join-Path $HomeDir  "skills/$s/SKILL.md"
    $pairs.Add(@{
        Relative = "skills/$s/SKILL.md"
        Repo     = $repoSkillMd
        Local    = $localSkillMd
        Kind     = 'Skill'
    })
}

# ============================== ANALYSE ==============================

function Get-FileHashSafe($path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-FileHash -Path $path -Algorithm SHA256).Hash } catch { return $null }
}

$results = foreach ($p in $pairs) {
    $repoExists  = Test-Path $p.Repo
    $localExists = Test-Path $p.Local

    $repoMtime  = if ($repoExists)  { (Get-Item $p.Repo).LastWriteTime  } else { $null }
    $localMtime = if ($localExists) { (Get-Item $p.Local).LastWriteTime } else { $null }

    $verdict = $null
    if (-not $repoExists -and -not $localExists) {
        $verdict = 'MISSING BOTH'
    } elseif (-not $repoExists) {
        $verdict = 'LOCAL ONLY'
    } elseif (-not $localExists) {
        $verdict = 'REPO ONLY'
    } else {
        # Hash compare pour les fichiers de taille raisonnable — si égaux, mtime ignoré
        $repoHash  = Get-FileHashSafe $p.Repo
        $localHash = Get-FileHashSafe $p.Local
        if ($repoHash -and $localHash -and $repoHash -eq $localHash) {
            $verdict = 'IDENTICAL'
        } elseif ($localMtime -gt $repoMtime) {
            $verdict = 'LOCAL NEWER'
        } elseif ($repoMtime -gt $localMtime) {
            $verdict = 'REPO NEWER'
        } else {
            $verdict = 'DIFFERENT (same mtime)'
        }
    }

    [PSCustomObject]@{
        File       = $p.Relative
        LocalMtime = if ($localMtime) { $localMtime.ToString('MM-dd HH:mm:ss') } else { '-' }
        RepoMtime  = if ($repoMtime)  { $repoMtime.ToString('MM-dd HH:mm:ss')  } else { '-' }
        Verdict    = $verdict
        _Sort      = switch ($verdict) {
            'LOCAL NEWER'           { 1 }
            'DIFFERENT (same mtime)' { 2 }
            'LOCAL ONLY'            { 3 }
            'REPO ONLY'             { 4 }
            'REPO NEWER'            { 5 }
            'IDENTICAL'             { 6 }
            default                 { 9 }
        }
    }
}

# Trier : LOCAL NEWER en premier (les plus urgents à voir)
$results = $results | Sort-Object _Sort, File

# ============================== AFFICHAGE ==============================

Write-Host ""
Write-Host "=== DEPLOY STATUS : ~/.claude/  ↔  $RepoRoot  ===" -ForegroundColor Cyan
Write-Host ""

# Affichage coloré ligne par ligne (Format-Table n'a pas de couleur conditionnelle)
$headerFmt = "{0,-50}  {1,-15}  {2,-15}  {3}"
Write-Host ($headerFmt -f 'File', 'Local Mtime', 'Repo Mtime', 'Verdict') -ForegroundColor White
Write-Host ($headerFmt -f ('-' * 50), ('-' * 15), ('-' * 15), ('-' * 20)) -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = switch ($r.Verdict) {
        'LOCAL NEWER'            { 'Red' }
        'DIFFERENT (same mtime)' { 'Yellow' }
        'LOCAL ONLY'             { 'Yellow' }
        'REPO ONLY'              { 'Cyan' }
        'REPO NEWER'             { 'Green' }
        'IDENTICAL'              { 'DarkGray' }
        default                  { 'White' }
    }
    Write-Host ($headerFmt -f $r.File, $r.LocalMtime, $r.RepoMtime, $r.Verdict) -ForegroundColor $color
}

# ============================== VERDICT GLOBAL ==============================

$dangerCount = ($results | Where-Object { $_.Verdict -eq 'LOCAL NEWER' }).Count
$diffCount   = ($results | Where-Object { $_.Verdict -eq 'DIFFERENT (same mtime)' }).Count

Write-Host ""
if ($dangerCount -gt 0) {
    Write-Host "VERDICT : -Pull DANGEREUX" -ForegroundColor Red
    Write-Host "  $dangerCount fichier(s) en LOCAL NEWER seraient écrasés par -Pull." -ForegroundColor Red
    Write-Host ""
    Write-Host "Actions recommandées :" -ForegroundColor Yellow
    Write-Host "  1. RECOMMANDÉ : .\deploy.ps1 -Push  (propage le travail local au repo)" -ForegroundColor White
    Write-Host "  2. Puis (si tu veux quand même Pull) : .\deploy.ps1 -Pull  (sera safe après Push)" -ForegroundColor White
    Write-Host "  3. ALTERNATIVE ciblée : cp <repo-file> ~/.claude/<file> pour UN seul fichier" -ForegroundColor White
    Write-Host "  4. DERNIER RECOURS : demander à l'user si l'écrasement est OK" -ForegroundColor White
    exit 1
} elseif ($diffCount -gt 0) {
    Write-Host "VERDICT : -Pull POSSIBLE mais inspecter les DIFFÉRENCES" -ForegroundColor Yellow
    Write-Host "  $diffCount fichier(s) ont des contenus différents avec mtimes identiques (rare)." -ForegroundColor Yellow
    Write-Host "  À investiguer manuellement avant -Pull." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "VERDICT : -Pull SAFE" -ForegroundColor Green
    Write-Host "  Tous les fichiers sont IDENTICAL, REPO NEWER, ou REPO ONLY. -Pull peut procéder." -ForegroundColor Green
    exit 0
}

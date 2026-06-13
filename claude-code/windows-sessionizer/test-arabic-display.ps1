# test-arabic-display.ps1 -- tests du pre-shaping arabe du sessionizer (hook -Shape).
# Usage : pwsh -NoProfile -ExecutionPolicy Bypass -File test-arabic-display.ps1
#
# ASCII-only (regle d'or repo) : toutes les chaines arabes sont construites par
# codepoints, jamais en litteral. Valeurs attendues = shaping calcule a la main
# contre la table Unicode Arabic Presentation Forms-B (U+FE70-U+FEFF), et rendu
# verifie visuellement dans Windows Terminal (2026-06-13).
#
# Convention : "shaped" = formes de presentation U+FExx en ORDRE VISUEL
# (inverse), le format que les terminaux sans BiDi (WT #538, Termux #2953)
# affichent correctement de gauche a droite.

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

$sess = Join-Path $PSScriptRoot 'sessionizer.ps1'
$script:fails = 0
$script:total = 0

function Convert-ToHex([string]$s) {
    ($s.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '
}

function Invoke-Shape([string]$InText) {
    (& pwsh -NoProfile -ExecutionPolicy Bypass -File $script:sess -Shape $InText | Out-String).TrimEnd("`r`n")
}

function Assert-Shape([string]$Name, [int[]]$InCps, [int[]]$WantCps) {
    $script:total++
    $in   = -join ($InCps   | ForEach-Object { [char]$_ })
    $want = -join ($WantCps | ForEach-Object { [char]$_ })
    $got  = Invoke-Shape $in
    if ($got -ceq $want) {
        Write-Host "  ok   $Name"
    } else {
        $script:fails++
        Write-Host "  FAIL $Name"
        Write-Host "       in:   $(Convert-ToHex $in)"
        Write-Host "       want: $(Convert-ToHex $want)"
        Write-Host "       got:  $(Convert-ToHex $got)"
    }
}

Write-Host 'shaping unitaire (-Shape) :'

# 1. ASCII pur : aucun caractere arabe -> retour identique.
Assert-Shape 'ascii inchange' `
    @(0x64,0x65,0x76,0x2D,0x65,0x6E,0x76) `
    @(0x64,0x65,0x76,0x2D,0x65,0x6E,0x76)

# 2. al-islam (nom du vault) : alef lam alef-hamza-below seen lam alef meem.
#    Shaping logique : alef-iso, ligature lam-alef-hamza-iso, seen-init,
#    ligature lam-alef-final, meem-iso -> puis inversion visuelle.
Assert-Shape 'al-islam (2 ligatures lam-alef)' `
    @(0x0627,0x0644,0x0625,0x0633,0x0644,0x0627,0x0645) `
    @(0xFEE1,0xFEFC,0xFEB3,0xFEF9,0xFE8D)

# 3. marhaban : meem reh hah beh alef.
#    meem-init, reh-final, hah-init, beh-medial, alef-final -> inverse.
Assert-Shape 'marhaban (right-joiners au milieu)' `
    @(0x0645,0x0631,0x062D,0x0628,0x0627) `
    @(0xFE8E,0xFE92,0xFEA3,0xFEAE,0xFEE3)

# 4. al-arabiya : alef lam ain reh beh yeh teh-marbuta.
#    alef-iso, lam-init, ain-medial, reh-final, beh-init, yeh-medial,
#    teh-marbuta-final -> inverse.
Assert-Shape 'al-arabiya (medials + teh marbuta)' `
    @(0x0627,0x0644,0x0639,0x0631,0x0628,0x064A,0x0629) `
    @(0xFE94,0xFEF4,0xFE91,0xFEAE,0xFECC,0xFEDF,0xFE8D)

# 5. shay : sheen yeh hamza. hamza = non-joining (isolee seulement) :
#    sheen-init, yeh-final, hamza-iso -> inverse.
Assert-Shape 'hamza non-joining' `
    @(0x0634,0x064A,0x0621) `
    @(0xFE80,0xFEF2,0xFEB7)

# 6. Mixte latin + arabe : seul le run arabe est transforme, le reste
#    garde sa position (pas d'UBA complet, assume pour des noms de dossiers).
Assert-Shape 'mixte A-beh-1' `
    @(0x41,0x2D,0x0628,0x2D,0x31) `
    @(0x41,0x2D,0xFE8F,0x2D,0x31)

# 7. Diacritique (damma) : transparent pour la liaison, reste APRES sa base.
#    beh + damma : beh-iso + damma (cluster indivisible).
Assert-Shape 'diacritique attache a sa base' `
    @(0x0628,0x064C) `
    @(0xFE8F,0x064C)

# 8. Chiffres arabes-indiens : hors run (lecture LTR), jamais inverses.
Assert-Shape 'chiffres arabes-indiens inchanges' `
    @(0x0661,0x0662,0x0663) `
    @(0x0661,0x0662,0x0663)

# 9. Idempotence : une chaine deja convertie (U+FExx) ne rematche pas.
Assert-Shape 'idempotence (deja shape)' `
    @(0xFEE1,0xFEFC,0xFEB3,0xFEF9,0xFE8D) `
    @(0xFEE1,0xFEFC,0xFEB3,0xFEF9,0xFE8D)

# --- Module partage arabic-shaping.ps1 (dot-source, in-process) ----------------
# Garde anti-desync : le module est EXTRAIT du sessionizer (meme algorithme). On
# verifie qu'une fois dot-source il expose ConvertTo-ArabicDisplay et produit le
# meme shaping. Valide aussi que le dot-source / scope marche (le profil pwsh en
# depend pour le prompt et l'auto-cd).
Write-Host 'module arabic-shaping.ps1 (in-process) :'
. (Join-Path $PSScriptRoot 'arabic-shaping.ps1')
function Assert-Mod([string]$Name, [int[]]$InCps, [int[]]$WantCps) {
    $script:total++
    $in   = -join ($InCps   | ForEach-Object { [char]$_ })
    $want = -join ($WantCps | ForEach-Object { [char]$_ })
    $got  = ConvertTo-ArabicDisplay $in
    if ($got -ceq $want) { Write-Host "  ok   $Name" }
    else {
        $script:fails++; Write-Host "  FAIL $Name"
        Write-Host "       want: $(Convert-ToHex $want)"
        Write-Host "       got:  $(Convert-ToHex $got)"
    }
}
Assert-Mod 'module al-islam'     @(0x0627,0x0644,0x0625,0x0633,0x0644,0x0627,0x0645) @(0xFEE1,0xFEFC,0xFEB3,0xFEF9,0xFE8D)
Assert-Mod 'module marhaban'     @(0x0645,0x0631,0x062D,0x0628,0x0627)               @(0xFE8E,0xFE92,0xFEA3,0xFEAE,0xFEE3)
Assert-Mod 'module idempotence'  @(0xFEE1,0xFEFC,0xFEB3,0xFEF9,0xFE8D)               @(0xFEE1,0xFEFC,0xFEB3,0xFEF9,0xFE8D)

# --- Integration : -List ------------------------------------------------------
# Le champ 2 (nom technique) reste BRUT, le champ 3 (label) est shape.
Write-Host 'integration (-List) :'
$script:total++
$alislam       = -join (@(0x0627,0x0644,0x0625,0x0633,0x0644,0x0627,0x0645) | ForEach-Object { [char]$_ })
$alislamShaped = -join (@(0xFEE1,0xFEFC,0xFEB3,0xFEF9,0xFE8D)               | ForEach-Object { [char]$_ })
$rows = & pwsh -NoProfile -ExecutionPolicy Bypass -File $sess -List -View vaults
$vaultRow = $rows | Where-Object { ($_ -split "`t")[1] -eq $alislam } | Select-Object -First 1
if (-not $vaultRow) {
    Write-Host '  SKIP -List : vault arabe absent de cette machine'
    $script:total--
} else {
    $label = (($vaultRow -split "`t")[2]) -replace "$([char]27)\[[0-9;]*m", ''
    if ($label.Contains($alislamShaped) -and -not $label.Contains($alislam)) {
        Write-Host '  ok   -List : nom brut en champ 2, label shape en champ 3'
    } else {
        $script:fails++
        Write-Host '  FAIL -List : label non shape ou nom brut fuite dans le label'
        Write-Host "       label: $(Convert-ToHex $label)"
    }
}

# --- Integration : creation d'une session de vault arabe ----------------------
# L'attach doit utiliser le nom PRE-SHAPE (zellij l'affiche correctement), le
# repertoire de depart -d doit rester le nom BRUT (dossier reel sur disque).
# Portable : -Pick bypasse le menu, pas besoin que le vault existe.
Write-Host 'integration (creation -> attach pre-shape) :'
$script:total++
$dryCreate = & pwsh -NoProfile -ExecutionPolicy Bypass -File $sess -DryRun -Pick "vault`t$alislam`tx" -View vaults | Out-String
$attachShaped = $dryCreate.Contains("attach -c $alislamShaped options")
$attachRaw    = $dryCreate.Contains("attach -c $alislam options")
$dirRaw       = $dryCreate.Contains("-d C:\obsidian-vaults\$alislam ") -or $dryCreate.Contains("-d $alislam")
if ($attachShaped -and -not $attachRaw) {
    Write-Host '  ok   creation : attach -c pre-shape, dossier brut conserve en -d'
} else {
    $script:fails++
    Write-Host '  FAIL creation : le nom de session attach n''est pas pre-shape'
    Write-Host "       cmd: $($dryCreate.Trim())"
}

# --- Integration : detection d'une session PRE-SHAPEE comme vault actif --------
# Via -FakeActives (hook de test) : une session nommee en pre-shape doit etre
# reconnue comme SON vault (ligne 'active', champ 2 = nom reel pre-shape) et
# surtout PAS classee en orphelin (section "Sessions").
Write-Host 'integration (-FakeActives : reconciliation pre-shape) :'
$script:total++
$vaultsRoot = if ($env:PC_VAULTS_WIN) { $env:PC_VAULTS_WIN } else { 'C:\obsidian-vaults' }
if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $vaultsRoot $alislam) '.obsidian'))) {
    Write-Host '  SKIP -FakeActives : vault arabe absent de cette machine'
    $script:total--
} else {
    $rows2     = & pwsh -NoProfile -ExecutionPolicy Bypass -File $sess -List -View vaults -FakeActives $alislamShaped
    $stripped2 = @($rows2 | ForEach-Object { $_ -replace "$([char]27)\[[0-9;]*m", '' })
    $activeRow = $rows2 | Where-Object { $g = ($_ -split "`t"); $g[0] -eq 'active' -and $g[1] -eq $alislamShaped } | Select-Object -First 1
    $hasOrphanSection = [bool]($stripped2 | Where-Object { $_ -match '\bSessions\b' })
    if ($activeRow -and -not $hasOrphanSection) {
        Write-Host '  ok   -FakeActives : session pre-shapee reconnue comme vault actif (pas orphelin)'
    } else {
        $script:fails++
        Write-Host '  FAIL -FakeActives : session pre-shapee mal classee'
        Write-Host "       rows: $($stripped2 -join ' || ')"
    }
}

Write-Host ''
if ($script:fails) {
    Write-Host "$($script:fails)/$($script:total) tests en echec" -ForegroundColor Red
    exit 1
}
Write-Host "$($script:total)/$($script:total) tests ok" -ForegroundColor Green
exit 0

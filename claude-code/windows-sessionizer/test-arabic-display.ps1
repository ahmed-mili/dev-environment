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

Write-Host ''
if ($script:fails) {
    Write-Host "$($script:fails)/$($script:total) tests en echec" -ForegroundColor Red
    exit 1
}
Write-Host "$($script:total)/$($script:total) tests ok" -ForegroundColor Green
exit 0

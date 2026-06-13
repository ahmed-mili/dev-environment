# arabic-shaping.ps1 -- pre-shaping arabe pour terminaux sans BiDi (fonctions pures).
# SOURCE CANONIQUE EXTRAITE de sessionizer.ps1 (meme algorithme, byte-identique).
# Dot-source ce fichier pour exposer ConvertTo-ArabicDisplay sans effet de bord.
# Terminaux cibles : Windows Terminal (#538), Termux (#2953), Zellij natif -- aucun
# n'applique l'algorithme bidirectionnel Unicode ni le shaping contextuel : un nom
# arabe brut sort inverse ET deconnecte. Parade : formes de presentation U+FExx en
# ordre visuel. ConvertTo-ArabicDisplay est IDEMPOTENT et IDENTITE sur l'ASCII.
# ASCII-only (regle repo) : les codepoints arabes sont numeriques, jamais litteraux.
#
# Tests : test-arabic-display.ps1 (dont un cross-check exhaustif module <-> sessionizer).

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


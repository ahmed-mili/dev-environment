# error-vault-trigger.ps1 -- hook UserPromptSubmit (fail-open, budget < 300 ms)
# Detecte une phrase de correction/repetition dans le prompt utilisateur et
# rappelle a Claude de consulter puis alimenter ~/.claude/skills/error-vault.
# Sans match : aucune sortie (aucun contexte injecte). Ne bloque JAMAIS le
# prompt : toute erreur interne est avalee et on sort en 0.
# ASCII-only (regle dev-environment) : le prompt est normalise sans
# diacritiques avant le match, la regex est donc en ASCII pur.
$ErrorActionPreference = 'SilentlyContinue'
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $json = $raw | ConvertFrom-Json
    $prompt = [string]$json.prompt
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

    # Normalisation : minuscules puis suppression des marques diacritiques
    # (les variantes accentuees et non accentuees deviennent identiques).
    $norm = $prompt.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new($norm.Length)
    foreach ($ch in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $flat = $sb.ToString()

    $rx = 'je t.{0,3}ai deja|deja (dit|demande|explique|corrige)|combien de fois|encore (une fois|la meme|pareil|faux|rate|casse)|arrete de|(ne )?refais (pas|plus) (ca|la meme)|tu (recommences|refais la meme)|meme erreur|toujours (pas compris|la meme erreur)|c.{0,2}etait deja|tu l.{0,3}avais deja'
    if ($flat -match $rx) {
        # Sortie au format hook UserPromptSubmit (JSON, cf. doc hooks.md) :
        # additionalContext est injecte dans le contexte avant traitement.
        $msg = 'RAPPEL error-vault : phrase de correction/repetition detectee dans ce prompt. AVANT de repondre : (1) lire la categorie concernee dans ~/.claude/skills/error-vault/ (index dans SKILL.md) ; (2) appliquer la correction ; (3) ajouter ou incrementer l entree (errors/<categorie>.md ou preferences.md) et mettre a jour l index ; (4) consigne repetee 2 fois ou plus -> proposer sa promotion en regle CLAUDE.md.'
        $payload = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $msg } }
        $json = $payload | ConvertTo-Json -Depth 5 -Compress
        # UTF-8 SANS BOM, ecrit directement sur stdout : un BOM en tete fait
        # tomber le parseur de hooks en mode "plain text" (vu au debug log).
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
        $stdout = [Console]::OpenStandardOutput()
        $stdout.Write($bytes, 0, $bytes.Length)
        $stdout.Flush()
    }
} catch { }
exit 0

# clip-watcher.ps1 v4 — surveille le clipboard Windows, convertit en PNG, puis
# REMPLACE le clipboard Windows par un marker texte court (pas Clear!) pour
# neutraliser WSLg.
#
# CAUSE RACINE v4 (2026-05-28, après repro contrôlée du bug "WSLg storm") :
# `[Clipboard]::Clear()` met Win dans un état "vide" que WSLg essaie de propager
# AGRESSIVEMENT vers Wayland en continu (chaque changement Wayland → re-sync
# Win-vide → kill notre wl-copy). Boucle infinie : bridge perd 100% du temps.
#
# Découverte clé : avec Win clipboard = TEXTE NON-VIDE, WSLg laisse Wayland
# tranquille (vérifié : wl-copy image/png tient 10s+ stable). Donc on remplace
# Clear() par SetText d'un marker court. WSLg sync ce texte une fois vers
# Wayland (text/plain), puis notre wl-copy image/png l'écrase, et WSLg ne
# revient pas combattre (Win a un état stable, pas vide).
#
# v3 (Clear) : Win clipboard vide après détection — l'effet de bord historique
# (pas collable Paint/Word) était déjà accepté. v4 (SetText marker) garde le
# même compromis user-side (Win ne contient plus l'image originale) tout en
# corrigeant la bataille avec WSLg.
#
# Polling 50ms.

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$outFile  = "\\wsl.localhost\Ubuntu\tmp\clip-latest.png"
$flagFile = "\\wsl.localhost\Ubuntu\tmp\clip-latest.flag"
$lastHash = ""

while ($true) {
    try {
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if ($img -ne $null) {
            $ms = New-Object System.IO.MemoryStream
            $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bytes = $ms.ToArray()
            $ms.Dispose(); $img.Dispose()

            $md5  = [System.Security.Cryptography.MD5]::Create()
            $hash = -join ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
            $md5.Dispose()

            if ($hash -ne $lastHash) {
                # Écrire le PNG + flag AVANT de remplacer le Win clipboard
                [System.IO.File]::WriteAllBytes($outFile, $bytes)
                [System.IO.File]::WriteAllText($flagFile, $hash)
                $lastHash = $hash
                # NE PAS Clear() — ça déclenche la "WSLg empty-storm" qui écrase
                # notre wl-copy en boucle. À la place, SetText d'un marker court :
                # WSLg sync ce texte vers Wayland UNE fois, puis se calme. Notre
                # wl-copy image/png posé après par le bridge tient stable.
                [System.Windows.Forms.Clipboard]::SetText("__clip-watcher__")
            }
        } else {
            # Clipboard Windows ne contient plus d'image (par nous via SetText,
            # ou par l'user qui a copié autre chose). Reset pour redétecter une
            # éventuelle re-copie de la même image plus tard.
            $lastHash = ""
        }
    } catch {}
    Start-Sleep -Milliseconds 50
}

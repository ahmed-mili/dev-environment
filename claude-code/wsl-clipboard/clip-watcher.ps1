# clip-watcher.ps1 v5 — surveille le clipboard Windows, convertit toute image en
# PNG pour Wayland/Alt+V, et LAISSE l'image INTACTE dans le clipboard Windows
# (collable Paint/Word/autre app/autre Claude).
#
# ÉVOLUTION v4 -> v5 (2026-05-28, après repro contrôlée + instrumentation) :
# v4 remplaçait l'image par un marker texte `SetText("__clip-watcher__")` pour
# neutraliser la "WSLg empty-storm". Effet de bord assumé à l'époque : l'image
# disparaissait du clipboard Windows (plus collable ailleurs).
#
# L'instrumentation (image laissée dans Win + wl-copy PNG, mesuré 20s) montre que
# ce compromis était INUTILE : la storm WSLg n'était déclenchée QUE par l'état
# "vide-sentinel" du `[Clipboard]::Clear()` (v3). Une IMAGE laissée dans le
# clipboard est un état STABLE que WSLg respecte autant qu'un texte — notre
# wl-copy image/png tient (hash inchangé sur 20s, AUCUN écrasement) ET le
# clipboard Windows garde l'image (ContainsImage=True tout du long).
# => On ne touche donc PLUS DU TOUT au clipboard Windows. Alt+V marche ET
#    l'image reste collable. Les deux objectifs, zéro compromis.
#
# EFFET DE BORD neutralisé (sinon régression CPU) : si l'image reste dans le
# clipboard, la boucle ré-encoderait PNG+MD5 20x/s en continu tant qu'elle y est
# (v4 masquait ça en transformant l'image en texte après 1 tick -> GetImage null).
# On ajoute donc une PORTE par GetClipboardSequenceNumber() : on n'ouvre le
# clipboard (GetImage + encode + hash) QUE quand le numéro de séquence change,
# i.e. quand le contenu du clipboard a réellement changé. Idle = lecture d'un uint
# 20x/s, coût négligeable.
#
# Le hash MD5 reste pour dédupliquer le CONTENU (ne ré-écrit PNG/flag que si
# l'image diffère de la dernière traitée). Le bridge (clip-watcher-bridge v10)
# garde sa fenêtre de défense comme filet de sécurité si WSLg tentait un
# écrasement ponctuel.
#
# Polling 50ms.

# Charger les types AVANT de masquer les erreurs : un échec d'Add-Type doit être
# bruyant (visible dans le log supervisor) plutôt que de produire une boucle
# no-op silencieuse.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ClipSeq {
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
}
"@

$ErrorActionPreference = "SilentlyContinue"

$outFile  = "\\wsl.localhost\Ubuntu\tmp\clip-latest.png"
$flagFile = "\\wsl.localhost\Ubuntu\tmp\clip-latest.flag"
$lastHash = ""
$lastSeq  = [uint32]::MaxValue   # force le traitement de ce qui est déjà présent au démarrage

while ($true) {
    try {
        # Porte : ne rien faire tant que le clipboard n'a pas changé.
        $seq = [ClipSeq]::GetClipboardSequenceNumber()
        if ($seq -ne $lastSeq) {
            $lastSeq = $seq

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
                    # Écrire le PNG + flag pour le bridge. On NE TOUCHE PLUS au
                    # clipboard Windows : l'image y reste (collable). WSLg respecte
                    # cet état stable ; le wl-copy image/png du bridge tient.
                    [System.IO.File]::WriteAllBytes($outFile, $bytes)
                    [System.IO.File]::WriteAllText($flagFile, $hash)
                    $lastHash = $hash
                }
            } else {
                # Clipboard changé vers un non-image (texte/fichier/vide). Reset
                # pour re-détecter une éventuelle re-copie de la même image plus tard.
                $lastHash = ""
            }
        }
    } catch {}
    Start-Sleep -Milliseconds 50
}

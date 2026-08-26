#Requires AutoHotkey v2.0
#SingleInstance Force

; Alt+V : insere le chemin de la capture la plus recente dans la fenetre active
; (Claude Code). Le chemin est aussi place dans le presse-papiers en secours.
; SendText saisit le chemin directement et ne depend pas du Ctrl+V de Warp/Claude Code.
; Le backend glm n'ayant pas la vision,
; Claude analysera ensuite l'image via kimi-vision.ps1 (delegation a kimi-k2.7-code:cloud).
; Script installe par Claude Code le 2026-06-17. Dossier screenshots par defaut Windows :
; C:\Users\<user>\Pictures\Screenshots (Win+PrtScn).
;
; 2026-07-21 -- priorite au presse-papiers. En session de bureau a distance
; (StarDesk, Parsec), Win+Shift+S part TANTOT sur l'hote, TANTOT sur la machine
; cliente, selon que la fenetre du client capture le clavier a cet instant. Quand
; il part cote client, aucun fichier n'est ecrit ici et le script inserait
; silencieusement une capture vieille de plusieurs heures. Mesure ce jour : trois
; captures d'affilee, deux atterries cote laptop, une cote desktop.
; StarDesk propage en revanche l'image vers le presse-papiers de l'hote, donc le
; presse-papiers est la source fiable : on l'ecrit dans un fichier et on l'utilise.
; Couvre aussi le Win+Shift+S local sans "enregistrement automatique", et toute
; image copiee depuis une autre application.

!v:: {
    KeyWait "Alt"
    path := ClipboardImageToFile()
    if (path = "")
        path := LatestScreenshotFile()
    if (path != "") {
        A_Clipboard := path
        SendText path
    }
}

; Ecrit l'image du presse-papiers dans Pictures\Screenshots et renvoie son chemin.
; Renvoie "" s'il n'y a pas d'image, ou si l'ecriture a echoue.
ClipboardImageToFile() {
    ; CF_DIB = 8. Teste AVANT de lancer quoi que ce soit : sans image dans le
    ; presse-papiers (le cas courant), Alt+V ne paie aucun processus.
    if !DllCall("IsClipboardFormatAvailable", "UInt", 8)
        return ""

    dir := EnvGet("USERPROFILE") "\Pictures\Screenshots"
    if !DirExist(dir) {
        try DirCreate dir
        catch
            return ""
    }
    out := dir "\Clipboard " FormatTime(A_Now, "yyyy-MM-dd HHmmss") ".png"

    ; Le chemin passe par une variable d'environnement plutot que par la ligne de
    ; commande : aucun probleme de guillemets, d'espaces ni d'accents a echapper.
    EnvSet "CLIP_OUT_PATH", out

    ; Windows PowerShell 5.1 et non pwsh : 165 ms contre 241 ms mesures, pour un
    ; travail que les deux font aussi bien. -Sta est obligatoire, l'API presse-papiers
    ; de WinForms exige un thread STA.
    ps := "powershell -Sta -NoProfile -WindowStyle Hidden -Command "
        . "`"Add-Type -AssemblyName System.Windows.Forms,System.Drawing; "
        . "$i = [System.Windows.Forms.Clipboard]::GetImage(); "
        . "if ($i) { $i.Save($env:CLIP_OUT_PATH, [System.Drawing.Imaging.ImageFormat]::Png) }`""

    try RunWait ps, , "Hide"
    catch
        return ""

    return FileExist(out) ? out : ""
}

; Capture la plus recente sur CETTE machine, tous dossiers connus confondus.
; Reste le comportement historique, utilise des que le presse-papiers ne contient
; pas d'image.
LatestScreenshotFile() {
    up := EnvGet("USERPROFILE")
    dirs := [
        up "\Pictures\Screenshots",
        up "\OneDrive\Pictures\Screenshots",
        up "\OneDrive - Personal\Pictures\Screenshots",
        up "\Videos\Captures"
    ]
    exts := ["png", "jpg", "jpeg", "webp", "bmp"]
    latestPath := ""
    latestTime := 0
    for dir in dirs {
        if DirExist(dir) {
            for ext in exts {
                Loop Files dir "\*." ext, "F" {
                    if (A_LoopFileTimeModified > latestTime) {
                        latestTime := A_LoopFileTimeModified
                        latestPath := A_LoopFileFullPath
                    }
                }
            }
        }
    }
    return latestPath
}

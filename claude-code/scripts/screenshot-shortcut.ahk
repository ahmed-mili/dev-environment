#Requires AutoHotkey v2.0
#SingleInstance Force

; Alt+V : insere le chemin du screenshot le plus recent dans la fenetre active
; (Claude Code). Le chemin est aussi place dans le presse-papiers (fallback Ctrl+V manuel
; si le collage auto ne marche pas dans le terminal). Le backend glm n'ayant pas la vision,
; Claude analysera ensuite l'image via kimi-vision.ps1 (delegation a kimi-k2.7-code:cloud).
; Script installe par Claude Code le 2026-06-17. Dossier screenshots par defaut Windows :
; C:\Users\<user>\Pictures\Screenshots (Win+PrtScn).

!v:: {
    KeyWait "Alt"
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
    if (latestPath != "") {
        A_Clipboard := latestPath
        Sleep 80
        Send "^v"
    }
}
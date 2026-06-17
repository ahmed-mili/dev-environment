<#
.SYNOPSIS
  Analyse une image via kimi-k2.7-code:cloud (Ollama cloud, vision MoonViT).

.DESCRIPTION
  Délégation vision pour les sessions Claude Code dont le backend n'a pas la
  vision (ex. glm-5.2:cloud). Encode l'image en base64, l'envoie à l'API Ollama
  locale (http://localhost:11434/api/chat) qui route vers le cloud, et imprime
  la description textuelle de kimi sur stdout. À appeler depuis Claude Code
  (Bash/PowerShell) quand on a besoin d'analyser une image.

.PARAMETER ImagePath
  Chemin de l'image à analyser.

.PARAMETER Prompt
  Question/instruction à poser à kimi à propos de l'image.

.EXAMPLE
  powershell -NoProfile -File kimi-vision.ps1 -ImagePath "C:\img.png" -Prompt "Décris cette image"
#>
param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [string]$Prompt = "Décris cette image en détail : texte visible (OCR exact), éléments visuels, mise en page, couleurs, et toute information utile. Sois précis et complet."
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $ImagePath)) {
    [Console]::Error.WriteLine("Image introuvable : $ImagePath")
    exit 1
}

$full  = (Resolve-Path -LiteralPath $ImagePath).Path
$bytes = [System.IO.File]::ReadAllBytes($full)
$b64   = [System.Convert]::ToBase64String($bytes)

$body = @{
    model    = 'kimi-k2.7-code:cloud'
    stream   = $false
    messages = @(
        @{
            role    = 'user'
            content = $Prompt
            images  = @($b64)
        }
    )
} | ConvertTo-Json -Depth 10

try {
    $resp = Invoke-RestMethod -Uri 'http://localhost:11434/api/chat' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 240
    Write-Output $resp.message.content
}
catch {
    [Console]::Error.WriteLine("Erreur API Ollama : $($_.Exception.Message)")
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { [Console]::Error.WriteLine($_.ErrorDetails.Message) }
    exit 1
}
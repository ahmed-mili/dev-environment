#!/usr/bin/env bash
# ollama launch claude → 3 modèles DISTINCTS dans le picker /model de Claude Code
# -----------------------------------------------------------------------------
# Le picker /model natif n'a que 3 slots (Opus/Sonnet/Haiku, alimentés par les
# variables ANTHROPIC_DEFAULT_*_MODEL) + un "Custom" (saisie libre). `ollama launch`
# les pointe TOUS sur le même modèle → menu inutile (4× le même). Ce wrapper lance
# claude directement avec 3 modèles distincts dans ces slots, à partir de TA liste.
#
# Découverte clé : `ANTHROPIC_AUTH_TOKEN=ollama` est le mot littéral "ollama" (pas un
# secret) ; c'est le daemon local (OLLAMA_HOST) qui signe les requêtes avec ta clé.
# On peut donc fabriquer l'env soi-même au lieu de passer par `ollama launch`.
#
# Liste : ~/.config/ollama-claude-models (override : $OLLAMA_CLAUDE_MODELS).
#   - Les 3 PREMIERS modèles → slots Opus / Sonnet / Haiku (1er = défaut).
#   - Réordonne pour choisir tes 3. Au-delà : via "Custom model" dans /model.
#
# `ollama launch claude --model/--config/--restore/--help` → ollama natif.
# `ollama launch claude [--resume|-c|…]` → claude direct (args transmis à claude).
# Tout autre `ollama …` (run/pull/serve…) → inchangé.
_start_windows_clipboard_watcher_for_claude() {
    command -v powershell.exe >/dev/null 2>&1 || return 0
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '
$caller = $PID
$anchor = $caller
try {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$caller"
    if ($p.ParentProcessId -gt 0) { $anchor = [int]$p.ParentProcessId }
    while ($p) {
        if ($p.Name -ieq "zellij.exe" -and $p.CommandLine -match "--server") {
            $anchor = [int]$p.ProcessId
            break
        }
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
    }
} catch {}
$watcher = Join-Path $env:USERPROFILE ".local\bin\img-clip-watcher.ps1"
if (-not (Test-Path $watcher)) { return }
$cmd = "powershell.exe -Sta -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`" -CallerPid $anchor"
try {
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $cmd
        ProcessStartupInformation = $startup
    } | Out-Null
} catch {
    try {
        Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-Sta", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
            "-File", $watcher, "-CallerPid", $anchor
        ) | Out-Null
    } catch {}
}
' </dev/null >/dev/null 2>&1 || true
}

ollama() {
    if [ "$1" = launch ] && [ "$2" = claude ]; then
        # Flags propres à `ollama launch` → laisser ollama natif s'en occuper.
        local arg
        for arg in "${@:3}"; do
            case "$arg" in
                --model|--config|--restore|--help|-h) command ollama "$@"; return ;;
            esac
        done

        local list="${OLLAMA_CLAUDE_MODELS:-$HOME/.config/ollama-claude-models}"
        if [ ! -s "$list" ]; then
            mkdir -p "$(dirname "$list")"
            cat > "$list" <<'MODELS'
# Tes modèles Ollama Cloud pour `ollama launch claude`. Les 3 PREMIERS (non commentés)
# remplissent les slots Opus/Sonnet/Haiku du picker /model (1er = défaut). Réordonne
# pour choisir. Au-delà de 3 : via "Custom model" dans /model. # = commentaire.
# Catalogue : https://ollama.com/search?c=cloud
kimi-k2.6:cloud
glm-5.1:cloud
deepseek-v4-pro:cloud
minimax-m3:cloud
qwen3.5:cloud
MODELS
        fi

        local _ocm
        mapfile -t _ocm < <(grep -vE '^[[:space:]]*(#|$)' "$list")
        if [ "${#_ocm[@]}" -eq 0 ]; then
            echo "ollama: liste de modèles vide ($list)" >&2
            return 1
        fi
        local opus="${_ocm[0]}" sonnet="${_ocm[1]:-${_ocm[0]}}" haiku="${_ocm[2]:-${_ocm[1]:-${_ocm[0]}}}"

        local base="${OLLAMA_HOST:-http://127.0.0.1:11434}"
        case "$base" in http*) ;; *) base="http://$base" ;; esac

        # Daemon local injoignable → repli sur le lancement natif (1 modèle).
        if ! curl -sf -m 2 "$base/api/version" >/dev/null 2>&1; then
            _start_windows_clipboard_watcher_for_claude
            command ollama launch claude --model "$opus" --yes "${@:3}"
            return
        fi

        # Args restants destinés à claude ; retire un éventuel séparateur "--".
        local cargs=("${@:3}")
        [ "${cargs[0]:-}" = "--" ] && cargs=("${cargs[@]:1}")

        _start_windows_clipboard_watcher_for_claude
        ANTHROPIC_BASE_URL="$base" \
        ANTHROPIC_AUTH_TOKEN=ollama \
        ANTHROPIC_API_KEY= \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$opus" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku" \
        CLAUDE_CODE_SUBAGENT_MODEL="$haiku" \
        command claude "${cargs[@]}"
        return
    fi
    command ollama "$@"
}

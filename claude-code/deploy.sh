#!/usr/bin/env bash
# Bidirectional sync between dev-environment/claude-code/ and the WSL/Linux ~/.claude/.
#
# Counterpart of deploy.ps1, which targets the WINDOWS %USERPROFILE%\.claude.
# This script targets $HOME/.claude on Linux/WSL, where Claude Code runs with
# platform=linux. The desktop is WSL-primary, so this WSL config is the source
# of truth for dev; deploy.ps1 (Windows) is kept frozen for the gaming/admin
# install.
#
# Usage:
#   ./deploy.sh --pull            # repo -> ~/.claude/    (bootstrap a new WSL machine)
#   ./deploy.sh --push            # ~/.claude/ -> repo    (before git commit/push)
#   ./deploy.sh --pull --force    # overwrite even if the local file is newer
#
# What it syncs (WSL-relevant, platform-independent only):
#   - keybindings.json                 (Alt+V image-paste fix; see the Obsidian guide)
#   - tmux.conf -> ~/.tmux.conf        (truecolor passthrough; see the SSH Android guide)
#   - the 11 whitelisted custom skills (same list as deploy.ps1)
#
# What it deliberately does NOT touch, and why:
#   - settings.json  : diverges per platform (statusline path /home vs C:\,
#                      extraKnownMarketplaces, effortLevel). Each OS keeps its own.
#   - statusline.ps1, statusline-rs/ : PowerShell / Windows-built .exe, N/A on Linux.
#   - hooks/         : PowerShell hooks, N/A on Linux.
#   - official / marketplace skills  : kept out of the repo to stay lean.
#
# Safety: Pull uses `rsync --update`, so it NEVER overwrites a ~/.claude file
# that is newer than the repo copy -- the exact failure mode the deploy-safety
# skill exists to prevent. Pass --force to override.

set -euo pipefail

MODE=""
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --pull)  MODE="pull"  ;;
        --push)  MODE="push"  ;;
        --force) FORCE=1      ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "Usage: ./deploy.sh --pull | --push  [--force]" >&2
    exit 1
fi

command -v rsync >/dev/null 2>&1 || { echo "rsync required: sudo apt install rsync" >&2; exit 3; }

REPO_CLAUDE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_CLAUDE="$HOME/.claude"

# Files that land in ~/.claude/ (basename used as both source and dest).
CLAUDE_FILES=( "keybindings.json" )

# Files that land in $HOME directly. Format: "<repo-name>:<home-name>"
# (e.g. tmux.conf in the repo -> ~/.tmux.conf, the leading dot is added).
HOME_FILES=( "tmux.conf:.tmux.conf" )

# Device-context detectors (deployed as a subdir under ~/.claude/)
DEVICE_CONTEXT_DIR="device-context"

# Utility scripts (deployed as a subdir under ~/.claude/)
SCRIPTS_DIR="scripts"

# Custom skills tracked in the repo (mirror of deploy.ps1's $CustomSkills).
SKILLS=(
    claude-file-recovery copy-edit css-layout-check deploy-safety
    edit-block lucide-icons release root-cause-fix smart-edit
    sticky-column-bleed-fix webapp-deploy
)

# -a archive; --update skips files newer on the receiver (the safety guard),
# disabled by --force. No --delete: sync is additive, never removes files.
RSYNC_OPTS=( -a )
[ "$FORCE" -eq 0 ] && RSYNC_OPTS+=( --update )

copy_file() {  # src dst
    local src="$1" dst="$2"
    if [ ! -e "$src" ]; then printf '  %-6s %s\n' "SKIP" "$(basename "$src")"; return; fi
    mkdir -p "$(dirname "$dst")"
    rsync "${RSYNC_OPTS[@]}" "$src" "$dst" >/dev/null
    printf '  %-6s %s\n' "OK" "$(basename "$src")"
}

copy_skill() {  # src-dir dst-dir
    local src="$1" dst="$2"
    if [ ! -d "$src" ]; then printf '  %-6s %s\n' "SKIP" "$(basename "$src")/"; return; fi
    mkdir -p "$dst"
    rsync "${RSYNC_OPTS[@]}" "$src/" "$dst/" >/dev/null
    printf '  %-6s %s\n' "OK" "$(basename "$src")/"
}

if [ "$MODE" = "pull" ]; then
    echo "=== Pull: $REPO_CLAUDE -> $HOME_CLAUDE  (--update protects newer local files) ==="
    echo "Files in ~/.claude/:"
    for f in "${CLAUDE_FILES[@]}"; do copy_file "$REPO_CLAUDE/$f" "$HOME_CLAUDE/$f"; done
    echo "Files in ~/:"
    for pair in "${HOME_FILES[@]}"; do
        src="${pair%%:*}"; dst="${pair##*:}"
        copy_file "$REPO_CLAUDE/$src" "$HOME/$dst"
    done
    echo "Skills:"
    for s in "${SKILLS[@]}"; do copy_skill "$REPO_CLAUDE/skills/$s" "$HOME_CLAUDE/skills/$s"; done
    echo "Device context:"
    copy_skill "$REPO_CLAUDE/$DEVICE_CONTEXT_DIR" "$HOME_CLAUDE/$DEVICE_CONTEXT_DIR"
    echo "Scripts:"
    copy_skill "$REPO_CLAUDE/$SCRIPTS_DIR" "$HOME_CLAUDE/$SCRIPTS_DIR"
    echo "Done. keybindings.json hot-reloads (no restart). tmux: 'tmux source-file ~/.tmux.conf' to apply on a running server. New skills: restart Claude Code."
else
    echo "=== Push: $HOME_CLAUDE -> $REPO_CLAUDE ==="
    echo "Files from ~/.claude/:"
    for f in "${CLAUDE_FILES[@]}"; do copy_file "$HOME_CLAUDE/$f" "$REPO_CLAUDE/$f"; done
    echo "Files from ~/:"
    for pair in "${HOME_FILES[@]}"; do
        src="${pair%%:*}"; dst="${pair##*:}"
        copy_file "$HOME/$dst" "$REPO_CLAUDE/$src"
    done
    echo "Skills:"
    for s in "${SKILLS[@]}"; do copy_skill "$HOME_CLAUDE/skills/$s" "$REPO_CLAUDE/skills/$s"; done
    echo "Device context:"
    copy_skill "$HOME_CLAUDE/$DEVICE_CONTEXT_DIR" "$REPO_CLAUDE/$DEVICE_CONTEXT_DIR"
    echo "Scripts:"
    copy_skill "$HOME_CLAUDE/$SCRIPTS_DIR" "$REPO_CLAUDE/$SCRIPTS_DIR"
    echo "Done. Reminder: cd dev-environment ; git add -A ; git commit ; git push"
fi

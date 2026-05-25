#!/data/data/com.termux/files/usr/bin/bash
# Android Termux — single entry point. Detects state and runs the right script:
#   - fresh install  → android/setup-ssh-client.sh
#   - legacy install → android/migrate-legacy.sh (cleanup + setup-ssh-client.sh)
#
# Two generations are recognised as "legacy" and trigger the migrator:
#   1. Ollama + proot-distro Ubuntu  (mid-2025 setup)
#   2. Native Claude Code on Termux  (early-2026 setup — auto-pull/push hooks)
#
# One-liner from anywhere:
#   bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.sh)

set -e

REPO_RAW="https://raw.githubusercontent.com/ahmed-mili/dev-environment/main"

# Detection: any one of these is enough to trigger the migrator.
legacy=no
# Generation 1 (Ollama / proot)
if command -v proot-distro >/dev/null 2>&1 && proot-distro list 2>/dev/null | grep -qi 'ubuntu.*installed'; then
    legacy=yes
fi
if [ -f "$PREFIX/bin/ollama.proot" ]; then
    legacy=yes
fi
if [ -f "$HOME/.bashrc.local" ] && grep -q 'ollama serve autostart' "$HOME/.bashrc.local" 2>/dev/null; then
    legacy=yes
fi
# Generation 2 (native Claude Code + auto-pull/push hooks)
if [ -d "$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code" ]; then
    legacy=yes
fi
if [ -f "$HOME/.claude/hooks/auto-pull.sh" ] || [ -f "$HOME/.claude/hooks/auto-push.sh" ]; then
    legacy=yes
fi
if [ -f "$HOME/.claude/settings.json" ] && grep -qE 'auto-(pull|push)\.sh' "$HOME/.claude/settings.json" 2>/dev/null; then
    legacy=yes
fi

_y=$(printf '\033[33m'); _g=$(printf '\033[32m'); _r=$(printf '\033[0m')

# wget is the one prerequisite. The setup-ssh-client.sh preamble itself fixes
# broken curl on some Termux builds, but wget has no equivalent fragility —
# so we use it here as the bootstrap fetcher.
command -v wget >/dev/null 2>&1 || { pkg install -y wget; }

if [ "$legacy" = yes ]; then
    printf '%s==>%s Legacy install detected — running migration\n' "$_y" "$_r"
    bash <(wget -qO- "$REPO_RAW/android/migrate-legacy.sh")
else
    printf '%s==>%s Fresh install — running setup-ssh-client.sh\n' "$_g" "$_r"
    bash <(wget -qO- "$REPO_RAW/android/setup-ssh-client.sh")
fi

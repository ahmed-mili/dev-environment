#!/data/data/com.termux/files/usr/bin/bash
# Migrate a Termux install from the old Claude Code + Ollama setup
# (proot-distro Ubuntu, ollama wrapper, autostart in bashrc.local)
# to the current Termux-native Claude Code config.
#
# Idempotent: every step checks state first and skips if already done.
# Safe to re-run.
#
# One-liner:
#   bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/migrate-from-ollama.sh)

set -e

REPO_DIR="/storage/emulated/0/dev/dev-environment"

_b=$(printf '\033[1m'); _g=$(printf '\033[32m'); _y=$(printf '\033[33m'); _r=$(printf '\033[0m')
step() { printf '\n%s==> %s%s\n' "$_b" "$1" "$_r"; }
ok()   { printf '    %s✓%s %s\n' "$_g" "$_r" "$1"; }
skip() { printf '    %s·%s %s (skip)\n' "$_y" "$_r" "$1"; }

step "1/5  Remove proot-distro Ubuntu (if installed)"
if command -v proot-distro >/dev/null 2>&1 && proot-distro list 2>/dev/null | grep -qi 'ubuntu.*installed'; then
    proot-distro remove ubuntu
    ok "Ubuntu proot removed (freed ~1GB+)"
else
    skip "Ubuntu proot absent"
fi

step "2/5  Remove ollama wrapper (if installed)"
if [ -f "$PREFIX/bin/ollama.proot" ] || [ -L "$PREFIX/bin/ollama" ] || [ -f "$PREFIX/bin/ollama" ]; then
    rm -f "$PREFIX/bin/ollama" "$PREFIX/bin/ollama.proot"
    rm -f "$HOME/.ollama.log" 2>/dev/null || true
    ok "wrapper + log removed"
else
    skip "no ollama wrapper"
fi

step "3/5  Clean ~/.bashrc.local of Ollama autostart block"
if [ -f "$HOME/.bashrc.local" ] && grep -q 'ollama serve autostart' "$HOME/.bashrc.local" 2>/dev/null; then
    cp "$HOME/.bashrc.local" "$HOME/.bashrc.local.bak-pre-ollama-removal"
    awk '
        /^# termux-config: ollama serve autostart/ { skip = 1 }
        skip && /^fi$/ { skip = 0; next }
        !skip
    ' "$HOME/.bashrc.local.bak-pre-ollama-removal" > "$HOME/.bashrc.local"
    ok "cleaned (backup at ~/.bashrc.local.bak-pre-ollama-removal)"
else
    skip "bashrc.local already clean"
fi

step "4/5  git pull dev-environment to latest"
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --ff-only
    ok "repo up to date at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
else
    skip "no clone at $REPO_DIR — setup.sh will bootstrap from GitHub raw"
fi

step "5/5  Re-run setup.sh (idempotent, current Termux-native config)"
if [ -f "$REPO_DIR/android/setup.sh" ]; then
    bash "$REPO_DIR/android/setup.sh"
else
    bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh)
fi

printf '\n%s==> Migration complete.%s\n' "$_b" "$_r"
printf '    Verify : %sclaude --version%s\n\n' "$_g" "$_r"

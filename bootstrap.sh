#!/data/data/com.termux/files/usr/bin/bash
# Android Termux — single entry point. Detects state and runs the right script:
#   - fresh install  → android/setup.sh
#   - legacy install → android/migrate-from-ollama.sh (cleanup + setup.sh)
#
# One-liner from anywhere:
#   bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.sh)

set -e

REPO_RAW="https://raw.githubusercontent.com/ahmed-mili/dev-environment/main"

# Detection: legacy Ollama/proot setup leaves three telltale signs.
legacy=no
if command -v proot-distro >/dev/null 2>&1 && proot-distro list 2>/dev/null | grep -qi 'ubuntu.*installed'; then
    legacy=yes
fi
if [ -f "$PREFIX/bin/ollama.proot" ]; then
    legacy=yes
fi
if [ -f "$HOME/.bashrc.local" ] && grep -q 'ollama serve autostart' "$HOME/.bashrc.local" 2>/dev/null; then
    legacy=yes
fi

_y=$(printf '\033[33m'); _g=$(printf '\033[32m'); _r=$(printf '\033[0m')

# wget is the one prerequisite. The setup.sh preamble itself fixes broken curl
# on some Termux builds, but wget has no equivalent fragility — so we use it
# here as the bootstrap fetcher.
command -v wget >/dev/null 2>&1 || { pkg install -y wget; }

if [ "$legacy" = yes ]; then
    printf '%s==>%s Legacy Ollama/proot setup detected — running migration\n' "$_y" "$_r"
    bash <(wget -qO- "$REPO_RAW/android/migrate-from-ollama.sh")
else
    printf '%s==>%s Fresh install — running setup.sh\n' "$_g" "$_r"
    bash <(wget -qO- "$REPO_RAW/android/setup.sh")
fi

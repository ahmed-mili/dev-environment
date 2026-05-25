#!/data/data/com.termux/files/usr/bin/bash
# ---------------------------------------------------------------------------
# Termux installer for the "SSH client to a remote dev machine" workflow.
#
# What this installs:
#   - A polished Termux (Catppuccin Mocha colours, JetBrainsMono Nerd Font,
#     starship prompt, fastfetch splash, fzf bindings)
#   - The SSH stack needed to reach a remote PC over Tailscale:
#     openssh client, mosh (resilient over flaky mobile networks), tmux
#   - An ed25519 SSH key (printed at the end so you can paste it into
#     ~/.ssh/authorized_keys on the remote host)
#   - A wake lock on shell start so Android does not kill the mosh tunnel
#     while the screen is off / Termux is in the background
#
# What this does NOT install any more (intentional pivot — see android/README.md):
#   - Claude Code on the phone (it now runs on the PC, reached via SSH/mosh)
#   - Node.js / npm / npm-global tree
#   - Auto-pull / auto-push hooks (no repos live on the phone any more)
#   - sshd (this bundle is a pure SSH client; install openssh separately if
#     you also want PC -> phone access)
#
# Idempotent: re-running picks up where the previous run stopped, skips
# anything already in place, and never overwrites without a timestamped
# backup. Safe to invoke after upgrading Termux or wiping ~/.bashrc.
#
# Usage (from anywhere on the phone — paste as one line):
#   curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; \
#   pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup-ssh-client.sh)
# or, after cloning the repo:
#   bash /storage/emulated/0/dev/dev-environment/android/setup-ssh-client.sh
#
# The `dpkg -r` preamble is a no-op on a healthy Termux. It only fires on
# the broken-libngtcp2 builds where curl is dynamically dead, which also
# breaks `pkg install` itself (pkg shells out to curl for mirror selection).
# Process-substitution `bash <(...)` instead of `curl ... | bash` because
# the git-identity prompts in this script need stdin attached to a TTY
# (see `[ -t 0 ]` checks below).
# ---------------------------------------------------------------------------

set -u
# We never want a single failing optional step to abort the whole install,
# so individual blocks below decide whether to fail-fast on their own.

# Termux/Bionic ships without a working `locale` command (termux-packages#546),
# so tools that probe the encoding fall back blindly. These two exports
# make sure every child process spawned by setup-ssh-client.sh (git,
# ssh-keygen, etc.) inherits a sane UTF-8 environment.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

REPO_RAW="https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android"

TERMUX_DIR="$HOME/.termux"
CONFIG_DIR="$HOME/.config"
STARSHIP_PATH="$CONFIG_DIR/starship.toml"
FASTFETCH_PATH="$CONFIG_DIR/fastfetch/config.jsonc"

# ---- printing helpers (Catppuccin Mocha-tinted) --------------------------
_blue=$'\033[38;2;137;180;250m'
_green=$'\033[38;2;166;227;161m'
_yellow=$'\033[38;2;249;226;175m'
_red=$'\033[38;2;243;139;168m'
_dim=$'\033[38;2;108;112;134m'
_reset=$'\033[0m'

step() { printf '  %s==>%s %s\n' "$_blue" "$_reset" "$1"; }
ok()   { printf '      %s✓%s %s\n' "$_green" "$_reset" "$1"; }
note() { printf '      %s!%s %s\n' "$_yellow" "$_reset" "$1"; }
fail() { printf '      %s✗%s %s\n' "$_red" "$_reset" "$1"; }

# ---- precondition: we are running inside Termux --------------------------
if [ -z "${PREFIX:-}" ] || [ "$PREFIX" != "/data/data/com.termux/files/usr" ]; then
    fail "This script must be run inside Termux ($PREFIX != /data/data/com.termux/files/usr)."
    exit 1
fi

# Where to read source files from. When piped via curl/wget, we fetch from
# the repo; when run from a local clone, we use the script's directory.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

read_file() {
    # $1 = relative path inside the repo (e.g. files/bashrc)
    local rel="$1"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$rel" ]; then
        cat "$SCRIPT_DIR/$rel"
    elif command -v wget >/dev/null 2>&1; then
        # Prefer wget — works even when curl is broken by the libngtcp2 /
        # openssl ABI mismatch that Termux occasionally ships.
        wget -qO- "$REPO_RAW/$rel"
    else
        curl -fsSL "$REPO_RAW/$rel"
    fi
}

backup_if_exists() {
    local target="$1"
    if [ -e "$target" ]; then
        local stamp
        stamp=$(date '+%Y%m%d-%H%M%S')
        cp -a "$target" "$target.bak-$stamp"
    fi
}

deploy_file() {
    # $1 = relative source in repo, $2 = absolute target, $3 = mode
    local rel="$1" target="$2" mode="${3:-0644}"
    local dir
    dir=$(dirname "$target")
    mkdir -p "$dir"
    backup_if_exists "$target"
    local content
    content=$(read_file "$rel") || { fail "could not read $rel"; return 1; }
    printf '%s' "$content" > "$target"
    chmod "$mode" "$target"
}

short_path() {
    case "$1" in
        "$HOME"*) printf '~%s' "${1#$HOME}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# 1) Termux storage access (skipped silently if already granted)
# ---------------------------------------------------------------------------
step "Storage access"
if [ ! -d "$HOME/storage" ]; then
    note "running termux-setup-storage — accept the Android permission prompt"
    termux-setup-storage 2>/dev/null || note "termux-setup-storage not available; skipping"
else
    ok "already granted"
fi

# ---------------------------------------------------------------------------
# 2) Package install
# ---------------------------------------------------------------------------
step "Termux packages"

# Auto-repair the Termux libngtcp2-crypto-ossl / openssl ABI mismatch.
# Some Termux APK snapshots (especially older F-Droid builds) ship the
# HTTP/3 shim against a newer OpenSSL than what's installed, so any
# curl invocation explodes with `cannot locate symbol
# "SSL_set_quic_tls_transport_params"`. The shim is a Recommends, not
# a hard Depends — removing it restores curl, just without HTTP/3
# (irrelevant for GitHub — serves HTTP/2).
if dpkg -s libngtcp2-crypto-ossl >/dev/null 2>&1 \
    && command -v curl >/dev/null 2>&1 \
    && ! curl --version >/dev/null 2>&1; then
    note "detected broken curl (libngtcp2-crypto-ossl ABI mismatch) — repairing"
    apt-mark hold libngtcp2-crypto-ossl >/dev/null 2>&1 || true
    pkg uninstall -y libngtcp2-crypto-ossl >/dev/null 2>&1 || \
        dpkg -r --force-depends libngtcp2-crypto-ossl >/dev/null 2>&1 || true
    if curl --version >/dev/null 2>&1; then
        ok "curl repaired (HTTP/3 disabled, HTTP/1.1 and HTTP/2 still work)"
    fi
fi

# `pkg upgrade` is mandatory before `pkg install` on Termux: the repos move
# fast and partial upgrades leave you with ABI mismatches (libcurl /
# openssl / libngtcp2 are the classic offenders). Doing upgrade first
# keeps every package in lockstep before we add new ones.
# --force-confold keeps the user's local /etc/* files instead of replacing
# them with maintainer defaults — safe for both fresh and re-run scenarios.
# (pkg upgrade auto-runs apt-get update first, so no separate update call.)
pkg upgrade -y -o Dpkg::Options::="--force-confold" >/dev/null 2>&1 \
    || note "pkg upgrade returned non-zero — continuing, install may fail"

PKGS=(
    # Core CLI
    git openssh mosh curl wget nano
    # Shell UX
    fzf fastfetch starship
    eza bat fd ripgrep
    tmux
    # Termux integrations (clipboard, wake-lock, etc.)
    termux-api
    # Base GNU userland (some Termux builds ship busybox-flavoured variants)
    coreutils gawk grep sed
)
to_install=()
for p in "${PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
        to_install+=("$p")
    fi
done
if [ "${#to_install[@]}" -gt 0 ]; then
    note "installing: ${to_install[*]}"
    pkg install -y "${to_install[@]}" || note "some packages failed; continuing"
fi

# Quick sanity-check on the SSH client stack — this is the whole point of
# the bundle, so flag loudly if either binary refuses to load.
for bin in ssh mosh; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        fail "$bin not on PATH after install — re-run \`pkg install $bin\` manually"
    fi
done

# ---------------------------------------------------------------------------
# 3) JetBrainsMono Nerd Font for the Termux terminal view
# ---------------------------------------------------------------------------
step "JetBrainsMono Nerd Font"
mkdir -p "$TERMUX_DIR"
FONT_TARGET="$TERMUX_DIR/font.ttf"
if [ -s "$FONT_TARGET" ]; then
    ok "$(short_path "$FONT_TARGET") (already present)"
else
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/JetBrainsMono/Ligatures/Regular/JetBrainsMonoNerdFont-Regular.ttf"
    if curl -fsSL "$FONT_URL" -o "$FONT_TARGET.tmp" && [ -s "$FONT_TARGET.tmp" ]; then
        mv "$FONT_TARGET.tmp" "$FONT_TARGET"
        ok "$(short_path "$FONT_TARGET")"
    else
        rm -f "$FONT_TARGET.tmp"
        note "font download failed — Termux will keep its default font. Re-run later."
    fi
fi

# ---------------------------------------------------------------------------
# 4) Termux Catppuccin Mocha palette + UX tweaks
# ---------------------------------------------------------------------------
step "Termux colours + properties"
deploy_file "files/colors.properties"  "$TERMUX_DIR/colors.properties"  0644
deploy_file "files/termux.properties"  "$TERMUX_DIR/termux.properties"  0644
termux-reload-settings 2>/dev/null || true
ok "$(short_path "$TERMUX_DIR/colors.properties")"
ok "$(short_path "$TERMUX_DIR/termux.properties")"

# ---------------------------------------------------------------------------
# 5) Bash profile + starship + fastfetch config
# ---------------------------------------------------------------------------
step "Shell profile"
deploy_file "files/bashrc"                 "$HOME/.bashrc"     0644
deploy_file "files/starship.toml"          "$STARSHIP_PATH"    0644
deploy_file "files/fastfetch-config.jsonc" "$FASTFETCH_PATH"   0644
ok "$(short_path "$HOME/.bashrc")"
ok "$(short_path "$STARSHIP_PATH")"
ok "$(short_path "$FASTFETCH_PATH")"

# ---------------------------------------------------------------------------
# 5b) Remove any leftover ble.sh install from previous versions of this bundle
# ---------------------------------------------------------------------------
# Earlier versions of this script installed ble.sh (bash autosuggestions +
# syntax highlighting). It is intentionally dropped now: ble.sh logs a noisy
# `locale 'C' seems broken` warning on every shell start because Termux/Bionic
# ships no `locale` command for it to probe (termux-packages#546), and the
# combo starship + fzf history search is enough for our use. Sweep any
# leftover install + blerc so the warning disappears on next shell start.
step "ble.sh cleanup (if previously installed)"
BLESH_DIR="$HOME/.local/share/blesh"
if [ -d "$BLESH_DIR" ]; then
    rm -rf "$BLESH_DIR"
    rm -f "$HOME/.blerc" 2>/dev/null || true
    ok "removed $(short_path "$BLESH_DIR")"
else
    ok "no leftover ble.sh install"
fi

# ---------------------------------------------------------------------------
# 6) SSH key (used to authenticate to the remote dev machine)
# ---------------------------------------------------------------------------
step "SSH key"
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
KEY="$SSH_DIR/id_ed25519"
if [ ! -f "$KEY" ]; then
    # Empty passphrase — required for mosh's seamless auto-reconnect on a
    # flaky mobile link. Comment uses git user.email if set, else a neutral
    # fallback so anyone forking this gets a key that does not impersonate
    # the maintainer.
    keygen_comment="$(git config --global user.email 2>/dev/null)"
    [ -z "$keygen_comment" ] && keygen_comment="$(whoami)@termux"
    ssh-keygen -t ed25519 -C "$keygen_comment" -f "$KEY" -N "" >/dev/null
    ok "generated $(short_path "$KEY")"
else
    ok "$(short_path "$KEY") already present"
fi

# ---------------------------------------------------------------------------
# 7) Git identity (only prompts if missing AND we have a TTY)
# ---------------------------------------------------------------------------
# Useful for the occasional `git clone` / `git pull` on the phone — e.g.
# pulling this repo to re-run setup-ssh-client.sh after a Termux wipe.
step "Git identity"
git config --global pull.ff only
git config --global init.defaultBranch main
gn=$(git config --global user.name 2>/dev/null)
ge=$(git config --global user.email 2>/dev/null)
if [ -z "$gn" ] && [ -t 0 ]; then
    printf '  git user.name (e.g. "Jane Doe"): '
    read -r gn
    [ -n "$gn" ] && git config --global user.name "$gn"
fi
if [ -z "$ge" ] && [ -t 0 ]; then
    printf '  git user.email: '
    read -r ge
    [ -n "$ge" ] && git config --global user.email "$ge"
fi
if [ -n "$gn" ] && [ -n "$ge" ]; then
    ok "$gn <$ge>"
else
    note "git identity not fully set — \`git config --global user.{name,email}\` later"
fi

# ---------------------------------------------------------------------------
# 8) Wake lock auto-acquire on shell start
# ---------------------------------------------------------------------------
# Without a wake lock, Android (especially MIUI on Xiaomi) throttles or
# kills Termux as soon as the screen turns off — which would drop the mosh
# tunnel mid-session. termux-wake-lock requests a partial wake lock from
# Android: CPU keeps running, screen can still turn off (battery cost is
# small in practice).
# Release manually with `termux-wake-unlock` or remove the line from
# ~/.bashrc.local. The pgrep guard makes this a no-op if already held.
step "Wake lock (keeps mosh / ssh alive in background)"
if ! grep -q '^# termux-config: wake lock' "$HOME/.bashrc.local" 2>/dev/null; then
    cat >> "$HOME/.bashrc.local" <<'EOF'

# termux-config: wake lock — prevents Android from suspending Termux while
# mosh / ssh / tmux are running. Remove this line to conserve battery if you
# only use Termux for short interactive sessions.
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
EOF
    ok "auto-acquire on shell start (release with termux-wake-unlock)"
else
    ok "already configured in ~/.bashrc.local"
fi
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null


# ---------------------------------------------------------------------------
# Done — print pubkey + next-steps reminder.
# ---------------------------------------------------------------------------
printf '\n  %sDone.%s\n\n' "$_green" "$_reset"

if [ -f "$KEY.pub" ]; then
    printf '  %sYour public key (add it to ~/.ssh/authorized_keys on the remote host):%s\n' "$_yellow" "$_reset"
    printf '  %s\n\n' "$(cat "$KEY.pub")"
    # Copy to Android clipboard if termux-api is functional — beats long-press
    # selecting on a TTY full of escape codes. timeout caps the hang if the
    # Termux:API app is not installed.
    if command -v termux-clipboard-set >/dev/null 2>&1; then
        if printf '%s' "$(cat "$KEY.pub")" | timeout 3 termux-clipboard-set 2>/dev/null; then
            ok "key copied to Android clipboard"
        fi
    fi
fi

printf '  %sNext steps:%s\n' "$_yellow" "$_reset"
printf '    %s1.%s  Add the key above to the remote host ~/.ssh/authorized_keys\n' "$_dim" "$_reset"
printf '    %s2.%s  Connect:  %smosh <host>%s     (resilient over flaky 4G/5G)\n' "$_dim" "$_reset" "$_dim" "$_reset"
printf '    %s3.%s  Inside the remote shell:  %stmux new -A -s main%s\n\n' "$_dim" "$_reset" "$_dim" "$_reset"
printf '  Docs: %shttps://github.com/ahmed-mili/dev-environment%s\n\n' "$_dim" "$_reset"

# Auto-reload the shell so the user gets the new look + starship
# immediately, no `source ~/.bashrc` to remember. exec replaces this script
# process with a fresh interactive login bash — when the user types `exit`
# they go back to whatever shell launched the bootstrap (or Termux closes).
# Gated on stdin+stdout being a TTY: skip in CI, non-interactive pipes, etc.
if [ -t 0 ] && [ -t 1 ]; then
    printf '  %sLoading the new shell...%s\n\n' "$_dim" "$_reset"
    exec bash -l
fi

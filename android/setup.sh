#!/data/data/com.termux/files/usr/bin/bash
# ---------------------------------------------------------------------------
# Termux + Claude Code setup bundle for ahmed-mili's multi-device dev flow.
#
# Counterpart to https://github.com/ahmed-mili/dev-environment/tree/main/windows :
#   - installs core packages (git, openssh, nodejs-lts, fzf, fastfetch,
#     starship, eza, bat, fd, ripgrep, nano)
#   - deploys a Catppuccin Mocha look (Termux colours, JetBrainsMono Nerd
#     Font, starship prompt, gradient USER@HOST + fastfetch splash)
#   - generates an ed25519 SSH key and prints the public part for GitHub
#   - installs Claude Code via npm (global, ~/.npm-global)
#   - prompts (optional) for sshd, Tailscale
#   - drops auto-pull / auto-push hooks scoped to /storage/emulated/0/dev
#     and patches ~/.claude/settings.json so SessionStart pulls and
#     SessionEnd pushes
#
# The installer is personal-repo agnostic: it sets up the Termux + Claude
# Code environment, then leaves /storage/emulated/0/dev/ empty for you to
# `git clone` your own repos into. That path puts code on the phone's
# shared storage so file managers / Android editors (Acode, etc.) can see
# it — see "FUSE caveats" below before cloning anything that uses
# symlinks, executable bits, or node_modules.
#
# Idempotent: re-running picks up where the previous run stopped, skips
# anything already in place, and never overwrites without a timestamped
# backup. Safe to invoke after upgrading Termux or wiping ~/.bashrc.
#
# Usage (from anywhere on the phone — paste as one line):
#   curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; \
#   pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh)
# or, after cloning the repo:
#   bash /storage/emulated/0/dev/dev-environment/android/setup.sh
#
# The `dpkg -r` preamble is a no-op on a healthy Termux. It only fires on
# the broken-libngtcp2 builds where curl is dynamically dead, which also
# breaks `pkg install` itself (pkg shells out to curl for mirror selection).
# Process-substitution `bash <(...)` instead of `curl ... | bash` because
# the GitHub-SSH / sshd prompts in this script need stdin attached
# to a TTY (see `[ -t 0 ]` checks below).
# ---------------------------------------------------------------------------

set -u
# We never want a single failing optional step to abort the whole install,
# so individual blocks below decide whether to fail-fast on their own.

# Termux ships with a broken `C` locale (termux-packages#23010). ble.sh and
# other tools warn or refuse to load when LC_CTYPE=C. Setting C.UTF-8 here
# at the top of the script means EVERY child process (make install of ble.sh,
# npm scripts, git, etc.) inherits a sane locale.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

REPO_RAW="https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android"

# Dev tree lives on Android shared storage so it shows up in file managers
# and Android editors. Created only after `termux-setup-storage` (step 1)
# has granted the FUSE mount. FUSE caveat: no symlinks inside, no exec
# bits, no proper Unix permissions — set `git config core.fileMode false`
# per repo if `git status` floods with mode changes, and keep node_modules
# / Python venvs out of this tree (they break on FUSE).
DEV_DIR="/storage/emulated/0/dev"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
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

# Where to read source files from. When piped via curl, we fetch from the
# repo; when run from a local clone, we use the script's directory.
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
# (irrelevant for GitHub, npm — all serve HTTP/2).
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
    git openssh curl wget nano
    nodejs-lts
    fzf fastfetch starship
    eza bat fd ripgrep
    tmux
    termux-api
    coreutils gawk grep sed
    make
    gh
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

# Verify the critical packages individually. `pkg install` can return 0 even
# when one of the requested packages silently fell back to a broken state
# (typical on Termux when an ABI mismatch in a dep prevents a binary from
# loading). nodejs-lts is non-negotiable: if `node` can't run, the Claude
# Code install later will hard-fail with no useful diagnostic.
if ! node --version >/dev/null 2>&1; then
    note "node binary not functional after pkg install — reinstalling nodejs-lts"
    pkg reinstall -y nodejs-lts || pkg install -y nodejs || fail "nodejs install kept failing — Claude Code install will not work"
fi
if node --version >/dev/null 2>&1; then
    ok "node $(node --version) / npm $(npm --version)"
else
    fail "no working node — fix `pkg install nodejs-lts` manually before re-running"
fi

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
deploy_file "files/bashrc"              "$HOME/.bashrc"          0644
deploy_file "files/starship.toml"       "$STARSHIP_PATH"          0644
deploy_file "files/fastfetch-config.jsonc" "$FASTFETCH_PATH"      0644
ok "$(short_path "$HOME/.bashrc")"
ok "$(short_path "$STARSHIP_PATH")"
ok "$(short_path "$FASTFETCH_PATH")"

# ---------------------------------------------------------------------------
# 5b) ble.sh — bash autosuggestions + syntax highlighting (PSReadLine equivalent)
# ---------------------------------------------------------------------------
# Not in the Termux apt repo, so we install upstream via `make install` into
# ~/.local. ble.sh is 100% bash — make just copies files, no compilation.
# bashrc sources $HOME/.local/share/blesh/ble.sh conditionally; if this step
# fails the shell still works, just without autosuggestions.
step "ble.sh (autosuggestions + syntax highlighting)"
BLESH="$HOME/.local/share/blesh/ble.sh"
if [ -f "$BLESH" ]; then
    ok "ble.sh already installed at $(short_path "$BLESH")"
else
    note "cloning + building ble.sh from upstream (one-time, ~15s)"
    _tmp=$(mktemp -d)
    if git clone --recursive --depth 1 --shallow-submodules \
            https://github.com/akinomyoga/ble.sh.git "$_tmp/ble.sh" >/dev/null 2>&1 \
        && make -C "$_tmp/ble.sh" install PREFIX="$HOME/.local" >/dev/null 2>&1 \
        && [ -f "$BLESH" ]; then
        ok "ble.sh installed at $(short_path "$BLESH")"
    else
        note "ble.sh install failed — shell will work without autosuggestions"
    fi
    rm -rf "$_tmp"
fi

# ---------------------------------------------------------------------------
# 6) SSH key for GitHub
# ---------------------------------------------------------------------------
step "SSH key for GitHub"
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
KEY="$SSH_DIR/id_ed25519"
if [ ! -f "$KEY" ]; then
    # Comment uses git config email if set, else a neutral fallback. Generic
    # so anyone forking and running this gets a key that doesn't impersonate
    # the maintainer.
    keygen_comment="$(git config --global user.email 2>/dev/null)"
    [ -z "$keygen_comment" ] && keygen_comment="$(whoami)@termux"
    ssh-keygen -t ed25519 -C "$keygen_comment" -f "$KEY" -N "" >/dev/null
    ok "generated $(short_path "$KEY")"
else
    ok "$(short_path "$KEY") already present"
fi

# Trust github.com host key automatically — first git over SSH would otherwise
# prompt interactively, which breaks Claude Code's session pipe.
if ! grep -q '^github.com ' "$SSH_DIR/known_hosts" 2>/dev/null; then
    ssh-keyscan -t ed25519,rsa github.com >> "$SSH_DIR/known_hosts" 2>/dev/null
fi
chmod 600 "$SSH_DIR/known_hosts" 2>/dev/null || true

# ssh config: explicitly point GitHub at this key so multi-account setups
# (e.g. ahmed-mili school account later) don't pick the wrong identity.
SSH_CONFIG="$SSH_DIR/config"
if ! grep -q 'Host github.com' "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

EOF
    chmod 600 "$SSH_CONFIG"
fi

# Verify connectivity FIRST — if SSH already authenticates, the key is already
# registered on GitHub (e.g. re-run on an already-set-up device, or key copied
# from another machine). ssh -T github.com always exits 1 even on success
# (GitHub never grants a shell), so we grep the welcome line instead.
check_ssh_github() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true
}
SSH_AUTH_OK=no
ssh_test=$(check_ssh_github)
case "$ssh_test" in
    *"successfully authenticated"*)
        SSH_AUTH_OK=yes
        ok "SSH auth OK ($(printf '%s' "$ssh_test" | awk -F'Hi ' '{print $2}' | awk -F'!' '{print $1}')) — key already on GitHub"
        ;;
esac

# Not authed yet — use GitHub CLI (gh) device-code flow to register the
# pubkey automatically. The user types an 8-char code into the browser
# instead of copy-pasting an 80-char SSH key. gh handles auth, key upload,
# and (bonus) leaves a usable token for `gh repo clone`, `gh pr create` etc.
if [ "$SSH_AUTH_OK" = no ] && command -v gh >/dev/null 2>&1 && [ -t 0 ]; then
    note "registering SSH key on GitHub via 'gh' CLI (easier than copy-pasting)"

    # Step 1: ensure gh is authenticated to github.com.
    if ! gh auth status -h github.com >/dev/null 2>&1; then
        note "you'll see a short 8-character code — type it in the browser when prompted"
        # --git-protocol ssh tells gh to clone via SSH (matches the key we just
        # generated). --hostname pins it to github.com (vs ghe.io). --web opens
        # the verification page automatically.
        if gh auth login --hostname github.com --git-protocol ssh --web; then
            ok "authenticated to github.com via gh CLI"
        else
            note "gh auth login failed or was cancelled — falling back to manual flow"
        fi
    else
        ok "gh CLI already authenticated to github.com"
    fi

    # Step 2: add the SSH key via API (idempotent — checks current keys first).
    if gh auth status -h github.com >/dev/null 2>&1; then
        pubkey_content=$(awk '{print $2}' "$KEY.pub")
        if gh ssh-key list 2>/dev/null | grep -qF "$pubkey_content"; then
            ok "SSH key already registered on GitHub"
        else
            key_title="termux-$(whoami)-$(date +%Y-%m-%d)"
            if gh ssh-key add "$KEY.pub" --title "$key_title" 2>/dev/null; then
                ok "SSH key uploaded to GitHub (title: $key_title)"
                # Edge propagation — give GitHub a moment before re-testing.
                sleep 2
                ssh_test=$(check_ssh_github)
                case "$ssh_test" in
                    *"successfully authenticated"*)
                        SSH_AUTH_OK=yes
                        ok "SSH auth OK ($(printf '%s' "$ssh_test" | awk -F'Hi ' '{print $2}' | awk -F'!' '{print $1}'))"
                        ;;
                esac
            else
                note "gh ssh-key add failed — token may lack 'admin:public_key' scope"
                note "  re-run: gh auth refresh -h github.com -s admin:public_key"
            fi
        fi
    fi
fi

# Manual fallback — only kicks in if (a) gh isn't available, (b) gh auth was
# cancelled, or (c) gh upload failed AND ssh still isn't authenticated.
if [ "$SSH_AUTH_OK" = no ] && [ -t 0 ]; then
    PUBKEY=$(cat "$KEY.pub")
    clipboard_done=no
    if command -v termux-clipboard-set >/dev/null 2>&1; then
        if printf '%s' "$PUBKEY" | timeout 3 termux-clipboard-set 2>/dev/null; then
            clipboard_done=yes
        fi
    fi

    printf '\n'
    printf '  %sManual fallback — add this public key at https://github.com/settings/keys%s\n' "$_yellow" "$_reset"
    printf '  %s\n\n' "$PUBKEY"
    if [ "$clipboard_done" = yes ]; then
        ok "key copied to Android clipboard — paste it directly in the GitHub form"
    fi
    if command -v termux-open-url >/dev/null 2>&1; then
        timeout 3 termux-open-url "https://github.com/settings/ssh/new" >/dev/null 2>&1 \
            && ok "opened github.com/settings/ssh/new in your browser"
    fi

    printf '\n  Once the key is saved on GitHub, press ENTER (or "s" to skip): '
    read -r _retry
    if [ "$_retry" != "s" ] && [ "$_retry" != "S" ]; then
        ssh_test=$(check_ssh_github)
        case "$ssh_test" in
            *"successfully authenticated"*)
                SSH_AUTH_OK=yes
                ok "SSH auth OK on retry ($(printf '%s' "$ssh_test" | awk -F'Hi ' '{print $2}' | awk -F'!' '{print $1}'))"
                ;;
            *)
                note "SSH still failing — git push/pull over SSH won't work until fixed"
                note "  re-run setup.sh later or do it manually: ~/.ssh/id_ed25519.pub"
                ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# 7) Git identity
# ---------------------------------------------------------------------------
step "Git identity"
# pull --ff-only and main default are safe for everyone — set unconditionally.
git config --global pull.ff only
git config --global init.defaultBranch main
# Name/email are personal — prompt only if missing AND we have a TTY.
# If non-interactive and missing, leave unset (git will fail loudly on first
# commit, which is the right signal).
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

# Ensure $DEV_DIR exists on shared storage so hooks have something to walk.
# Cloning specific repos into it is the user's job — this installer is
# personal-repo agnostic.
#
# If a previous version of this script created $HOME/dev (real dir or
# symlink), clean it up so there is exactly one dev tree, at $DEV_DIR.
# Non-empty $HOME/dev is left alone with a warning — the user has to
# decide what to migrate (FUSE can't store everything a Termux home can).
if [ -L "$HOME/dev" ]; then
    rm -f "$HOME/dev"
elif [ -d "$HOME/dev" ]; then
    if [ -z "$(ls -A "$HOME/dev" 2>/dev/null)" ]; then
        rmdir "$HOME/dev"
    else
        note "leftover $HOME/dev is not empty — move its contents to $DEV_DIR manually, then \`rm -rf $HOME/dev\`"
    fi
fi
mkdir -p "$DEV_DIR"

# ---------------------------------------------------------------------------
# 8) Dev tools: Claude Code CLI
# ---------------------------------------------------------------------------
# Claude Code is the entire point of the bundle — install unconditionally,
# no prompt. The npm prefix is configured first so any later global install
# (yarn, pnpm, another CLI...) drops into the same user-scoped tree.

step "Dev tools"

# Pin npm prefix to ~/.npm-global so global installs don't touch $PREFIX.
NPM_PREFIX="$HOME/.npm-global"
mkdir -p "$NPM_PREFIX"
npm config set prefix "$NPM_PREFIX" >/dev/null 2>&1
export PATH="$NPM_PREFIX/bin:$PATH"

# Bake the prefix into bashrc.local so future shells pick it up without
# polluting the shared bashrc (which lives in the repo).
if ! grep -q 'NPM_PREFIX' "$HOME/.bashrc.local" 2>/dev/null; then
    cat >> "$HOME/.bashrc.local" <<EOF
# Added by termux-config setup.sh
export NPM_PREFIX="$NPM_PREFIX"
export PATH="\$NPM_PREFIX/bin:\$PATH"
EOF
fi

# Try the install up to twice: a fresh attempt, then a retry after clearing
# the npm cache (handles partial-download poisoning that survives reruns).
# npm's stdout/stderr is NOT redirected — claude is the entire point of the
# script, so if it fails the user needs to see the real error.
install_claude_native() {
    local attempt=1
    while [ "$attempt" -le 2 ]; do
        [ "$attempt" -eq 2 ] && {
            note "first install failed — clearing npm cache and retrying"
            npm cache clean --force >/dev/null 2>&1 || true
        }
        if npm install -g @anthropic-ai/claude-code; then
            # Post-install verification: `npm install` can return 0 even when
            # the binary isn't actually wired up (broken symlink, wrong prefix
            # at install time, etc.). Re-resolve via the configured prefix.
            local bin
            bin=$(npm bin -g 2>/dev/null)/claude
            if [ -x "$bin" ] || command -v claude >/dev/null 2>&1; then
                return 0
            fi
            note "npm reported success but claude binary not found at $bin"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

if ! command -v claude >/dev/null 2>&1; then
    note "installing @anthropic-ai/claude-code (can take a minute — npm output follows)"
    if install_claude_native; then
        ok "claude installed at $(command -v claude || printf '%s/claude' "$NPM_PREFIX/bin")"
    else
        fail "Claude Code install failed after retry. Diagnostic:"
        note "  Run manually: npm install -g @anthropic-ai/claude-code"
        note "  Check node:   node --version  (should be v20+)"
        note "  Check space:  df -h \$HOME"
        note "  If \"EACCES\" or permission error: rm -rf ~/.npm-global && rerun setup.sh"
    fi
else
    ok "claude already installed ($(command -v claude))"
fi

# ---------------------------------------------------------------------------
# 9) Auto-pull / auto-push hooks scoped to /storage/emulated/0/dev
# ---------------------------------------------------------------------------
step "Claude Code hooks"
mkdir -p "$HOOKS_DIR"
deploy_file "files/auto-pull.sh" "$HOOKS_DIR/auto-pull.sh" 0755
deploy_file "files/auto-push.sh" "$HOOKS_DIR/auto-push.sh" 0755
ok "$(short_path "$HOOKS_DIR/auto-pull.sh")"
ok "$(short_path "$HOOKS_DIR/auto-push.sh")"

# Patch ~/.claude/settings.json — preserve the existing keys (model, theme,
# enabledPlugins, etc.) and only overwrite the hooks block. Implemented in
# node so we don't depend on jq being installed.
SETTINGS="$CLAUDE_DIR/settings.json"
mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
backup_if_exists "$SETTINGS"

node - "$SETTINGS" "$HOOKS_DIR/auto-pull.sh" "$HOOKS_DIR/auto-push.sh" <<'NODE'
const fs = require('fs');
const [,, file, pullPath, pushPath] = process.argv;

let data = {};
try {
    const raw = fs.readFileSync(file, 'utf8').trim();
    data = raw ? JSON.parse(raw) : {};
} catch (e) {
    console.error('settings.json unreadable, starting fresh:', e.message);
    data = {};
}

data.hooks = data.hooks || {};
data.hooks.SessionStart = [{
    hooks: [{
        type: 'command',
        command: 'bash',
        args: [pullPath],
        timeout: 30,
        statusMessage: 'auto-pull...'
    }]
}];
data.hooks.SessionEnd = [{
    hooks: [{
        type: 'command',
        command: 'bash',
        args: [pushPath],
        timeout: 30,
        statusMessage: 'auto-push...'
    }]
}];

fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
NODE

if [ $? -eq 0 ]; then
    ok "$(short_path "$SETTINGS") patched"
else
    fail "settings.json patch failed — check $(short_path "$SETTINGS")"
fi

# ---------------------------------------------------------------------------
# 10b) Termux UX: auto-acquire wake lock on shell start
# ---------------------------------------------------------------------------
# Without a wake lock, Android (especially MIUI on Xiaomi) will throttle
# or kill Termux as soon as the screen turns off — destroying any tmux
# session, sshd, or long-running Claude Code prompt. termux-wake-lock
# requests a partial wake lock from Android: CPU keeps running, screen
# can still turn off (battery cost is small in practice).
# Release manually with `termux-wake-unlock` or remove the line from
# ~/.bashrc.local. The pgrep guard makes this a no-op if already held.
step "Wake lock (keep Claude Code alive in background)"
if ! grep -q '^# termux-config: wake lock' "$HOME/.bashrc.local" 2>/dev/null; then
    cat >> "$HOME/.bashrc.local" <<'EOF'

# termux-config: wake lock — prevents Android from suspending Termux while
# tmux/sshd/claude are running. Remove this line if you'd rather conserve
# battery and don't run long-running sessions.
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
EOF
    ok "auto-acquire on shell start (release with termux-wake-unlock)"
else
    ok "already configured in ~/.bashrc.local"
fi
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null

# ---------------------------------------------------------------------------
# 10) Optional: SSH server (control Termux from your PC) + Tailscale
# ---------------------------------------------------------------------------
# Termux's sshd listens on port 8022 (Android blocks <1024 without root) and
# uses the running uid for the username — i.e. whatever `whoami` returns.
# State-aware: only prompt to install when missing. If sshd is already
# installed, we just ensure autostart is wired up and print the connection
# info so the user remembers how to connect. Same for Tailscale.

step "Remote access from PC (optional)"

# --- Detect current state ---
sshd_installed=no; dpkg -s openssh >/dev/null 2>&1 && sshd_installed=yes
sshd_running=no;   pgrep -x sshd >/dev/null 2>&1   && sshd_running=yes
tailscale_installed=no; dpkg -s tailscale >/dev/null 2>&1 && tailscale_installed=yes

# --- Decide what to do ---
# If already installed, treat as "yes" (so the post-install wiring still runs
# idempotently — autostart line, info print). If absent, prompt only when TTY.
setup_sshd=$sshd_installed
setup_tailscale=$tailscale_installed

if [ "$sshd_installed" = no ] && [ -t 0 ]; then
    printf '  Install OpenSSH server so you can ssh into Termux from your PC? [y/N] '
    read -r _ans
    case "$_ans" in [yY]*) setup_sshd=yes ;; esac
elif [ "$sshd_installed" = yes ]; then
    ok "openssh already installed (sshd $([ "$sshd_running" = yes ] && echo running || echo 'not running — will autostart'))"
fi

if [ "$setup_sshd" = yes ] && [ "$tailscale_installed" = no ] && [ -t 0 ]; then
    printf '  Also install Tailscale CLI for access from any network (not just local Wi-Fi)? [y/N] '
    read -r _ans
    case "$_ans" in [yY]*) setup_tailscale=yes ;; esac
elif [ "$tailscale_installed" = yes ]; then
    ok "tailscale already installed"
fi

if [ "$sshd_installed" = no ] && [ ! -t 0 ]; then
    note "non-interactive shell — skipping sshd prompt. Re-run from a TTY to enable it."
fi

# --- Install if needed ---
if [ "$setup_sshd" = yes ] && [ "$sshd_installed" = no ]; then
    pkg install -y openssh >/dev/null 2>&1 \
        && ok "openssh installed" \
        || { note "openssh install failed"; setup_sshd=no; }
fi

# --- Wire up sshd (autostart + authorized_keys + info), skipped if not setup ---
if [ "$setup_sshd" = yes ]; then
    touch "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"

    # Optional: trust a PC's pubkey so SSH from that PC skips the password
    # prompt. Two-step: (1) y/N gate with a one-line "why", (2) paste only
    # if user opts in. Skipped entirely when authorized_keys already has a
    # key — that's the "already set up" signal. Never bundle a key in the
    # repo: a public installer that grants the maintainer ssh into every
    # forker's phone would be a backdoor.
    keys_present=no
    if [ -s "$SSH_DIR/authorized_keys" ] && grep -q '^ssh-' "$SSH_DIR/authorized_keys" 2>/dev/null; then
        keys_present=yes
    fi
    if [ "$keys_present" = yes ]; then
        _nkeys=$(grep -c '^ssh-' "$SSH_DIR/authorized_keys" 2>/dev/null || printf 0)
        ok "$_nkeys PC key(s) already authorized — password-less SSH ready"
    elif [ -t 0 ]; then
        printf '\n  Trust your PC for SSH (no password)? [y/N]\n'
        printf '    %sNeeds: ~/.ssh/id_ed25519.pub from your PC.%s\n' "$_dim" "$_reset"
        printf '  > '
        read -r _ans
        case "$_ans" in
            [yY]*)
                printf '\n  Paste the pubkey line:\n  > '
                read -r pc_pubkey
                case "$pc_pubkey" in
                    ssh-*)
                        if grep -qxF "$pc_pubkey" "$SSH_DIR/authorized_keys" 2>/dev/null; then
                            ok "key already in authorized_keys"
                        else
                            printf '%s\n' "$pc_pubkey" >> "$SSH_DIR/authorized_keys"
                            ok "PC key added to authorized_keys"
                        fi
                        ;;
                    "")
                        note "no key pasted — keeping password auth"
                        ;;
                    *)
                        note "doesn't look like an SSH pubkey (should start with 'ssh-')"
                        ;;
                esac
                ;;
            *)
                ok "keeping password auth"
                ;;
        esac
    fi

    # Autostart sshd whenever Termux opens. Lives in bashrc.local (gitignored)
    # rather than the shared bashrc so opting out is a one-line edit.
    if ! grep -q '^# termux-config: sshd autostart' "$HOME/.bashrc.local" 2>/dev/null; then
        cat >> "$HOME/.bashrc.local" <<'EOF'

# termux-config: sshd autostart — listens on 8022 (Android blocks <1024).
# pgrep guard makes this a no-op if sshd is already running.
pgrep -x sshd >/dev/null 2>&1 || sshd 2>/dev/null
EOF
        ok "sshd autostart added to ~/.bashrc.local"
    fi
    pgrep -x sshd >/dev/null 2>&1 || sshd 2>/dev/null

    # Print connection info every run — useful reminder even on idempotent
    # re-runs. `ip route get` works without root on Termux when wifi is up.
    local_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    termux_user=$(whoami)
    printf '\n  %ssshd running on port 8022.%s\n' "$_green" "$_reset"
    if [ -n "$local_ip" ]; then
        printf '  Same Wi-Fi from your PC:  %sssh -p 8022 %s@%s%s\n' "$_dim" "$termux_user" "$local_ip" "$_reset"
    else
        printf '  Wi-Fi IP not detected. Check Android Settings → Wi-Fi → connected network.\n'
    fi
fi

# --- Tailscale (install + first-run instructions only if newly installed) ---
if [ "$setup_tailscale" = yes ] && [ "$tailscale_installed" = no ]; then
    if pkg install -y tailscale >/dev/null 2>&1; then
        ok "tailscale CLI installed"
        tailscale_installed=yes
    else
        note "tailscale install failed (Termux community repo may need refresh)"
    fi
fi
if [ "$setup_tailscale" = yes ] && [ "$tailscale_installed" = yes ]; then
    # First-time wiring info — only when tailscale isn't yet authenticated.
    # `tailscale status` exits non-zero before login; we use that as the gate.
    if ! tailscale status >/dev/null 2>&1; then
        printf '\n  Tailscale CLI needs a one-time setup. In two separate Termux tabs run:\n'
        printf '    %sTab 1: tailscaled%s   (keep this tab open — it is the daemon)\n' "$_dim" "$_reset"
        printf '    %sTab 2: tailscale up%s (open the URL it prints, log in to your tailnet)\n' "$_dim" "$_reset"
        printf '  Then from your PC on any network:  %sssh -p 8022 %s@<phone-tailscale-ip>%s\n' "$_dim" "$(whoami)" "$_reset"
        note "Easier alternative: install the official Tailscale Android app — same 100.x.x.x IP, no CLI dance."
    else
        ok "tailscale authenticated and running"
    fi
fi

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
printf '\n  %sDone.%s\n\n' "$_green" "$_reset"
printf '  %sRecommended workflow:%s\n' "$_yellow" "$_reset"
printf '    %s1.%s  git clone git@github.com:YOUR/REPO.git %s/REPO\n' "$_dim" "$_reset" "$DEV_DIR"
printf '    %s2.%s  tmain                       %s# attach the persistent tmux session%s\n' "$_dim" "$_reset" "$_dim" "$_reset"
printf '    %s3.%s  cd %s/REPO && claude     %s# SessionStart auto-pulls%s\n' "$_dim" "$_reset" "$DEV_DIR" "$_dim" "$_reset"
printf '    %s4.%s  Ctrl+B then D               %s# detach; close Termux; come back later with tmain%s\n\n' "$_dim" "$_reset" "$_dim" "$_reset"
printf '  Docs: %shttps://github.com/ahmed-mili/dev-environment%s\n\n' "$_dim" "$_reset"

# Auto-reload the shell so the user gets the new look + blesh + starship
# immediately, no `source ~/.bashrc` to remember. exec replaces this script
# process with a fresh interactive login bash — when the user types `exit`
# they go back to whatever shell launched the bootstrap (or Termux closes).
# Gated on stdin+stdout being a TTY: skip in CI, non-interactive pipes, etc.
if [ -t 0 ] && [ -t 1 ]; then
    printf '  %sLoading the new shell...%s\n\n' "$_dim" "$_reset"
    exec bash -l
fi

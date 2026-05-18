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
#   - prompts (optional) for Ollama, sshd, Tailscale
#   - drops auto-pull / auto-push hooks scoped to ~/dev and patches
#     ~/.claude/settings.json so SessionStart pulls and SessionEnd pushes
#
# The installer is personal-repo agnostic: it sets up the Termux + Claude
# Code environment, then leaves ~/dev/ empty for you to `git clone` your
# own repos into.
#
# Idempotent: re-running picks up where the previous run stopped, skips
# anything already in place, and never overwrites without a timestamped
# backup. Safe to invoke after upgrading Termux or wiping ~/.bashrc.
#
# Usage (from anywhere on the phone — paste as one line):
#   curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; \
#   pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh)
# or, after cloning the repo:
#   bash ~/dev/dev-environment/android/setup.sh
#
# The `dpkg -r` preamble is a no-op on a healthy Termux. It only fires on
# the broken-libngtcp2 builds where curl is dynamically dead, which also
# breaks `pkg install` itself (pkg shells out to curl for mirror selection).
# Process-substitution `bash <(...)` instead of `curl ... | bash` because
# the GitHub-SSH / sshd / ollama prompts in this script need stdin attached
# to a TTY (see `[ -t 0 ]` checks below).
# ---------------------------------------------------------------------------

set -u
# We never want a single failing optional step to abort the whole install,
# so individual blocks below decide whether to fail-fast on their own.

REPO_RAW="https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android"

DEV_DIR="$HOME/dev"
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
# (irrelevant for GitHub, npm, ollama.com — all serve HTTP/2).
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

PUBKEY=$(cat "$KEY.pub")

# UX shortcuts when the Termux:API Android app is installed (not just the
# `termux-api` pkg): drop the pubkey straight into the Android clipboard
# and open the GitHub form in a browser tab. Both calls are wrapped in
# `timeout` because without the companion app the helpers hang forever
# (they expect an answering daemon that never appears). 3s is enough for
# the real daemon to respond; longer means the app is missing.
clipboard_done=no
api_app_missing=no
if command -v termux-clipboard-set >/dev/null 2>&1; then
    if printf '%s' "$PUBKEY" | timeout 3 termux-clipboard-set 2>/dev/null; then
        clipboard_done=yes
    else
        api_app_missing=yes
    fi
fi

printf '\n'
printf '  %sPublic key — add this at https://github.com/settings/keys (New SSH key)%s\n' "$_yellow" "$_reset"
# Print without dim so the terminal lets you long-press-select the line
# cleanly even when the clipboard helper above is unavailable.
printf '  %s\n\n' "$PUBKEY"
if [ "$clipboard_done" = yes ]; then
    ok "key copied to Android clipboard — paste it directly in the GitHub form"
fi
if [ "$clipboard_done" = no ] && command -v termux-open-url >/dev/null 2>&1; then
    # Only try open-url when clipboard worked or wasn't present — if clipboard
    # already timed out the API app is missing, no point hanging again.
    timeout 3 termux-open-url "https://github.com/settings/ssh/new" >/dev/null 2>&1 \
        && ok "opened github.com/settings/ssh/new in your browser"
elif [ "$clipboard_done" = yes ]; then
    timeout 3 termux-open-url "https://github.com/settings/ssh/new" >/dev/null 2>&1 \
        && ok "opened github.com/settings/ssh/new in your browser"
fi
if [ "$api_app_missing" = yes ]; then
    note "Termux:API CLI is installed but the Android companion app isn't —"
    note "  long-press the key above to select+copy it manually, then open"
    note "  https://github.com/settings/ssh/new in any browser."
    note "  (Install Termux:API from F-Droid for one-tap clipboard next time.)"
fi

# Don't block forever in non-interactive contexts (curl|bash from another
# script); only prompt when stdin is a TTY.
if [ -t 0 ]; then
    printf '\n  Once the key is saved on GitHub, come back to Termux and press ENTER... '
    read -r _
fi

# Verify connectivity. ssh -T github.com always exits 1 even on success
# (GitHub never grants a shell), so we grep the welcome line instead.
# Retry once if the user pressed ENTER too early — GitHub's edge takes a few
# seconds to propagate a newly-added key, and people commonly forget to add
# it at all the first time round.
SSH_AUTH_OK=no
check_ssh_github() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true
}
ssh_test=$(check_ssh_github)
case "$ssh_test" in
    *"successfully authenticated"*)
        SSH_AUTH_OK=yes
        ok "SSH auth OK ($(printf '%s' "$ssh_test" | awk -F'Hi ' '{print $2}' | awk -F'!' '{print $1}'))"
        ;;
esac

if [ "$SSH_AUTH_OK" = no ] && [ -t 0 ]; then
    note "SSH auth to github.com failed. Most common cause: pubkey not yet"
    note "added to https://github.com/settings/keys (or added <10s ago — GitHub"
    note "edge takes a moment to propagate)."
    printf '\n  Re-check now? Add the key (printed above) then press ENTER, or type s to skip: '
    read -r _retry
    if [ "$_retry" != "s" ] && [ "$_retry" != "S" ]; then
        ssh_test=$(check_ssh_github)
        case "$ssh_test" in
            *"successfully authenticated"*)
                SSH_AUTH_OK=yes
                ok "SSH auth OK on retry ($(printf '%s' "$ssh_test" | awk -F'Hi ' '{print $2}' | awk -F'!' '{print $1}'))"
                ;;
            *)
                note "SSH still failing. Output: $ssh_test"
                note "git push/pull over SSH won't work until this is fixed."
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

# Ensure $DEV_DIR exists so hooks targeting ~/dev have something to walk.
# Cloning specific repos into it is the user's job — this installer is
# personal-repo agnostic.
mkdir -p "$DEV_DIR"

# ---------------------------------------------------------------------------
# 8) Dev tools: Claude Code CLI (always) + Ollama (opt-in)
# ---------------------------------------------------------------------------
# Claude Code is the entire point of the bundle — install unconditionally,
# no prompt. Ollama is opt-in because each model is multi-GB and not
# everyone wants local inference. The npm prefix is configured first so
# any later global install (yarn, pnpm, another CLI...) drops into the
# same user-scoped tree.

step "Dev tools"
install_ollama=no
if [ -t 0 ]; then
    printf '  Install Ollama (ollama run <model>, etc.)? [y/N] '
    read -r _ans
    case "$_ans" in [yY]*) install_ollama=yes ;; esac
fi

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

if [ "$install_ollama" = yes ]; then
    # Strategy: prefer the Termux native `ollama` package when it provides the
    # `launch` subcommand (Ollama v0.15+ — needed for `ollama launch claude
    # --model X:cloud -y -- <flags>`). If the native package is missing or
    # too old, fall back to proot-distro + Ubuntu + the official install.sh,
    # which always pulls the latest release. A wrapper at $PREFIX/bin/ollama
    # forwards calls into the proot so the CLI UX is unchanged.
    #
    # Sentinel ($PREFIX/bin/ollama.proot) distinguishes proot wrapper from
    # native binary on re-runs.

    # `ollama help launch` succeeds (exits 0) on v0.15+ and fails on older
    # versions. Cheaper than parsing `ollama --version`.
    ollama_has_launch() {
        ollama help launch >/dev/null 2>&1
    }

    ollama_mode=""

    # Path 1: previous proot install — keep it.
    if [ -f "$PREFIX/bin/ollama.proot" ] && command -v ollama >/dev/null 2>&1; then
        if ollama_has_launch; then
            ok "ollama (proot-distro wrapper, supports launch) already installed"
            ollama_mode=proot
        else
            note "existing proot Ollama is too old — refreshing inside the Ubuntu proot"
            proot-distro login ubuntu -- bash -c '
                curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
            ' && ok "proot Ollama upgraded"
            ollama_mode=proot
        fi
    fi

    # Path 2: native (existing or newly installed). Only accept it if it has
    # `launch`; otherwise remove it and fall through to proot.
    if [ -z "$ollama_mode" ]; then
        native_present=no
        if command -v ollama >/dev/null 2>&1; then
            native_present=yes
        elif pkg install -y ollama >/dev/null 2>&1 && command -v ollama >/dev/null 2>&1; then
            native_present=yes
        fi
        if [ "$native_present" = yes ]; then
            if ollama_has_launch; then
                ok "ollama (native, v0.15+) at $(command -v ollama)"
                ollama_mode=native
            else
                note "native ollama lacks the \`launch\` subcommand (needs v0.15+) — removing and switching to proot"
                pkg uninstall -y ollama >/dev/null 2>&1 || rm -f "$PREFIX/bin/ollama"
            fi
        fi
    fi

    # Path 3: proot-distro fallback. install.sh always tracks the latest release.
    if [ -z "$ollama_mode" ]; then
        note "installing Ollama via proot-distro (gives latest v0.15+ with \`launch\` support)"
        if ! command -v proot-distro >/dev/null 2>&1; then
            pkg install -y proot-distro >/dev/null 2>&1 || fail "proot-distro install failed"
        fi
        if ! proot-distro list 2>/dev/null | grep -qiE 'ubuntu.*installed'; then
            note "installing Ubuntu in proot (one-time ~150MB download)..."
            proot-distro install ubuntu >/dev/null 2>&1 || fail "proot-distro install ubuntu failed"
        fi
        note "installing Ollama inside the Ubuntu proot (one-time ~1GB)..."
        proot-distro login ubuntu -- bash -c '
            command -v ollama >/dev/null 2>&1 || {
                apt-get update -y >/dev/null 2>&1
                apt-get install -y curl ca-certificates >/dev/null 2>&1
                curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
            }
        ' || fail "Ollama install inside proot failed"

        : > "$PREFIX/bin/ollama.proot"
        cat > "$PREFIX/bin/ollama" <<'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
# Installed by termux-config: routes every `ollama` call into the Ubuntu
# proot so the CLI UX matches a real PC — `ollama run llama3.2:1b`,
# `ollama pull glm-5:cloud`, `ollama launch claude --model X:cloud -y -- ...`
# all work unchanged. --shared-tmp keeps /tmp shared so model downloads
# can be inspected from Termux too.
exec proot-distro login ubuntu --shared-tmp -- ollama "$@"
WRAPPER
        chmod +x "$PREFIX/bin/ollama"
        ok "ollama wrapper installed (proot-distro ubuntu backend)"
        ollama_mode=proot
    fi

    # When ollama runs inside the Ubuntu proot, `ollama launch claude ...`
    # spawns `claude` from the proot's $PATH — NOT from Termux's. The native
    # claude install above is invisible to it. Install Claude Code inside
    # the proot too so the wrapper actually works.
    if [ "$ollama_mode" = proot ]; then
        note "installing Claude Code inside the proot Ubuntu so \`ollama launch claude\` can find it"
        proot-distro login ubuntu -- bash -c '
            set -e
            if command -v claude >/dev/null 2>&1; then
                echo "claude already present in proot"
                exit 0
            fi
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl ca-certificates >/dev/null 2>&1
            # NodeSource keeps a current Node 22 LTS for arm64. The apt
            # nodejs package on Ubuntu 22.04 is too old (v12) and would
            # fail to install the modern Claude Code CLI.
            if ! command -v node >/dev/null 2>&1 || [ "$(node -v 2>/dev/null | sed s/v// | cut -d. -f1)" -lt 20 ]; then
                curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
                apt-get install -y nodejs >/dev/null 2>&1
            fi
            npm install -g @anthropic-ai/claude-code
        ' && ok "claude installed inside proot Ubuntu" \
          || fail "claude install inside proot failed — run manually: proot-distro login ubuntu, then npm install -g @anthropic-ai/claude-code"
    fi

    # Autostart `ollama serve` in the background whenever Termux opens, so
    # `ollama run` calls connect to a ready daemon (same UX as the ollama
    # systemd service on PC). pgrep guard makes the line a no-op on re-entry.
    if ! grep -q '^# termux-config: ollama serve autostart' "$HOME/.bashrc.local" 2>/dev/null; then
        cat >> "$HOME/.bashrc.local" <<'EOF'

# termux-config: ollama serve autostart — listens on 127.0.0.1:11434.
# No-op if a server is already running.
if command -v ollama >/dev/null 2>&1 && ! pgrep -f 'ollama serve' >/dev/null 2>&1; then
    nohup ollama serve >"$HOME/.ollama.log" 2>&1 &
    disown
fi
EOF
    fi
    if command -v ollama >/dev/null 2>&1 && ! pgrep -f 'ollama serve' >/dev/null 2>&1; then
        nohup ollama serve >"$HOME/.ollama.log" 2>&1 &
        disown 2>/dev/null || true
        ok "ollama serve started in the background (logs: ~/.ollama.log)"
    else
        ok "ollama serve already running"
    fi

    # Cloud models (`glm-5.1:cloud`, `kimi-k2.5:cloud`, etc.) are proxied
    # through ollama.com and need either `ollama signin` or an OLLAMA_API_KEY
    # env var. Run signin straight away — if the user installed Ollama they
    # almost certainly want cloud models, and the signin flow itself is
    # interactive (browser device-code), so refusing it just means an extra
    # command later. Skip silently if non-TTY or daemon not up.
    if [ -t 0 ] && pgrep -f 'ollama serve' >/dev/null 2>&1; then
        sleep 1
        if ollama signin; then
            ok "signed in to ollama.com — :cloud models now available"
        else
            note "ollama signin not completed — re-run \`ollama signin\` later for :cloud models"
        fi
    fi

    if [ "$ollama_mode" = proot ]; then
        note "proot adds startup latency. Suggested first commands:"
        note "  ollama run qwen2.5:0.5b                                          # local, ~400MB, snappy"
        note "  ollama launch claude --model glm-5.1:cloud -y -- --dangerously-skip-permissions"
    else
        note "Suggested first commands:"
        note "  ollama run qwen2.5:0.5b                                          # local, ~400MB, snappy"
        note "  ollama launch claude --model glm-5.1:cloud -y -- --dangerously-skip-permissions"
    fi
fi

# ---------------------------------------------------------------------------
# 10) Auto-pull / auto-push hooks scoped to ~/dev
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
# 11) Optional: SSH server (control Termux from your PC) + Tailscale
# ---------------------------------------------------------------------------
# Termux's sshd listens on port 8022 (Android blocks <1024 without root) and
# uses the running uid for the username — i.e. whatever `whoami` returns.
# We ask before installing so users who only want the local setup don't get
# an extra daemon and an open port for nothing.

step "Remote access from PC (optional)"
install_sshd=no
install_tailscale=no
if [ -t 0 ]; then
    printf '  Install OpenSSH server so you can ssh into Termux from your PC? [y/N] '
    read -r _ans
    case "$_ans" in [yY]*) install_sshd=yes ;; esac
    if [ "$install_sshd" = yes ]; then
        printf '  Also install Tailscale CLI for access from any network (not just local Wi-Fi)? [y/N] '
        read -r _ans
        case "$_ans" in [yY]*) install_tailscale=yes ;; esac
    fi
else
    note "non-interactive shell — skipping prompts. Re-run from a TTY to enable sshd."
fi

if [ "$install_sshd" = yes ]; then
    if ! dpkg -s openssh >/dev/null 2>&1; then
        pkg install -y openssh >/dev/null 2>&1 \
            && ok "openssh installed" \
            || { fail "openssh install failed"; install_sshd=no; }
    else
        ok "openssh already installed"
    fi
fi

if [ "$install_sshd" = yes ]; then
    touch "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"

    # Ask the user for their PC pubkey. We deliberately do NOT bundle any
    # key in the repo: this is a public installer, and a bundled pubkey
    # would silently grant the maintainer SSH access into every forker's
    # phone. The right authorization model is "the person installing
    # decides whose key gets in".
    if [ -t 0 ]; then
        printf '\n  Paste your PC pubkey (from ~/.ssh/id_ed25519.pub on the PC).\n'
        printf '  Leave empty to skip — append later to ~/.ssh/authorized_keys.\n'
        printf '  PC pubkey > '
        read -r pc_pubkey
        if [ -n "$pc_pubkey" ]; then
            if grep -qxF "$pc_pubkey" "$SSH_DIR/authorized_keys" 2>/dev/null; then
                ok "PC key already in authorized_keys"
            else
                printf '%s\n' "$pc_pubkey" >> "$SSH_DIR/authorized_keys"
                ok "PC key added to authorized_keys"
            fi
        else
            note "no PC key added — append it later or run \`passwd\` for password auth"
        fi
    else
        note "no TTY — skipping authorized_keys prompt. Append your PC pubkey to ~/.ssh/authorized_keys manually."
    fi

    # Autostart sshd whenever Termux opens. Lives in bashrc.local (gitignored)
    # rather than the shared bashrc so opting out is a one-line edit.
    if ! grep -q '^# termux-config: sshd autostart' "$HOME/.bashrc.local" 2>/dev/null; then
        cat >> "$HOME/.bashrc.local" <<'EOF'

# termux-config: sshd autostart — listens on 8022 (Android blocks <1024).
# pgrep guard makes this a no-op if sshd is already running.
pgrep -x sshd >/dev/null 2>&1 || sshd 2>/dev/null
EOF
    fi
    pgrep -x sshd >/dev/null 2>&1 || sshd 2>/dev/null

    # Discover the local Wi-Fi IP so we can print the exact ssh command.
    # `ip route get` works without root on Termux when wifi is up.
    local_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    termux_user=$(whoami)
    printf '\n  %ssshd running on port 8022.%s\n' "$_green" "$_reset"
    if [ -n "$local_ip" ]; then
        printf '  Same Wi-Fi from your PC:  %sssh -p 8022 %s@%s%s\n' "$_dim" "$termux_user" "$local_ip" "$_reset"
    else
        printf '  Wi-Fi IP not detected. Run %sifconfig wlan0%s on the phone to find it.\n' "$_dim" "$_reset"
    fi
fi

if [ "$install_tailscale" = yes ]; then
    if ! dpkg -s tailscale >/dev/null 2>&1; then
        pkg install -y tailscale >/dev/null 2>&1 \
            && ok "tailscale CLI installed" \
            || fail "tailscale install failed (Termux community repo may need refresh)"
    else
        ok "tailscale already installed"
    fi
    printf '\n  Tailscale CLI needs a one-time setup. In two separate Termux tabs run:\n'
    printf '    %sTab 1: tailscaled%s   (keep this tab open — it is the daemon)\n' "$_dim" "$_reset"
    printf '    %sTab 2: tailscale up%s (open the URL it prints, log in to your tailnet)\n' "$_dim" "$_reset"
    printf '  Then from your PC on any network:  %sssh -p 8022 %s@<phone-tailscale-ip>%s\n' "$_dim" "$(whoami)" "$_reset"
    note "Easier alternative: install the official Tailscale Android app — same 100.x.x.x IP, no CLI dance."
fi

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
printf '\n  %sDone.%s\n' "$_green" "$_reset"
printf '  Restart Termux (or run %ssource ~/.bashrc%s) for the look + prompt to take effect.\n\n' "$_dim" "$_reset"
printf '  %sRecommended workflow:%s\n' "$_yellow" "$_reset"
printf '    %s1.%s  git clone git@github.com:YOUR/REPO.git ~/dev/REPO\n' "$_dim" "$_reset"
printf '    %s2.%s  tmain                       %s# attach the persistent tmux session%s\n' "$_dim" "$_reset" "$_dim" "$_reset"
printf '    %s3.%s  cd ~/dev/REPO && claude     %s# SessionStart auto-pulls%s\n' "$_dim" "$_reset" "$_dim" "$_reset"
printf '    %s4.%s  Ctrl+B then D               %s# detach; close Termux; come back later with tmain%s\n\n' "$_dim" "$_reset" "$_dim" "$_reset"
printf '  Ollama cloud (if you installed Ollama and signed in):\n'
printf '    %sollama launch claude --model glm-5.1:cloud -y -- --dangerously-skip-permissions%s\n\n' "$_dim" "$_reset"
printf '  Docs: %shttps://github.com/ahmed-mili/dev-environment%s\n\n' "$_dim" "$_reset"

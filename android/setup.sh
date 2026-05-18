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
#   - clones the five dev repos under ~/dev/ (kebab-case mirrors)
#   - drops auto-pull / auto-push hooks scoped to ~/dev and patches
#     ~/.claude/settings.json so SessionStart pulls and SessionEnd pushes
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
REPO_OWNER="ahmed-mili"
REPOS=(
    "droid-detector"
    "droid-tycoon-rebirth-guide"
    "efrei-projet-web"
    "obsidian-neo-calendar"
    "obsidian-quiz-blocks"
)

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
ok "packages ready"

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
    ssh-keygen -t ed25519 -C "ahmedmili435@gmail.com (termux)" -f "$KEY" -N "" >/dev/null
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
                note "Repo clones will be skipped; re-run setup.sh after fixing SSH."
                ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# 7) Git identity
# ---------------------------------------------------------------------------
step "Git identity"
if [ -z "$(git config --global user.name)" ]; then
    git config --global user.name  "Ahmed MILI"
fi
if [ -z "$(git config --global user.email)" ]; then
    git config --global user.email "ahmedmili435@gmail.com"
fi
# pull --ff-only by default — matches the auto-pull hook policy.
git config --global pull.ff only
git config --global init.defaultBranch main
ok "$(git config --global user.name) <$(git config --global user.email)>"

# ---------------------------------------------------------------------------
# 8) Clone the five dev repos
# ---------------------------------------------------------------------------
step "Clone repos under $(short_path "$DEV_DIR")"
mkdir -p "$DEV_DIR"
# If SSH auth didn't confirm, skip all clones. The HTTPS fallback would
# prompt for a username/password on private repos and lock up the install
# in an interactive loop the user can't escape cleanly — exactly the
# "Username for 'https://github.com':" trap. Idempotent re-run is the
# right escape hatch instead: fix SSH, run setup.sh again, clones resume.
SKIPPED_REPOS=()
if [ "$SSH_AUTH_OK" != yes ]; then
    note "Skipping repo clones (SSH to github.com not authenticated)."
    note "After adding the pubkey to GitHub, re-run setup.sh to clone."
    for r in "${REPOS[@]}"; do
        [ -d "$DEV_DIR/$r/.git" ] && continue
        SKIPPED_REPOS+=("$r")
    done
else
    for r in "${REPOS[@]}"; do
        target="$DEV_DIR/$r"
        if [ -d "$target/.git" ]; then
            ok "$r (already cloned)"
            continue
        fi
        if [ -e "$target" ] && [ ! -d "$target/.git" ]; then
            note "$r exists but is not a git repo — skipping"
            continue
        fi
        # GIT_TERMINAL_PROMPT=0 belt-and-suspenders: if SSH unexpectedly
        # fails for a single repo (e.g. archived, access revoked), git
        # will NOT fall back to an HTTPS credential prompt.
        if GIT_TERMINAL_PROMPT=0 git clone "git@github.com:$REPO_OWNER/$r.git" "$target" 2>/tmp/.clone-err; then
            ok "$r"
        else
            err_short=$(head -1 /tmp/.clone-err 2>/dev/null | tr -d '\r')
            fail "$r clone failed (${err_short:-unknown})"
            SKIPPED_REPOS+=("$r")
        fi
    done
    rm -f /tmp/.clone-err
fi

# ---------------------------------------------------------------------------
# 9) Optional dev tools: Claude Code CLI + Ollama
# ---------------------------------------------------------------------------
# Both prompts default to "claude=yes, ollama=no" because Claude Code is the
# point of this whole bundle, while Ollama models eat several GB each — let
# the user opt in when they have the storage and want local inference.
# Either way the npm prefix is configured first so any later global install
# (yarn, pnpm, another CLI...) drops into the same user-scoped tree.

step "Dev tools (optional)"
install_claude=yes
install_ollama=no
if [ -t 0 ]; then
    printf '  Install Claude Code CLI (claude, claude --dangerously-skip-permissions)? [Y/n] '
    read -r _ans
    case "$_ans" in [nN]*) install_claude=no ;; esac
    printf '  Install Ollama (ollama run <model>, etc.)? [y/N] '
    read -r _ans
    case "$_ans" in [yY]*) install_ollama=yes ;; esac
else
    note "non-interactive — defaulting to claude=yes, ollama=no"
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

if [ "$install_claude" = yes ]; then
    if ! command -v claude >/dev/null 2>&1; then
        note "installing @anthropic-ai/claude-code (may take a minute)"
        if npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; then
            ok "claude installed at $(command -v claude)"
        else
            fail "npm install failed — run manually: npm install -g @anthropic-ai/claude-code"
        fi
    else
        ok "claude already installed ($(command -v claude))"
    fi
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
    # env var. Offer signin interactively; users who prefer the API key path
    # can set OLLAMA_API_KEY in ~/.bashrc.local manually.
    if [ -t 0 ]; then
        printf '\n  Sign in to ollama.com now (needed for :cloud models like glm-5.1:cloud)? [Y/n] '
        read -r _ans
        case "$_ans" in
            [nN]*)
                note "skipped — run \`ollama signin\` later, or set OLLAMA_API_KEY in ~/.bashrc.local"
                ;;
            *)
                # signin needs the daemon up; we just started it, give it a beat.
                sleep 1
                if ollama signin; then
                    ok "signed in to ollama.com — :cloud models now available"
                else
                    note "signin did not complete — re-run \`ollama signin\` whenever you want cloud models"
                fi
                ;;
        esac
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

    # Prefer the pubkey bundled in the repo (files/pc-authorized_keys) — that's
    # the maintainer's PC keys, committed because pubkeys are public-by-design
    # and committing them turns this into a true one-command install. Fall back
    # to prompting if the file is missing (e.g. someone forked and removed it).
    pc_keys=""
    if pc_keys=$(read_file "files/pc-authorized_keys" 2>/dev/null) && [ -n "$pc_keys" ]; then
        added=0
        while IFS= read -r line; do
            # Skip blank lines and comments.
            case "$line" in ''|'#'*) continue ;; esac
            if ! grep -qxF "$line" "$SSH_DIR/authorized_keys" 2>/dev/null; then
                printf '%s\n' "$line" >> "$SSH_DIR/authorized_keys"
                added=$((added + 1))
            fi
        done <<EOF
$pc_keys
EOF
        if [ "$added" -gt 0 ]; then
            ok "$added PC key(s) added to authorized_keys from files/pc-authorized_keys"
        else
            ok "PC key(s) already present in authorized_keys"
        fi
    elif [ -t 0 ]; then
        printf '\n  No bundled PC pubkey found. Paste yours now (from ~/.ssh/id_ed25519.pub on Windows).\n'
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
        note "no bundled key and no TTY — skipping authorized_keys setup"
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
printf '  Restart Termux (or run %ssource ~/.bashrc%s) for the look + prompt to take effect.\n' "$_dim" "$_reset"
printf '  Then launch %sclaude%s inside any repo under %s~/dev/%s — SessionStart will auto-pull.\n\n' "$_dim" "$_reset" "$_dim" "$_reset"

if [ "${#SKIPPED_REPOS[@]}" -gt 0 ]; then
    printf '  %s%d repo(s) still to clone:%s %s\n' "$_yellow" "${#SKIPPED_REPOS[@]}" "$_reset" "${SKIPPED_REPOS[*]}"
    printf '  Fix SSH (add %s~/.ssh/id_ed25519.pub%s to https://github.com/settings/keys),\n' "$_dim" "$_reset"
    printf '  verify with %sssh -T git@github.com%s, then re-run this setup.sh — it is idempotent\n' "$_dim" "$_reset"
    printf '  and will resume at the clone step.\n\n'
fi

printf '  Docs: %shttps://github.com/ahmed-mili/dev-environment%s\n\n' "$_dim" "$_reset"

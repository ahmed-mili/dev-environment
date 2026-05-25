#!/data/data/com.termux/files/usr/bin/bash
# ---------------------------------------------------------------------------
# Migrate a Termux from any previous incarnation of this repo to the current
# "SSH client" workflow. Two generations are cleaned in one pass, then
# setup-ssh-client.sh is re-run.
#
#   Generation 1 — Ollama + proot-distro Ubuntu (mid-2025 dev-environment)
#       * proot-distro Ubuntu install
#       * $PREFIX/bin/ollama wrapper + ~/.ollama.log
#       * "ollama serve autostart" block in ~/.bashrc.local
#
#   Generation 2 — Native Claude Code on Termux (early-2026 dev-environment)
#       * @anthropic-ai/claude-code in ~/.npm-global
#       * SessionStart / SessionEnd hooks in ~/.claude/settings.json that
#         point at the auto-pull.sh / auto-push.sh scripts (now removed)
#       * "sshd autostart" + NPM_PREFIX blocks in ~/.bashrc.local
#       * /storage/emulated/0/dev tree (removed only if empty — user repos
#         are left in place)
#
# Idempotent: every step checks state first and skips if already done.
# Re-runnable safely.
#
# One-liner:
#   bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/migrate-legacy.sh)
# ---------------------------------------------------------------------------

set -e

REPO_DIR="/storage/emulated/0/dev/dev-environment"
REPO_RAW="https://raw.githubusercontent.com/ahmed-mili/dev-environment/main"

_b=$(printf '\033[1m'); _g=$(printf '\033[32m'); _y=$(printf '\033[33m'); _r=$(printf '\033[0m')
step() { printf '\n%s==> %s%s\n' "$_b" "$1" "$_r"; }
ok()   { printf '    %s✓%s %s\n' "$_g" "$_r" "$1"; }
skip() { printf '    %s·%s %s (skip)\n' "$_y" "$_r" "$1"; }

# ============================================================================
# Generation 1: Ollama + proot-distro Ubuntu
# ============================================================================

step "1/7  Remove proot-distro Ubuntu (if installed)"
if command -v proot-distro >/dev/null 2>&1 && proot-distro list 2>/dev/null | grep -qi 'ubuntu.*installed'; then
    proot-distro remove ubuntu
    ok "Ubuntu proot removed (freed ~1GB+)"
else
    skip "Ubuntu proot absent"
fi

step "2/7  Remove ollama wrapper (if installed)"
if [ -f "$PREFIX/bin/ollama.proot" ] || [ -L "$PREFIX/bin/ollama" ] || [ -f "$PREFIX/bin/ollama" ]; then
    rm -f "$PREFIX/bin/ollama" "$PREFIX/bin/ollama.proot"
    rm -f "$HOME/.ollama.log" 2>/dev/null || true
    ok "wrapper + log removed"
else
    skip "no ollama wrapper"
fi

# ============================================================================
# Generation 2: native Claude Code on Termux + auto-pull/push hooks
# ============================================================================

step "3/7  Uninstall native Claude Code (npm-global)"
removed=no
if command -v npm >/dev/null 2>&1 && npm list -g --depth=0 2>/dev/null | grep -q '@anthropic-ai/claude-code'; then
    npm uninstall -g @anthropic-ai/claude-code >/dev/null 2>&1 && removed=yes
fi
# Even if npm is gone, sweep the ~/.npm-global tree (the previous setup.sh
# created it as the global prefix). Safe: a fresh setup-ssh-client.sh does
# not install anything into it.
if [ -d "$HOME/.npm-global" ]; then
    rm -rf "$HOME/.npm-global"
    removed=yes
fi
[ "$removed" = yes ] && ok "claude + ~/.npm-global removed" || skip "no native Claude Code install"

step "4/7  Drop legacy hooks from ~/.claude/settings.json"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -qE 'auto-(pull|push)\.sh' "$SETTINGS" 2>/dev/null; then
    if command -v node >/dev/null 2>&1; then
        cp "$SETTINGS" "$SETTINGS.bak-pre-migrate-legacy"
        node - "$SETTINGS" <<'NODE'
const fs = require('fs');
const [,, file] = process.argv;
let data = {};
try { data = JSON.parse(fs.readFileSync(file, 'utf8') || '{}'); } catch (e) { process.exit(0); }
if (data.hooks) {
    for (const evt of ['SessionStart', 'SessionEnd']) {
        if (!Array.isArray(data.hooks[evt])) continue;
        data.hooks[evt] = data.hooks[evt].filter(group =>
            !(group.hooks || []).some(h =>
                (h.args || []).some(a => /auto-(pull|push)\.sh$/.test(a))
            )
        );
        if (data.hooks[evt].length === 0) delete data.hooks[evt];
    }
    if (Object.keys(data.hooks).length === 0) delete data.hooks;
}
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
NODE
        ok "hooks stripped (backup at $SETTINGS.bak-pre-migrate-legacy)"
    else
        skip "node missing — edit $SETTINGS by hand: remove SessionStart/SessionEnd entries pointing at auto-pull.sh / auto-push.sh"
    fi
else
    skip "no legacy hooks in settings.json"
fi

step "5/7  Remove legacy hook scripts + empty /storage/emulated/0/dev tree"
removed=no
for f in "$HOME/.claude/hooks/auto-pull.sh" "$HOME/.claude/hooks/auto-push.sh"; do
    if [ -f "$f" ]; then rm -f "$f"; removed=yes; fi
done
LEGACY_DEV="/storage/emulated/0/dev"
if [ -d "$LEGACY_DEV" ] && [ -z "$(ls -A "$LEGACY_DEV" 2>/dev/null)" ]; then
    rmdir "$LEGACY_DEV" 2>/dev/null && removed=yes
fi
[ "$removed" = yes ] && ok "removed" || skip "nothing to remove"

# ============================================================================
# Clean ~/.bashrc.local of every legacy autostart block from both generations
# ============================================================================

step "6/7  Clean ~/.bashrc.local of legacy autostart blocks"
if [ -f "$HOME/.bashrc.local" ]; then
    legacy_found=no
    for marker in 'ollama serve autostart' 'sshd autostart' 'Added by termux-config setup.sh'; do
        if grep -q "$marker" "$HOME/.bashrc.local" 2>/dev/null; then
            legacy_found=yes
            break
        fi
    done
    if [ "$legacy_found" = yes ]; then
        cp "$HOME/.bashrc.local" "$HOME/.bashrc.local.bak-pre-migrate-legacy"
        # Single awk pass strips three kinds of legacy blocks:
        #   - "ollama serve autostart"        if-block ending at a bare `fi`
        #   - "sshd autostart"                3 lines (2 comments + pgrep cmd)
        #   - "Added by termux-config setup.sh"  3 lines (comment + 2 exports)
        # Leaves the current "wake lock" block untouched.
        awk '
            BEGIN { skip_ollama = 0; skip_n = 0 }
            /^# termux-config: ollama serve autostart/ { skip_ollama = 1; next }
            skip_ollama && /^fi$/                       { skip_ollama = 0; next }
            skip_ollama                                  { next }
            /^# termux-config: sshd autostart/          { skip_n = 3 }
            /^# Added by termux-config setup\.sh/       { skip_n = 3 }
            skip_n > 0                                   { skip_n--; next }
            { print }
        ' "$HOME/.bashrc.local.bak-pre-migrate-legacy" > "$HOME/.bashrc.local"
        ok "cleaned (backup at ~/.bashrc.local.bak-pre-migrate-legacy)"
    else
        skip "already clean"
    fi
else
    skip "no ~/.bashrc.local"
fi

# ============================================================================
# Final: pull the latest repo (if cloned locally) and re-run setup-ssh-client
# ============================================================================

step "7/7  Re-run setup-ssh-client.sh (idempotent, current config)"
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --ff-only 2>/dev/null || true
fi
if [ -f "$REPO_DIR/android/setup-ssh-client.sh" ]; then
    bash "$REPO_DIR/android/setup-ssh-client.sh"
else
    bash <(wget -qO- "$REPO_RAW/android/setup-ssh-client.sh")
fi

printf '\n%s==> Migration complete.%s\n\n' "$_b" "$_r"

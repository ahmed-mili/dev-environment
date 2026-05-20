# android/

Generic Termux installer: bash + Catppuccin Mocha, starship, fastfetch, Claude Code CLI, auto-pull / auto-push hooks on `~/dev/`.

## Files

| File | Target |
| --- | --- |
| `setup.sh` | One-liner Termux installer |
| `files/bashrc` | `~/.bashrc` |
| `files/starship.toml` | `~/.config/starship.toml` |
| `files/fastfetch-config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| `files/termux.properties` | `~/.termux/termux.properties` |
| `files/colors.properties` | `~/.termux/colors.properties` |
| `files/auto-pull.sh` | Claude Code SessionStart hook |
| `files/auto-push.sh` | Claude Code SessionEnd hook |

## Installation

```bash
curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; \
pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh)
```

The script installs the required packages, deploys the Catppuccin configs, generates an ed25519 SSH key, and installs Claude Code via npm. A single opt-in prompt: sshd (for SSH PC→phone). Everything else is non-interactive.

You end up with an empty `~/dev/` and Claude Code available — all that's left is cloning the repos you want.

> The `dpkg -r libngtcp2-crypto-ossl` preamble is a no-op on a healthy Termux — it only kicks in on builds where the HTTP/3 lib has an ABI mismatch with OpenSSL and breaks `curl` (and `pkg install` along with it). Process substitution `bash <(...)` rather than `curl ... | bash` because the sshd prompt and the GitHub SSH key prompt need a TTY stdin.

## Customize after install

```bash
# Git identity (the script also prompts if missing)
git config --global user.name  "Your Name"
git config --global user.email "you@email"

# Clone your own repos
mkdir -p ~/dev
for r in repo1 repo2 repo3; do
  git clone git@github.com:YOUR_USER/$r.git ~/dev/$r
done

# If you use sshd: add your PC pubkey
echo "ssh-ed25519 AAAA... your-pc-comment" >> ~/.ssh/authorized_keys
```

## Recommended workflow for Claude Code

```bash
tmain                          # attach the "main" tmux session (create if absent)
cd ~/dev/my-repo
claude                         # SessionStart hook runs auto-pull before handing control back
# work...
# Ctrl+B then D                # detach — session keeps running in the background
# close Termux, switch apps, lock the screen: the session survives
# later:
tmain                          # you find Claude exactly where you left it
```

The wake-lock is acquired automatically by `~/.bashrc.local` (release with `termux-wake-unlock` or delete the line).

## Maximize performance on Xiaomi / MIUI

Android aggressively kills background processes — especially MIUI. Three manual actions (once per phone) that make a visible difference:

**1. Exempt Termux from battery optimization**
Android Settings → Apps → Termux → Battery → "Unrestricted".

**2. Disable the phantom process killer** (Xiaomi/Android 12+ kills any child that exceeds 32 processes)
From a PC with ADB:
```bash
adb shell "settings put global settings_enable_monitor_phantom_procs false"
adb shell "device_config put activity_manager max_phantom_processes 2147483647"
```
(Both settings reset to zero on every Android update — re-apply if tmux/claude die.)

**3. Termux:Boot** (optional) — autostart tmux + sshd when the phone boots
Install the Termux:Boot APK from F-Droid, then:
```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
tmux new-session -d -s main
EOF
chmod +x ~/.termux/boot/start.sh
```

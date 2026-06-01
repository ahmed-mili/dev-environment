# android/

Termux installer for the **"SSH client to a remote dev machine"** workflow: a polished Termux (Catppuccin Mocha colours, JetBrainsMono Nerd Font, gradient prompt, fastfetch splash, fzf bindings) wired with the SSH stack you need to reach a remote PC over Tailscale (`openssh`, `mosh`, `tmux`). Nothing more.

## Files

| File | Target |
| --- | --- |
| `setup-ssh-client.sh` | One-liner Termux installer |
| `files/bashrc` | `~/.bashrc` |
| `files/fastfetch-config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| `files/termux.properties` | `~/.termux/termux.properties` |
| `files/colors.properties` | `~/.termux/colors.properties` |
| `migrate-legacy.sh` | Cleans up any previous install (Ollama/proot **or** native Claude Code + auto-pull/push hooks) before re-running `setup-ssh-client.sh` |

## Installation

Paste this **as a single line** in a fresh Termux (Termux:F-Droid or Termux:GitHub — the Play Store build is abandoned and frequently broken):

```bash
curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup-ssh-client.sh)
```

What each piece does:

- `curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null` — preamble that auto-repairs the rare-but-fatal libngtcp2 / OpenSSL ABI mismatch some Termux builds ship with (it breaks `curl`, which breaks `pkg install` itself). A no-op on a healthy Termux.
- `pkg install -y wget` — ensures `wget` is present (Termux does not always ship it preinstalled).
- `bash <(wget -qO- …)` — process substitution rather than `curl … | bash`: keeps `stdin` attached to the TTY so the script's `git user.name / user.email` prompts work.

The script installs the packages listed below, deploys the Catppuccin configs, generates an ed25519 SSH key, and prints the public part at the end (also copied to the Android clipboard if `termux-api` is functional) so you can paste it into the **remote host's** `~/.ssh/authorized_keys`. Everything is non-interactive except `git user.name / user.email` (prompted only if missing).

**Packages installed:** `git openssh mosh curl wget nano fzf fastfetch eza bat fd ripgrep tmux termux-api coreutils gawk grep sed`. Nothing else.

## What this bundle is NOT (any more)

This installer no longer puts Claude Code, Node.js or git-sync hooks on the phone. Claude Code now runs on the **PC** and is reached from Termux via `mosh <host>` + `tmux`.

If you were on either of the two previous setups (**Ollama + proot-distro Ubuntu**, or **native Claude Code on Termux** with auto-pull/push hooks), run `migrate-legacy.sh` — it detects and cleans up both generations (`~/.npm-global`, the SessionStart/SessionEnd hooks in `~/.claude/settings.json`, the autostart blocks in `~/.bashrc.local`, the empty `/storage/emulated/0/dev` tree if it still hangs around), then re-runs `setup-ssh-client.sh` for you. The top-level `bootstrap.sh` invokes it automatically when it detects either generation.

## Daily workflow

```bash
mosh <host>                    # resilient over 4G / 5G — survives screen-off and network changes
# inside the remote shell:
tmux new -A -s main            # attach the "main" tmux session, create if absent
# work in Claude Code, vim, whatever
# Ctrl+B then D                # detach — your session keeps running on the PC
# close Termux, switch apps, lock the screen: nothing dies
# later:
mosh <host>                    # mosh + tmux pick up exactly where you left off
```

The wake-lock is acquired automatically by `~/.bashrc.local` on every shell start (release with `termux-wake-unlock` or delete the line).

## Clipboard: "press c to copy" is silently dropped over mosh

Anything that copies to the clipboard via the **OSC 52** terminal escape — including Claude Code's `/login` "press `c` to copy" — *looks* like it works (the app prints "copied") but nothing lands in the Android clipboard. The copy is lost in transit, not at either end:

- The app emits OSC 52 correctly, and `tmux` is set up to forward it (`set-clipboard external` + the `clipboard` terminal feature on `xterm*`).
- `mosh` 1.4.0 (the latest stable release) has **no OSC 52 support at all**. Unlike SSH it is not a transparent byte pipe — its server interprets escape sequences and syncs only screen *state* to the client, so the out-of-band "set clipboard" action is dropped. OSC 52 is fire-and-forget, so the app never learns it failed and still says "copied".

No config fixes this while you are on `mosh` — it is a missing feature, not a tunable. Workarounds:

- **Select the text by hand** in Termux (long-press → selection → copy). Always works. For `/login`: select the URL, open it in the phone browser, then paste the returned code back into the session — keystrokes *into* mosh flow normally; only the outbound copy is blocked.
- **Use plain `ssh <host>` instead of `mosh`** for that one moment. SSH is a transparent pipe, so OSC 52 traverses `tmux` (already configured) and reaches Termux (which supports it). You lose mosh's resilience to network drops, so it is only worth it when you specifically need the copy.

## Maximize background reliability on Xiaomi / MIUI

Android aggressively kills background processes — especially MIUI. Three manual actions (once per phone) that make a visible difference:

**1. Exempt Termux from battery optimization**
Android Settings → Apps → Termux → Battery → "Unrestricted".

**2. Disable the phantom process killer** (Xiaomi / Android 12+ kills any child that exceeds 32 processes)
From a PC with ADB:
```bash
adb shell "settings put global settings_enable_monitor_phantom_procs false"
adb shell "device_config put activity_manager max_phantom_processes 2147483647"
```
(Both settings reset to zero on every Android update — re-apply if Termux sessions die.)

**3. Termux:Boot** (optional) — re-acquire the wake-lock automatically at boot
Install the Termux:Boot APK from F-Droid, then:
```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
EOF
chmod +x ~/.termux/boot/start.sh
```

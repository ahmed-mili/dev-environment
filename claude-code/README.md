# claude-code/

Claude Code config shared between Windows, WSL/Linux and Android. Single source of truth.

## Contents

| File | Role |
| --- | --- |
| `statusline.ps1` | PowerShell status line: colored path (depends on permission mode), git branch, live 5h/7d usage, plan + email. Portable fallback, no prerequisites. |
| `statusline-rs/` | Rust source for the compiled statusline (xhigh magenta halo + max rainbow stretch). **Requires SAC disabled** — see dedicated section. |
| `settings.json` | Claude Code config (model, plugins, `.exe` statusline) |
| `hooks/` | `auto-pull.ps1`, `auto-push.ps1`, `resolve-sync-conflicts.ps1` — reserved for manual/future use, no longer called from SessionStart/End |
| `skills/` | Custom skills: claude-file-recovery, copy-edit, css-layout-check, deploy-safety, edit-block, lucide-icons, release, root-cause-fix, smart-edit, sticky-column-bleed-fix, webapp-deploy |
| `deploy.ps1` | Manual bidirectional sync between this folder and the **Windows** `~/.claude/` |
| `deploy.sh` | Same, for the **WSL/Linux** `$HOME/.claude/` (keybindings.json + tmux.conf + custom skills). The desktop is WSL-primary. |
| `keybindings.json` | Custom Claude Code keybindings (`Alt+V` image paste on WSL — see the Obsidian guide) |
| `tmux.conf` | Deployed to `~/.tmux.conf` by `deploy.sh`. Lets tmux forward 24-bit color so Claude Code renders truecolor over `mosh`+`tmux` (see the SSH Android guide) |
| `termux/img2claude` | Termux (Android) script: sends an image (photo/screenshot) into the Claude session running on the desktop. `scp` to the desktop, then **`wl-copy --type image/png` into the Wayland clipboard** (detached, so its persistent server doesn't hold the ssh channel open), then `tmux send-keys M-v`. Claude v2.1.152 reads `wl-paste --type image/png` first — clean JPEG bytes re-sniffed by sharp. **Why not the Windows clipboard alone:** WSLg only bridges it to Wayland as a 32-bit BI_BITFIELDS `image/bmp` that Claude's sharp/libvips can't decode, and since `wl-paste image/bmp` succeeds Claude never reaches the PowerShell fallback → "No image found". A `SetImage` into the Windows clipboard is kept as a bonus so Discord & other Windows apps can paste too. **Always called with a file-path argument** — by `screenshot-watcher` (auto) and by the `termux-file-editor` share hook. The no-arg "most recent" mode (the `i` alias) was removed 2026-05-27 since the watcher's auto-push makes it redundant. Works around mosh not carrying the clipboard (Alt+V can't cross it). It shows a **two-state `termux-notification`** (same id `img2claude`): "⏳ Transfert en cours…" posted before the `scp`, flipped in place to "Image prête à coller" once staging succeeds (Android replaces a same-id notif). A `trap` removes the in-progress notif if the transfer/staging fails — while **preserving the non-zero exit code** so the watcher retries and never counts a failed upload as sent. It lives on its **own channel** `watcher-images` ("🖼️Image-prête", created best-effort) — a separate category in *Settings → Termux:API → Notifications*, distinct from the `watcher-toggle` control notif; falls back to the default channel if creation fails so the signal is never lost. ⚠️ Channel names must contain **no spaces**: `termux-notification-channel` expands its args unquoted and truncates a spaced name to its first word (confirmed 2026-05-29). |
| `termux/termux-file-editor` | Termux built-in hook (deployed to `~/bin/`): triggered by **Share → Termux → EDIT** on any image, delegates to `img2claude`. Requires the Android permission *Display over other apps* on Termux. Lives on the phone, not synced by `deploy.sh` — installed via the express block in the SSH Android guide. |
| `termux/screenshot-watcher` | Polling watcher (every 2s) on the phone's image dirs — each new image is **staged** through `img2claude` into the desktop's Wayland clipboard, then the user presses **Alt+V** manually to send it (no auto-paste; removed 2026-05-27). Two streams, both **ON by default** (flags created by `install.sh`, persistent in `$HOME`): `~/.screenshot-watcher.on` = `dcim/Screenshots`, `~/.screenshot-watcher.photos` = `dcim/Camera`. Photos default-on is safe because img2claude only stages — no photo enters Claude unless the user Alt+V's it. Only the **most recent** new image per stream is staged (not a FIFO replay): the clipboard holds one image, so on a slow link (cellular/tunnel) replaying a backlog made it lag behind — converging to the newest makes lag impossible. On success a `termux-notification` "Image prête à coller" fires so the user knows when Alt+V is safe; the cursor only advances on success, so a failed upload is retried, never silently dropped. Polling vs inotify because FUSE on `/sdcard` doesn't deliver inotify events from other apps. Toggle without killing: `touch`/`rm` the flag (aliases `photos-on`/`photos-off`). Deployed to `~/bin/screenshot-watcher`. |
| `termux/boot-screenshot-watcher` | Termux:Boot wrapper that starts `screenshot-watcher` at phone boot (acquires `termux-wake-lock` first). Deployed to `~/.termux/boot/screenshot-watcher` on the phone — Termux:Boot APK from F-Droid required. |
| `termux/watcher-toggle` | **Persistent** Termux:API notification (`--ongoing`) with 2 buttons showing each watcher stream's state (`📸 Captures: ON/OFF`, `🖼️ Photos: ON/OFF`) and toggling it **with one tap** — no command to type. Flips the same flags as `screenshot-watcher` / the `photos-on`/`photos-off` aliases, so the change takes effect in ≤2s without restarting the watcher. Buttons re-invoke the script via an **absolute `bash` + absolute script path** (the notification-action env is minimal, like Termux:Boot — no relative resolution possible). Posted on its **own notification channel** `watcher-control` ("🛰️Contrôle-des-flux" — no spaces, since `termux-notification-channel` truncates a spaced name to its first word; created best-effort in `show()`), so it shows up as a **separate category** in *Settings → Apps → Termux:API → Notifications* — apart from the `img2claude` "image ready" notifs (on their own `watcher-images` channel); silence this channel to sink the toggle to the bottom of the shade. Falls back to the default channel (no `--channel`) if channel creation fails, since an invalid channel would drop the notification (per `--help`) — so the notif is never lost. Posted by `install.sh` and re-posted on every boot by `boot-screenshot-watcher`. Silent no-op if Termux:API is absent (flags still controllable from the CLI). Deployed to `~/bin/watcher-toggle`. |

## Bootstrap a new machine

```powershell
# Clone the repo, then pull configs to ~/.claude/
git clone https://github.com/ahmed-mili/dev-environment.git C:\dev\dev-environment
C:\dev\dev-environment\claude-code\deploy.ps1 -Pull
# Restart Claude Code
```

## Daily workflow

Sync between `~/.claude/` and this repo is **manual** (no more auto hooks on SessionStart/End). Rationale: avoid silent Syncthing/git conflicts and keep explicit control over what gets committed.

### You added or modified a skill or setting in `~/.claude/`?

```powershell
cd C:\dev\dev-environment
.\claude-code\deploy.ps1 -Push
git add -A ; git commit -m "<message>" ; git push
```

> ⚠️ `deploy.ps1 -Push` only copies the **11 whitelisted custom skills** to the repo. Anthropic's official skills or marketplace downloads (`brand-guidelines`, `claude-api`, `docx`, etc.) are never committed (keeps the repo lean).

### To add a new custom skill to the whitelist

Edit `deploy.ps1` line `$CustomSkills = @(...)` and add your skill's folder name.

## WSL / Linux sync (`deploy.sh`)

The desktop runs Claude Code in **WSL**, so the WSL `$HOME/.claude/` is the source of truth for dev. `deploy.sh` is the bash counterpart of `deploy.ps1`:

```bash
cd ~/dev/dev-environment
./claude-code/deploy.sh --pull     # repo -> ~/.claude/  (bootstrap a WSL machine)
./claude-code/deploy.sh --push     # ~/.claude/ -> repo  (before git commit)
```

It syncs only what is platform-independent: `keybindings.json`, `tmux.conf` (deployed to `~/.tmux.conf`), and the 11 custom skills. It deliberately does **not** touch `settings.json` (diverges: statusline path `/home/...` vs `C:\...`, marketplaces, effortLevel), `statusline.ps1` / `statusline-rs/` or `hooks/` (Windows-only). Pull uses `rsync --update`, so it never overwrites a local file newer than the repo (deploy-safety). `deploy.ps1` (Windows) is kept frozen for the gaming/admin install.

### One-time bashrc snippet (not auto-synced)

Claude Code downgrades to 256-color whenever it sees `$TMUX` (it ignores `COLORTERM` and `FORCE_COLOR` in that case). A small wrapper in `~/.bashrc` makes `claude` always launch without `TMUX`, so it emits real 24-bit again — `tmux.conf` then forwards it untouched. Add this once on a fresh WSL machine:

```bash
cat >> ~/.bashrc <<'EOF'

# Claude Code rabaisse en 256-color quand $TMUX est defini -> le lancer sans.
claude() { env -u TMUX claude "$@"; }
EOF
```

(`.bashrc` isn't tracked because each machine's bashrc has unrelated history; the snippet is idempotent — running it twice just defines the function twice, harmless.)

## Statusline — technical details

Private Claude Code endpoint for live usage:
```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken from ~/.claude/.credentials.json>
anthropic-beta: oauth-2025-04-20
```

| Permission mode | Path color (RGB) |
| --- | --- |
| `bypassPermissions` | 255,121,198 (hot pink) |
| `plan` | 139,233,253 (light cyan) |
| `acceptEdits` | 80,250,123 (green) |
| `dontAsk` | 189,147,249 (purple) |
| `auto` | 255,184,108 (orange) |

| Usage % | Bar/text color |
| --- | --- |
| `< 50%` | green (80,250,123) |
| `50–80%` | yellow (241,250,140) |
| `> 80%` | red (255,85,85) |

Caches: usage 60s (`~/.claude/usage-cache.json`), auth 1h (`~/.claude/auth-status-cache.json`).

## Effort level rendering

The 5 effort levels (`low`, `medium`, `high`, `xhigh`, `max`) render as follows in the statusline:

| Level | Rendering |
| --- | --- |
| `low` | yellowBright bold |
| `medium` | greenBright bold |
| `high` | blueBright bold |
| `xhigh` | uniform `#F2C1E9` (rose pastel) bold |
| `max` | uniform `#FF79C6` (rose vif) bold — **exact same color as the path in `bypassPermissions` mode** |

All renderings are static. `xhigh` and `max` use truecolor RGB (`\e[38;2;R;G;Bm`) explicitly, so the color is identical on every Windows Terminal theme and unaffected by the Claude Code `dark-ansi` theme. Claude Code's internal `/effort` picker animates `xhigh` and `max` at ~10 Hz (Ink/React inside the binary), but the statusline does not animate — `claude.exe` invokes the statusline subprocess on state changes, not on a timer, so per-frame animation from a subprocess is impractical. Both `.ps1` and `.exe` renderings are visually equivalent.

## Build the Rust statusline (optional)

The default `.ps1` statusline works with no prerequisites and is visually equivalent to the Rust binary. Compile the Rust version only if you want the marginal speedup of a single-shot compiled binary over a PowerShell process.

### Prerequisites

1. **Smart App Control = Off** — otherwise Windows 11 blocks execution of any unsigned Rust binary (OS error 4551 on `cargo build` too). Settings → Privacy & security → Smart App Control. ⚠️ **Disabling SAC is permanent**: re-enabling requires a full Windows reset.
2. **Rust toolchain**:
   ```powershell
   winget install Rustlang.Rustup
   ```
   If Visual Studio Build Tools are absent, `build.ps1` automatically installs WinLibs/MinGW via winget (provides `gcc.exe` for ring/rustls) and builds with `stable-gnu`.

### Build

```powershell
cd C:\dev\dev-environment\claude-code\statusline-rs
.\build.ps1
```

`build.ps1` builds in `--release` (LTO + strip), redirects `CARGO_TARGET_DIR` to `%LOCALAPPDATA%\statusline-build\target` (trusted zone outside `C:\dev`, avoids SAC blocks on cargo build scripts), falls back to `stable-gnu` plus WinLibs/MinGW when MSVC is absent, then copies the binary to `~/.claude/statusline.exe`.

## Credit

The `/usage` endpoint was discovered by [Melvynx (codelynx.dev)](https://codelynx.dev/posts/claude-code-usage-limits-statusline) via Proxyman.

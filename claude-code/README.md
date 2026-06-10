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
| `termux/img2claude` | Termux (Android) script: stages a phone photo/screenshot on the desktop. It transfers the file to WSL `~/.claude-images`, arms Claude WSL through `wl-copy --type image/png`, and deliberately does **not** run `ssh -p 2222 ... SetImage` anymore: that writes to the clipboard of an ephemeral SSH window station and returns a false success. Claude pwsh native is handled on the PC by `windows-clipboard/img-clip-watcher.ps1`, launched from the pwsh `claude()` wrapper in the same window station as the reader. **Always called with a file-path argument** — by `screenshot-watcher` (auto) and by the `termux-file-editor` share hook. The notification reuses the same `img2claude` id so Android updates it in place: during `rsync --partial --info=progress2` it shows sent/total size, percentage, and ETA under `Image to PC clipboard`; after staging it switches to `Ready to paste` / `Alt+V in Claude (WSL & pwsh)`. If `rsync` is absent it falls back to `scp` with an explicit "transfer in progress" message; new Android bootstrap installs include `rsync`. A `trap` removes the in-progress notif if transfer/staging fails while preserving the non-zero exit code, so the watcher retries and never counts a failed upload as sent. It lives on its own `watcher-images` channel and explicit Android notification group (`Image-ready`, best-effort, no spaces in channel names because `termux-notification-channel` truncates spaced names). |
| `termux/termux-file-editor` | Termux built-in hook (deployed to `~/bin/`): triggered by **Share → Termux → EDIT** on any image, delegates to `img2claude`. Requires the Android permission *Display over other apps* on Termux. Lives on the phone, not synced by `deploy.sh` — installed via the express block in the SSH Android guide. |
| `termux/screenshot-watcher` | Polling watcher (every 0.5s while enabled) on the phone's image dirs. As soon as a new screenshot/photo is detected, it posts `Image detected` on the same `img2claude` notification id, then waits until the file size is stable before handing it to `img2claude`; the notification is later replaced in place by transfer progress and final clipboard state. Two streams, both **ON by default** (flags created by `install.sh`, persistent in `$HOME`): `~/.screenshot-watcher.on` = `dcim/Screenshots`, `~/.screenshot-watcher.photos` = `dcim/Camera`. Only the **most recent** new image per stream is staged (not a FIFO replay): the clipboard holds one image, so converging to the newest avoids stale uploads on slow links. The cursor only advances on success, so a failed upload is retried, never silently dropped. Polling vs inotify because FUSE on `/sdcard` doesn't deliver inotify events from other apps. Toggle without killing: `touch`/`rm` the flag (aliases `photos-on`/`photos-off`). Deployed to `~/bin/screenshot-watcher`. |
| `termux/boot-screenshot-watcher` | Termux:Boot wrapper that starts `screenshot-watcher` at phone boot (acquires `termux-wake-lock` first). Deployed to `~/.termux/boot/screenshot-watcher` on the phone — Termux:Boot APK from F-Droid required. |
| `termux/watcher-toggle` | **Persistent** Termux:API notification (`--ongoing` + `--on-delete`) titled `Images to PC`, with a plain state line such as `Screenshots on - Photos paused` and 2 action buttons (`Pause/Enable screenshots`, `Pause/Enable photos`). The line is honest about liveness: if the supervisor/watcher is down it says `Service offline - open Termux`; if images still run but `sshd` is down it appends `ssh phone offline`. If HyperOS still lets the user swipe it away, the delete action calls `watcher-toggle restore` and reposts the same notification immediately; remaining latency is the Android/Termux:API dispatch cost. Flips the same flags as `screenshot-watcher` / the `photos-on`/`photos-off` aliases, so the change takes effect on the next 0.5s watcher pass without restarting it. Buttons re-invoke the script via an **absolute `bash` + absolute script path** (the notification-action env is minimal, like Termux:Boot — no relative resolution possible). Posted on its **own notification channel** and Android notification group `watcher-control` (`Image-control` — no spaces, since `termux-notification-channel` truncates a spaced name to its first word; created best-effort in `show()`), apart from the image notifications. Termux:API does not expose native notification animations, so the UI stays stable and relies on Android's own expand/update motion instead of fake repost animations. Falls back to the default channel (no `--channel`) if channel creation fails, since an invalid channel would drop the notification (per `--help`) — so the notif is never lost. Posted by `install.sh` and re-posted on every boot by `boot-screenshot-watcher`. Silent no-op if Termux:API is absent (flags still controllable from the CLI). Deployed to `~/bin/watcher-toggle`. |

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

### Device context detection (so the assistant knows where it's talking)

Each shell profile defines a `claude()` wrapper that calls a small detector before launching the real Claude binary. The detector writes a JSON file at `~/.claude/.device-context`:

| Field | Example | Meaning |
| --- | --- | --- |
| `device` | `desktop` / `phone` | Which physical device |
| `context` | `wsl` / `termux` / `ssh-to-wsl` / `pwsh-native` | Which shell / path |
| `shell` | `bash` / `pwsh` | Shell type |
| `distro` | `Ubuntu` | WSL distro (WSL only) |
| `model` | `Xiaomi 13T Pro` | Phone model (Termux only) |
| `ssh_from` | `100.x.y.z` | Client IP if connected via SSH |
| `timestamp` | ISO 8601 | When the context was last written |

**WSL / Linux** : the `claude()` wrapper in `~/.bashrc` calls `detect.sh` then `env -u TMUX claude`.
**Windows pwsh** : the `claude()` function in `$PROFILE` calls `detect.ps1` then the binary.
**Termux** : same wrapper as WSL — `detect.sh` detects Termux via `$PREFIX`.

The assistant can read this file with `Read ~/.claude/.device-context` to know whether the user is on their phone, their PC, or SSH-ing from one to the other. This avoids proposing PC-only actions when the user is on Termux, or phone-only actions when the user is on WSL.

### Plugin integrity check

Plugins listed in `settings.json` -> `enabledPlugins` may appear "enabled" but not actually installed (cache corruption, new machine, reinstall). This makes skills appear in the system reminder but they are not invocable — the assistant will not know they exist.

**Detect missing plugins:**
```bash
# WSL / Linux / Termux
bash ~/.claude/scripts/check-plugins.sh

# Windows PowerShell
& ~/.claude/scripts/check-plugins.ps1
```

**Install missing plugins automatically:**
```bash
bash ~/.claude/scripts/check-plugins.sh --fix
# Windows: & ~/.claude/scripts/check-plugins.ps1 -Fix
```

Run this after any `deploy --pull` or `bootstrap` on a new machine, or whenever the Skill Registry looks incomplete. The script parses `settings.json`, compares against `claude plugin list`, and installs whatever is missing.

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

Claude Code downgrades to 256-color whenever it sees `$TMUX` (it ignores `COLORTERM` and `FORCE_COLOR` in that case). A small wrapper in `~/.bashrc` makes `claude` always launch without `TMUX`, so it emits real 24-bit again — `tmux.conf` then forwards it untouched. **Zellij does not trigger this** (it sets `$ZELLIJ`, not `$TMUX`), so truecolor works out of the box there; the wrapper is kept anyway for when `claude` runs inside a real tmux (agent orchestrators, the `wdev` shortcut). Add this once on a fresh WSL machine:

```bash
cat >> ~/.bashrc <<'EOF'

# Claude Code rabaisse en 256-color quand $TMUX est defini -> le lancer sans.
claude() { env -u TMUX claude "$@"; }
EOF
```

(`.bashrc` isn't tracked because each machine's bashrc has unrelated history; the snippet is idempotent — running it twice just defines the function twice, harmless.)

### Shell autosuggestions: ble.sh + atuin + zoxide (opt-in, not auto-synced)

PSReadLine-style inline "ghost text" autosuggestions, fuzzy history search and a
frecency `cd`, so WSL/Termux feels like the Windows PowerShell 7 profile:

| Tool | Role | Install |
| --- | --- | --- |
| [ble.sh](https://github.com/akinomyoga/ble.sh) | Line editor: grey ghost-text autosuggestion, syntax highlight, completion menu | `git clone --recursive --depth 1 --shallow-submodules https://github.com/akinomyoga/ble.sh ~/ble.sh && make -C ~/ble.sh && bash ~/ble.sh/ble.sh --install ~/.local/share` |
| [atuin](https://atuin.sh) | History DB + `Ctrl+R` fuzzy search | `curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh \| sh` |
| [zoxide](https://github.com/ajeetdsouza/zoxide) | `cd` by frecency | `curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \| sh` |

Then add this to `~/.bashrc`. Order matters: ble.sh is sourced **early** with
`--attach=none`, and `ble-attach` is the **last** statement of the file.

```bash
# ── ble.sh: line editor. Source EARLY with --attach=none (ble-attach goes last).
if [[ $- == *i* ]] && [[ -f ~/.local/share/blesh/ble.sh ]]; then
  source ~/.local/share/blesh/ble.sh --attach=none
fi

# ... (the rest of your ~/.bashrc) ...

# ── atuin: history DB. --disable-up-arrow leaves the Up key to ble.sh (history
#    + ghost text); Ctrl+R stays atuin's fuzzy-search UI.
. "$HOME/.atuin/bin/env"
eval "$(atuin init bash --disable-up-arrow)"

# atuin registers itself as ble.sh's inline-suggestion source by default. Remove
# it so the ghost text comes from ~/.bash_history (clean) rather than the atuin
# DB — which gets polluted by the multi-line commands Claude Code records via the
# `atuin hook claude-code` hook (parasitic multi-line suggestions on `cd`).
[[ ${BLE_VERSION-} ]] && ble/util/import/eval-after-load core-complete '
    ble/array#remove _ble_complete_auto_source atuin-history'

# ── zoxide: smarter `cd` (frecency). Needs the ble.sh integration module, else
#    ble.sh short-circuits zoxide's `cd` function → "cd: too many arguments".
eval "$(zoxide init bash --cmd cd)"
[[ ${BLE_VERSION-} ]] && ble-import contrib/integration/zoxide

# ── ble.sh: PSReadLine-style behaviour ──
if [[ ${BLE_VERSION-} ]]; then
  ble-face auto_complete='fg=#6C7086'   # grey ghost text, no background
  ble-face syntax_error='fg=default'    # don't paint unknown commands red
  ble-bind -m auto_complete -f 'TAB' 'auto_complete/@end insert'  # Tab accepts
  ble-bind -m auto_complete -f 'C-i' 'auto_complete/@end insert'  # the suggestion
  ble-bind -f 'f3' 'menu-complete'      # F3 = navigable completion menu
  # F2 = tmux sessionizer (same fzf menu as `pc` on the phone). -c runs an external
  # fullscreen program (fzf) with the terminal restored, then redraws the prompt.
  ble-bind -c 'f2' "$HOME/dev/dev-environment/claude-code/tmux-sessionizer.sh"
fi

# ble-attach MUST be the last statement of ~/.bashrc.
[[ ${BLE_VERSION-} ]] && ble-attach
```

#### Optional: feed Claude Code's own commands into atuin

To record the `Bash` commands Claude Code runs into your atuin history, add these
hooks to `~/.claude/settings.json`. They are kept **out** of the shared
`settings.json` on purpose: without atuin installed, every Bash call would fail
with `atuin: command not found`.

```json
"hooks": {
  "PreToolUse":        [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "atuin hook claude-code" }] }],
  "PostToolUse":       [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "atuin hook claude-code" }] }],
  "PostToolUseFailure":[{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "atuin hook claude-code" }] }]
}
```

> The bashrc snippet above intentionally drops atuin as ble.sh's *inline* ghost-text
> source (the multi-line commands Claude records would otherwise pollute the
> suggestion on `cd`). `Ctrl+R` still searches the full atuin DB, Claude's commands included.

### Phone: continuous block bars in Termux (one-time font patch, not synced)

The `pc` sessionizer menu draws fzf's gutter as one `▌` (U+2588 family) per line. On the desktop they tile into a solid vertical bar; in **Termux** the same bytes render with a ~1px gap between rows. The cause is **Termux's sub-pixel rounding**, *not* the font: JetBrainsMono Nerd Font's block glyphs already fill the cell exactly (`yMax == ascent`, `yMin == descent`), so there's no overshoot to absorb the rounding. (Swapping the font is the wrong fix — verified with fontTools.)

The fix overshoots the **full-height block glyphs** so they bleed past the cell (like DejaVu Sans Mono, whose blocks overshoot by ~25 units and never gap). Patch the phone's `~/.termux/font.ttf` once, on the desktop, then `scp` it back — the family name is unchanged, so Nerd Font icons are untouched:

```bash
pip install --user --break-system-packages fonttools   # PEP 668 override, user-site only
scp phone:~/.termux/font.ttf /tmp/f.ttf                 # thin-client: patch on desktop, not phone
python3 - /tmp/f.ttf /tmp/f-patched.ttf <<'PY'
import sys
from fontTools.ttLib import TTFont
src, dst = sys.argv[1], sys.argv[2]
f = TTFont(src); asc, desc = f['hhea'].ascent, f['hhea'].descent
cmap, glyf = f.getBestCmap(), f['glyf']
DELTA = 64   # overshoot top+bottom; bump to 96/128 if a residual gap remains
for cp in (0x2588,0x2589,0x258A,0x258B,0x258C,0x258D,0x258E,0x258F,0x2590,0x2595):
    gn = cmap.get(cp)
    if not gn or gn not in glyf: continue
    g = glyf[gn]
    if g.isComposite() or g.numberOfContours < 1: continue
    if abs(g.yMax-asc) > 2 or abs(g.yMin-desc) > 2: continue   # full-height bars only
    for i,(x,y) in enumerate(g.coordinates):
        if   y >= g.yMax-1: g.coordinates[i] = (x, y+DELTA)
        elif y <= g.yMin+1: g.coordinates[i] = (x, y-DELTA)
    g.recalcBounds(glyf)
f.save(dst)
PY
ssh phone 'cp ~/.termux/font.ttf ~/.termux/font.ttf.bak'  # backup -> rollback in one line
scp /tmp/f-patched.ttf phone:~/.termux/font.ttf
ssh phone 'termux-reload-settings'
```

Rollback: `ssh phone 'cp ~/.termux/font.ttf.bak ~/.termux/font.ttf && termux-reload-settings'`. Re-run the patch if a Termux font update overwrites it.

## Sessionizer (`wsl` / `pwsh` / F2)

`tmux-sessionizer.sh` (kept name; it now drives **Zellij**, not tmux) is the shared fzf menu that merges, in one list: `●` **active** Zellij sessions (attach), `○` **`~/dev` projects** with no session (create one in the folder), `○` **Obsidian vaults** in violet (native PowerShell), and **new** ad-hoc sessions (Ctrl+N). The **same** menu has three perimeters, driven by the `PC_VIEW` env var. The split is by **world** (which side of the filesystem / where it runs best), not by object type, so the two worlds never share a cluttered list:

> **Why Zellij, not tmux?** tmux has no native Windows build, and the only native-Windows tmux clone (psmux) was too buggy (laggy Claude TUI, Esc-blocked-after-Ctrl+letter, truecolor off). Zellij ships a native-Windows ConPTY binary (≥ 0.44) that runs `pwsh` natively (full-speed C: I/O) **with** detach/reattach. So one multiplexer covers both worlds: Zellij in WSL (projects) + Zellij on Windows (vaults). tmux stays installed as a dependency of agent orchestrators and a `0.x` fallback, but is no longer the daily mux. Active sessions are merged cross-OS: `zellij ls` for the WSL world, plus a read of the Windows Zellij IPC dir and `AppData/Local/Zellij/cache/.../session_info` over `/mnt/c` for vaults (no interop needed).

| Entry point | `PC_VIEW` | World — shows |
|---|---|---|
| `wsl` (SSH) / `wslm` (mosh) — phone | `wsl` | **Linux/ext4**: Zellij sessions + `~/dev` projects (no vaults) |
| `pwsh` (SSH) / `pwshm` (mosh) — phone | `ps` | **Windows/C: in native pwsh**: Obsidian vaults as Zellij sessions (extensible to any C: folder better in PowerShell) |
| **F2** — desktop WSL shell | `all` (default) | everything (vaults open as Windows Terminal tabs running `zellij attach -c ... options --on-force-close detach` via interop) |

`sleep-pc` suspends the desktop, `stop-pc` shuts it down — both run a native Windows command through the Windows sshd (port 2222) + `$WIN_USER` (the WSL ssh on port 22 has no Windows interop, so `rundll32`/`shutdown` can't run there).

> **Picking a vault from the phone opens native Windows PowerShell — automatically.** A vault lives on `C:`, so it must run in native `pwsh`, but the phone's SSH-into-WSL session **can't reach Windows**: the **WSL→Windows hop is broken by a WSL mirrored-networking bug** — `127.0.0.1` is policy-routed to `loopback0` and the host handshake times out (confirmed across *all* Windows ports; `LoopbackEnabled=True` + `wsl --shutdown` does **not** fix it). So when you pick a vault in `pwsh`, the sessionizer (in WSL) just **records the name and exits with code 42**; the phone's `pwsh`/`wsl` function catches that and opens the vault **client-side** — an `ssh` **directly** from the phone to the **Windows OpenSSH server** (port 2222, bound to localhost + the Tailscale IP, key-only) into native `pwsh` in the vault folder. You pick in the menu, the vault just opens — nothing to type. The phone-side ssh runs `zellij attach -c <vault> options --on-force-close detach` in native `pwsh`, so **the vault is a persistent Zellij session** (`default_shell` → `pwsh` on Windows): if Termux/SSH/5G dies brutally, Zellij detaches the client instead of quitting/resetting the pane. It shows as `●` active in the menu and survives detach/reattach — type half a message in `claude`, lose 5G, run `pwsh` again, and finish the same message. No automatic `delete-session` runs on open; only explicit `Ctrl+X` is destructive. The Windows account for that ssh can't be derived from the phone, so it's read from **`$WIN_USER`** — set it in `~/.bashrc.local` (`export WIN_USER=<your Windows account>`), kept out of git so the versioned `bashrc` stays shareable. One-time Windows setup (OpenSSH Server, keys, firewall, `LoopbackEnabled`): see `docs/superpowers/plans/2026-06-01-vault-native-pwsh-ssh.md`.

| Key | Action |
|---|---|
| ⏎ | open / attach |
| ↹ Tab | switch category (projects ⇄ vaults) — F2 `all` view only; `wsl`/`pwsh` each show one world |
| Ctrl+N | new session (free name) |
| Ctrl+X | kill the active session (see below) |
| Ctrl+G | toggle the help header |
| Esc | cancel a Ctrl+N/R/X prompt typed by mistake |
| Click / tap | move the `▌` cursor to that line (visual feedback, does **not** open) |
| Double-click / double-tap | open the item under the pointer (titles stay inert) |

> **Mouse** works over `pc` (ssh) and F2 (desktop) only — `pcm` (mosh) doesn't route the mouse, so taps never reach fzf. There is **no hover highlight**: fzf tracks clicks and scroll (terminal mouse modes 1000/1002), not bare cursor motion (1003), so it gets no event until you actually click. Opening is on the **second** click *because* there's no hover — the first click moves the `▌` cursor onto the line (your "look before you leap"), the second confirms. **`◆` titles are never selectable by mouse**: clicking one bounces the cursor to its section's first item (fzf positions the cursor on the clicked line *before* the bound action — `terminal.go:7848` — so the bind can detect a title via `$FZF_POS` and step off it), and a double-click on a title is ignored.

### Ctrl+X: kill ≠ delete

`Ctrl+X` runs `zellij kill-session` — it ends the **running process** (the live shell / `claude`), never any file on disk. (Ctrl+R rename is disabled with Zellij: its CLI can't rename a detached session.) What happens to the **menu row** depends on whether a folder backs it:

| Session killed | Menu row after kill | Why |
|---|---|---|
| 🟢 `~/dev` **project** | ✅ stays, flips to `○` **inactive** | the project folder still exists to anchor the `○` row |
| 🟣 **Obsidian vault** | ✅ stays, flips to `○` **inactive** | same — the vault folder still exists |
| ⚪ **disposable** (free name, no folder) | ❌ **disappears entirely** | a `○` row means "folder exists, no session"; a disposable session has no folder, so nothing is left to list |

A "real" session is therefore **never lost** from the list — `Ctrl+X` just deactivates it (`●` → `○`), and you re-enter it later (`claude --resume` recovers the transcript). Only a truly disposable session vanishes, which is the whole point of "disposable". The confirm prompt states which case applies before you commit (`Kill 'x'? Stays listed as ○ inactive.` vs `… Disposable — disappears from the list.`).

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

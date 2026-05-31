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
| `termux/img2claude` | Termux (Android) script: sends an image (photo/screenshot) into the Claude session running on the desktop. `scp` to the desktop, then **`wl-copy --type image/png` into the Wayland clipboard** (detached, so its persistent server doesn't hold the ssh channel open), then `tmux send-keys M-v`. Claude v2.1.152 reads `wl-paste --type image/png` first — clean JPEG bytes re-sniffed by sharp. **Why not the Windows clipboard alone:** WSLg only bridges it to Wayland as a 32-bit BI_BITFIELDS `image/bmp` that Claude's sharp/libvips can't decode, and since `wl-paste image/bmp` succeeds Claude never reaches the PowerShell fallback → "No image found". A `SetImage` into the Windows clipboard is kept as a bonus so Discord & other Windows apps can paste too. **Always called with a file-path argument** — by `screenshot-watcher` (auto) and by the `termux-file-editor` share hook. The no-arg "most recent" mode (the `i` alias) was removed 2026-05-27 since the watcher's auto-push makes it redundant. Works around mosh not carrying the clipboard (Alt+V can't cross it). It shows a **two-state `termux-notification`** (same id `img2claude`): "⏳ Transfert en cours…" posted before the `scp`, flipped in place to "Image prête à coller" once staging succeeds (Android replaces a same-id notif). When `rsync` is installed on the phone (`pkg install rsync`) the transfer uses `rsync --partial --info=progress2` instead of `scp` — the ⏳ shows a **live percentage** and a dropped/slow tunnel **resumes** instead of restarting (the dest filename is a stable hash of the source so retries resume the partial), with an idle `--timeout`; it falls back to the unchanged `scp` path if `rsync` is absent (the percentage simply turns on once rsync is installed). A `trap` removes the in-progress notif if the transfer/staging fails — while **preserving the non-zero exit code** so the watcher retries and never counts a failed upload as sent. It lives on its **own channel** `watcher-images` ("🖼️Image-prête", created best-effort) — a separate category in *Settings → Termux:API → Notifications*, distinct from the `watcher-toggle` control notif; falls back to the default channel if creation fails so the signal is never lost. ⚠️ Channel names must contain **no spaces**: `termux-notification-channel` expands its args unquoted and truncates a spaced name to its first word (confirmed 2026-05-29). |
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

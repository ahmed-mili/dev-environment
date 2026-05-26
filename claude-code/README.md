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

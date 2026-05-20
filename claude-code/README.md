# claude-code/

Claude Code config shared between Windows and Android. Single source of truth.

## Contents

| File | Role |
| --- | --- |
| `statusline.ps1` | PowerShell status line: colored path (depends on permission mode), git branch, live 5h/7d usage, plan + email. Portable fallback, no prerequisites. |
| `statusline-rs/` | Rust source for the 9 Hz animated statusline (xhigh magenta halo + max rainbow stretch). **Requires SAC disabled + patched claude.exe** — see dedicated section. |
| `settings.json` | Claude Code config (model, plugins, `.exe` statusline at 0.112s, SessionStart hook patch-claude-exe) |
| `hooks/patch-claude-exe.ps1` | Patches `claude.exe` on session start to lift the `refreshInterval >= 1` clamp + the 300ms debounce + idle keep-alive. **Flagged `FileFix.BBA!MTB` by Defender** — exception required. |
| `hooks/` (others) | `auto-pull.ps1`, `auto-push.ps1`, `resolve-sync-conflicts.ps1` — reserved for manual/future use, no longer called from SessionStart/End |
| `skills/` | 9 custom skills: copy-edit, css-layout-check, edit-block, lucide-icons, release, root-cause-fix, smart-edit, sticky-column-bleed-fix, webapp-deploy |
| `deploy.ps1` | Manual bidirectional sync between this folder and `~/.claude/` |

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

> ⚠️ `deploy.ps1 -Push` only copies the **9 whitelisted custom skills** to the repo. Anthropic's official skills or marketplace downloads (`brand-guidelines`, `claude-api`, `docx`, etc.) are never committed (keeps the repo lean).

### To add a new custom skill to the whitelist

Edit `deploy.ps1` line `$CustomSkills = @(...)` and add your skill's folder name.

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

## Effort level — two rendering modes

The 5 effort levels (`low`, `medium`, `high`, `xhigh`, `max`) have two possible renderings:

| Level | `.ps1` rendering (fallback) | `.exe` rendering (Rust, 9 Hz) |
| --- | --- | --- |
| `low` | yellowBright bold | yellowBright bold |
| `medium` | greenBright bold | greenBright bold |
| `high` | blueBright bold | blueBright bold |
| `xhigh` | centered Gaussian magenta halo (base `#F5C2E7` ↔ highlight `#d0b4ff`, sigma=0.9) — **static** | magenta halo sweeping left→right at 8.93 Hz |
| `max` | 7-stop Catppuccin palette stretched across the label width (`#F38BA8` → `#A6E3A1` → `#F5C2E7`) — **static** | rainbow palette cycling char-by-char at 8.93 Hz |

Claude Code's internal `/effort` picker animates `xhigh` and `max` at 10 Hz (Ink/React inside the binary). The `.ps1` statusline reproduces the **exact same colors** but statically (no time tick). The Rust version + patched `claude.exe` reproduces the animation **identically to the picker** (M=112 ms, i.e. 8.93 Hz). See the "9 Hz animated version (advanced)" section below for prerequisites.

## 9 Hz animated version (advanced)

The default `.ps1` rendering works with no prerequisites and all static renderings are visually correct. **Only enable the 9 Hz version if you want the motion.**

### Prerequisites (all required)

1. **Smart App Control = Off** — otherwise Windows 11 blocks execution of any unsigned Rust binary (OS error 4551 on `cargo build` too). Settings → Privacy & security → Smart App Control. ⚠️ **Disabling SAC is permanent**: re-enabling requires a full Windows reset. Only do this if you accept the trade-off.
2. **Defender exception for `~/.claude/hooks/patch-claude-exe.ps1`** — this script is flagged `Trojan:Win32/FileFix.BBA!MTB` (standard heuristic for binary patchers). Without an exception, Defender quarantines the file on clone and the hook never fires. Add the exception:
   ```powershell
   # From an elevated PowerShell:
   Add-MpPreference -ExclusionPath "$env:USERPROFILE\.claude\hooks\patch-claude-exe.ps1"
   ```
3. **Rust toolchain** — to compile the binary:
   ```powershell
   winget install Rustlang.Rustup
   ```

### Build

```powershell
cd C:\dev\dev-environment\claude-code\statusline-rs
.\build.ps1
```

`build.ps1` builds in `--release` (LTO + strip), redirects `CARGO_TARGET_DIR` to `%LOCALAPPDATA%\statusline-build\target` (trusted zone outside `C:\dev`, avoids SAC blocks on cargo build scripts), then copies the binary to `~/.claude/statusline.exe`.

### How the patch works

`patch-claude-exe.ps1` is a `SessionStart` hook that scans `claude.exe` on every session start and applies 4 in-place patches (in-place = same length, no byte shift):

| Patch | Pattern replaced | Effect |
| --- | --- | --- |
| 1 | `Math.max(1,X)*1000` → `Math.max(0,X)*1000` | Lifts the `refreshInterval >= 1` clamp on the statusline |
| 3 | `=H(()=>{F()},300)` → `=H(()=>{F()}, 50)` | Reduces the statusline component's 300 ms debounce (without this, refresh < 300 ms stays blocked) |
| 4 | `!K\|\|q===null?gZH:` → `false?gZH:       ` | Forces the active path of the `_9` hook even when `useContext(YQ)` is null (otherwise ~30s freeze in idle) |
| 5 | `K.setTimeout(Y,q)` → `Is8(Y,q)         ` (×2) | Bypasses the Ink RootStore's setTimeout, uses the native one via `Is8` → continuous tick in idle |

Patches are idempotent (skipped if already applied via the `~/.claude/last-patched-claude-exe.txt` mtime marker) and tolerant of the minified variable names that change on every Anthropic release (regex search with context).

After a Claude Code update, the hook re-patches automatically on the next session and emits a `systemMessage` to signal that the animation has been re-enabled.

## Credit

The `/usage` endpoint was discovered by [Melvynx (codelynx.dev)](https://codelynx.dev/posts/claude-code-usage-limits-statusline) via Proxyman.

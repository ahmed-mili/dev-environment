# dev-environment

Cross-platform config for my Claude Code setup on **Windows** and **Android** (Termux).

## Structure

```
dev-environment/
├── windows/        # PowerShell 7, Windows Terminal, Fastfetch
├── android/        # Termux: bash, starship, fastfetch
└── claude-code/    # statusline, settings, hooks, skills
```

## Install

### Windows (one-liner)

**Prerequisites**:
- **Smart App Control = Off** (Settings > Privacy & security > Smart App Control). ⚠️ Disabling SAC is permanent — re-enabling requires a full Windows reset. Most developers already have SAC off.
- **Elevated PowerShell**: launch Windows Terminal as administrator. Required to add a Defender exception on `patch-claude-exe.ps1` (flagged `Trojan:Win32/FileFix.BBA!MTB` — the bootstrap adds the exception before `git clone` so the file isn't quarantined silently).

```powershell
$b="$env:TEMP\dev-env-bootstrap.ps1"; irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1 -OutFile $b; Unblock-File $b; & $b
```

> Pattern `irm -OutFile + & file` (download to disk, then execute from the file) instead of `iex (irm ...)` (download + in-memory execute). The latter is the classic ClickFix signature (`Trojan:Win32/ClickFix.DAI!MTB`) — Defender now flags any script that combines `iex` with `irm` on a Github raw payload. The former is harmless (oh-my-posh, scoop, etc. all use it) and lets you inspect the downloaded `.ps1` before execution.

The bootstrap: (1) checks SAC + admin, (2) adds the Defender exception, (3) clones the repo to `C:\dev\dev-environment`, (4) installs winget packages (PowerShell 7, Terminal, Fastfetch, Rust toolchain), (5) builds the Rust statusline in `--release` (9 Hz animation), (6) deploys the Claude Code config. `claude.exe` is then patched automatically by the SessionStart hook on the next session.

Optional: run `/plugin` inside Claude Code afterward to install `frontend-design`, `code-review`, `superpowers` from the `claude-plugins-official` marketplace.

### Android (Termux, one-liner)
```bash
pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.sh)
```

`bootstrap.sh` auto-detects the state: fresh install → `android/setup.sh`; legacy Ollama/proot setup detected → `android/migrate-from-ollama.sh` (cleanup, then re-run `setup.sh`). Idempotent either way.

## License

[MIT](./LICENSE)

<!-- sync test 2026-05-17 from desktop -->

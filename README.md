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

**Prerequisite**: **Smart App Control = Off** (Settings > Privacy & security > Smart App Control). ⚠️ Disabling SAC is permanent — re-enabling requires a full Windows reset. Most developers already have SAC off.

```powershell
$b="$env:TEMP\dev-env-bootstrap.ps1"; irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1 -OutFile $b; Unblock-File $b; & $b
```

> Pattern `irm -OutFile + & file` (download to disk, then execute from the file) instead of `iex (irm ...)` (download + in-memory execute). The latter is the classic ClickFix signature (`Trojan:Win32/ClickFix.DAI!MTB`) — Defender now flags any script that combines `iex` with `irm` on a Github raw payload. The former is harmless (oh-my-posh, scoop, etc. all use it) and lets you inspect the downloaded `.ps1` before execution.

The bootstrap (8 idempotent steps): (1) checks SAC, (2) installs Git, (3) prompts once for `git user.name` / `user.email` if unset, (4) clones the repo to `C:\dev\dev-environment`, (5) installs winget packages (PowerShell 7, Terminal, Fastfetch, Rust toolchain, **Claude Code via `Anthropic.ClaudeCode`**, plus WinLibs/MinGW only if MSVC Build Tools are missing), (6) builds the Rust statusline in `--release`, (7) deploys the Claude Code config (statusline + settings + hooks + skills), (8) installs the official Claude plugins listed in `enabledPlugins` (`frontend-design`, `code-review`, `superpowers`, `rust-analyzer-lsp`).

Optional: run `/plugin` inside Claude Code afterward to install `frontend-design`, `code-review`, `superpowers` from the `claude-plugins-official` marketplace.

### Android (Termux, one-liner)
```bash
pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.sh)
```

`bootstrap.sh` auto-detects the state: fresh install → `android/setup-ssh-client.sh`; previous-generation install detected (Ollama/proot **or** native Claude Code + auto-pull/push hooks) → `android/migrate-legacy.sh`, which cleans up then re-runs `setup-ssh-client.sh`. Idempotent either way.

## License

[MIT](./LICENSE)

<!-- sync test 2026-05-17 from desktop -->

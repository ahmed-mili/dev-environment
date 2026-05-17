# dev-environment

Cross-platform config for my Claude Code + Ollama setup on **Windows** and **Android** (Termux).

## Structure

```
dev-environment/
├── windows/        # PowerShell 7, Windows Terminal, Fastfetch
├── android/        # Termux: bash, starship, fastfetch
├── claude-code/    # statusline, settings, hooks, skills
└── ollama/         # cloud model integrations
```

## Install

### Windows (one-liner)
```powershell
iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1).TrimStart([char]0xFEFF)
```

Clones the repo to `C:\dev\dev-environment`, installs winget packages + PS7 profile + Terminal + Fastfetch, deploys Claude Code statusline/settings/hooks/skills. Optionally run `/plugin` inside Claude Code afterward to add `frontend-design`, `code-review`, `superpowers` from `claude-plugins-official`.

### Android (Termux)
```bash
curl -fsSL https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh | bash
```

## License

[MIT](./LICENSE)

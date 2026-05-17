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

### Windows
```powershell
git clone https://github.com/ahmed-mili/dev-environment.git C:\dev\dev-environment
cd C:\dev\dev-environment
.\windows\install.ps1
.\claude-code\deploy.ps1 -Pull
```

Then in Claude Code, run `/plugin` and install `frontend-design`, `code-review`, `superpowers` from `claude-plugins-official`.

### Android (Termux)
```bash
curl -fsSL https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh | bash
```

### Windows bootstrap (no clone)
```powershell
iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/windows/install.ps1).TrimStart([char]0xFEFF)
```

## License

[MIT](./LICENSE)

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
```powershell
$b="$env:TEMP\dev-env-bootstrap.ps1"; irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1 -OutFile $b; Unblock-File $b; & $b
```

> Pattern `irm -OutFile + & file` (téléchargement vers disk puis exécution depuis le fichier) au lieu de `iex (irm ...)` (téléchargement + exécution in-memory). Le second est la signature classique de ClickFix (`Trojan:Win32/ClickFix.DAI!MTB`) — Defender flag aujourd'hui n'importe quel script qui combine `iex` avec `irm` sur un payload Github raw. Le premier est inoffensif (oh-my-posh, scoop, etc. l'utilisent), et permet à l'user d'inspecter le `.ps1` téléchargé avant exécution s'il le souhaite.

Clones the repo to `C:\dev\dev-environment`, installs winget packages + PS7 profile + Terminal + Fastfetch, deploys Claude Code statusline/settings/hooks/skills. Optionally run `/plugin` inside Claude Code afterward to add `frontend-design`, `code-review`, `superpowers` from `claude-plugins-official`.

### Android (Termux)
```bash
curl --version >/dev/null 2>&1 || dpkg -r --force-depends libngtcp2-crypto-ossl 2>/dev/null; \
pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/android/setup.sh)
```

## License

[MIT](./LICENSE)

<!-- sync test 2026-05-17 from desktop -->

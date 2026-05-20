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

**Prérequis** :
- **Smart App Control = Off** (Settings > Privacy & security > Smart App Control). ⚠️ Désactivation définitive : pour réactiver, reset Windows.
- **PowerShell admin** : lance Windows Terminal en administrateur. Requis pour l'exception Defender sur `patch-claude-exe.ps1` (script flagged `Trojan:Win32/FileFix.BBA!MTB` — le bootstrap ajoute l'exception avant le `git clone` pour éviter la quarantaine silencieuse).

```powershell
$b="$env:TEMP\dev-env-bootstrap.ps1"; irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.ps1 -OutFile $b; Unblock-File $b; & $b
```

> Pattern `irm -OutFile + & file` (téléchargement vers disk puis exécution depuis le fichier) au lieu de `iex (irm ...)` (téléchargement + exécution in-memory). Le second est la signature classique de ClickFix (`Trojan:Win32/ClickFix.DAI!MTB`) — Defender flag aujourd'hui n'importe quel script qui combine `iex` avec `irm` sur un payload Github raw. Le premier est inoffensif (oh-my-posh, scoop, etc. l'utilisent), et permet à l'user d'inspecter le `.ps1` téléchargé avant exécution s'il le souhaite.

Le bootstrap : (1) vérifie SAC + admin, (2) ajoute l'exception Defender, (3) clone le repo dans `C:\dev\dev-environment`, (4) installe les winget packages (PowerShell 7, Terminal, Fastfetch, Rust toolchain), (5) build le statusline Rust en `--release` (animation 9 Hz), (6) déploie la config Claude Code. `claude.exe` est ensuite patché automatiquement par le SessionStart hook à la prochaine session.

Optionnel : lance `/plugin` dans Claude Code après pour ajouter `frontend-design`, `code-review`, `superpowers` du marketplace `claude-plugins-official`.

### Android (Termux, one-liner)
```bash
pkg install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/bootstrap.sh)
```

Le `bootstrap.sh` auto-détecte l'état : fresh install → `android/setup.sh`, ancien setup Ollama/proot détecté → `android/migrate-from-ollama.sh` (cleanup puis re-run de setup.sh). Idempotent dans les deux cas.

## License

[MIT](./LICENSE)

<!-- sync test 2026-05-17 from desktop -->

# terminal-config-bundle

Single-file installer for my Windows Terminal + PowerShell setup.

## Install

```powershell
iwr https://raw.githubusercontent.com/ahmed-mili/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
```

## What it does

- Installs **PowerShell 7** and **Windows Terminal** via `winget` (skipped if already present).
- Sets `CurrentUser` execution policy to `RemoteSigned`.
- Backs up any existing config as `<name>.bak-<timestamp>` before overwriting.
- Drops these three files:

| File | Path | Contents |
| --- | --- | --- |
| PowerShell 7 profile | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` | `isadmin` helper, Tab accepts PSReadLine's inline grey suggestion (falls back to menu-complete) |
| Windows PowerShell 5 profile | `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` | Forces UTF-8, neutralizes the default blue background, `isadmin` helper |
| Windows Terminal settings | `~\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` | `Ctrl+C` / `Ctrl+V` / `Alt+Shift+D` keybindings, dark theme, PowerShell 7 as default profile |

## License

[MIT](./LICENSE)

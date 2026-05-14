# terminal-config-bundle

Single-file installer for my Windows Terminal + PowerShell setup.

## Install

```powershell
iwr https://raw.githubusercontent.com/ahmed-mili/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
```

## What it does

Installs **PowerShell 7** and **Windows Terminal** via `winget` (skipped if already present), sets `CurrentUser` execution policy to `RemoteSigned`, and deploys these three files (any existing config is backed up as `<name>.bak-<timestamp>` first):

| File | Path |
| --- | --- |
| PowerShell 7 profile | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows PowerShell 5 profile | `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows Terminal settings | `~\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` |

The profiles add an `isadmin` helper, force UTF-8 on PS 5.1, neutralize Windows PowerShell's default blue background, and rebind Tab in PS 7 to accept PSReadLine's inline grey suggestion (falling back to menu-complete). The Windows Terminal settings ship `Ctrl+C` / `Ctrl+V` / `Alt+Shift+D` keybindings, the dark theme, and PowerShell 7 as the default profile.

## License

[MIT](./LICENSE)

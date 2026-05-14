# terminal-config-bundle

Single-file installer for my Windows Terminal + PowerShell setup.

## Install

```powershell
iwr https://raw.githubusercontent.com/ahmed-mili/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
```

## What it does

- Installs **PowerShell 7** and **Windows Terminal** via `winget` (skipped if already present).
- Sets `CurrentUser` execution policy to `RemoteSigned` so the deployed profiles load on every future session.
- Drops a **PowerShell 7 profile** with an `isadmin` helper and a Tab key that accepts PSReadLine's inline grey suggestion when one is visible (falls back to menu-complete otherwise).
- Drops a **Windows PowerShell 5 profile** that forces UTF-8 on every startup, neutralizes the default blue background, and exposes the same `isadmin` helper.
- Drops a **Windows Terminal `settings.json`** with `Ctrl+C` / `Ctrl+V` / `Alt+Shift+D` keybindings, dark theme, and PowerShell 7 as the default profile.
- Backs up any existing config as `<name>.bak-<timestamp>` before overwriting.

## License

[MIT](./LICENSE)

# terminal-config-bundle

Single-file installer for my Windows Terminal + PowerShell setup.

## Install

```powershell
iwr https://raw.githubusercontent.com/ahmed-mili/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
```

Installs PowerShell 7 and Windows Terminal via `winget` if missing, then drops
the embedded PS5/PS7 profiles and Windows Terminal `settings.json`. Any existing
config is backed up as `<name>.bak-<timestamp>`.

## License

[MIT](./LICENSE)

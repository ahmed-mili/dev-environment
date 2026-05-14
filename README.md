# terminal-config-bundle

A minimal, single-file installer that sets up **Windows Terminal** and **PowerShell**
the way I like them — on any Windows 10/11 machine — in about 10 seconds.

Everything (PS5 profile, PS7 profile, Windows Terminal `settings.json`) is embedded
into one script. No separate config files to chase, no manual copy/paste.

## Quick install

Open PowerShell on the target machine and run:

```powershell
iwr https://raw.githubusercontent.com/ahmed-mili/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
```

That's it. The script will:

1. Install **PowerShell 7** and **Windows Terminal** via `winget` (skipped if already present).
2. Set your `CurrentUser` execution policy to `RemoteSigned` so future profile loads don't get blocked.
3. Drop a PowerShell 7 profile, a Windows PowerShell 5 profile, and a Windows Terminal `settings.json` — backing up any existing file as `<name>.bak-<timestamp>`.
4. `Unblock-File` the deployed scripts so they aren't flagged as downloaded.

Reopen Windows Terminal and you're done.

## Install from a local clone

```powershell
git clone https://github.com/ahmed-mili/terminal-config-bundle.git
cd terminal-config-bundle
.\install.ps1
```

If Windows Terminal has never been launched on this machine, its config folder doesn't
exist yet. Launch WT once, close it, then re-run with `-SkipWinget`:

```powershell
.\install.ps1 -SkipWinget
```

## What it changes

| File | Path |
| --- | --- |
| PowerShell 7 profile | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows PowerShell 5 profile | `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows Terminal settings | `~\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` |

The profiles add an `isadmin` helper, force UTF-8 on PS 5.1, and neutralize the default
blue background of Windows PowerShell. The Windows Terminal settings ship sensible
keybindings (`Ctrl+C` / `Ctrl+V`, `Alt+Shift+D` to duplicate a pane), `dark` theme,
and PowerShell 7 as the default profile.

## Restore previous config

Every overwrite leaves a `.bak-<timestamp>` next to the original file:

```powershell
# Example: restore PS7 profile
$p = "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
Copy-Item "$p.bak-20260101-120000" $p -Force
```

## Customizing for yourself

Fork the repo, edit the three `@'...'@` here-strings near the top of `install.ps1`, push.
Your one-liner becomes:

```powershell
iwr https://raw.githubusercontent.com/<you>/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
```

## License

[MIT](./LICENSE)

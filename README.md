# terminal-config-bundle

Single-file installer for my Windows Terminal + PowerShell setup. Fish-like
predictions, fzf fuzzy search, Catppuccin Mocha theme, JetBrains Mono Nerd
Font, and a Fastfetch (Arch logo) splash on every shell launch. **Windows only.**

## Install

```powershell
iwr https://raw.githubusercontent.com/ahmed-mili/terminal-config-bundle/main/install.ps1 -UseBasicParsing | iex
```

## What it does

Installs **PowerShell 7**, **Windows Terminal**, **fzf**, **JetBrains Mono Nerd Font** and **Fastfetch** via `winget` (skipped if already present). Installs the `CompletionPredictor` and `PSFzf` modules from the PSGallery. Sets `CurrentUser` execution policy to `RemoteSigned`, marks the PSGallery repo as `Trusted`, and deploys these three files (any existing config is backed up as `<name>.bak-<timestamp>` first):

| File | Path |
| --- | --- |
| PowerShell 7 profile | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows PowerShell 5 profile | `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows Terminal settings | `~\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` |

The PS 7 profile turns on PSReadLine inline predictions (grey ghost text from history + smart completions), rebinds Tab to accept the suggestion (falling back to the completion menu), wires PSFzf for fuzzy history and file pickers, and runs `fastfetch --logo arch` at the top of every interactive session. The PS 5 profile forces UTF-8, neutralizes the default blue background, and exposes an `isadmin` helper. The Windows Terminal settings ship `Ctrl+C` / `Ctrl+V` / `Alt+Shift+D` keybindings, the **Catppuccin Mocha** color scheme, JetBrains Mono Nerd Font at 11 pt, acrylic background at 95% opacity, and PowerShell 7 as the default profile.

> When `fzf`, the Nerd Font, or Fastfetch are freshly installed, the new `PATH` and fonts only apply to **new** shells. Close and reopen Windows Terminal once after install.

## Keybindings in PS 7

| Key | Action |
| --- | --- |
| `Tab` | Accept the grey suggestion; otherwise open the completion menu |
| `→` / `Ctrl+→` | Accept the suggestion (full / word-by-word) |
| `F2` | Toggle between inline ghost text and dropdown list view |
| `Ctrl+R` | Fuzzy reverse history search (fzf) |
| `Ctrl+T` | Fuzzy file / directory picker (fzf) |

## License

[MIT](./LICENSE)

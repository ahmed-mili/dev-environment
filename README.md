# windows-pwsh-config

Single-file installer for a polished Windows Terminal + PowerShell 7 setup:
**Catppuccin Mocha** theme, **JetBrainsMono Nerd Font**, **Fastfetch** splash
with gradient header, plus PSReadLine predictions, Terminal-Icons and PSFzf.
**Windows only.**

## Install / Update

```powershell
iex (irm https://raw.githubusercontent.com/ahmed-mili/windows-pwsh-config/main/install.ps1).TrimStart([char]0xFEFF)
```

Idempotent — backs up existing configs, skips what's already installed, re-runs
chassis detection if you move between machines.

## What it installs

**Winget packages:** PowerShell 7, Windows Terminal, fzf, JetBrainsMono Nerd
Font, Fastfetch. **PSGallery modules:** CompletionPredictor, PSFzf,
Terminal-Icons.

**Config files deployed** (existing ones backed up with `.bak-<timestamp>`):

| File | Path |
| --- | --- |
| PS 7 profile | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| PS 5 profile | `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` |
| Terminal settings | `…\LocalState\settings.json` |
| Fastfetch config | `~\.config\fastfetch\config.jsonc` |

All payloads are base64-encoded inside `install.ps1` to avoid quoting issues
with ANSI escapes and Nerd Font glyphs.

## Highlights

- **Fastfetch splash** — mauve→sapphire gradient on divider, module icons and
  `USER@HOST` header. RAM auto-detected from WMI (`2 × 16 GiB DDR4-3600`);
  physical disk shows model + interconnect. GPU ignores virtual adapters.
- **PSReadLine** — inline predictions (history + CompletionPredictor), Catppuccin
  syntax colors. `F2` toggles inline ↔ dropdown. `Tab` accepts suggestion or
  opens menu.
- **PSFzf** — `Ctrl+R` fuzzy history, `Ctrl+T` fuzzy file picker.
- **Terminal** — acrylic at 85 %, `pwsh -NoLogo -NoProfileLoadTime` as default,
  `Ctrl+C`/`Ctrl+V`/`Alt+Shift+D` keybindings.
- **Desktop shortcut** — `Ctrl+Alt+T` opens Terminal as Administrator.

> New `PATH` entries and fonts only apply to **new** shells. Reopen Terminal
> once after install.

## Keybindings

| Key | Action |
| --- | --- |
| `Tab` | Accept suggestion / open completion menu |
| `→` / `Ctrl+→` | Accept suggestion (full / word-by-word) |
| `F2` | Toggle inline ↔ dropdown predictions |
| `Ctrl+R` | Fuzzy history search (fzf) |
| `Ctrl+T` | Fuzzy file picker (fzf) |
| `Ctrl+Alt+T` | Open elevated Terminal (desktop shortcut) |

## License

[MIT](./LICENSE)
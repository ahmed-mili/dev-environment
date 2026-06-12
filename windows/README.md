# windows/

Sous-section Windows du repo [`dev-environment`](../README.md). Single-file installer pour un setup Windows Terminal + PowerShell 7 :
**Catppuccin Mocha** theme, **JetBrains Mono + Noto Naskh Arabic + Nerd Font symbols**,
**Fastfetch** splash with gradient header, plus PSReadLine predictions,
Terminal-Icons et PSFzf.

## Install / Update

```powershell
iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/windows/install.ps1).TrimStart([char]0xFEFF)
```

Idempotent — backs up existing configs, skips what's already installed, re-runs
chassis detection if you move between machines.

## What it installs

**Winget packages:** PowerShell 7, Windows Terminal, fzf, zoxide, Fastfetch.
**User fonts:** JetBrains Mono, Noto Naskh Arabic, Symbols Nerd Font Mono,
Noto Color Emoji. **PSGallery modules:** CompletionPredictor, PSFzf, Terminal-Icons.

**Config files deployed** (existing ones backed up with `.bak-<timestamp>`):

| File | Path |
| --- | --- |
| PS 7 profile | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| PS 5 profile | `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` |
| Terminal settings | `…\LocalState\settings.json` |
| Fastfetch config | `~\.config\fastfetch\config.jsonc` |

**Scheduled task:** `zellij-web-server` (at logon) runs `zellij web` on
`127.0.0.1:8082` inside the interactive logon session, so sessions opened from
the phone are born desktop-native (joinable from the F2 sessionizer). Never
start this server from an ssh context (Session 0).

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

[MIT](../LICENSE)

# windows-pwsh-config

Single-file installer for a clean Windows Terminal + PowerShell setup.
**Catppuccin Mocha** scheme, **JetBrainsMono Nerd Font**, a portable
**Fastfetch splash** with a per-character gradient `USER@HOST` header, a
gradient divider, gradient-tinted module rows, dynamically-detected RAM and
physical disk, plus PSReadLine with Catppuccin syntax colors,
fish-like inline predictions, Terminal-Icons in `ls` output and PSFzf for
fuzzy `Ctrl+R` / `Ctrl+T`. The native PowerShell prompt is kept
(`PS C:\Users\Ahmed>`). **Windows only.**

## Install

```powershell
iwr https://raw.githubusercontent.com/ahmed-mili/windows-pwsh-config/main/install.ps1 -UseBasicParsing | iex
```

## What it does

Installs the following via `winget` (skipped if already present):
**PowerShell 7**, **Windows Terminal**, **fzf**, **JetBrainsMono Nerd Font**,
**Fastfetch**. Installs the `CompletionPredictor`, `PSFzf` and `Terminal-Icons`
modules from the PSGallery into PowerShell 7's module path.

Sets `CurrentUser` execution policy to `RemoteSigned`, marks the PSGallery repo
as `Trusted`, and deploys these files (any existing config is backed up as
`<name>.bak-<timestamp>` first):

| File | Path |
| --- | --- |
| PowerShell 7 profile | `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows PowerShell 5 profile | `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` |
| Windows Terminal settings | `~\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` |
| Fastfetch config | `~\.config\fastfetch\config.jsonc` |

All payloads are embedded as base64 inside `install.ps1` to keep it a true
single-file installer and avoid quoting issues with ANSI escapes, Nerd Font
glyphs and embedded single quotes.

### PowerShell 7 profile highlights

- Forces the console to UTF-8 (`InputEncoding`, `OutputEncoding`,
  `$OutputEncoding`) so accents and Nerd Font glyphs render correctly.
- **PSReadLine**: `HistoryAndPlugin` predictions in `InlineView`, syntax
  colors aligned with the Catppuccin Mocha palette. `F2` toggles between
  inline ghost text and the list dropdown. `Tab` accepts the inline
  suggestion when one is visible, falls back to `MenuComplete` otherwise.
- **CompletionPredictor**: extends predictions beyond shell history to
  cmdlet parameters, git branches, file paths and so on.
- **Terminal-Icons**: Nerd Font icons in `Get-ChildItem` / `ls` output.
- **PSFzf**: `Ctrl+R` for fuzzy reverse-history search, `Ctrl+T` for
  fuzzy file/directory picker (only loaded if `fzf.exe` is on `PATH`).
- **Fastfetch splash** on every interactive shell, with two pieces of
  dynamic information computed in the profile so the splash is portable
  across PCs without rewriting the JSONC file:
  - `$env:FF_RAM` — RAM summary built from `Win32_PhysicalMemory` WMI
    (counts identical sticks → `2 × 16 GiB DDR4-3600 (Corsair)`; mixed
    sticks → `4 sticks, 64 GiB DDR5 (mixed)`).
  - A per-character gradient `USER@HOST` header (`%USERNAME%@%COMPUTERNAME%`)
    printed just before fastfetch runs, sharing the cool-tone Catppuccin
    palette of the splash's divider and module rows.

### Fastfetch config highlights

A cool-tone Catppuccin gradient (a mauve→lavender→sapphire trio) is applied
consistently to:

- the divider (`─` × 46, one ANSI color per dash),
- every module key/icon (`Shell`, `OS`, `Board`, `CPU`, `GPU`, `RAM`, `Drive`,
  `Display`, `Uptime`), each sampled at its position in the 9-step gradient,
- the `USER@HOST` header rendered by the profile (per-character lerp through
  the same trio).

Specific modules:

- `gpu` uses `detectionMethod: "vulkan"` to ignore virtual GPUs (Parsec
  virtual display, etc.) and report only the real device.
- `physicaldisk` shows the physical drive's model + interconnect + size
  (e.g. `Samsung SSD 980 PRO 1TB — NVMe 931.51 GiB`).
- `command` reads `%FF_RAM%` from the env so the RAM line is detection-driven
  rather than hard-coded.
- No Linux-style 8-color palette footer (irrelevant on Windows where there's
  no ANSI scheme to advertise).

### Windows Terminal settings

- **Catppuccin Mocha** color scheme.
- **JetBrainsMono Nerd Font** at 11 pt, acrylic background at 85 % opacity.
- **PowerShell 7** as the default profile, launched with
  `pwsh.exe -NoLogo -NoProfileLoadTime` so the splash isn't preceded by
  `PowerShell 7.6.1` or `Loading personal and system profiles took … ms.`
- Keybindings: `Ctrl+C` copy, `Ctrl+V` paste, `Alt+Shift+D` duplicate pane.

> When `fzf`, the Nerd Font or Fastfetch are freshly installed, the new
> `PATH` and fonts only apply to **new** shells. Close and reopen Windows
> Terminal once after install.

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

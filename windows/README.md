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

Payloads (PS profiles, Terminal settings, Fastfetch config) live in `windows/files/`
as plain files and are copied as-is — *not* base64-inlined: the decode-then-write
pattern is the standard heuristic signature of a stager, and it got `install.ps1`
flagged by Defender as `Trojan:Win32/ClickFix.AAC!MTB`.

## SSH server (phone → PC)

Needed by the Termux `pwsh` / `dev` / `sleep-pc` functions (`android/files/bashrc`),
which reach the desktop over the Windows sshd on **port 2222**.

```powershell
# From an ADMIN PowerShell (unlike install.ps1, this one needs UAC):
$k = ssh phone "cat ~/.ssh/id_ed25519.pub"
.\install-sshd.ps1 -PublicKey $k
```

Installs the OpenSSH Server capability, listens on 2222, **key-only auth**
(`PasswordAuthentication no`), and a firewall rule scoped to the **Tailscale CGNAT
range only** (`100.64.0.0/10`) — the port is never exposed to the LAN or a public
Wi-Fi. Idempotent.

Three traps this script exists to absorb:

- `Add-WindowsCapability` fails with *"Class not registered"* under PowerShell 7
  (the DISM module isn't loaded there). The script delegates to Windows PowerShell 5.1.
- For a user in the **administrators** group, sshd reads
  `__PROGRAMDATA__/ssh/administrators_authorized_keys`, **not** `~/.ssh/authorized_keys`
  (see the `Match Group administrators` block in `sshd_config`). A key in the wrong
  file is ignored silently. Its ACL must also be Administrators + SYSTEM only.
- Reinstalling Windows registers a **new Tailscale node with a new IP**, so the phone's
  `~/.ssh/config` keeps pointing at the dead one. Fix `HostName` with `tailscale ip -4`.

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
| `Alt+L` | Claude Code `/login` (auto-confirms the default method) |
| `Alt+R` | Claude Code `/resume` |

`Alt+L`/`Alt+R` are Windows Terminal actions (`sendInput`), deployed with `wt-settings.json` above. Same two shortcuts also exist for VS Code's integrated terminal — not auto-deployed (a real `keybindings.json` usually already holds personal bindings): merge `files/vscode-keybindings.json` into `%APPDATA%\Code\User\keybindings.json` by hand. Details in [`claude-code/README.md`](../claude-code/README.md#login--resume-shortcuts-altl--altr).

## License

[MIT](../LICENSE)

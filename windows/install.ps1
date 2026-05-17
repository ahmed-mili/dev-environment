#Requires -Version 5.1
<#
.SYNOPSIS
    Windows + PowerShell config bundle -- single-file installer.

.DESCRIPTION
    Installs PowerShell 7, Windows Terminal, fzf, JetBrainsMono Nerd Font and
    Fastfetch via winget (skipped if already present), then deploys:
      - PowerShell 7 profile (UTF-8, Catppuccin PSReadLine, predictions,
        Terminal-Icons, PSFzf, fastfetch splash with WMI-detected RAM and a
        per-character gradient USER@HOST header)
      - Windows PowerShell 5 profile (UTF-8 + isadmin helper)
      - Windows Terminal settings.json (Catppuccin Mocha scheme, JetBrainsMono
        Nerd Font 11pt, acrylic, PowerShell 7 default with
        `pwsh.exe -NoLogo -NoProfileLoadTime`)
      - Fastfetch config (cool-tone Catppuccin gradient across header,
        divider and module rows -- no Linux-style 8-color palette footer)
    All payloads are embedded as base64 (handles ANSI escapes, single quotes
    and Nerd Font glyphs without quoting issues).

.PARAMETER SkipWinget
    Skip the winget installation step.

.LINK
    https://github.com/ahmed-mili/dev-environment

.EXAMPLE
    # One-liner (no clone required):
    iex (irm https://raw.githubusercontent.com/ahmed-mili/dev-environment/main/windows/install.ps1).TrimStart([char]0xFEFF)

.EXAMPLE
    # From a local clone:
    .\install.ps1
#>

param(
    [switch]$SkipWinget
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "  ==> $msg" -ForegroundColor Blue }
function Write-Ok($msg)   { Write-Host "      ✓ " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Note($msg) { Write-Host "      ! " -ForegroundColor Yellow -NoNewline; Write-Host $msg }

function Short-Path([string]$p) {
    if ($p.StartsWith($env:USERPROFILE)) { "~" + $p.Substring($env:USERPROFILE.Length) }
    else { $p }
}

# ---------------------------------------------------------------------------
# Embedded payloads (base64 to neutralise quoting / control-char hazards)
# ---------------------------------------------------------------------------

$ps7ProfileB64 = 'IyBGb3JjZSB0aGUgY29uc29sZSB0byBVVEYtOCBzbyBub24tQVNDSUkgb3V0cHV0IChGYXN0ZmV0Y2ggaWNvbnMsIE5lcmQgRm9udAojIGdseXBocywgYWNjZW50cyBpbiBkaXJlY3RvcnkgbmFtZXMpIHJlbmRlcnMgY29ycmVjdGx5IGluc3RlYWQgb2YgbW9qaWJha2UuCltDb25zb2xlXTo6SW5wdXRFbmNvZGluZyAgPSBbU3lzdGVtLlRleHQuVVRGOEVuY29kaW5nXTo6bmV3KCkKW0NvbnNvbGVdOjpPdXRwdXRFbmNvZGluZyA9IFtTeXN0ZW0uVGV4dC5VVEY4RW5jb2RpbmddOjpuZXcoKQokT3V0cHV0RW5jb2RpbmcgICAgICAgICAgID0gW1N5c3RlbS5UZXh0LlVURjhFbmNvZGluZ106Om5ldygpCgpmdW5jdGlvbiBpc2FkbWluIHsKICAgIChbU2VjdXJpdHkuUHJpbmNpcGFsLldpbmRvd3NQcmluY2lwYWxdW1NlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzSWRlbnRpdHldOjpHZXRDdXJyZW50KCkpLklzSW5Sb2xlKFtTZWN1cml0eS5QcmluY2lwYWwuV2luZG93c0J1aWx0SW5Sb2xlXTo6QWRtaW5pc3RyYXRvcikKfQoKZnVuY3Rpb24gZGV2IHsgU2V0LUxvY2F0aW9uIEM6XGRldiB9CgojIC0tLS0gUFNSZWFkTGluZTogbW9kZXJuIHByZWRpY3Rpb25zICsgc21hcnQgVGFiICsgQ2F0cHB1Y2NpbiBNb2NoYSBjb2xvcnMgLS0tLQojIC0gSW5saW5lVmlldyBieSBkZWZhdWx0IChncmV5IGdob3N0IHRleHQpLiBGMiB0b2dnbGVzIHRvIExpc3RWaWV3IChkcm9wZG93bikuCiMgLSBUYWIgYWNjZXB0cyB0aGUgaW5saW5lIHByZWRpY3Rpb24gaWYgb25lIGlzIHZpc2libGUsIGVsc2UgTWVudUNvbXBsZXRlLgojIC0gUmlnaHQgQXJyb3cgLyBDdHJsK1JpZ2h0QXJyb3cgYWxzbyBhY2NlcHQgKHN0YW5kYXJkIFBTUmVhZExpbmUgYmVoYXZpb3IpLgojIC0gU3ludGF4LWhpZ2hsaWdodCBjb2xvcnMgYWxpZ25lZCB3aXRoIHRoZSBDYXRwcHVjY2luIE1vY2hhIHBhbGV0dGUuCmlmIChHZXQtTW9kdWxlIC1OYW1lIFBTUmVhZExpbmUgLUxpc3RBdmFpbGFibGUpIHsKICAgIFNldC1QU1JlYWRMaW5lT3B0aW9uIC1QcmVkaWN0aW9uU291cmNlIEhpc3RvcnlBbmRQbHVnaW4gLVByZWRpY3Rpb25WaWV3U3R5bGUgSW5saW5lVmlldyAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZQogICAgU2V0LVBTUmVhZExpbmVPcHRpb24gLUNvbG9ycyBAewogICAgICAgIENvbW1hbmQgICAgICAgICAgICA9ICcjODlCNEZBJyAgIyBCbHVlCiAgICAgICAgUGFyYW1ldGVyICAgICAgICAgID0gJyNGNUMyRTcnICAjIFBpbmsKICAgICAgICBWYXJpYWJsZSAgICAgICAgICAgPSAnI0Y1QzJFNycgICMgUGluawogICAgICAgIFN0cmluZyAgICAgICAgICAgICA9ICcjQTZFM0ExJyAgIyBHcmVlbgogICAgICAgIE51bWJlciAgICAgICAgICAgICA9ICcjRkFCMzg3JyAgIyBQZWFjaAogICAgICAgIFR5cGUgICAgICAgICAgICAgICA9ICcjRjlFMkFGJyAgIyBZZWxsb3cKICAgICAgICBLZXl3b3JkICAgICAgICAgICAgPSAnI0NCQTZGNycgICMgTWF1dmUKICAgICAgICBDb21tZW50ICAgICAgICAgICAgPSAnIzZDNzA4NicgICMgT3ZlcmxheTAKICAgICAgICBPcGVyYXRvciAgICAgICAgICAgPSAnIzg5RENFQicgICMgU2t5CiAgICAgICAgTWVtYmVyICAgICAgICAgICAgID0gJyM5NEUyRDUnICAjIFRlYWwKICAgICAgICBFcnJvciAgICAgICAgICAgICAgPSAnI0YzOEJBOCcgICMgUmVkCiAgICAgICAgRW1waGFzaXMgICAgICAgICAgID0gJyNGMzhCQTgnICAjIFJlZAogICAgICAgIElubGluZVByZWRpY3Rpb24gICA9ICcjNkM3MDg2JyAgIyBPdmVybGF5MCAoZGltbWVkIGdob3N0IHRleHQpCiAgICAgICAgRGVmYXVsdCAgICAgICAgICAgID0gJyNDREQ2RjQnICAjIFRleHQKICAgICAgICBDb250aW51YXRpb25Qcm9tcHQgPSAnI0E2QURDOCcgICMgU3VidGV4dDAKICAgIH0gLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKICAgIFNldC1QU1JlYWRMaW5lS2V5SGFuZGxlciAtS2V5IEYyIC1GdW5jdGlvbiBTd2l0Y2hQcmVkaWN0aW9uVmlldwogICAgU2V0LVBTUmVhZExpbmVLZXlIYW5kbGVyIC1LZXkgVGFiIC1TY3JpcHRCbG9jayB7CiAgICAgICAgJGxpbmUgPSAkbnVsbDsgJGN1cnNvciA9ICRudWxsCiAgICAgICAgW01pY3Jvc29mdC5Qb3dlclNoZWxsLlBTQ29uc29sZVJlYWRMaW5lXTo6R2V0QnVmZmVyU3RhdGUoW3JlZl0kbGluZSwgW3JlZl0kY3Vyc29yKQogICAgICAgIFtNaWNyb3NvZnQuUG93ZXJTaGVsbC5QU0NvbnNvbGVSZWFkTGluZV06OkFjY2VwdFN1Z2dlc3Rpb24oKQogICAgICAgICRuZXdMaW5lID0gJG51bGw7ICRuZXdDdXJzb3IgPSAkbnVsbAogICAgICAgIFtNaWNyb3NvZnQuUG93ZXJTaGVsbC5QU0NvbnNvbGVSZWFkTGluZV06OkdldEJ1ZmZlclN0YXRlKFtyZWZdJG5ld0xpbmUsIFtyZWZdJG5ld0N1cnNvcikKICAgICAgICBpZiAoJGxpbmUgLWVxICRuZXdMaW5lKSB7CiAgICAgICAgICAgIFtNaWNyb3NvZnQuUG93ZXJTaGVsbC5QU0NvbnNvbGVSZWFkTGluZV06Ok1lbnVDb21wbGV0ZSgpCiAgICAgICAgfQogICAgfQp9CgojIC0tLS0gQ29tcGxldGlvblByZWRpY3Rvcjogc21hcnQgcHJlZGljdGlvbnMgYmV5b25kIHNoZWxsIGhpc3RvcnkKIyAoY21kbGV0IHBhcmFtZXRlcnMsIGdpdCBicmFuY2hlcywgZmlsZSBwYXRocywgZXRjLikgLS0tLQppZiAoR2V0LU1vZHVsZSAtTGlzdEF2YWlsYWJsZSAtTmFtZSBDb21wbGV0aW9uUHJlZGljdG9yKSB7CiAgICBJbXBvcnQtTW9kdWxlIENvbXBsZXRpb25QcmVkaWN0b3IgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKfQoKIyAtLS0tIHpveGlkZTogc21hcnQgYGNkYCBiYXNlZCBvbiBmcmVjZW5jeS4gQWZ0ZXIgdmlzaXRpbmcgYSBkaXIgb25jZSwKIyBgY2QgPGZ1enp5LW5hbWU+YCBqdW1wcyB0aGVyZSBmcm9tIGFueXdoZXJlIChlLmcuIGBjZCBkZXYtZW52YCDihpIKIyBDOlxkZXZcZGV2LWVudmlyb25tZW50KS4gT3JpZ2luYWwgbGl0ZXJhbCBgY2QgLi9wYXRoYCBzdGlsbCB3b3JrcyBmaXJzdC4KaWYgKEdldC1Db21tYW5kIHpveGlkZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSkgewogICAgSW52b2tlLUV4cHJlc3Npb24gKCYgeyAoem94aWRlIGluaXQgcG93ZXJzaGVsbCAtLWNtZCBjZCB8IE91dC1TdHJpbmcpIH0pCn0KCiMgLS0tLSBBcmd1bWVudCBjb21wbGV0ZXIgZm9yIGBjZGA6IHN1cmZhY2VzIGV2ZXJ5IHN1YmRpciBvZiBDOlxkZXZcIGFzIGEKIyBjb21wbGV0aW9uIGNhbmRpZGF0ZSwgc28gYGNkIGRldi1lbnY8VGFiPmAgc2hvd3MgYGRldi1lbnZpcm9ubWVudGAgZXZlbgojIGZyb20gYSBicmFuZC1uZXcgc2hlbGwgdGhhdCBoYXNuJ3QgdmlzaXRlZCB0aGUgcGF0aCB5ZXQuIENvbXBsZW1lbnRzCiMgem94aWRlICh3aGljaCBvbmx5IGtub3dzIGRpcnMgYWZ0ZXIgdGhlIGZpcnN0IG1hbnVhbCB2aXNpdCkuClJlZ2lzdGVyLUFyZ3VtZW50Q29tcGxldGVyIC1Db21tYW5kTmFtZSBjZCwgU2V0LUxvY2F0aW9uLCBzbCAtUGFyYW1ldGVyTmFtZSBQYXRoIC1TY3JpcHRCbG9jayB7CiAgICBwYXJhbSgkY21kLCAkcGFyYW0sICR3b3JkLCAkYXN0LCAkYm91bmQpCiAgICAkdyA9ICR3b3JkLlRyaW0oIiciLCAnIicpCiAgICBpZiAoLW5vdCAoVGVzdC1QYXRoICdDOlxkZXYnKSkgeyByZXR1cm4gfQogICAgR2V0LUNoaWxkSXRlbSAnQzpcZGV2JyAtRGlyZWN0b3J5IC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlIHwKICAgICAgICBXaGVyZS1PYmplY3QgeyAtbm90ICR3IC1vciAkXy5OYW1lIC1saWtlICIqJHcqIiB9IHwKICAgICAgICBGb3JFYWNoLU9iamVjdCB7CiAgICAgICAgICAgICRwID0gJF8uRnVsbE5hbWUKICAgICAgICAgICAgW1N5c3RlbS5NYW5hZ2VtZW50LkF1dG9tYXRpb24uQ29tcGxldGlvblJlc3VsdF06Om5ldygiJyRwJyIsICRfLk5hbWUsICdQYXJhbWV0ZXJWYWx1ZScsICRwKQogICAgICAgIH0KfQoKIyAtLS0tIFRlcm1pbmFsLUljb25zOiBOZXJkIEZvbnQgaWNvbnMgaW4gR2V0LUNoaWxkSXRlbSAoYGxzYCkgb3V0cHV0IC0tLS0KaWYgKEdldC1Nb2R1bGUgLUxpc3RBdmFpbGFibGUgLU5hbWUgVGVybWluYWwtSWNvbnMpIHsKICAgIEltcG9ydC1Nb2R1bGUgVGVybWluYWwtSWNvbnMgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKfQoKIyAtLS0tIFBTRnpmOiBDdHJsK1IgZnV6enkgcmV2ZXJzZS1oaXN0b3J5LCBDdHJsK1QgZnV6enkgZmlsZS9kaXIgcGlja2VyIC0tLS0KIyBPbmx5IGxvYWRlZCB3aGVuIGZ6Zi5leGUgaXMgYXZhaWxhYmxlIG9uIFBBVEguCmlmICgoR2V0LU1vZHVsZSAtTGlzdEF2YWlsYWJsZSAtTmFtZSBQU0Z6ZikgLWFuZCAoR2V0LUNvbW1hbmQgZnpmIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlKSkgewogICAgSW1wb3J0LU1vZHVsZSBQU0Z6ZiAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZQogICAgU2V0LVBzRnpmT3B0aW9uIC1QU1JlYWRsaW5lQ2hvcmRQcm92aWRlciAnQ3RybCt0JyAtUFNSZWFkbGluZUNob3JkUmV2ZXJzZUhpc3RvcnkgJ0N0cmwrcicgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKfQoKIyAtLS0tIEZhc3RmZXRjaCBzcGxhc2ggKFdpbmRvd3MgbG9nbyArIHN5c3RlbSBpbmZvKSAtLS0tCiMgVXNlcyB0aGUgY29uZmlnIGF0IH4vLmNvbmZpZy9mYXN0ZmV0Y2gvY29uZmlnLmpzb25jIGRlcGxveWVkIGJ5IHRoaXMgYnVuZGxlLgojIFJ1bnMgb25seSBpbiBpbnRlcmFjdGl2ZSBzZXNzaW9ucyB0byBhdm9pZCBwb2xsdXRpbmcgc2NyaXB0ZWQvcGlwZWQgcHdzaCBjYWxscy4KaWYgKCgtbm90IFtTeXN0ZW0uQ29uc29sZV06OklzT3V0cHV0UmVkaXJlY3RlZCkgLWFuZCAoR2V0LUNvbW1hbmQgZmFzdGZldGNoIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlKSkgewogICAgIyBBZ2dyZWdhdGUgcGh5c2ljYWwtbWVtb3J5IGluZm8gdmlhIFdNSSAocG9ydGFibGUgYWNyb3NzIGFueSBXaW5kb3dzIFBDKSBhbmQKICAgICMgZXhwb3NlIGFzICRlbnY6RkZfUkFNIHNvIGZhc3RmZXRjaCdzIGBjb21tYW5kYCBtb2R1bGUgY2FuIGVjaG8gaXQgY2hlYXBseQogICAgIyBpbnN0ZWFkIG9mIHBheWluZyBDSU0gY29zdCBvbiBldmVyeSBmYXN0ZmV0Y2ggaW52b2NhdGlvbi4KICAgIHRyeSB7CiAgICAgICAgJG0gPSBHZXQtQ2ltSW5zdGFuY2UgV2luMzJfUGh5c2ljYWxNZW1vcnkgLUVycm9yQWN0aW9uIFN0b3AKICAgICAgICAkdHlwZU1hcCA9IEB7IDIwPSdERFInOyAyMT0nRERSMic7IDI0PSdERFIzJzsgMjY9J0REUjQnOyAzND0nRERSNScgfQogICAgICAgICR0eXBlcyA9ICRtLlNNQklPU01lbW9yeVR5cGUgfCBTb3J0LU9iamVjdCAtVW5pcXVlCiAgICAgICAgJHNwZWVkcyA9ICRtLlNwZWVkIHwgU29ydC1PYmplY3QgLVVuaXF1ZQogICAgICAgICRzaXplcyA9ICRtLkNhcGFjaXR5IHwgU29ydC1PYmplY3QgLVVuaXF1ZQogICAgICAgICR2ZW5kb3JzID0gKCRtLk1hbnVmYWN0dXJlciB8IEZvckVhY2gtT2JqZWN0IHsgJF8uVHJpbSgpIH0gfCBXaGVyZS1PYmplY3QgeyAkXyB9KSB8IFNvcnQtT2JqZWN0IC1VbmlxdWUKICAgICAgICBpZiAoJHR5cGVzLkNvdW50IC1lcSAxIC1hbmQgJHNwZWVkcy5Db3VudCAtZXEgMSAtYW5kICRzaXplcy5Db3VudCAtZXEgMSkgewogICAgICAgICAgICAkdCA9ICR0eXBlTWFwW1tpbnRdJHR5cGVzWzBdXTsgaWYgKC1ub3QgJHQpIHsgJHQgPSAnRFJBTScgfQogICAgICAgICAgICAkc2l6ZUVhY2ggPSBbTWF0aF06OlJvdW5kKCRzaXplc1swXSAvIDFHQiwgMikKICAgICAgICAgICAgJHZlbmRvciA9IGlmICgkdmVuZG9ycykgeyAiICgkKCR2ZW5kb3JzIC1qb2luICcvJykpIiB9IGVsc2UgeyAnJyB9CiAgICAgICAgICAgICRlbnY6RkZfUkFNID0gIiQoJG0uQ291bnQpICQoW2NoYXJdMHgwMEQ3KSAkc2l6ZUVhY2ggR2lCICR0LSQoJHNwZWVkc1swXSkkdmVuZG9yIgogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICR0b3RhbEdpQiA9IFtNYXRoXTo6Um91bmQoKCgkbSB8IE1lYXN1cmUtT2JqZWN0IENhcGFjaXR5IC1TdW0pLlN1bSkgLyAxR0IsIDIpCiAgICAgICAgICAgICR0ID0gJHR5cGVNYXBbW2ludF0kdHlwZXNbMF1dOyBpZiAoLW5vdCAkdCkgeyAkdCA9ICdEUkFNJyB9CiAgICAgICAgICAgICRlbnY6RkZfUkFNID0gIiQoJG0uQ291bnQpIHN0aWNrcywgJHRvdGFsR2lCIEdpQiAkdCAobWl4ZWQpIgogICAgICAgIH0KICAgIH0gY2F0Y2ggewogICAgICAgICRlbnY6RkZfUkFNID0gJycKICAgIH0KCiAgICAjIFByaW50IGEgcGVyLWNoYXJhY3RlciBncmFkaWVudCBVU0VSQEhPU1QgaGVhZGVyIGJlZm9yZSBmYXN0ZmV0Y2guCiAgICAjIFRoZSBncmFkaWVudCB3YWxrcyB0aGUgc2FtZSA1IENhdHBwdWNjaW4gc3RvcHMgYXMgdGhlIHJlc3Qgb2YgdGhlIHNwbGFzaAogICAgIyAoRmxhbWluZ28g4oaSIFBpbmsg4oaSIE1hdXZlIOKGkiBMYXZlbmRlciDihpIgU2FwcGhpcmUpIHNvIHRoZSB3aG9sZSBoZWFkZXIgaXMgYQogICAgIyBzaW5nbGUgY29udGludW91cyBwYWxldHRlIHJpYmJvbi4KICAgICR0aXRsZVRleHQgPSAiJGVudjpVU0VSTkFNRUAkZW52OkNPTVBVVEVSTkFNRSIKICAgICMgUmVzdHJpY3RlZCBncmFkaWVudCBmb3IgdGhlIHRpdGxlIOKAlCB1c2VzIG9ubHkgdGhlIGNvb2wtc2lkZSB0cmlvOgogICAgIyB0aGUgZXhhY3QgY29sb3JzIG9mIHRoZSBSQU0sIERyaXZlIGFuZCBEaXNwbGF5IHJvd3Mgb2YgdGhlIHNwbGFzaC4KICAgICRzdG9wcyA9IEAoCiAgICAgICAgQCgxOTIsIDE3OCwgMjUwKSwgICMgUkFNICAgICAobGVycCBNYXV2ZeKGkkxhdmVuZGVyKQogICAgICAgIEAoMTgwLCAxOTAsIDI1NCksICAjIERyaXZlICAgKExhdmVuZGVyKQogICAgICAgIEAoMTQ4LCAxOTQsIDI0NSkgICAjIERpc3BsYXkgKGxlcnAgTGF2ZW5kZXLihpJTYXBwaGlyZSkKICAgICkKICAgICRzZWdDb3VudCA9ICRzdG9wcy5Db3VudCAtIDEKICAgICRzYiA9IFtTeXN0ZW0uVGV4dC5TdHJpbmdCdWlsZGVyXTo6bmV3KCkKICAgIFt2b2lkXSRzYi5BcHBlbmQoImBuIikKICAgICRuID0gJHRpdGxlVGV4dC5MZW5ndGgKICAgIGZvciAoJGkgPSAwOyAkaSAtbHQgJG47ICRpKyspIHsKICAgICAgICAkdSA9IGlmICgkbiAtZ3QgMSkgeyAoJGkgLyAoJG4gLSAxKSkgKiAkc2VnQ291bnQgfSBlbHNlIHsgMCB9CiAgICAgICAgJHNlZyA9IFtNYXRoXTo6TWluKFtpbnRdW01hdGhdOjpGbG9vcigkdSksICRzZWdDb3VudCAtIDEpCiAgICAgICAgJHQgPSAkdSAtICRzZWcKICAgICAgICAkYSA9ICRzdG9wc1skc2VnXTsgJGIgPSAkc3RvcHNbJHNlZyArIDFdCiAgICAgICAgJHIgPSBbaW50XVtNYXRoXTo6Um91bmQoJGFbMF0gKyAoJGJbMF0gLSAkYVswXSkgKiAkdCkKICAgICAgICAkZyA9IFtpbnRdW01hdGhdOjpSb3VuZCgkYVsxXSArICgkYlsxXSAtICRhWzFdKSAqICR0KQogICAgICAgICRiYiA9IFtpbnRdW01hdGhdOjpSb3VuZCgkYVsyXSArICgkYlsyXSAtICRhWzJdKSAqICR0KQogICAgICAgIFt2b2lkXSRzYi5BcHBlbmQoIiQoW2NoYXJdMjcpWzE7Mzg7MjskcjskZzske2JifW0kKCR0aXRsZVRleHRbJGldKSIpCiAgICB9CiAgICBbdm9pZF0kc2IuQXBwZW5kKCIkKFtjaGFyXTI3KVswbSIpCiAgICBbQ29uc29sZV06Ok91dC5Xcml0ZUxpbmUoJHNiLlRvU3RyaW5nKCkpCgogICAgZmFzdGZldGNoCn0='

$ps5ProfileB64 = 'ZnVuY3Rpb24gcHJvbXB0IHsgIlBTICQoJGV4ZWN1dGlvbkNvbnRleHQuU2Vzc2lvblN0YXRlLlBhdGguQ3VycmVudExvY2F0aW9uKSQoJz4nICogKCRuZXN0ZWRQcm9tcHRMZXZlbCArIDEpKSAiIH0KCltDb25zb2xlXTo6SW5wdXRFbmNvZGluZyAgPSBbU3lzdGVtLlRleHQuVVRGOEVuY29kaW5nXTo6bmV3KCkKW0NvbnNvbGVdOjpPdXRwdXRFbmNvZGluZyA9IFtTeXN0ZW0uVGV4dC5VVEY4RW5jb2RpbmddOjpuZXcoKQpjaGNwIDY1MDAxID4gJG51bGwKCiRIb3N0LlVJLlJhd1VJLkJhY2tncm91bmRDb2xvciA9ICdCbGFjaycKJEhvc3QuVUkuUmF3VUkuRm9yZWdyb3VuZENvbG9yID0gJ0dyYXknCgpmdW5jdGlvbiBpc2FkbWluIHsKICAgIChbU2VjdXJpdHkuUHJpbmNpcGFsLldpbmRvd3NQcmluY2lwYWxdW1NlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzSWRlbnRpdHldOjpHZXRDdXJyZW50KCkpLklzSW5Sb2xlKFtTZWN1cml0eS5QcmluY2lwYWwuV2luZG93c0J1aWx0SW5Sb2xlXTo6QWRtaW5pc3RyYXRvcikKfQ=='

$wtSettingsB64 = 'ewogICAgIiRoZWxwIjogImh0dHBzOi8vYWthLm1zL3Rlcm1pbmFsLWRvY3VtZW50YXRpb24iLAogICAgIiRzY2hlbWEiOiAiaHR0cHM6Ly9ha2EubXMvdGVybWluYWwtcHJvZmlsZXMtc2NoZW1hIiwKICAgICJhY3Rpb25zIjogW10sCiAgICAiY29weUZvcm1hdHRpbmciOiAibm9uZSIsCiAgICAiY29weU9uU2VsZWN0IjogZmFsc2UsCiAgICAiZGVmYXVsdFByb2ZpbGUiOiAiezU3NGU3NzVlLTRmMmEtNWI5Ni1hYzFlLWEyOTYyYTQwMjMzNn0iLAogICAgImtleWJpbmRpbmdzIjoKICAgIFsKICAgICAgICB7ICJpZCI6ICJUZXJtaW5hbC5Db3B5VG9DbGlwYm9hcmQiLCAgICAgImtleXMiOiAiY3RybCtjIiB9LAogICAgICAgIHsgImlkIjogIlRlcm1pbmFsLlBhc3RlRnJvbUNsaXBib2FyZCIsICAia2V5cyI6ICJjdHJsK3YiIH0sCiAgICAgICAgeyAiaWQiOiAiVGVybWluYWwuRHVwbGljYXRlUGFuZUF1dG8iLCAgICJrZXlzIjogImFsdCtzaGlmdCtkIiB9CiAgICBdLAogICAgIm5ld1RhYk1lbnUiOgogICAgWwogICAgICAgIHsgInR5cGUiOiAicmVtYWluaW5nUHJvZmlsZXMiIH0KICAgIF0sCiAgICAicHJvZmlsZXMiOgogICAgewogICAgICAgICJkZWZhdWx0cyI6CiAgICAgICAgewogICAgICAgICAgICAiY29sb3JTY2hlbWUiOiAiQ2F0cHB1Y2NpbiBNb2NoYSIsCiAgICAgICAgICAgICJmb250IjoKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgImZhY2UiOiAiSmV0QnJhaW5zTW9ubyBOZXJkIEZvbnQiLAogICAgICAgICAgICAgICAgInNpemUiOiAxMQogICAgICAgICAgICB9LAogICAgICAgICAgICAib3BhY2l0eSI6IDg1LAogICAgICAgICAgICAidXNlQWNyeWxpYyI6IHRydWUKICAgICAgICB9LAogICAgICAgICJsaXN0IjoKICAgICAgICBbCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICJjb21tYW5kbGluZSI6ICIlU3lzdGVtUm9vdCVcXFN5c3RlbTMyXFxXaW5kb3dzUG93ZXJTaGVsbFxcdjEuMFxccG93ZXJzaGVsbC5leGUiLAogICAgICAgICAgICAgICAgImd1aWQiOiAiezYxYzU0YmJkLWMyYzYtNTI3MS05NmU3LTAwOWE4N2ZmNDRiZn0iLAogICAgICAgICAgICAgICAgImhpZGRlbiI6IHRydWUsCiAgICAgICAgICAgICAgICAibmFtZSI6ICJXaW5kb3dzIFBvd2VyU2hlbGwiCiAgICAgICAgICAgIH0sCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICJjb21tYW5kbGluZSI6ICIlU3lzdGVtUm9vdCVcXFN5c3RlbTMyXFxjbWQuZXhlIiwKICAgICAgICAgICAgICAgICJndWlkIjogInswY2FhMGRhZC0zNWJlLTVmNTYtYThmZi1hZmNlZWVhYTYxMDF9IiwKICAgICAgICAgICAgICAgICJoaWRkZW4iOiBmYWxzZSwKICAgICAgICAgICAgICAgICJuYW1lIjogIkNvbW1hbmQgUHJvbXB0IgogICAgICAgICAgICB9LAogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAiZ3VpZCI6ICJ7YjQ1M2FlNjItNGUzZC01ZTU4LWI5ODktMGE5OThlYzQ0MWI4fSIsCiAgICAgICAgICAgICAgICAiaGlkZGVuIjogZmFsc2UsCiAgICAgICAgICAgICAgICAibmFtZSI6ICJBenVyZSBDbG91ZCBTaGVsbCIsCiAgICAgICAgICAgICAgICAic291cmNlIjogIldpbmRvd3MuVGVybWluYWwuQXp1cmUiCiAgICAgICAgICAgIH0sCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICJjb21tYW5kbGluZSI6ICJwd3NoLmV4ZSAtTm9Mb2dvIC1Ob1Byb2ZpbGVMb2FkVGltZSIsCiAgICAgICAgICAgICAgICAiZ3VpZCI6ICJ7NTc0ZTc3NWUtNGYyYS01Yjk2LWFjMWUtYTI5NjJhNDAyMzM2fSIsCiAgICAgICAgICAgICAgICAiaGlkZGVuIjogZmFsc2UsCiAgICAgICAgICAgICAgICAibmFtZSI6ICJQb3dlclNoZWxsIiwKICAgICAgICAgICAgICAgICJzb3VyY2UiOiAiV2luZG93cy5UZXJtaW5hbC5Qb3dlcnNoZWxsQ29yZSIKICAgICAgICAgICAgfQogICAgICAgIF0KICAgIH0sCiAgICAic2NoZW1lcyI6CiAgICBbCiAgICAgICAgewogICAgICAgICAgICAibmFtZSI6ICJDYXRwcHVjY2luIE1vY2hhIiwKICAgICAgICAgICAgImN1cnNvckNvbG9yIjogIiNGNUUwREMiLAogICAgICAgICAgICAic2VsZWN0aW9uQmFja2dyb3VuZCI6ICIjNTg1QjcwIiwKICAgICAgICAgICAgImJhY2tncm91bmQiOiAiIzFFMUUyRSIsCiAgICAgICAgICAgICJmb3JlZ3JvdW5kIjogIiNDREQ2RjQiLAogICAgICAgICAgICAiYmxhY2siOiAiIzQ1NDc1QSIsCiAgICAgICAgICAgICJyZWQiOiAiI0YzOEJBOCIsCiAgICAgICAgICAgICJncmVlbiI6ICIjQTZFM0ExIiwKICAgICAgICAgICAgInllbGxvdyI6ICIjRjlFMkFGIiwKICAgICAgICAgICAgImJsdWUiOiAiIzg5QjRGQSIsCiAgICAgICAgICAgICJwdXJwbGUiOiAiI0Y1QzJFNyIsCiAgICAgICAgICAgICJjeWFuIjogIiM5NEUyRDUiLAogICAgICAgICAgICAid2hpdGUiOiAiI0JBQzJERSIsCiAgICAgICAgICAgICJicmlnaHRCbGFjayI6ICIjNTg1QjcwIiwKICAgICAgICAgICAgImJyaWdodFJlZCI6ICIjRjM4QkE4IiwKICAgICAgICAgICAgImJyaWdodEdyZWVuIjogIiNBNkUzQTEiLAogICAgICAgICAgICAiYnJpZ2h0WWVsbG93IjogIiNGOUUyQUYiLAogICAgICAgICAgICAiYnJpZ2h0Qmx1ZSI6ICIjODlCNEZBIiwKICAgICAgICAgICAgImJyaWdodFB1cnBsZSI6ICIjRjVDMkU3IiwKICAgICAgICAgICAgImJyaWdodEN5YW4iOiAiIzk0RTJENSIsCiAgICAgICAgICAgICJicmlnaHRXaGl0ZSI6ICIjQTZBREM4IgogICAgICAgIH0KICAgIF0sCiAgICAidGhlbWUiOiAiZGFyayIsCiAgICAidGhlbWVzIjogW10KfQ=='

$fastfetchConfigB64 = 'ew0KICAiJHNjaGVtYSI6ICJodHRwczovL2dpdGh1Yi5jb20vZmFzdGZldGNoLWNsaS9mYXN0ZmV0Y2gvcmF3L2Rldi9kb2MvanNvbl9zY2hlbWEuanNvbiIsDQoNCiAgImxvZ28iOiB7ICJ0eXBlIjogIm5vbmUiIH0sDQoNCiAgImRpc3BsYXkiOiB7DQogICAgInNlcGFyYXRvciI6ICIgICIsDQogICAgImtleSI6IHsgIndpZHRoIjogMTQgfSwNCiAgICAiY29sb3IiOiB7ICJzZXBhcmF0b3IiOiAiIzZDNzA4NiIgfQ0KICB9LA0KDQogICJtb2R1bGVzIjogWw0KICAgIHsgInR5cGUiOiAiY3VzdG9tIiwgICJmb3JtYXQiOiAiXHUwMDFiWzM4OzI7MTkyOzE3ODsyNTBt4pSAXHUwMDFiWzM4OzI7MTkxOzE3OTsyNTBt4pSAXHUwMDFiWzM4OzI7MTkxOzE3OTsyNTBt4pSAXHUwMDFiWzM4OzI7MTkwOzE4MDsyNTFt4pSAXHUwMDFiWzM4OzI7MTkwOzE4MDsyNTFt4pSAXHUwMDFiWzM4OzI7MTg5OzE4MTsyNTFt4pSAXHUwMDFiWzM4OzI7MTg5OzE4MTsyNTFt4pSAXHUwMDFiWzM4OzI7MTg4OzE4MjsyNTFt4pSAXHUwMDFiWzM4OzI7MTg4OzE4MjsyNTFt4pSAXHUwMDFiWzM4OzI7MTg3OzE4MzsyNTJt4pSAXHUwMDFiWzM4OzI7MTg3OzE4MzsyNTJt4pSAXHUwMDFiWzM4OzI7MTg2OzE4NDsyNTJt4pSAXHUwMDFiWzM4OzI7MTg2OzE4NDsyNTJt4pSAXHUwMDFiWzM4OzI7MTg1OzE4NTsyNTJt4pSAXHUwMDFiWzM4OzI7MTg1OzE4NTsyNTJt4pSAXHUwMDFiWzM4OzI7MTg0OzE4NjsyNTNt4pSAXHUwMDFiWzM4OzI7MTgzOzE4NzsyNTNt4pSAXHUwMDFiWzM4OzI7MTgzOzE4NzsyNTNt4pSAXHUwMDFiWzM4OzI7MTgyOzE4ODsyNTNt4pSAXHUwMDFiWzM4OzI7MTgyOzE4ODsyNTNt4pSAXHUwMDFiWzM4OzI7MTgxOzE4OTsyNTRt4pSAXHUwMDFiWzM4OzI7MTgxOzE4OTsyNTRt4pSAXHUwMDFiWzM4OzI7MTgwOzE5MDsyNTRt4pSAXHUwMDFiWzM4OzI7MTc5OzE5MDsyNTRt4pSAXHUwMDFiWzM4OzI7MTc4OzE5MDsyNTNt4pSAXHUwMDFiWzM4OzI7MTc2OzE5MDsyNTNt4pSAXHUwMDFiWzM4OzI7MTc1OzE5MTsyNTNt4pSAXHUwMDFiWzM4OzI7MTc0OzE5MTsyNTJt4pSAXHUwMDFiWzM4OzI7MTcyOzE5MTsyNTJt4pSAXHUwMDFiWzM4OzI7MTcxOzE5MTsyNTFt4pSAXHUwMDFiWzM4OzI7MTY5OzE5MTsyNTFt4pSAXHUwMDFiWzM4OzI7MTY4OzE5MjsyNTFt4pSAXHUwMDFiWzM4OzI7MTY2OzE5MjsyNTBt4pSAXHUwMDFiWzM4OzI7MTY1OzE5MjsyNTBt4pSAXHUwMDFiWzM4OzI7MTY0OzE5MjsyNDlt4pSAXHUwMDFiWzM4OzI7MTYyOzE5MjsyNDlt4pSAXHUwMDFiWzM4OzI7MTYxOzE5MjsyNDlt4pSAXHUwMDFiWzM4OzI7MTU5OzE5MzsyNDht4pSAXHUwMDFiWzM4OzI7MTU4OzE5MzsyNDht4pSAXHUwMDFiWzM4OzI7MTU3OzE5MzsyNDdt4pSAXHUwMDFiWzM4OzI7MTU1OzE5MzsyNDdt4pSAXHUwMDFiWzM4OzI7MTU0OzE5MzsyNDdt4pSAXHUwMDFiWzM4OzI7MTUyOzE5MzsyNDZt4pSAXHUwMDFiWzM4OzI7MTUxOzE5NDsyNDZt4pSAXHUwMDFiWzM4OzI7MTQ5OzE5NDsyNDVt4pSAXHUwMDFiWzM4OzI7MTQ4OzE5NDsyNDVt4pSAXHUwMDFiWzBtIiB9LA0KICAgIHsgInR5cGUiOiAic2hlbGwiLCAgICAgICAia2V5IjogIlx1MDAxYlszODsyOzE5MjsxNzg7MjUwbfOwnrcgIFNoZWxsXHUwMDFiWzBtIiwgICAiZm9ybWF0IjogIntwcmV0dHktbmFtZX0ge3ZlcnNpb259IiB9LA0KICAgIHsgInR5cGUiOiAib3MiLCAgICAgICAgICAia2V5IjogIlx1MDAxYlszODsyOzE4OTsxODE7MjUxbfOwlrMgIE9TXHUwMDFiWzBtIiB9LA0KICAgIHsgInR5cGUiOiAiYm9hcmQiLCAgICAgICAia2V5IjogIlx1MDAxYlszODsyOzE4NjsxODQ7MjUybfOwmpcgIEJvYXJkXHUwMDFiWzBtIiB9LA0KICAgIHsgInR5cGUiOiAiY3B1IiwgICAgICAgICAia2V5IjogIlx1MDAxYlszODsyOzE4MzsxODc7MjUzbfOwu58gIENQVVx1MDAxYlswbSIsICAgICAiZm9ybWF0IjogIntuYW1lfSIgfSwNCiAgICB7ICJ0eXBlIjogImdwdSIsICAgICAgICAgImtleSI6ICJcdTAwMWJbMzg7MjsxODA7MTkwOzI1NG3zsKKuICBHUFVcdTAwMWJbMG0iLCAgICAgImZvcm1hdCI6ICJ7bmFtZX0gKHt0eXBlfSkiLCAiZGV0ZWN0aW9uTWV0aG9kIjogInZ1bGthbiIgfSwNCiAgICB7ICJ0eXBlIjogImNvbW1hbmQiLCAgICAgImtleSI6ICJcdTAwMWJbMzg7MjsxNzI7MTkxOzI1Mm3zsJiYICBSQU1cdTAwMWJbMG0iLCAgICAgInNoZWxsIjogImNtZCIsICJ0ZXh0IjogImVjaG8gJUZGX1JBTSUiIH0sDQogICAgeyAidHlwZSI6ICJwaHlzaWNhbGRpc2siLCJrZXkiOiAiXHUwMDFiWzM4OzI7MTY0OzE5MjsyNTBt87CLiiAgRHJpdmVcdTAwMWJbMG0iLCAgICJmb3JtYXQiOiAie25hbWV9IOKAlCB7aW50ZXJjb25uZWN0fSB7c2l6ZX0iIH0sDQogICAgeyAidHlwZSI6ICJkaXNwbGF5IiwgICAgICJrZXkiOiAiXHUwMDFiWzM4OzI7MTU2OzE5MzsyNDdt87CNuSAgRGlzcGxheVx1MDAxYlswbSIsICJmb3JtYXQiOiAie3dpZHRofXh7aGVpZ2h0fSBAIHtyZWZyZXNoLXJhdGV9SHoiIH0sDQogICAgeyAidHlwZSI6ICJ1cHRpbWUiLCAgICAgICJrZXkiOiAiXHUwMDFiWzM4OzI7MTQ4OzE5NDsyNDVt87CllCAgVXB0aW1lXHUwMDFiWzBtIiB9LA0KICAgICJicmVhayIsDQogICAgImJyZWFrIg0KICBdDQp9DQo='

function FromB64($b64) {
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

$ps7Profile      = FromB64 $ps7ProfileB64
$ps5Profile      = FromB64 $ps5ProfileB64
$wtSettings      = FromB64 $wtSettingsB64
$fastfetchConfig = FromB64 $fastfetchConfigB64

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Backup-IfExists {
    # Silent: the .bak-<timestamp> file is created so a re-run never destroys
    # existing config, but we don't print a line for each one. They pile up
    # on disk only when there was something to back up, and are easy to find
    # with `Get-ChildItem -Recurse -Filter '*.bak-*'` if needed.
    param([string]$Path)
    if (Test-Path $Path) {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $Path "$Path.bak-$stamp" -Force
    }
}

# UTF-8 write. PS profile .ps1 files get a BOM so Windows PowerShell 5.1 parses
# accented chars correctly. JSON / JSONC get no BOM to keep parsers happy.
function Write-Utf8File {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Content,
        [bool]$WithBom = $true
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Backup-IfExists $Path
    $encoding = New-Object System.Text.UTF8Encoding($WithBom)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Install-WingetPackage {
    param([string]$Id, [string]$DisplayName)
    if ($SkipWinget) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Note "winget not found -- install $DisplayName manually from the Microsoft Store."
        return
    }
    $installed = winget list --id $Id --exact --source winget 2>$null | Select-String $Id
    if ($installed) {
        Write-Ok $DisplayName
        return
    }
    Write-Step "Installing $DisplayName..."
    winget install --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements
}

# ---------------------------------------------------------------------------
# Bootstrap: execution policy + unblock self
# ---------------------------------------------------------------------------

Write-Step 'Bootstrap'

if ((Get-ExecutionPolicy -Scope Process) -notin 'Bypass','Unrestricted') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# Prefer the *effective* policy: a machine/user GPO may already grant Bypass
# even when CurrentUser is Undefined, in which case Set-ExecutionPolicy emits
# a non-terminating warning that ErrorActionPreference=Stop would promote to
# a hard failure for no real reason. So: skip when effectively permissive,
# and ignore the override warning when we do set.
$effective = Get-ExecutionPolicy
if ($effective -in 'RemoteSigned','Unrestricted','Bypass') {
    Write-Ok "execution policy ($effective)"
} else {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        Write-Ok "execution policy → RemoteSigned"
    } catch {
        Write-Note "Could not set CurrentUser policy ($($_.Exception.Message.Split([Environment]::NewLine)[0])). Continuing anyway."
    }
}

if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    try { Unblock-File $PSCommandPath -ErrorAction Stop } catch {}
}

# ---------------------------------------------------------------------------
# 1) Prerequisites: PowerShell 7 + Windows Terminal + fzf + Nerd Font + Fastfetch
# ---------------------------------------------------------------------------

Write-Step 'Prerequisites'
Install-WingetPackage -Id 'Microsoft.PowerShell'          -DisplayName 'PowerShell 7'
Install-WingetPackage -Id 'Microsoft.WindowsTerminal'     -DisplayName 'Windows Terminal'
Install-WingetPackage -Id 'junegunn.fzf'                  -DisplayName 'fzf'
Install-WingetPackage -Id 'ajeetdsouza.zoxide'            -DisplayName 'zoxide'
Install-WingetPackage -Id 'DEVCOM.JetBrainsMonoNerdFont'  -DisplayName 'JetBrainsMono Nerd Font'
Install-WingetPackage -Id 'Fastfetch-cli.Fastfetch'       -DisplayName 'Fastfetch'

# ---------------------------------------------------------------------------
# 2) PowerShell 7 profile
# ---------------------------------------------------------------------------

Write-Step 'PowerShell 7 profile'
$ps7Path = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
Write-Utf8File -Path $ps7Path -Content $ps7Profile -WithBom $true
Unblock-File $ps7Path
Write-Ok (Short-Path $ps7Path)

# ---------------------------------------------------------------------------
# 3) Windows PowerShell 5 profile
# ---------------------------------------------------------------------------

Write-Step 'Windows PowerShell 5 profile'
$ps5Path = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
Write-Utf8File -Path $ps5Path -Content $ps5Profile -WithBom $true
Unblock-File $ps5Path
Write-Ok (Short-Path $ps5Path)

# ---------------------------------------------------------------------------
# 4) Windows Terminal settings.json
# ---------------------------------------------------------------------------

Write-Step 'Windows Terminal settings'
$wtDir    = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
$wtTarget = Join-Path $wtDir 'settings.json'
if (-not (Test-Path $wtDir)) {
    Write-Note "Windows Terminal LocalState not found -- launch WT once, then re-run with -SkipWinget."
} else {
    Write-Utf8File -Path $wtTarget -Content $wtSettings -WithBom $false
    Write-Ok (Short-Path $wtTarget)
}

# ---------------------------------------------------------------------------
# 5) Fastfetch config (~/.config/fastfetch/config.jsonc)
# ---------------------------------------------------------------------------

Write-Step 'Fastfetch config'
$ffDir        = Join-Path $env:USERPROFILE '.config\fastfetch'
$ffConfigPath = Join-Path $ffDir 'config.jsonc'

# Decide whether this is a laptop or a desktop, so the "Board" row in
# fastfetch can be relabelled "Laptop" (with the laptop icon) on portables.
#
# Two independent signals are combined because each one fails on some
# hardware:
#  1) Win32_SystemEnclosure.ChassisTypes  (SMBIOS)
#     Some OEMs ship laptops with this field set to "Desktop" (3) or
#     "Unknown" (2), so on its own it can miss real laptops.
#  2) Win32_Battery presence
#     Desktops never have an internal battery exposed via WMI, laptops
#     always do. Far more reliable in practice than ChassisTypes.
#
# Portable SMBIOS chassis types we accept: 8 Portable, 9 Laptop,
# 10 Notebook, 11 Hand Held, 14 Sub Notebook, 30 Tablet, 31 Convertible,
# 32 Detachable. (12 Docking Station, 18 Expansion, 21 Peripheral are NOT
# laptops and were dropped from the previous list.)
$laptopChassisTypes = @(8,9,10,11,14,30,31,32)
$isLaptop = $false
$reason   = ''
try {
    $chassis = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
    foreach ($c in $chassis) {
        if ($c -in $laptopChassisTypes) { $isLaptop = $true; $reason = "ChassisTypes=$c"; break }
    }
} catch {}
if (-not $isLaptop) {
    try {
        if (Get-CimInstance Win32_Battery -ErrorAction Stop) {
            $isLaptop = $true
            $reason   = 'battery present'
        }
    } catch {}
}

if ($isLaptop) {
    # The JSON file stores ESC as the 6-char escape ''; the icon glyph
    # is a 4-byte UTF-8 supplementary-plane char, built here via
    # ConvertFromUtf32 so this .ps1 source stays free of raw 4-byte chars.
    # U+F0697 = nf-md-developer_board (desktops)
    # U+F0322 = nf-md-laptop          (laptops)
    $boardIcon  = [char]::ConvertFromUtf32(0xF0697)
    $laptopIcon = [char]::ConvertFromUtf32(0xF0322)
    $boardKey   = $boardIcon  + '  Board'
    $laptopKey  = $laptopIcon + '  Laptop'

    $before = $fastfetchConfig
    $fastfetchConfig = $fastfetchConfig.Replace($boardKey, $laptopKey)
    if ($fastfetchConfig -eq $before) {
        Write-Note "Laptop detected ($reason) but the board key was not found in the embedded config -- icon NOT swapped."
    } else {
        Write-Ok "laptop ($reason) → icon + label ""Laptop"""
    }
} else {
    Write-Ok 'desktop → keeping "Board"'
}
Write-Utf8File -Path $ffConfigPath -Content $fastfetchConfig -WithBom $false
Write-Ok (Short-Path $ffConfigPath)

# ---------------------------------------------------------------------------
# 6) PowerShell 7 modules: CompletionPredictor + PSFzf + Terminal-Icons
# ---------------------------------------------------------------------------

Write-Step 'PowerShell 7 modules'

function Get-PwshExe {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Install-PS7Module {
    param([string]$Name)
    $pwsh = Get-PwshExe
    if (-not $pwsh) {
        Write-Note "pwsh.exe not on PATH yet; skipping $Name. Re-run this script after a shell restart."
        return
    }
    $check = & $pwsh -NoProfile -NoLogo -Command "if (Get-Module -ListAvailable -Name '$Name') { 'yes' } else { 'no' }"
    if ($check -eq 'yes') {
        Write-Ok $Name
        return
    }
    Write-Step "Installing PS7 module: $Name"
    & $pwsh -NoProfile -NoLogo -Command "if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }; Install-Module -Name '$Name' -Scope CurrentUser -Force -AcceptLicense"
    if ($LASTEXITCODE -eq 0) { Write-Ok $Name } else { Write-Note "$Name install failed (exit $LASTEXITCODE)" }
}

Install-PS7Module -Name CompletionPredictor
Install-PS7Module -Name PSFzf
Install-PS7Module -Name Terminal-Icons

# ---------------------------------------------------------------------------
# 7) Desktop shortcut: Ctrl+Alt+T opens Windows Terminal as Administrator
# ---------------------------------------------------------------------------

Write-Step 'Desktop shortcut (Ctrl+Alt+T = Terminal Admin)'
$wtExe = Get-Command wt.exe -ErrorAction SilentlyContinue
if (-not $wtExe) {
    Write-Note 'wt.exe not on PATH yet. Re-run after restarting the shell to create the shortcut.'
} else {
    $lnkPath  = [IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'Terminal Admin.lnk')
    $shell    = New-Object -ComObject WScript.Shell
    $lnk      = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = $wtExe.Source
    $lnk.HotKey     = 'Ctrl+Alt+T'
    $lnk.Save()

    # Flip the "Run as administrator" bit (byte 21, bit 0x20) in the .lnk
    $bytes = [IO.File]::ReadAllBytes($lnkPath)
    $bytes[21] = $bytes[21] -bor 0x20
    [IO.File]::WriteAllBytes($lnkPath, $bytes)

    Write-Ok (Short-Path $lnkPath)
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host '  Restart Windows Terminal for all changes to take effect.'
Write-Host ''
Write-Host '  Keybindings & docs' -ForegroundColor Blue
Write-Host '    https://github.com/ahmed-mili/dev-environment/blob/main/windows/README.md#keybindings'

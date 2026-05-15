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
    https://github.com/ahmed-mili/windows-pwsh-config

.EXAMPLE
    # One-liner (no clone required):
    iex (irm https://raw.githubusercontent.com/ahmed-mili/windows-pwsh-config/main/install.ps1).TrimStart([char]0xFEFF)

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

$ps7ProfileB64 = 'IyBGb3JjZSB0aGUgY29uc29sZSB0byBVVEYtOCBzbyBub24tQVNDSUkgb3V0cHV0IChGYXN0ZmV0Y2ggaWNvbnMsIE5lcmQgRm9udAojIGdseXBocywgYWNjZW50cyBpbiBkaXJlY3RvcnkgbmFtZXMpIHJlbmRlcnMgY29ycmVjdGx5IGluc3RlYWQgb2YgbW9qaWJha2UuCltDb25zb2xlXTo6SW5wdXRFbmNvZGluZyAgPSBbU3lzdGVtLlRleHQuVVRGOEVuY29kaW5nXTo6bmV3KCkKW0NvbnNvbGVdOjpPdXRwdXRFbmNvZGluZyA9IFtTeXN0ZW0uVGV4dC5VVEY4RW5jb2RpbmddOjpuZXcoKQokT3V0cHV0RW5jb2RpbmcgICAgICAgICAgID0gW1N5c3RlbS5UZXh0LlVURjhFbmNvZGluZ106Om5ldygpCgpmdW5jdGlvbiBpc2FkbWluIHsKICAgIChbU2VjdXJpdHkuUHJpbmNpcGFsLldpbmRvd3NQcmluY2lwYWxdW1NlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzSWRlbnRpdHldOjpHZXRDdXJyZW50KCkpLklzSW5Sb2xlKFtTZWN1cml0eS5QcmluY2lwYWwuV2luZG93c0J1aWx0SW5Sb2xlXTo6QWRtaW5pc3RyYXRvcikKfQoKIyAtLS0tIFBTUmVhZExpbmU6IG1vZGVybiBwcmVkaWN0aW9ucyArIHNtYXJ0IFRhYiArIENhdHBwdWNjaW4gTW9jaGEgY29sb3JzIC0tLS0KIyAtIElubGluZVZpZXcgYnkgZGVmYXVsdCAoZ3JleSBnaG9zdCB0ZXh0KS4gRjIgdG9nZ2xlcyB0byBMaXN0VmlldyAoZHJvcGRvd24pLgojIC0gVGFiIGFjY2VwdHMgdGhlIGlubGluZSBwcmVkaWN0aW9uIGlmIG9uZSBpcyB2aXNpYmxlLCBlbHNlIE1lbnVDb21wbGV0ZS4KIyAtIFJpZ2h0IEFycm93IC8gQ3RybCtSaWdodEFycm93IGFsc28gYWNjZXB0IChzdGFuZGFyZCBQU1JlYWRMaW5lIGJlaGF2aW9yKS4KIyAtIFN5bnRheC1oaWdobGlnaHQgY29sb3JzIGFsaWduZWQgd2l0aCB0aGUgQ2F0cHB1Y2NpbiBNb2NoYSBwYWxldHRlLgppZiAoR2V0LU1vZHVsZSAtTmFtZSBQU1JlYWRMaW5lIC1MaXN0QXZhaWxhYmxlKSB7CiAgICBTZXQtUFNSZWFkTGluZU9wdGlvbiAtUHJlZGljdGlvblNvdXJjZSBIaXN0b3J5QW5kUGx1Z2luIC1QcmVkaWN0aW9uVmlld1N0eWxlIElubGluZVZpZXcgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKICAgIFNldC1QU1JlYWRMaW5lT3B0aW9uIC1Db2xvcnMgQHsKICAgICAgICBDb21tYW5kICAgICAgICAgICAgPSAnIzg5QjRGQScgICMgQmx1ZQogICAgICAgIFBhcmFtZXRlciAgICAgICAgICA9ICcjRjVDMkU3JyAgIyBQaW5rCiAgICAgICAgVmFyaWFibGUgICAgICAgICAgID0gJyNGNUMyRTcnICAjIFBpbmsKICAgICAgICBTdHJpbmcgICAgICAgICAgICAgPSAnI0E2RTNBMScgICMgR3JlZW4KICAgICAgICBOdW1iZXIgICAgICAgICAgICAgPSAnI0ZBQjM4NycgICMgUGVhY2gKICAgICAgICBUeXBlICAgICAgICAgICAgICAgPSAnI0Y5RTJBRicgICMgWWVsbG93CiAgICAgICAgS2V5d29yZCAgICAgICAgICAgID0gJyNDQkE2RjcnICAjIE1hdXZlCiAgICAgICAgQ29tbWVudCAgICAgICAgICAgID0gJyM2QzcwODYnICAjIE92ZXJsYXkwCiAgICAgICAgT3BlcmF0b3IgICAgICAgICAgID0gJyM4OURDRUInICAjIFNreQogICAgICAgIE1lbWJlciAgICAgICAgICAgICA9ICcjOTRFMkQ1JyAgIyBUZWFsCiAgICAgICAgRXJyb3IgICAgICAgICAgICAgID0gJyNGMzhCQTgnICAjIFJlZAogICAgICAgIEVtcGhhc2lzICAgICAgICAgICA9ICcjRjM4QkE4JyAgIyBSZWQKICAgICAgICBJbmxpbmVQcmVkaWN0aW9uICAgPSAnIzZDNzA4NicgICMgT3ZlcmxheTAgKGRpbW1lZCBnaG9zdCB0ZXh0KQogICAgICAgIERlZmF1bHQgICAgICAgICAgICA9ICcjQ0RENkY0JyAgIyBUZXh0CiAgICAgICAgQ29udGludWF0aW9uUHJvbXB0ID0gJyNBNkFEQzgnICAjIFN1YnRleHQwCiAgICB9IC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlCiAgICBTZXQtUFNSZWFkTGluZUtleUhhbmRsZXIgLUtleSBGMiAtRnVuY3Rpb24gU3dpdGNoUHJlZGljdGlvblZpZXcKICAgIFNldC1QU1JlYWRMaW5lS2V5SGFuZGxlciAtS2V5IFRhYiAtU2NyaXB0QmxvY2sgewogICAgICAgICRsaW5lID0gJG51bGw7ICRjdXJzb3IgPSAkbnVsbAogICAgICAgIFtNaWNyb3NvZnQuUG93ZXJTaGVsbC5QU0NvbnNvbGVSZWFkTGluZV06OkdldEJ1ZmZlclN0YXRlKFtyZWZdJGxpbmUsIFtyZWZdJGN1cnNvcikKICAgICAgICBbTWljcm9zb2Z0LlBvd2VyU2hlbGwuUFNDb25zb2xlUmVhZExpbmVdOjpBY2NlcHRTdWdnZXN0aW9uKCkKICAgICAgICAkbmV3TGluZSA9ICRudWxsOyAkbmV3Q3Vyc29yID0gJG51bGwKICAgICAgICBbTWljcm9zb2Z0LlBvd2VyU2hlbGwuUFNDb25zb2xlUmVhZExpbmVdOjpHZXRCdWZmZXJTdGF0ZShbcmVmXSRuZXdMaW5lLCBbcmVmXSRuZXdDdXJzb3IpCiAgICAgICAgaWYgKCRsaW5lIC1lcSAkbmV3TGluZSkgewogICAgICAgICAgICBbTWljcm9zb2Z0LlBvd2VyU2hlbGwuUFNDb25zb2xlUmVhZExpbmVdOjpNZW51Q29tcGxldGUoKQogICAgICAgIH0KICAgIH0KfQoKIyAtLS0tIENvbXBsZXRpb25QcmVkaWN0b3I6IHNtYXJ0IHByZWRpY3Rpb25zIGJleW9uZCBzaGVsbCBoaXN0b3J5CiMgKGNtZGxldCBwYXJhbWV0ZXJzLCBnaXQgYnJhbmNoZXMsIGZpbGUgcGF0aHMsIGV0Yy4pIC0tLS0KaWYgKEdldC1Nb2R1bGUgLUxpc3RBdmFpbGFibGUgLU5hbWUgQ29tcGxldGlvblByZWRpY3RvcikgewogICAgSW1wb3J0LU1vZHVsZSBDb21wbGV0aW9uUHJlZGljdG9yIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlCn0KCiMgLS0tLSBUZXJtaW5hbC1JY29uczogTmVyZCBGb250IGljb25zIGluIEdldC1DaGlsZEl0ZW0gKGBsc2ApIG91dHB1dCAtLS0tCmlmIChHZXQtTW9kdWxlIC1MaXN0QXZhaWxhYmxlIC1OYW1lIFRlcm1pbmFsLUljb25zKSB7CiAgICBJbXBvcnQtTW9kdWxlIFRlcm1pbmFsLUljb25zIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlCn0KCiMgLS0tLSBQU0Z6ZjogQ3RybCtSIGZ1enp5IHJldmVyc2UtaGlzdG9yeSwgQ3RybCtUIGZ1enp5IGZpbGUvZGlyIHBpY2tlciAtLS0tCiMgT25seSBsb2FkZWQgd2hlbiBmemYuZXhlIGlzIGF2YWlsYWJsZSBvbiBQQVRILgppZiAoKEdldC1Nb2R1bGUgLUxpc3RBdmFpbGFibGUgLU5hbWUgUFNGemYpIC1hbmQgKEdldC1Db21tYW5kIGZ6ZiAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSkpIHsKICAgIEltcG9ydC1Nb2R1bGUgUFNGemYgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKICAgIFNldC1Qc0Z6Zk9wdGlvbiAtUFNSZWFkbGluZUNob3JkUHJvdmlkZXIgJ0N0cmwrdCcgLVBTUmVhZGxpbmVDaG9yZFJldmVyc2VIaXN0b3J5ICdDdHJsK3InIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlCn0KCiMgLS0tLSBGYXN0ZmV0Y2ggc3BsYXNoIChXaW5kb3dzIGxvZ28gKyBzeXN0ZW0gaW5mbykgLS0tLQojIFVzZXMgdGhlIGNvbmZpZyBhdCB+Ly5jb25maWcvZmFzdGZldGNoL2NvbmZpZy5qc29uYyBkZXBsb3llZCBieSB0aGlzIGJ1bmRsZS4KIyBSdW5zIG9ubHkgaW4gaW50ZXJhY3RpdmUgc2Vzc2lvbnMgdG8gYXZvaWQgcG9sbHV0aW5nIHNjcmlwdGVkL3BpcGVkIHB3c2ggY2FsbHMuCmlmICgoLW5vdCBbU3lzdGVtLkNvbnNvbGVdOjpJc091dHB1dFJlZGlyZWN0ZWQpIC1hbmQgKEdldC1Db21tYW5kIGZhc3RmZXRjaCAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSkpIHsKICAgICMgQWdncmVnYXRlIHBoeXNpY2FsLW1lbW9yeSBpbmZvIHZpYSBXTUkgKHBvcnRhYmxlIGFjcm9zcyBhbnkgV2luZG93cyBQQykgYW5kCiAgICAjIGV4cG9zZSBhcyAkZW52OkZGX1JBTSBzbyBmYXN0ZmV0Y2gncyBgY29tbWFuZGAgbW9kdWxlIGNhbiBlY2hvIGl0IGNoZWFwbHkKICAgICMgaW5zdGVhZCBvZiBwYXlpbmcgQ0lNIGNvc3Qgb24gZXZlcnkgZmFzdGZldGNoIGludm9jYXRpb24uCiAgICB0cnkgewogICAgICAgICRtID0gR2V0LUNpbUluc3RhbmNlIFdpbjMyX1BoeXNpY2FsTWVtb3J5IC1FcnJvckFjdGlvbiBTdG9wCiAgICAgICAgJHR5cGVNYXAgPSBAeyAyMD0nRERSJzsgMjE9J0REUjInOyAyND0nRERSMyc7IDI2PSdERFI0JzsgMzQ9J0REUjUnIH0KICAgICAgICAkdHlwZXMgPSAkbS5TTUJJT1NNZW1vcnlUeXBlIHwgU29ydC1PYmplY3QgLVVuaXF1ZQogICAgICAgICRzcGVlZHMgPSAkbS5TcGVlZCB8IFNvcnQtT2JqZWN0IC1VbmlxdWUKICAgICAgICAkc2l6ZXMgPSAkbS5DYXBhY2l0eSB8IFNvcnQtT2JqZWN0IC1VbmlxdWUKICAgICAgICAkdmVuZG9ycyA9ICgkbS5NYW51ZmFjdHVyZXIgfCBGb3JFYWNoLU9iamVjdCB7ICRfLlRyaW0oKSB9IHwgV2hlcmUtT2JqZWN0IHsgJF8gfSkgfCBTb3J0LU9iamVjdCAtVW5pcXVlCiAgICAgICAgaWYgKCR0eXBlcy5Db3VudCAtZXEgMSAtYW5kICRzcGVlZHMuQ291bnQgLWVxIDEgLWFuZCAkc2l6ZXMuQ291bnQgLWVxIDEpIHsKICAgICAgICAgICAgJHQgPSAkdHlwZU1hcFtbaW50XSR0eXBlc1swXV07IGlmICgtbm90ICR0KSB7ICR0ID0gJ0RSQU0nIH0KICAgICAgICAgICAgJHNpemVFYWNoID0gW01hdGhdOjpSb3VuZCgkc2l6ZXNbMF0gLyAxR0IsIDIpCiAgICAgICAgICAgICR2ZW5kb3IgPSBpZiAoJHZlbmRvcnMpIHsgIiAoJCgkdmVuZG9ycyAtam9pbiAnLycpKSIgfSBlbHNlIHsgJycgfQogICAgICAgICAgICAkZW52OkZGX1JBTSA9ICIkKCRtLkNvdW50KSAkKFtjaGFyXTB4MDBENykgJHNpemVFYWNoIEdpQiAkdC0kKCRzcGVlZHNbMF0pJHZlbmRvciIKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAkdG90YWxHaUIgPSBbTWF0aF06OlJvdW5kKCgoJG0gfCBNZWFzdXJlLU9iamVjdCBDYXBhY2l0eSAtU3VtKS5TdW0pIC8gMUdCLCAyKQogICAgICAgICAgICAkdCA9ICR0eXBlTWFwW1tpbnRdJHR5cGVzWzBdXTsgaWYgKC1ub3QgJHQpIHsgJHQgPSAnRFJBTScgfQogICAgICAgICAgICAkZW52OkZGX1JBTSA9ICIkKCRtLkNvdW50KSBzdGlja3MsICR0b3RhbEdpQiBHaUIgJHQgKG1peGVkKSIKICAgICAgICB9CiAgICB9IGNhdGNoIHsKICAgICAgICAkZW52OkZGX1JBTSA9ICcnCiAgICB9CgogICAgIyBQcmludCBhIHBlci1jaGFyYWN0ZXIgZ3JhZGllbnQgVVNFUkBIT1NUIGhlYWRlciBiZWZvcmUgZmFzdGZldGNoLgogICAgIyBUaGUgZ3JhZGllbnQgd2Fsa3MgdGhlIHNhbWUgNSBDYXRwcHVjY2luIHN0b3BzIGFzIHRoZSByZXN0IG9mIHRoZSBzcGxhc2gKICAgICMgKEZsYW1pbmdvIOKGkiBQaW5rIOKGkiBNYXV2ZSDihpIgTGF2ZW5kZXIg4oaSIFNhcHBoaXJlKSBzbyB0aGUgd2hvbGUgaGVhZGVyIGlzIGEKICAgICMgc2luZ2xlIGNvbnRpbnVvdXMgcGFsZXR0ZSByaWJib24uCiAgICAkdGl0bGVUZXh0ID0gIiRlbnY6VVNFUk5BTUVAJGVudjpDT01QVVRFUk5BTUUiCiAgICAjIFJlc3RyaWN0ZWQgZ3JhZGllbnQgZm9yIHRoZSB0aXRsZSDigJQgdXNlcyBvbmx5IHRoZSBjb29sLXNpZGUgdHJpbzoKICAgICMgdGhlIGV4YWN0IGNvbG9ycyBvZiB0aGUgUkFNLCBEcml2ZSBhbmQgRGlzcGxheSByb3dzIG9mIHRoZSBzcGxhc2guCiAgICAkc3RvcHMgPSBAKAogICAgICAgIEAoMTkyLCAxNzgsIDI1MCksICAjIFJBTSAgICAgKGxlcnAgTWF1dmXihpJMYXZlbmRlcikKICAgICAgICBAKDE4MCwgMTkwLCAyNTQpLCAgIyBEcml2ZSAgIChMYXZlbmRlcikKICAgICAgICBAKDE0OCwgMTk0LCAyNDUpICAgIyBEaXNwbGF5IChsZXJwIExhdmVuZGVy4oaSU2FwcGhpcmUpCiAgICApCiAgICAkc2VnQ291bnQgPSAkc3RvcHMuQ291bnQgLSAxCiAgICAkc2IgPSBbU3lzdGVtLlRleHQuU3RyaW5nQnVpbGRlcl06Om5ldygpCiAgICBbdm9pZF0kc2IuQXBwZW5kKCJgbiIpCiAgICAkbiA9ICR0aXRsZVRleHQuTGVuZ3RoCiAgICBmb3IgKCRpID0gMDsgJGkgLWx0ICRuOyAkaSsrKSB7CiAgICAgICAgJHUgPSBpZiAoJG4gLWd0IDEpIHsgKCRpIC8gKCRuIC0gMSkpICogJHNlZ0NvdW50IH0gZWxzZSB7IDAgfQogICAgICAgICRzZWcgPSBbTWF0aF06Ok1pbihbaW50XVtNYXRoXTo6Rmxvb3IoJHUpLCAkc2VnQ291bnQgLSAxKQogICAgICAgICR0ID0gJHUgLSAkc2VnCiAgICAgICAgJGEgPSAkc3RvcHNbJHNlZ107ICRiID0gJHN0b3BzWyRzZWcgKyAxXQogICAgICAgICRyID0gW2ludF1bTWF0aF06OlJvdW5kKCRhWzBdICsgKCRiWzBdIC0gJGFbMF0pICogJHQpCiAgICAgICAgJGcgPSBbaW50XVtNYXRoXTo6Um91bmQoJGFbMV0gKyAoJGJbMV0gLSAkYVsxXSkgKiAkdCkKICAgICAgICAkYmIgPSBbaW50XVtNYXRoXTo6Um91bmQoJGFbMl0gKyAoJGJbMl0gLSAkYVsyXSkgKiAkdCkKICAgICAgICBbdm9pZF0kc2IuQXBwZW5kKCIkKFtjaGFyXTI3KVsxOzM4OzI7JHI7JGc7JHtiYn1tJCgkdGl0bGVUZXh0WyRpXSkiKQogICAgfQogICAgW3ZvaWRdJHNiLkFwcGVuZCgiJChbY2hhcl0yNylbMG0iKQogICAgW0NvbnNvbGVdOjpPdXQuV3JpdGVMaW5lKCRzYi5Ub1N0cmluZygpKQoKICAgIGZhc3RmZXRjaAp9'

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
Write-Host '    https://github.com/ahmed-mili/windows-pwsh-config#keybindings'

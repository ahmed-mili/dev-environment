# Detect device context and write to ~/.claude/.device-context
# Works on: Windows PowerShell (native), SSH sessions from phone
#
# This script is called by the claude() wrapper in the PowerShell profile,
# or manually when needed. It produces a small JSON file that the assistant
# can read to know which machine/shell/context it is talking to.
#
# Example output (pwsh native, direct):
#   {"device":"desktop","context":"pwsh-native","shell":"pwsh","timestamp":"2026-06-09T07:00:00+02:00"}
#
# Example output (SSH from phone to Windows sshd):
#   {"device":"phone","context":"ssh-to-pwsh","shell":"pwsh","ssh_from":"100.x.x.x","timestamp":"..."}

$deviceContextFile = "$env:USERPROFILE\.claude\.device-context"

$device = "desktop"
$context = "pwsh-native"
$shell = "pwsh"
$extraFields = @{}

# -- SSH connection (likely from phone) ------------------------------------
if ($env:SSH_CLIENT) {
    $device = "phone"
    $context = "ssh-to-pwsh"
    $sshFrom = $env:SSH_CLIENT.Split(" ")[0]
    $extraFields["ssh_from"] = $sshFrom
}

# Build hashtable
$context = @{
    device    = $device
    context   = $context
    shell     = $shell
    timestamp = (Get-Date -Format "o")
} + $extraFields

# Write atomically (tmp+mv)
$dir = Split-Path -Parent $deviceContextFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$tmpFile = "$deviceContextFile.tmp"
$context | ConvertTo-Json -Compress | Set-Content $tmpFile
Move-Item $tmpFile $deviceContextFile -Force

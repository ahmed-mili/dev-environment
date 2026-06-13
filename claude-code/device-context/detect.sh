#!/usr/bin/env bash
# Detect device context and write to ~/.claude/.device-context
# Works on: native Linux, Termux (Android), SSH sessions
#
# This script is called by the claude() wrapper in each shell's profile/rc,
# or manually when needed. It produces a small JSON file that the assistant
# can read to know which machine/shell/context it is talking to.
#
# Example output (Linux desktop, direct):
#   {"device":"desktop","context":"linux","shell":"bash","timestamp":"2026-06-09T07:00:00+02:00"}
#
# Example output (Termux, direct):
#   {"device":"phone","context":"termux","shell":"bash","model":"Xiaomi 13T Pro","timestamp":"..."}
#
# Example output (SSH from phone to desktop):
#   {"device":"phone","context":"ssh-to-desktop","shell":"bash","ssh_from":"100.x.x.x","timestamp":"..."}

set -euo pipefail

DEVICE_CONTEXT_FILE="${HOME}/.claude/.device-context"

detect_device() {
  local device="desktop"
  local context="linux"
  local shell="bash"
  local extra_fields=()

  # -- Termux (Android) ----------------------------------------------------
  if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *"com.termux"* ]]; then
    device="phone"
    context="termux"
    local model
    model=$(getprop ro.product.model 2>/dev/null || echo "unknown")
    extra_fields+=("\"model\":\"$model\"")
  fi

  # -- SSH connection (likely from phone to desktop) ------------------------
  if [ -n "${SSH_CONNECTION:-}" ]; then
    device="phone"
    context="ssh-to-${context}"
    local ssh_from
    ssh_from="${SSH_CONNECTION%% *}"
    extra_fields+=("\"ssh_from\":\"$ssh_from\"")
  fi

  # -- mosh detection (no SSH_CONNECTION, but mosh-server running) ----------
  if [ -z "${SSH_CONNECTION:-}" ] && command -v pgrep >/dev/null 2>&1; then
    if pgrep -x mosh-server >/dev/null 2>&1; then
      device="phone"
      context="mosh-to-${context}"
    fi
  fi

  # Build JSON
  local json="{\"device\":\"$device\",\"context\":\"$context\",\"shell\":\"$shell\""
  for field in "${extra_fields[@]}"; do
    json="$json,$field"
  done
  json="$json,\"timestamp\":\"$(date -Iseconds)\"}"

  # Write atomically (tmp+mv)
  mkdir -p "$(dirname "$DEVICE_CONTEXT_FILE")"
  printf '%s\n' "$json" > "$DEVICE_CONTEXT_FILE.tmp"
  mv "$DEVICE_CONTEXT_FILE.tmp" "$DEVICE_CONTEXT_FILE"
}

detect_device

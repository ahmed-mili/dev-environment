#!/usr/bin/env bash
# Check that all plugins listed in ~/.claude/settings.json are actually installed.
# Install any missing ones with `claude plugin install`.
#
# Usage:
#   ./check-plugins.sh        # dry-run: list missing plugins
#   ./check-plugins.sh --fix  # install missing plugins
#
# This script is meant to be run after deploy/bootstrap or whenever
# the Skill Registry looks incomplete.

set -euo pipefail

SETTINGS="${HOME}/.claude/settings.json"
FIX=0
if [[ "${1:-}" == "--fix" ]]; then FIX=1; fi

if [[ ! -f "$SETTINGS" ]]; then
    echo "ERROR: $SETTINGS not found" >&2
    exit 1
fi

# Parse enabledPlugins keys (format: name@marketplace)
# Requires python3 (available on every modern Linux/WSL/Termux)
mapfile -t WANTED < <(python3 -c "
import json, sys
try:
    d = json.load(open('$SETTINGS'))
    plugins = d.get('enabledPlugins', {})
    for k, v in plugins.items():
        if v:
            print(k)
except Exception as e:
    sys.stderr.write(f'ERROR parsing settings: {e}\n')
    sys.exit(1)
")

if [[ ${#WANTED[@]} -eq 0 ]]; then
    echo "No plugins enabled in $SETTINGS"
    exit 0
fi

# Check which ones are actually installed
MISSING=()
for plugin in "${WANTED[@]}"; do
    name="${plugin%%@*}"
    # claude plugin list prints indented lines like: "  ❯ name@marketplace"
    if ! claude plugin list 2>/dev/null | grep -q "❯ ${name}@"; then
        MISSING+=("$plugin")
    fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo "All ${#WANTED[@]} plugins are installed."
    exit 0
fi

echo "MISSING plugins (${#MISSING[@]}/${#WANTED[@]}):"
for p in "${MISSING[@]}"; do echo "  - $p"; done

if [[ "$FIX" -eq 1 ]]; then
    echo ""
    echo "Installing missing plugins..."
    for p in "${MISSING[@]}"; do
        echo "  -> claude plugin install $p --scope user"
        claude plugin install "$p" --scope user || true
    done
    echo "Done. Restart Claude Code so new plugins are loaded."
else
    echo ""
    echo "Run with --fix to install them automatically."
    exit 1
fi

#!/data/data/com.termux/files/usr/bin/bash
# Auto-pull on Claude Code SessionStart, scoped to repos under
# /storage/emulated/0/dev (Android shared storage — see setup.sh).
# Fails loud on conflict (no auto-merge). Silent no-op otherwise.
#
# Mirrors C:\Users\<user>\.claude\hooks\auto-pull.ps1 from the Windows
# config bundle. Outputs a single-line JSON {"systemMessage": "..."}
# that Claude Code surfaces to the user.

set +e

repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$repo_root" ] && exit 0

# Scope: only repos under /storage/emulated/0/dev/ — keep this in sync
# with DEV_DIR in setup.sh. Hardcoded (not $HOME-relative) because the
# dev tree lives on Android shared storage, not in Termux home.
dev_dir="/storage/emulated/0/dev"
case "$repo_root" in
    "$dev_dir"/*) ;;
    *) exit 0 ;;
esac

# Bail if no remotes (orphan local repo)
if ! git -C "$repo_root" remote | grep -q .; then
    exit 0
fi

repo_name=$(basename "$repo_root")
output=$(git -C "$repo_root" pull --ff-only 2>&1)
exit_code=$?
msg=$(printf '%s' "$output" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Inline JSON-escape: backslashes, double quotes, newlines, tabs.
_json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk 'BEGIN{ORS=""} {if (NR>1) print "\\n"; print}'
}

if [ "$exit_code" -eq 0 ]; then
    case "$msg" in
        ""|*"Already up to date"*|*"Already up-to-date"*|*"Déjà à jour"*|*"Deja a jour"*)
            exit 0
            ;;
        *)
            esc=$(_json_escape "$msg")
            printf '{"systemMessage":"[auto-pull %s] %s"}\n' "$repo_name" "$esc"
            ;;
    esac
else
    esc=$(_json_escape "$msg")
    printf '{"systemMessage":"[auto-pull %s] ECHEC: %s\\n--> Une autre machine a pousse des commits incompatibles. Resous avant de continuer."}\n' "$repo_name" "$esc"
fi

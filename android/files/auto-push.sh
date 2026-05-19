#!/data/data/com.termux/files/usr/bin/bash
# Auto-commit + push on Claude Code SessionEnd, scoped to repos under
# /storage/emulated/0/dev (Android shared storage — see setup.sh).
# Commits any working-tree changes as "wip auto-sync (<host> <date>)" then pushes.
#
# Mirrors C:\Users\<user>\.claude\hooks\auto-push.ps1 from the Windows
# config bundle.

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

if ! git -C "$repo_root" remote | grep -q .; then
    exit 0
fi

# Commit any pending working-tree changes.
if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then
    git -C "$repo_root" add -A >/dev/null 2>&1
    host_id=$(getprop ro.product.device 2>/dev/null \
        || hostname 2>/dev/null \
        || echo termux)
    host_id=$(printf '%s' "$host_id" | tr '[:upper:]' '[:lower:]')
    date_str=$(date '+%Y-%m-%d %H:%M')
    git -C "$repo_root" commit -m "wip auto-sync ($host_id $date_str)" >/dev/null 2>&1
fi

push_output=$(git -C "$repo_root" push 2>&1)
push_exit=$?
repo_name=$(basename "$repo_root")

if [ "$push_exit" -ne 0 ]; then
    msg=$(printf '%s' "$push_output" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
    esc=$(printf '%s' "$msg" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk 'BEGIN{ORS=""} {if (NR>1) print "\\n"; print}')
    printf '{"systemMessage":"[auto-push %s] ECHEC: %s"}\n' "$repo_name" "$esc"
fi

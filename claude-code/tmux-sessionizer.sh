#!/usr/bin/env bash
#
# tmux-sessionizer.sh — session menu historique (Linux/Termux).
#
# *(Conservé pour compatibilité tierce ; le desktop actuel utilise
#  windows-sessionizer/sessionizer.ps1 en PowerShell natif.)*
#
# Invoked by the `pwsh` / `pwshm` functions in the Termux bashrc :
#   pwsh  -> ssh  -t desktop  "~/dev/dev-environment/claude-code/tmux-sessionizer.sh"
#   pwshm -> mosh   desktop -- bash -lc "~/dev/.../tmux-sessionizer.sh"
#
# Shows an fzf menu that merges, in a single list:
#   ● tmux sessions ALREADY active -> attach to it
#   ○ ~/dev projects with no session -> create the session IN the right folder
#   ◆ Obsidian vaults              -> native PowerShell in the vault (see below)
#   ＋ new (free name)              -> create an ad-hoc session
#
# On CREATION (projects / new), it just opens a shell (interactive bash) in the right
# folder — NO auto `claude`: the user launches it themselves to pick their options
# (--resume, --model, etc.). The claude() wrapper in ~/.bashrc then does the
# `env -u TMUX` that restores truecolor for Claude (it downgrades to 256 colors
# if it sees $TMUX; cf. ~/.tmux.conf + memory claude-truecolor-tmux).
#
# SPECIAL CASE — Obsidian vaults: they live on C: (NTFS), where native Windows I/O
# is ~7.5x faster than via /mnt/c from Linux (cf. memory
# feedback_claude-side-matches-filesystem) -> we open native PowerShell, not bash:
#   - desktop (F2)  : new Windows Terminal tab (`wt.exe -w 0 nt`, native pwsh)
#   - phone (ssh)   : this menu CANNOT open it (Linux→Windows hop broken by a
#                     mirrored-networking bug) -> it delegates to the `vault` command
#                     (ssh straight from the phone to the Windows sshd). See plan
#                     vault-native-pwsh-ssh.
# Detected via SSH_CONNECTION (is_remote). The user types `claude` (their PowerShell config).
#
# Debug hooks (no effect in normal use):
#   --list        : print the generated menu then exit
#   PC_PICK=<tsv> : bypass fzf with a forced choice (type<TAB>name<TAB>label)
#   PC_DRYRUN=1   : print the tmux command instead of running it
#
set -euo pipefail

DEV_DIR="${PC_DEV_DIR:-$HOME/dev}"
VAULTS_DIR="${PC_VAULTS_DIR:-/mnt/c/obsidian-vaults}"

# fzf: local binary (installed without sudo in ~/.fzf/bin), fall back to the PATH.
FZF="$HOME/.fzf/bin/fzf"
[[ -x "$FZF" ]] || FZF="$(command -v fzf 2>/dev/null || true)"

# --- collect -------------------------------------------------------------
# Zellij binary + helpers to list active sessions per world.
# Linux/Termux sessions: `zellij ls`. Windows (vault) sessions: read Zellij's Windows
# IPC/cache dirs via /mnt/c — the Linux binary can't talk to the Windows server
# (different OS), and there's no interop over ssh. The `%TEMP%\zellij` socket
# dir only lists sessions visible from the current Windows logon/window station;
# phone-opened native pwsh sessions can be missing there but still appear under
# `AppData/Local/Zellij/cache/.../session_info`. Glob contract_version_* for
# cross-version safety, and /mnt/c/Users/* so nothing personal is hard-coded.
ZJ="$(command -v zellij 2>/dev/null || echo "$HOME/.local/bin/zellij")"
zj_actives_linux() { "$ZJ" ls -ns 2>/dev/null | sort || true; }
zj_actives_win() {
  local base d
  {
    # Live IPC files, visible for normal Windows Zellij sessions.
    for base in /mnt/c/Users/*/AppData/Local/Temp/zellij; do
      for d in "$base"/contract_version_*; do
        [[ -d "$d" ]] && find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null
      done
    done

    # Session metadata, needed for vault sessions opened via Windows sshd.
    for base in /mnt/c/Users/*/AppData/Local/Zellij/cache; do
      for d in "$base"/contract_version_*/session_info; do
        [[ -d "$d" ]] && find "$d" -mindepth 1 -maxdepth 1 -type d \
          -exec test -f '{}/session-metadata.kdl' ';' -printf '%f\n' 2>/dev/null
      done
    done
  } | sort -u
}
actives=()   # filled per-view in the PC_VIEW case below

projects=()
mapfile -t projects < <(find "$DEV_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true)

# Obsidian vaults = subfolders of VAULTS_DIR that contain a .obsidian/
# (that's what tells a real vault apart from a plain folder).
vaults=()
mapfile -t vaults < <(find "$VAULTS_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -d '{}/.obsidian' ';' -printf '%f\n' 2>/dev/null | sort || true)

# VIEW (PC_VIEW) — same menu, different perimeter, set by the phone functions.
# We partition by WORLD (which side of the filesystem / where it runs best), not by type:
#   all (default, F2 desktop) : everything — sessions + projects + vaults
#   linux                       : Linux/ext4 world — tmux sessions + ~/dev projects, NO vaults
#   ps  (`pwsh`, ex-`obs`)    : Windows/C: world in native pwsh — Obsidian vaults (extensible
#                               to any C: folder better in PowerShell). None is a tmux session.
# We prune the arrays HERE, upstream of the position/section computation → everything
# else (fzf navigation, build_menu, dispatch) works with no other change.
case "${PC_VIEW:-all}" in
  linux) vaults=();   mapfile -t actives < <(zj_actives_linux) ;;   # Linux world: projects + their Zellij sessions
  ps)    projects=(); mapfile -t actives < <(zj_actives_win) ;;       # C: world: vaults + their (Windows) Zellij sessions
  *)     mapfile -t actives < <( { zj_actives_linux; zj_actives_win; } | sort -u ) ;;   # all (F2 desktop)
esac

# ANSI colors (interpreted by fzf --ansi)
G=$'\e[32m'; D=$'\e[90m'; R=$'\e[0m'; M=$'\e[38;5;141m'   # M = violet (vaults)

# Each project/vault stays in ITS place within its section; if it has an active
# session of the same name we mark it ● (active) instead of moving it to the top.
# Membership helpers.
in_list()   { local x="$1"; shift; local e; for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done; return 1; }
is_active() { in_list "$1" "${actives[@]}"; }

# Orphans = active sessions that are NEITHER a project NOR a vault (typically
# created via «＋ new»). With no section of their own -> a small zone at the top.
orphans=()
for _s in "${actives[@]}"; do
  in_list "$_s" "${projects[@]}" || in_list "$_s" "${vaults[@]}" || orphans+=("$_s")
done

# Counters for the POSITIONS of the fzf navigation binds (below).
n_orphan=${#orphans[@]}; n_proj=${#projects[@]}; n_vault=${#vaults[@]}

# --- menu (TSV: type <TAB> name <TAB> displayed label) -------------------
build_menu() {
  local s p v
  # type 'sep' = decorative title: the arrows skip it (binds), a click on it
  # reopens the menu (dispatch 'sep') -> not selectable.
  # 1) off-category sessions (neither ~/dev project nor vault) under a « ◆ Sessions » title.
  if (( n_orphan )); then
    printf 'sep\t\t%s──────  %s◆ Sessions%s  ──────%s\n' "$D" "$R" "$D" "$R"
    for s in "${orphans[@]}"; do
      printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$s" "$G" "$R" "$s" "$G" "$R"
    done
  fi
  # 2) ~/dev projects under « ◆ Projects » (light text on grey dashes); each in ITS
  #    place; active -> ● (active), otherwise ○ grey.
  if (( n_proj )); then
    printf 'sep\t\t%s──────  %s◆ Projects%s  ──────%s\n' "$D" "$R" "$D" "$R"
    for p in "${projects[@]}"; do
      if is_active "$p"; then
        printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$p" "$G" "$R" "$p" "$G" "$R"
      else
        printf 'project\t%s\t%s○%s %s\n' "$p" "$D" "$R" "$p"
      fi
    done
  fi
  # 3) Obsidian vaults under « ◆ Obsidian Vaults » (violet); same active rule.
  if (( n_vault )); then
    printf 'sep\t\t%s──────  %s◆ Obsidian Vaults%s  ──────%s\n' "$D" "$M" "$D" "$R"
    for v in "${vaults[@]}"; do
      if is_active "$v"; then
        printf 'active\t%s\t%s●%s %s  %s(active)%s\n' "$v" "$G" "$R" "$v" "$G" "$R"
      else
        printf 'vault\t%s\t%s○%s %s\n' "$v" "$M" "$R" "$v"
      fi
    done
  fi
  # No more « ＋ new » line: creation goes through the Ctrl-N shortcut
  # (--expect=ctrl-n + prompt) — cf. the « selection » block below.
}

[[ "${1:-}" == "--list" ]] && { build_menu; exit 0; }

# --- selection -----------------------------------------------------------
if [[ -n "${PC_PICK:-}" ]]; then
  key="${PC_KEY:-}"; choice="$PC_PICK"
else
  [[ -x "$FZF" ]] || { echo "fzf not found (~/.fzf/bin/fzf) — run: ~/.fzf/install --bin" >&2; exit 1; }
  # --with-nth=3: we only DISPLAY the label (field 3), which already holds the name
  # -> typing filters on what you see (WYSIWYG). No --nth: fzf rewrites the line
  # before applying --nth, so --nth=2,3 would look for vanished fields -> zero
  # match. The RETURNED value stays the original line (3 fields).
  # Navigation: skip the « ◆ … » titles (↑↓), toggle projects ⇄ vaults (Tab),
  # create a session (Ctrl-N, via --expect below).
  # 1-based positions (reverse layout, UNfiltered list):
  #   [« ◆ Sessions »] [orphans ..] [« ◆ Projects »] [projects ..] [« ◆ Vaults »] [vaults ..]
  # ssep/psep/vsep/osep = title lines; pfirst/vfirst/ofirst = first item of each section;
  # cursor0 = first SELECTABLE item (where the cursor starts — never on a title);
  # $seps = positions of ALL present titles (the ↑↓ step over them, via `case`).
  # The `[ -z {q} ]` guard disables skip/toggle as soon as a filter is typed: once
  # the list is filtered, these absolute positions no longer mean anything.
  # Help: a minimal « ^G help » header is ALWAYS visible; Ctrl-G toggles it
  # with the FULL list (hdr_full).
  nav=(); hdr_min='Ctrl+G  help'
  hdr_full='↑↓ navigate · ⏎ open · Ctrl+N new · Ctrl+R rename · Ctrl+X kill · Ctrl+G hide'
  ssep=0; psep=0; vsep=0; pfirst=0; vfirst=0; pos=0
  (( n_orphan )) && { ssep=$(( pos + 1 )); pos=$(( pos + 1 + n_orphan )); }
  (( n_proj ))   && { psep=$(( pos + 1 )); pfirst=$(( psep + 1 )); pos=$(( pos + 1 + n_proj )); }
  (( n_vault ))  && { vsep=$(( pos + 1 )); vfirst=$(( vsep + 1 )); pos=$(( pos + 1 + n_vault )); }
  if   (( n_orphan )); then cursor0=$(( ssep + 1 ))
  elif (( n_proj ));   then cursor0=$pfirst
  elif (( n_vault ));  then cursor0=$vfirst
  else                      cursor0=1; fi
  seps=""
  (( ssep )) && seps="$seps $ssep"
  (( psep )) && seps="$seps $psep"
  (( vsep )) && seps="$seps $vsep"
  if (( ssep || psep || vsep )); then
    nav+=(
      --bind "load:pos($cursor0)"
      --bind "down:transform:[ -z '{q}' ] || { echo down; exit 0; }; n=\$((FZF_POS+1)); case \" $seps \" in *\" \$n \"*) echo down+down;; *) echo down;; esac"
      --bind "up:transform:[ -z '{q}' ] || { echo up; exit 0; }; p=\$((FZF_POS-1)); case \" $seps \" in *\" \$p \"*) [ \$p -eq 1 ] && echo ignore || echo up+up;; *) echo up;; esac"
      # Mouse: OPEN on DOUBLE-click; the SINGLE click acts as a « hover » (true hover
      # is impossible in fzf — no « all-motion » 1003 tracking): it moves the ▌ cursor
      # onto the line WITHOUT opening, you confirm with the 2nd click.
      #
      # fzf places the cursor on the clicked line (t.vset) BEFORE running the
      # left-click / double-click action (terminal.go:7848 and :7836) → \$FZF_POS = clicked line.
      # So:
      #  - left-click on a TITLE « ◆ … » ($seps) → we BOUNCE one step down (echo down)
      #    to the section's 1st item (a title is always followed by ≥1 item): the
      #    cursor NEVER lands on a title via click, just like with the arrows. THIS is
      #    the bind that makes titles non-selectable. On an item → ignore (already
      #    positioned by t.vset).
      #  - double-click on an item → accept (opens); on a title → BOUNCE (down) too,
      #    never opens: so NO mouse action ever leaves the cursor on a title (the 2nd
      #    click re-vsets onto the title, the down re-ejects it).
      # Binding left-click does NOT break the double-click: distinct paths (7833 vs 7842).
      # Filter typed ({q} non-empty): titles filtered out of the list → no position test.
      --bind "left-click:transform:[ -n '{q}' ] && echo ignore || { case \" $seps \" in *\" \$FZF_POS \"*) echo down;; *) echo ignore;; esac; }"
      --bind "double-click:transform:[ -n '{q}' ] && echo accept || { case \" $seps \" in *\" \$FZF_POS \"*) echo down;; *) echo accept;; esac; }"
    )
    if (( n_proj && n_vault )); then
      nav+=( --bind "tab:transform:[ -n '{q}' ] && echo ignore || ( [ \$FZF_POS -lt $vfirst ] && echo 'pos($vfirst)' || echo 'pos($pfirst)' )" )
      # ↹ = U+21B9, the TWO-arrow « Tab key » symbol. Missing from JetBrainsMono
      # Nerd Font but rendered by the fallback font (Unicode Arrows block, like ⇄).
      hdr_full='↑↓ navigate · ↹ switch category · ⏎ open · Ctrl+N new · Ctrl+R rename · Ctrl+X kill · Ctrl+G hide'
    fi
  fi
  # Toggleable help WITHOUT ever losing the hint: a minimal « ^G help » header by
  # default, Ctrl-G toggles to/from the full list. fzf has no state variable, so we
  # store min/full in a file. ^G (not ^H = Backspace).
  HSTATE="${TMPDIR:-/tmp}/.pc-sessionizer-hdr.$(id -u)"; printf min > "$HSTATE"
  nav+=( --bind "ctrl-g:transform-header:if [ \"\$(cat '$HSTATE' 2>/dev/null)\" = full ]; then printf min > '$HSTATE'; printf '%s' \"$hdr_min\"; else printf full > '$HSTATE'; printf '%s' \"$hdr_full\"; fi" )
  # --color=pointer:8: by default fzf paints its pointer (the ▌ of the current
  # line) in pink-red (color 161), the only off-palette color
  # (green/violet/grey). We set it to neutral grey (8 = the $D of the ○)
  # so it reads as a pure cursor; the TYPE is already carried by the colored
  # bullet to its right (● green / ○ grey / ○ violet).
  # NB: a "chameleon" pointer (color depending on the targeted item) is IMPOSSIBLE in
  # fzf — --color=pointer is global, no change-color action exists, and
  # ANSI inside the pointer is rejected (uniseg width ≤ 2). Verified in the
  # 0.73.1 source (terminal.go:7952, options.go:3605). Do not retry.
  # --expect: these keys make fzf quit, putting the key on the 1st output line
  # (empty for Enter), the selection on the 2nd. ^N = create, ^X = kill,
  # ^R = rename. (^G toggles help WITHOUT quitting fzf -> not in --expect.)
  out="$(build_menu | "$FZF" \
      --ansi --delimiter=$'\t' --with-nth=3 \
      --layout=reverse --no-multi \
      --border=rounded \
      --padding=0,1 --info=hidden --ellipsis='…' \
      --color=pointer:117 \
      --prompt='🔍 Search ❯ ' \
      --header="$hdr_min" \
      --expect=ctrl-n,ctrl-x,ctrl-r \
      "${nav[@]}" \
    )" || exit 0
  key="$(sed -n '1p' <<<"$out")"
  choice="$(sed -n '2p' <<<"$out")"
fi

# Ctrl-N: we reuse the « new » creation flow (name prompt + create_session),
# without a « ＋ new » line in the menu.
if [[ "$key" == "ctrl-n" ]]; then
  type="new"; name=""
else
  [[ -z "$choice" ]] && exit 0
  type="$(cut -f1 <<<"$choice")"
  name="$(cut -f2 <<<"$choice")"
fi

# --- action --------------------------------------------------------------
# On creation we inject NO command: tmux opens the default shell (interactive
# bash), which sources ~/.bashrc → the claude() wrapper is available. The user
# types `claude` themselves when they want, with the options they want. The wrapper
# does the `env -u TMUX` that restores truecolor (cf. memory claude-truecolor-tmux).

# run : LAST command — `exec` (replaces the process); under PC_DRYRUN, prints it.
# step: SETUP command — runs without `exec`; under PC_DRYRUN, prints it.
run()  { if [[ -n "${PC_DRYRUN:-}" ]]; then printf 'DRYRUN: '; printf '%q ' "$@"; echo; else exec "$@"; fi; }
step() { if [[ -n "${PC_DRYRUN:-}" ]]; then printf 'DRYRUN: '; printf '%q ' "$@"; echo; else "$@"; fi; }

# read_or_cancel: reads input on /dev/tty (fzf rendered the terminal). If the
# FIRST key is Esc, CANCEL -> returns 1 (to abandon a Ctrl-N/R/X shortcut
# triggered by mistake). Otherwise the full input goes into $REPLY_OC.
# `-sn1` catches Esc BEFORE any echo; the 1st char is echoed back by hand,
# then we read the rest of the line normally.
read_or_cancel() {
  local first rest; REPLY_OC=""
  IFS= read -rsn1 first </dev/tty 2>/dev/null || return 1   # Ctrl-D / no tty
  [[ "$first" == $'\e' ]] && { echo >&2; return 1; }        # Esc -> cancel
  [[ -z "$first" ]] && { echo >&2; return 0; }              # Enter alone -> empty
  printf '%s' "$first" >&2
  IFS= read -r rest </dev/tty 2>/dev/null || rest=""
  REPLY_OC="$first$rest"
}

# Join an active session. A vault name is a Zellij session on the WINDOWS server,
# unreachable from Linux → delegate (open_vault). Otherwise it's a Linux session → attach.
attach_session() {  # $1 = session name
  if in_list "$1" "${vaults[@]}"; then open_vault "$1"
  else                                 run "$ZJ" attach "$1" options --on-force-close detach; fi
}

# Create (or join) a Zellij session named $1 in folder $2. `attach -c` is
# attach-or-create in one go; a NEW session inherits the current cwd, so we cd
# first. No command injected: Zellij opens the default shell, the user types
# `claude` themselves (cf. the claude() wrapper in ~/.bashrc).
create_session() {  # $1 = name   $2 = folder
  step cd "$2"
  # Phone reconnect invariant: opening a project must never delete a detached
  # session. `attach -c` is the only automatic action; explicit Ctrl-X is the
  # destructive path.
  run "$ZJ" attach -c "$1" options --on-force-close detach
}

# is_remote: am I launched from the phone (via `pwsh` = `ssh -t desktop …`)
# rather than from the physical desktop (F2 / ble.sh)? ssh exports SSH_CONNECTION;
# F2 doesn't. Used to pick how an Obsidian vault renders: native Windows Terminal
# tab (desktop, GUI visible) vs delegating to `vault` (phone, only reachable display).
is_remote() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; }

# open_wt_zellij: desktop (F2) — open a NEW Windows Terminal tab (PowerShell
# profile, `-p`, for the title/icon), `-d` set to the vault folder (Windows path
# via wslpath/cygpath fallback), running `zellij attach -c <vault> options --on-force-close detach`
# so the session lives natively on Windows (native I/O on C:, cf. memory
# feedback_claude-side-matches-filesystem) and a forced terminal close detaches.
_linux_to_win_path() {
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$1"
  elif command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    # Fallback: naive Linux path (e.g. /mnt/c/foo) -> C:\foo
    printf '%s' "$1" | sed 's|^/mnt/c/|C:/|; s|^/mnt/|\\|; s|/|\\|g'
  fi
}
open_wt_zellij() {  # $1 = vault name
  # Important for phone 5G reconnects: a detached Zellij session is still the
  # live Claude session. Do not run `delete-session` here; just attach-or-create.
  run wt.exe -w 0 nt -p "PowerShell" -d "$(_linux_to_win_path "$VAULTS_DIR/$1")" \
      pwsh -NoProfile -NoExit -Command "zellij attach -c $1 options --on-force-close detach"
}

# open_vault: route a vault choice by where the menu runs.
#   phone (ssh)  : the menu runs in Linux/Termux and Linux→Windows is broken (mirrored bug),
#                  so we DELEGATE — record the name, exit 42; `pwsh` phone-side
#                  catches 42, opens an SSH tunnel to the Windows Zellij web server,
#                  then runs the local Termux Zellij client against that tunnel.
#   desktop (F2) : new WT tab (open_wt_zellij). Cf. memories reference_ssh-linux-no-interop
#                  / reference_linux-mirrored-loopback-broken.
open_vault() {  # $1 = vault name
  if is_remote; then
    local req="${PC_VAULT_REQ:-$HOME/.cache/pc-vault-request}"
    mkdir -p "$(dirname "$req")" 2>/dev/null || true
    printf '%s\n' "$1" > "$req" 2>/dev/null || true
    [[ -n "${PC_DRYRUN:-}" ]] && { echo "DRYRUN: open vault '$1' client-side (wrote \$req, would exit 42)"; exit 0; }
    exit 42
  else
    open_wt_zellij "$1"
  fi
}

# Keyboard meta-actions (--expect) on an ACTIVE session: Ctrl-X kill, Ctrl-R
# rename. No effect on a non-started project/vault — we just reopen the menu
# to reflect the state. `read </dev/tty` because fzf rendered the terminal.
case "$key" in
  ctrl-x)
    if [[ "$type" == "active" ]]; then
      # kill ≠ delete: a PROJECT/vault session SURVIVES the kill (back to ○ inactive,
      # keeps its place in the menu) because its folder still anchors the ○ line; a
      # DISPOSABLE session (free name, no folder) DISAPPEARS from the menu — nothing to
      # anchor a ○. The prompt says which of the two cases applies, to avoid surprise.
      if in_list "$name" "${projects[@]}" || in_list "$name" "${vaults[@]}"; then
        printf "Kill '%s'? Stays listed as ○ inactive. [y/N] " "$name" >&2
      else
        printf "Kill '%s'? Disposable — disappears from the list. [y/N] " "$name" >&2
      fi
      # Esc (or any answer ≠ y) -> no kill; we just refresh the menu.
      if read_or_cancel && [[ "$REPLY_OC" == [yY]* ]]; then
        if in_list "$name" "${vaults[@]}"; then
          printf "(killing a Windows vault session from here isn't supported yet)\n" >&2
        else
          step "$ZJ" kill-session "$name"
        fi
      fi
    fi
    [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0   # no loop in test mode
    exec "$0"                                          # refresh the menu
    ;;
  ctrl-r)
    if [[ "$type" == "active" ]]; then
      printf "New name for '%s': " "$name" >&2
      # Esc (or empty name) -> no rename; we refresh the menu.
      if read_or_cancel && [[ -n "$REPLY_OC" ]]; then
        # Zellij CLI can't rename a DETACHED session (only from inside, via
        # `zellij action rename-session`) → no-op here in v1. Documented limit.
        printf "(rename via the menu isn't supported with Zellij yet — skipped)\n" >&2
      fi
    fi
    [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0
    exec "$0"
    ;;
esac

case "$type" in
  sep)
    [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0   # no loop in test mode
    exec "$0"                                          # separator: reopen the menu
    ;;
  active)
    attach_session "$name"
    ;;
  project)
    create_session "$name" "$DEV_DIR/$name"
    ;;
  vault)
    # Vault = on C: → native Windows Zellij (native I/O on C:). Routing in open_vault.
    open_vault "$name"
    ;;
  new)
    if [[ -z "$name" ]]; then
      printf 'Session name: ' >&2
      # Esc / empty input / Ctrl-D -> cancel creation and go back to the menu.
      if ! read_or_cancel || [[ -z "$REPLY_OC" ]]; then
        [[ -n "${PC_DRYRUN:-}${PC_PICK:-}" ]] && exit 0
        exec "$0"
      fi
      name="$REPLY_OC"
    fi
    [[ -d "$DEV_DIR/$name" ]] && start="$DEV_DIR/$name" || start="$HOME"
    create_session "$name" "$start"
    ;;
  *)
    echo "unknown choice: $type" >&2; exit 1
    ;;
esac

#!/usr/bin/env bash
#
# tmux-sessionizer.sh — tmux session menu for the phone (thin client).
#
# Invoked by the `wsl` / `wslm` / `pwsh` / `pwshm` functions in the Termux bashrc:
#   wsl  -> ssh  -t desktop  "~/dev/dev-environment/claude-code/tmux-sessionizer.sh"
#   wslm -> mosh   desktop -- bash -lc "~/dev/.../tmux-sessionizer.sh"
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
# is ~7.5x faster than via /mnt/c from WSL (cf. memory
# feedback_claude-side-matches-filesystem) -> we open native PowerShell, not bash:
#   - desktop (F2)  : new Windows Terminal tab (`wt.exe -w 0 nt`, native pwsh)
#   - phone (ssh)   : this menu CANNOT open it (WSL→Windows hop broken by a WSL
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
actives=()
mapfile -t actives < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort || true)

projects=()
mapfile -t projects < <(find "$DEV_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true)

# Obsidian vaults = subfolders of VAULTS_DIR that contain a .obsidian/
# (that's what tells a real vault apart from a plain folder).
vaults=()
mapfile -t vaults < <(find "$VAULTS_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -d '{}/.obsidian' ';' -printf '%f\n' 2>/dev/null | sort || true)

# VIEW (PC_VIEW) — same menu, different perimeter, set by the phone functions.
# We partition by WORLD (which side of the filesystem / where it runs best), not by type:
#   all (default, F2 desktop) : everything — sessions + projects + vaults
#   wsl (`wsl`, ex-`pc`)      : Linux/ext4 world — tmux sessions + ~/dev projects, NO vaults
#   ps  (`pwsh`, ex-`obs`)    : Windows/C: world in native pwsh — Obsidian vaults (extensible
#                               to any C: folder better in PowerShell). None is a tmux session.
# We prune the arrays HERE, upstream of the position/section computation → everything
# else (fzf navigation, build_menu, dispatch) works with no other change.
case "${PC_VIEW:-all}" in
  wsl) vaults=() ;;                  # wsl: no vaults
  ps)  actives=(); projects=() ;;   # ps : only the C: things (none is a tmux session)
esac

# ANSI colors (interpreted by fzf --ansi)
G=$'\e[32m'; D=$'\e[90m'; R=$'\e[0m'; M=$'\e[38;5;141m'   # M = violet (Obsidian vaults)

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
  # ssep/psep/vsep = title lines; pfirst/vfirst = first project/vault item;
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
      --bind "down:transform:[ -z {q} ] || { echo down; exit 0; }; n=\$((FZF_POS+1)); case \" $seps \" in *\" \$n \"*) echo down+down;; *) echo down;; esac"
      --bind "up:transform:[ -z {q} ] || { echo up; exit 0; }; p=\$((FZF_POS-1)); case \" $seps \" in *\" \$p \"*) [ \$p -eq 1 ] && echo ignore || echo up+up;; *) echo up;; esac"
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
      --bind "left-click:transform:[ -n {q} ] && echo ignore || { case \" $seps \" in *\" \$FZF_POS \"*) echo down;; *) echo ignore;; esac; }"
      --bind "double-click:transform:[ -n {q} ] && echo accept || { case \" $seps \" in *\" \$FZF_POS \"*) echo down;; *) echo accept;; esac; }"
    )
    if (( n_proj && n_vault )); then
      nav+=( --bind "tab:transform:[ -n {q} ] && echo ignore || ( [ \$FZF_POS -lt $vfirst ] && echo 'pos($vfirst)' || echo 'pos($pfirst)' )" )
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
      --color=pointer:8 \
      --prompt='pc ❯ ' \
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

# Join an ALREADY active session. Inside tmux, `attach` is forbidden (nesting) →
# `switch-client`; outside tmux → `attach`.
attach_session() {  # $1 = session name
  if [[ -n "${TMUX:-}" ]]; then run tmux switch-client  -t "$1"
  else                          run tmux attach-session -t "$1"; fi
}

# Create (or join if already there) a session in $2. Outside tmux: `new-session -A`
# (attach-or-create) in one go. Inside tmux: we can't attach → create detached
# (idempotent: `|| true` if the session already exists) then `switch-client`.
# $3 = optional command run in the session (string passed to sh -c by tmux);
# absent -> tmux opens the default shell (interactive bash).
create_session() {  # $1 = name   $2 = folder   $3 = command (optional)
  if [[ -n "${TMUX:-}" ]]; then
    step tmux new-session -d -s "$1" -c "$2" ${3:+"$3"} || true
    run  tmux switch-client -t "$1"
  else
    run tmux new-session -A -s "$1" -c "$2" ${3:+"$3"}
  fi
}

# is_remote: am I launched from the phone (via `wsl`/`pwsh` = `ssh -t desktop …`)
# rather than from the physical desktop (F2 / ble.sh)? ssh exports SSH_CONNECTION;
# F2 doesn't. Used to pick how an Obsidian vault renders: native Windows Terminal
# tab (desktop, GUI visible) vs delegating to `vault` (phone, only reachable display).
is_remote() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; }

# open_wt_pwsh: open a vault in a NEW Windows Terminal TAB (current window,
# `-w 0 nt`), via the profile named « PowerShell » (`-p`) and NOT the raw exe.
# `-p` applies the whole profile (title « PowerShell » + icon + colors + font);
# passing `pwsh.exe` as the command gave a « pwsh.exe » tab with a generic icon.
# `-d` forces the starting folder to the vault (Windows path via wslpath),
# overriding the profile's startingDirectory. Native Windows process = native I/O
# on C: (cf. memory feedback_claude-side-matches-filesystem); the user types `claude`.
open_wt_pwsh() {  # $1 = WSL folder of the vault
  run wt.exe -w 0 nt -p "PowerShell" -d "$(wslpath -w "$1")"
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
        step tmux kill-session -t "$name"
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
        step tmux rename-session -t "$name" "$REPLY_OC"
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
    # Obsidian vault = on C: (NTFS) → native Windows PowerShell (native I/O, cf. memory
    # feedback_claude-side-matches-filesystem).
    #   desktop (F2)  : native Windows Terminal tab (GUI visible locally)
    #   phone (ssh)   : the sessionizer runs in WSL, and the WSL→Windows hop is BROKEN by
    #     a WSL mirrored bug (127.0.0.1 routed to loopback0, handshake times out) → this menu
    #     CANNOT open a vault in native pwsh itself. But the PHONE can reach Windows
    #     (direct ssh, cmd `vault`). So we DELEGATE: we record the chosen vault name and
    #     exit with code 42; wsl()/pwsh() (phone-side) catch that 42 and run
    #     `vault <name>` automatically → the user picks in the menu and the vault opens, with
    #     nothing to type. Cf. docs/superpowers/plans/2026-06-01-vault-native-pwsh-ssh.md +
    #     memories reference_ssh-wsl-no-interop / reference_wsl-mirrored-loopback-broken.
    if is_remote; then
      req="${PC_VAULT_REQ:-$HOME/.cache/pc-vault-request}"
      mkdir -p "$(dirname "$req")" 2>/dev/null || true
      printf '%s\n' "$name" > "$req" 2>/dev/null || true
      [[ -n "${PC_DRYRUN:-}" ]] && { echo "DRYRUN: open vault '$name' client-side (wrote \$req, would exit 42)"; exit 0; }
      exit 42
    else
      open_wt_pwsh "$VAULTS_DIR/$name"
    fi
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

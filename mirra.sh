#!/bin/bash

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_SUCCESS=$'\e[32m'; C_WARN=$'\e[33m'; C_DANGER=$'\e[31m'
  C_ACCENT=$'\e[38;5;172m'; C_DIM=$'\e[2m'; BOLD=$'\e[1m'; NC=$'\e[0m'
else
  C_SUCCESS=''; C_WARN=''; C_DANGER=''; C_ACCENT=''; C_DIM=''; BOLD=''; NC=''
fi

MIRRA_VERSION="0.4.0"

case "$1" in
  --version|-v)
    echo "mirra v${MIRRA_VERSION}"
    exit 0
    ;;
  --help|-h)
    cat <<EOF
mirra v${MIRRA_VERSION}
An rsync wrapper for macOS disk and folder mirroring

Usage:
  mirra                              Launch interactive mode
  mirra --version                    Print version and exit
  mirra --help                       Print this help and exit
  mirra --dry-run <src> <dst>        Preview changes without modifying files
  mirra --verify  <src> <dst>        Check destination matches source
  mirra <src> <dst>                  Choose a mode interactively for the given paths

Modes (selected interactively or via flag):
  Dry run    Preview changes without modifying any files
  Sync       Mirror source to destination (destructive at destination;
             always asks for confirmation)
  Verify     Check destination matches source byte-for-byte

Author:   Ahmed Omer
Support:  ahmed@ahmedo.dev
Source:   github.com/ahmedomer/mirra

This software is provided "as is" without warranty of any kind,
express or implied. The author assumes no responsibility for data
loss, hardware damage, or any other harm arising from its use.
By using mirra, you accept all such risks.
EOF
    exit 0
    ;;
esac


# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Utilities ────────────────────────────────────────────────────────────────
format_time() {
  local s=$1
  if (( s < 60 )); then FTIME="${s}s"
  elif (( s < 3600 )); then FTIME="$(( s / 60 ))m $(( s % 60 ))s"
  else FTIME="$(( s / 3600 ))h $(( (s % 3600) / 60 ))m $(( s % 60 ))s"
  fi
}

# Tagged messages. The first argument is a printf format; pass paths and other
# user data as arguments, never inside the format.
_err()  { local fmt=$1; shift; printf "%s[Error]%s ${fmt}\n"   "$C_DANGER" "$NC" "$@"; }
_warn() { local fmt=$1; shift; printf "%s[Warning]%s ${fmt}\n" "$C_WARN"   "$NC" "$@"; }

# Asks "<question> [y/N]:" and exits with "Aborted." on anything but y/Y.
_confirm_or_abort() {
  local answer
  printf '%s [y/N]: ' "$1"
  read -r answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    printf 'Aborted.\n'
    exit 0
  fi
}

# Prints a risk warning before anything is written.
# Dry-run and verify write nothing, so they only warn. Sync stops and asks;
# anything but an explicit "y" aborts. A risk is never accepted automatically.
_risk() {
  _warn '%s' "$1"
  [ "$MODE" != sync ] && return 0
  _confirm_or_abort 'Continue anyway?'
  echo
}

# Looks up the volume that holds $1.
# Sets globals (no subshell-echo, same pattern as format_time):
#   MNT_POINT    — mount point, from `df -P` (handles spaces in the path)
#   MNT_FSTYPE   — filesystem type from `mount` (e.g. apfs, exfat); empty if unknown
#   MNT_NOOWNERS — true when the volume has "Ignore ownership" enabled
_mount_info() {
  local line opts
  MNT_POINT=""; MNT_FSTYPE=""; MNT_NOOWNERS=false
  while IFS= read -r line; do
    # The mount point is everything after the capacity column ("37%   /path").
    [[ "$line" =~ [0-9]+%[[:space:]]+(/.*)$ ]] && MNT_POINT="${BASH_REMATCH[1]}"
  done < <(df -P "$1" 2>/dev/null)
  [ -z "$MNT_POINT" ] && return 0
  while IFS= read -r line; do
    # Last match wins: a later mount on the same point shadows earlier ones.
    if [[ "$line" == *" on $MNT_POINT ("* ]]; then
      opts="${line##*" on $MNT_POINT ("}"
      opts="${opts%)}"
      MNT_FSTYPE="${opts%%,*}"
      MNT_NOOWNERS=false
      [[ ", $opts," == *", noowners,"* ]] && MNT_NOOWNERS=true
    fi
  done < <(mount)
}

# Prompts for an existing directory until one is given; sets global INPUT.
# Trims surrounding whitespace and one pair of matching quotes (drag-and-drop).
#   _prompt_dir <Role> <prompt label>
_prompt_dir() {
  local role=$1 prompt
  printf -v prompt '\001%s\002%s\001%s\002 ' "$BOLD" "$2" "$NC"
  while true; do
    read -e -p "$prompt" INPUT
    INPUT="${INPUT#"${INPUT%%[![:space:]]*}"}"
    INPUT="${INPUT%"${INPUT##*[![:space:]]}"}"
    [[ "$INPUT" == \'*\' || "$INPUT" == \"*\" ]] && INPUT="${INPUT:1:${#INPUT}-2}"
    [[ "$INPUT" == "~" || "$INPUT" == "~/"* ]] && INPUT="$HOME${INPUT:1}"
    if [[ -z "$INPUT" ]]; then
      _err '%s cannot be empty.' "$role"
    elif [[ ! -d "$INPUT" ]]; then
      _err '%s not found: %s' "$role" "$INPUT"
    else
      return 0
    fi
  done
}

# ─── UI ───────────────────────────────────────────────────────────────────────
spin() {
  local pid=$1 label=$2
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0 elapsed last_elapsed=-1
  [ -t 1 ] || { wait "$pid"; return; }  # no animation when output is a file or pipe
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( SECONDS - START_SECONDS ))
    if (( elapsed != last_elapsed )); then
      format_time "$elapsed"
      last_elapsed=$elapsed
    fi
    printf '\r\033[K%s%s%s %s  %s%s%s' \
      "$C_ACCENT" "${frames[$i]}" "$NC" "$label" "$C_DIM" "$FTIME" "$NC"
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
  printf '\r\033[K'
}

# ─── Execution engine ─────────────────────────────────────────────────────────
# Backgrounds rsync, shows spinner, waits for completion.
# Sets globals: RSYNC_EXIT, ELAPSED, PARTIAL, TMPFILE, ERRFILE, START_TIME,
#               START_SECONDS.
# Callers must rm -f "$TMPFILE" "$ERRFILE" when done.
_run_rsync() {
  local spin_label="$1"
  local RSYNC_PID CAFFEINATE_PID errline fda_hint=false
  TMPFILE=$(mktemp) || { _err 'Failed to create temp file.'; exit 1; }
  ERRFILE=$(mktemp) || { _err 'Failed to create temp file.'; rm -f "$TMPFILE"; exit 1; }
  sudo "$RSYNC_BIN" "${RSYNC_OPTS[@]}" "$SOURCE" "$DESTINATION" > "$TMPFILE" 2>"$ERRFILE" &
  RSYNC_PID=$!
  caffeinate -im -w "$RSYNC_PID" </dev/null >/dev/null 2>&1 &
  CAFFEINATE_PID=$!
  # On interrupt, still write the log: a stopped sync has already changed the destination.
  # rsync ignores Ctrl+C (background job) and runs as root, so stop it via sudo;
  # only wait if that worked, so a failed kill never freezes mirra.
  trap 'kill "$CAFFEINATE_PID" 2>/dev/null; sudo kill "$RSYNC_PID" 2>/dev/null && wait "$RSYNC_PID"
        format_time $(( SECONDS - START_SECONDS )); ELAPSED="$FTIME (interrupted)"
        _write_log; rm -f "$TMPFILE" "$ERRFILE"
        printf "\r\033[K"; _err "Interrupted. Log: %s" "$LOG_FILE"; exit 1' INT TERM HUP
  START_SECONDS=$SECONDS
  START_TIME=$(date '+%a %d %b %Y %H:%M:%S')
  printf 'Started: %s\n' "$START_TIME"
  spin "$RSYNC_PID" "$spin_label"
  wait "$RSYNC_PID"
  RSYNC_EXIT=$?
  kill "$CAFFEINATE_PID" 2>/dev/null
  wait "$CAFFEINATE_PID" 2>/dev/null
  trap - INT TERM HUP
  format_time $(( SECONDS - START_SECONDS ))
  ELAPSED=$FTIME
  PARTIAL=false
  [ "$RSYNC_EXIT" -eq 23 ] || [ "$RSYNC_EXIT" -eq 24 ] && PARTIAL=true
  while IFS= read -r errline; do
    _warn '%s' "$errline"
    [[ "$errline" == *"Operation not permitted"* ]] && fda_hint=true
  done < "$ERRFILE"
  if [ "$fda_hint" = true ]; then
    printf '%s[Hint]%s macOS blocked access to some files. Grant Full Disk Access to your terminal app in System Settings \xe2\x80\xba Privacy & Security, then run again.\n' \
      "$C_DIM" "$NC"
  fi
}

# ─── Output processor ─────────────────────────────────────────────────────────
# Parses rsync --out-format="%i %n" output from $1. Appends +/~/- entries to
# $LOG_FILE (plain text, no ANSI — for TextEdit compatibility).
# Sets globals: PARSE_TRANSFER, PARSE_ATTR, PARSE_DELETE.
# Invariants: *deleting matched before code extraction; directory lines skipped;
# filename at position 12 (11-char itemize string + 1 space).
# `c` (local change) and `h` (hard link) at position 0 cover both new items and
# attribute-only updates on existing items. Position 2 == "+" means new item
# (all itemize fields are "+" for new items) → reported as + (transfer).
# Position 2 != "+" means attribute-only update on existing item → reported as ~.
# `.` at position 0 means no data transfer, only attributes differ → ~.
# The log is opened once on fd 3 (not once per line); if it cannot be opened,
# entries go to /dev/null so the counts are still correct.
_process_output() {
  local tmpfile="$1"
  PARSE_TRANSFER=0; PARSE_ATTR=0; PARSE_DELETE=0
  local line filetype file
  { exec 3>>"$LOG_FILE"; } 2>/dev/null || exec 3>/dev/null
  while IFS= read -r line; do
    if [[ "$line" == '*deleting'[[:space:]]* ]]; then
      file="${line#\*deleting}"
      printf -- '- %s\n' "${file#"${file%%[![:space:]]*}"}" >&3
      (( PARSE_DELETE++ )); continue
    fi
    filetype="${line:1:1}"; file="${line:12}"
    [[ -z "$file" || "$filetype" == "d" ]] && continue
    case "${line:0:1}${line:2:1}" in
      ">"?|[ch]+) printf -- '+ %s\n' "$file" >&3; (( PARSE_TRANSFER++ )) ;;
      [ch.]?)     printf -- '~ %s\n' "$file" >&3; (( PARSE_ATTR++ )) ;;
    esac
  done < "$tmpfile"
  exec 3>&-
}

# ─── Mode orchestration ───────────────────────────────────────────────────────
# Writes the run log: header → _process_output → rsync warnings → summary
# footer. Written before the exit-code check so failed runs still leave a log.
_write_log() {
  {
    printf 'mirra %s\n' "$MODE"
    printf 'Started:     %s\n' "$START_TIME"
    printf 'Source:      %s\n' "${SOURCE%/}"
    printf 'Destination: %s\n' "$DESTINATION"
    printf -- '---\n'
  } > "$LOG_FILE" || _warn 'Could not write log to %s' "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null
  _process_output "$TMPFILE"
  [ -s "$ERRFILE" ] && { printf -- '---\nWarnings:\n' >> "$LOG_FILE"; cat "$ERRFILE" >> "$LOG_FILE" 2>/dev/null; }
  { printf -- '---\n'
    printf 'Summary:  + %d %s   ~ %d metadata   - %d %s\n' \
      "$PARSE_TRANSFER" "$WORD_TRANSFER" "$PARSE_ATTR" "$PARSE_DELETE" "$WORD_DELETE"
    printf 'Elapsed:  %s\n' "$ELAPSED"
  } >> "$LOG_FILE"
}

# Runs the selected mode end to end and prints the terminal summary.
run_mode() {
  local label spin_label total
  case "$MODE" in
    dry-run) label="Dry run"; spin_label="Dry run...";   WORD_TRANSFER=transfer;    WORD_DELETE=delete ;;
    verify)  label="Verify";  spin_label="Verifying..."; WORD_TRANSFER=transfer;    WORD_DELETE=delete ;;
    sync)    label="Sync";    spin_label="Syncing...";   WORD_TRANSFER=transferred; WORD_DELETE=deleted ;;
  esac

  _run_rsync "$spin_label"
  _write_log
  rm -f "$TMPFILE" "$ERRFILE"

  # Fail fast on hard errors; exit 23/24 (partial) still reports results.
  if [ "$RSYNC_EXIT" -ne 0 ] && [ "$PARTIAL" = false ]; then
    if [ "$MODE" = sync ]; then
      printf '%s\xe2\x9c\x97%s Sync failed in %s (rsync exit code %d). Check log at %s\n' \
        "$C_DANGER" "$NC" "$ELAPSED" "$RSYNC_EXIT" "$LOG_FILE"
    else
      _err '%s failed (rsync exit code %d). Check log at %s' "$label" "$RSYNC_EXIT" "$LOG_FILE"
    fi
    exit 1
  fi

  total=$(( PARSE_TRANSFER + PARSE_ATTR + PARSE_DELETE ))
  echo
  if [ "$MODE" = verify ] && (( total == 0 )) && [ "$PARTIAL" = false ]; then
    printf '  Destination matches source byte-for-byte.\n'
  else
    printf '  %s+%s %d %s   %s~%s %d metadata   %s-%s %d %s\n' \
      "$C_SUCCESS" "$NC" "$PARSE_TRANSFER" "$WORD_TRANSFER" \
      "$C_WARN" "$NC" "$PARSE_ATTR" \
      "$C_DANGER" "$NC" "$PARSE_DELETE" "$WORD_DELETE"
  fi

  # Verify with differences: no success line; point at the log instead.
  if [ "$MODE" = verify ] && (( total > 0 )); then
    _warn 'Differences found in %s \xe2\x80\x94 run Sync to resolve.' "$ELAPSED"
    [ "$PARTIAL" = true ] && _warn_partial
    printf '%sLog: %s%s\n' "$C_DIM" "$LOG_FILE" "$NC"
    open "$LOG_FILE" 2>/dev/null
    return 0
  fi

  if [ "$MODE" != verify ] || [ "$PARTIAL" = true ]; then
    printf '%sLog: %s%s\n' "$C_DIM" "$LOG_FILE" "$NC"
    (( total > 0 )) && open "$LOG_FILE" 2>/dev/null
  fi
  if [ "$PARTIAL" = true ]; then
    _warn_partial
  else
    echo
    printf '%s\xe2\x9c\x93%s %s completed in %s.\n' "$C_SUCCESS" "$NC" "$label" "$ELAPSED"
  fi
}

# "Partial dry run / verify / sync — ..." after rsync exit 23 or 24.
_warn_partial() {
  _warn 'Partial %s \xe2\x80\x94 some files were skipped (rsync exit %d). See Warnings in log.' "${MODE/-/ }" "$RSYNC_EXIT"
}

# ─── Branding ─────────────────────────────────────────────────────────────────
printf '%s%smirra%s v%s\n' "$C_ACCENT" "$BOLD" "$NC" "$MIRRA_VERSION"
printf '%sBy using mirra, you accept all responsibility for any data loss or\n' "$C_DIM"
printf 'damage. This software is provided without warranty of any kind.%s\n' "$NC"
echo

# ─── Parse flags ──────────────────────────────────────────────────────────────
# MODE is dry-run, verify, or sync. Sync has no flag: it is chosen only from
# the menu and always ends at the Proceed? confirmation.
MODE=""
case "$1" in
  --dry-run) MODE=dry-run; shift ;;
  --verify)  MODE=verify;  shift ;;
esac
if [[ "$1" == -* ]]; then
  _err 'Unknown flag: %s' "$1" >&2
  _err "Run 'mirra --help' for usage." >&2
  exit 1
fi

# ─── Source and destination ───────────────────────────────────────────────────
if [ $# -ge 2 ]; then
  if [[ -z "$1" || -z "$2" ]]; then
    _err 'Source and destination cannot be empty.'
    exit 1
  fi
  SOURCE="$1"
  DESTINATION="$2"
elif [ $# -eq 1 ]; then
  _err 'Usage: %s [--dry-run|--verify] [<source> <destination>]' "$0"
  exit 1
else
  if [[ ! -t 0 ]]; then
    _err 'Interactive mode requires a terminal. Usage: %s [--dry-run|--verify] <source> <destination>' "$0"
    exit 1
  fi
  _prompt_dir Source 'Source path:     '
  SOURCE=$INPUT
  echo
  _prompt_dir Destination 'Destination path:'
  DESTINATION=$INPUT
  echo
fi

# ─── Mode selection ───────────────────────────────────────────────────────────
# Skipped when a mode flag (--dry-run, --verify) is given.
if [ -z "$MODE" ]; then
  while true; do
    printf '%sMode:%s\n' "$BOLD" "$NC"
    printf '  %s[1]%s Dry run  (default)\n' "$C_ACCENT" "$NC"
    printf '  %s[2]%s Sync\n' "$C_ACCENT" "$NC"
    printf '  %s[3]%s Verify\n' "$C_ACCENT" "$NC"
    printf 'Select: '
    read -r _mode_choice
    case "$_mode_choice" in
      1|'') MODE=dry-run; break ;;
      2) MODE=sync; break ;;
      3) MODE=verify; break ;;
      *) _err 'Invalid selection. Enter 1, 2, or 3.'; echo ;;
    esac
  done
  echo
fi

# Source always gets a trailing slash ("sync contents into"); destination never.
SOURCE="${SOURCE%/}/"
DESTINATION="${DESTINATION%/}"

# Validate source and destination
if [[ ! -d "$SOURCE" ]]; then
  _err 'Source not found: %s' "$SOURCE"
  exit 1
fi
if [[ ! -d "$DESTINATION" ]]; then
  _err 'Destination not found: %s' "$DESTINATION"
  exit 1
fi
if [[ "${SOURCE%/}" -ef "$DESTINATION" ]]; then
  _err 'Source and destination are the same path.'
  exit 1
fi
# Nested paths: sync would delete the source while reading it (source inside
# destination) or copy the mirror into itself (destination inside source).
_src_real=$(cd -P "$SOURCE" && pwd -P); _dst_real=$(cd -P "$DESTINATION" && pwd -P)
if [[ "${_dst_real%/}/" == "${_src_real%/}/"* || "${_src_real%/}/" == "${_dst_real%/}/"* ]]; then
  _err 'Source and destination overlap (one is inside the other): %s, %s' "$_src_real" "$_dst_real"
  exit 1
fi

# Exclusions file (relative to this script)
EXCLUSIONS_FILE="$SCRIPT_DIR/exclusions.txt"
if [ ! -f "$EXCLUSIONS_FILE" ]; then
  printf '%s[Info]%s No exclusions file found at %s. Continuing without exclusions.\n' \
    "$C_DIM" "$NC" "$EXCLUSIONS_FILE"
  echo
  EXCLUSIONS_FILE=""
fi

# ─── Preflight checks ─────────────────────────────────────────────────────────
# Catch the ways a mirror goes wrong silently, before anything is written.
# Non-APFS is a hard error; everything else goes through _risk.
# Volume info is looked up once per side and reused by every check.
_mount_info "${SOURCE%/}"
SRC_MNT=$MNT_POINT; SRC_FSTYPE=$MNT_FSTYPE; SRC_NOOWNERS=$MNT_NOOWNERS
_mount_info "$DESTINATION"
DST_MNT=$MNT_POINT; DST_FSTYPE=$MNT_FSTYPE; DST_NOOWNERS=$MNT_NOOWNERS

# 1. APFS only — other filesystems cannot hold the full set of macOS metadata.
_require_apfs() {  # <Role> <mount point> <fstype>
  [ "$3" = "apfs" ] && return 0
  _err '%s volume %s is %s; mirra supports APFS volumes only.' \
    "$1" "${2:-(unknown)}" "${3:-an unknown filesystem}"
  exit 1
}
_require_apfs Source "$SRC_MNT" "$SRC_FSTYPE"
_require_apfs Destination "$DST_MNT" "$DST_FSTYPE"

# 2. Drive not mounted — a /Volumes/<name> path whose volume is the same one
#    /Volumes itself lives on is a leftover folder, not a connected drive.
#    Paths are resolved first so "/Volumes/Macintosh HD/..." (a symlink to /)
#    is not mistaken for an unmounted drive.
_check_mounted() {  # <Role> <path> <mount point>
  local resolved
  resolved=$(cd -P "$2" 2>/dev/null && pwd -P)
  [[ "$resolved" == /Volumes/* ]] || return 0
  if [ -z "$VOLUMES_MNT" ]; then
    _mount_info /Volumes
    VOLUMES_MNT=$MNT_POINT
  fi
  [ -n "$3" ] && [ "$3" = "$VOLUMES_MNT" ] && _risk "$1 $2 is not on a mounted volume — is the drive connected?"
}
VOLUMES_MNT=""
_check_mounted Source "${SOURCE%/}" "$SRC_MNT"
_check_mounted Destination "$DESTINATION" "$DST_MNT"

# 3. Empty source — sync would delete everything in the destination.
#    Top-level names listed in exclusions.txt (.DS_Store, .fseventsd, ...) are
#    ignored, so an empty volume root counts as empty. Unreadable sources are
#    skipped so permission errors are never mistaken for "empty".
_EMPTY_IGNORE=()
if [ -n "$EXCLUSIONS_FILE" ]; then
  while IFS= read -r _pattern || [ -n "$_pattern" ]; do
    _pattern="${_pattern%%#*}"
    _pattern="${_pattern#"${_pattern%%[![:space:]]*}"}"
    _pattern="${_pattern%"${_pattern##*[![:space:]]}"}"
    _pattern="${_pattern#/}"; _pattern="${_pattern%/}"
    [[ -z "$_pattern" || "$_pattern" == */* ]] && continue
    _EMPTY_IGNORE+=(! -name "$_pattern")
  done < "$EXCLUSIONS_FILE"
fi
_has_entries() {  # <dir> [find filters...] — stops at the first match
  local dir=$1; shift
  [ -n "$(find -H "$dir" -mindepth 1 -maxdepth 1 "$@" -print -quit 2>/dev/null)" ]
}
if [ -r "$SOURCE" ] && [ -x "$SOURCE" ] \
   && ! _has_entries "$SOURCE" "${_EMPTY_IGNORE[@]}" \
   && _has_entries "$DESTINATION"; then
  _risk "Source is empty — sync would delete everything in the destination."
fi

# 4. Ignored ownership — macOS enables this by default on external drives;
#    owners and permissions are then silently dropped, even with sudo.
[ "$SRC_NOOWNERS" = true ] && _risk "Ownership is ignored on $SRC_MNT (Source); owners and permissions will not be preserved. Fix: sudo diskutil enableOwnership \"$SRC_MNT\""
[ "$DST_NOOWNERS" = true ] && _risk "Ownership is ignored on $DST_MNT (Destination); owners and permissions will not be preserved. Fix: sudo diskutil enableOwnership \"$DST_MNT\""

# ─── rsync binary ─────────────────────────────────────────────────────────────
# Homebrew rsync is required; Apple's bundled /usr/bin/rsync is missing flags
# mirra depends on (-N, -H, -A, -X). The path resolved here is the one sudo
# runs, so sudo's restricted PATH cannot silently swap in a different rsync.
if ! RSYNC_BIN=$(command -v rsync); then
  _err 'rsync is not installed. Install Homebrew rsync: brew install rsync'
  exit 1
fi
if [[ "$RSYNC_BIN" == "/usr/bin/rsync" ]]; then
  _err "Apple's bundled rsync (/usr/bin/rsync) is missing flags mirra requires."
  _err 'Install Homebrew rsync (brew install rsync) and make sure Homebrew comes before /usr/bin in your PATH.'
  exit 1
fi

# Log file — written to the user-private $TMPDIR with a mode+timestamp suffix.
# This avoids write-permission failures when the script is installed in a
# read-only location, prevents log corruption from concurrent runs (each
# invocation gets a unique path), and restricts access to the current user.
_tmpdir="${TMPDIR:-/tmp}"
LOG_FILE="${_tmpdir%/}/mirra-${MODE}-$(date '+%Y%m%d-%H%M%S').log"

# ─── Build command ────────────────────────────────────────────────────────────
RSYNC_OPTS=(-aAXHN --delete --numeric-ids)
[ -n "$EXCLUSIONS_FILE" ] && RSYNC_OPTS+=(--exclude-from="$EXCLUSIONS_FILE")
case "$MODE" in
  verify)  RSYNC_OPTS+=(--checksum --dry-run) ;;
  dry-run) RSYNC_OPTS+=(--dry-run) ;;
esac
RSYNC_OPTS+=(--out-format="%i %n")  # every mode — the output parser depends on it

# ─── Preview ──────────────────────────────────────────────────────────────────
printf '  %s%s%s  \xe2\x86\x92  %s%s%s\n' \
  "$BOLD" "${SOURCE%/}" "$NC" "$BOLD" "$DESTINATION" "$NC"
case "$MODE" in
  verify)  printf '  Neither source nor destination will be modified.\n' ;;
  dry-run) printf '  Preview only \xe2\x80\x94 no files will be modified.\n' ;;
  sync)    printf '  Source will not be modified. Destination will be made an exact replica.\n' ;;
esac
printf '  sudo may prompt for your password to preserve file permissions and ACLs.\n'
echo
printf '  %ssudo%s %s%s%s \\\n' "$BOLD" "$NC" "$BOLD" "$RSYNC_BIN" "$NC"
for _opt in "${RSYNC_OPTS[@]}"; do
  [[ "$_opt" == *" "* ]] && printf '      "%s" \\\n' "$_opt" || printf '      %s \\\n' "$_opt"
done
printf '      "%s" \\\n' "$SOURCE"
printf '      "%s"\n' "$DESTINATION"
echo

# ─── Confirm (sync only) ──────────────────────────────────────────────────────
# Sync always requires an explicit "y" — there is deliberately no flag to skip it.
[ "$MODE" = sync ] && _confirm_or_abort 'Proceed?'
sudo -v || { _err 'sudo authentication failed.'; exit 1; }
echo

# ─── Dispatch ─────────────────────────────────────────────────────────────────
run_mode

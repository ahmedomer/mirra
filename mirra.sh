#!/bin/bash

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_SUCCESS=$'\e[32m'; C_WARN=$'\e[33m'; C_DANGER=$'\e[31m'
  C_ACCENT=$'\e[38;5;172m'; C_DIM=$'\e[2m'; BOLD=$'\e[1m'; NC=$'\e[0m'
else
  C_SUCCESS=''; C_WARN=''; C_DANGER=''; C_ACCENT=''; C_DIM=''; BOLD=''; NC=''
fi

MIRRA_VERSION="0.2.0"

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
  mirra --no-confirm <src> <dst>     Sync without confirmation prompt
  mirra -y <src> <dst>               Sync without confirmation prompt (short form)

Modes (selected interactively or via flag):
  Dry run    Preview changes without modifying any files
  Sync       Mirror source to destination (destructive at destination)
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

_cleanup() {
  tput cnorm 2>/dev/null
  kill -KILL -"$$" 2>/dev/null
  exit 130
}
trap '_cleanup' TSTP
trap 'tput cnorm 2>/dev/null' EXIT

# ─── UI ───────────────────────────────────────────────────────────────────────
spin() {
  local pid=$1 label=$2
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K%s%s%s %s' "$C_ACCENT" "${frames[$i]}" "$NC" "$label"
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
  printf '\r\033[K'
}

# ─── Execution engine ─────────────────────────────────────────────────────────
# Backgrounds rsync, shows spinner, waits for completion.
# Sets globals: RSYNC_EXIT, ELAPSED, PARTIAL, TMPFILE, ERRFILE.
# Callers must rm -f "$TMPFILE" "$ERRFILE" when done.
_run_rsync() {
  local spin_label="$1"
  local start=$SECONDS RSYNC_PID errline
  TMPFILE=$(mktemp) || { printf '%s[Error]%s Failed to create temp file.\n' "$C_DANGER" "$NC"; exit 1; }
  ERRFILE=$(mktemp) || { printf '%s[Error]%s Failed to create temp file.\n' "$C_DANGER" "$NC"; rm -f "$TMPFILE"; exit 1; }
  sudo rsync "${RSYNC_OPTS[@]}" "$SOURCE" "$DESTINATION" > "$TMPFILE" 2>"$ERRFILE" &
  RSYNC_PID=$!
  trap 'kill "$RSYNC_PID" 2>/dev/null; rm -f "$TMPFILE" "$ERRFILE"; exit 1' INT TERM HUP
  START_TIME=$(date '+%a %d %b %Y %H:%M:%S')
  printf '%s starting at %s\n' "$spin_label" "$START_TIME"
  spin "$RSYNC_PID" "$spin_label"
  wait "$RSYNC_PID"
  RSYNC_EXIT=$?
  trap - INT TERM HUP
  format_time $(( SECONDS - start ))
  ELAPSED=$FTIME
  PARTIAL=false
  [ "$RSYNC_EXIT" -eq 23 ] || [ "$RSYNC_EXIT" -eq 24 ] && PARTIAL=true
  if [ -s "$ERRFILE" ]; then
    while IFS= read -r errline; do
      printf '%s[Warning]%s %s\n' "$C_WARN" "$NC" "$errline"
    done < "$ERRFILE"
  fi
}

# ─── Output processor ─────────────────────────────────────────────────────────
# Parses rsync --out-format="%i %n" output from $1. Appends +/~/- entries to
# $LOG_FILE (plain text, no ANSI — for TextEdit compatibility).
# Sets globals: PARSE_TRANSFER, PARSE_ATTR, PARSE_DELETE.
# Invariants: *deleting matched before code extraction; directory lines skipped;
# filename at position 12 (11-char itemize string + 1 space).
# `c` at position 0 covers both new non-directory items (symlinks, special files)
# and attribute-only updates on existing items. Position 2 == "+" means new item
# (all itemize fields are "+" for new items) → reported as + (transfer).
# Position 2 != "+" means attribute-only update on existing item → reported as ~.
_process_output() {
  local tmpfile="$1"
  PARSE_TRANSFER=0; PARSE_ATTR=0; PARSE_DELETE=0
  local line line_trimmed code filetype file
  while IFS= read -r line; do
    line_trimmed="${line#"${line%%[! ]*}"}"
    line_trimmed="${line_trimmed%"${line_trimmed##*[! ]}"}"
    [[ "$line_trimmed" =~ ^\. ]] && continue
    if [[ "$line_trimmed" =~ ^\*deleting[[:space:]]+(.*) ]]; then
      printf '- %s\n' "${BASH_REMATCH[1]}" >> "$LOG_FILE"
      (( PARSE_DELETE++ )); continue
    fi
    code="${line_trimmed:0:1}"; filetype="${line_trimmed:1:1}"; file="${line_trimmed:12}"
    [[ -z "$file" || "$filetype" == "d" ]] && continue
    case "$code" in
      ">") printf '+ %s\n' "$file" >> "$LOG_FILE"; (( PARSE_TRANSFER++ )) ;;
      "c") if [[ "${line_trimmed:2:1}" == "+" ]]; then
             printf '+ %s\n' "$file" >> "$LOG_FILE"; (( PARSE_TRANSFER++ ))
           else
             printf '~ %s\n' "$file" >> "$LOG_FILE"; (( PARSE_ATTR++ ))
           fi ;;
      "x") (( PARSE_DELETE++ )) ;;
    esac
  done < "$tmpfile"
}

run_dry_run() {
  _run_rsync "Dry run..."
  {
    printf 'mirra dry-run\n'
    printf 'Started:     %s\n' "$START_TIME"
    printf 'Source:      %s\n' "${SOURCE%/}"
    printf 'Destination: %s\n' "$DESTINATION"
    printf -- '---\n'
  } > "$LOG_FILE" || printf '%s[Warning]%s Could not write log to %s\n' "$C_WARN" "$NC" "$LOG_FILE"
  _process_output "$TMPFILE"
  [ -s "$ERRFILE" ] && { printf -- '---\nWarnings:\n' >> "$LOG_FILE"; cat "$ERRFILE" >> "$LOG_FILE" 2>/dev/null; }
  { printf -- '---\n'
    printf 'Summary:  + %d transfer   ~ %d metadata   - %d delete\n' \
      "$PARSE_TRANSFER" "$PARSE_ATTR" "$PARSE_DELETE"
    printf 'Elapsed:  %s\n' "$ELAPSED"
  } >> "$LOG_FILE"
  rm -f "$TMPFILE" "$ERRFILE"
  if [ "$RSYNC_EXIT" -ne 0 ] && [ "$PARTIAL" = false ]; then
    printf '%s[Error]%s Dry run failed (rsync exit code %d). Check log at %s\n' \
      "$C_DANGER" "$NC" "$RSYNC_EXIT" "$LOG_FILE"
    exit 1
  fi
  echo
  printf '  %s+%s %d transfer   %s~%s %d metadata   %s-%s %d delete\n' \
    "$C_SUCCESS" "$NC" "$PARSE_TRANSFER" "$C_WARN" "$NC" "$PARSE_ATTR" "$C_DANGER" "$NC" "$PARSE_DELETE"
  if [ "$PARTIAL" = true ]; then
    printf '%s[Warning]%s Partial dry run \xe2\x80\x94 some files were skipped in %s (rsync exit %d).\n' \
      "$C_WARN" "$NC" "$ELAPSED" "$RSYNC_EXIT"
  else
    echo
    printf '%s\xe2\x9c\x93%s Dry run completed in %s.\n' "$C_SUCCESS" "$NC" "$ELAPSED"
  fi
  if (( PARSE_TRANSFER + PARSE_ATTR + PARSE_DELETE > 0 )); then
    printf '%sLog written to %s — opening in TextEdit.%s\n' "$C_DIM" "$LOG_FILE" "$NC"
    open -a TextEdit "$LOG_FILE"
  fi
}

run_verify() {
  _run_rsync "Verifying..."
  {
    printf 'mirra verify\n'
    printf 'Started:     %s\n' "$START_TIME"
    printf 'Source:      %s\n' "${SOURCE%/}"
    printf 'Destination: %s\n' "$DESTINATION"
    printf -- '---\n'
  } > "$LOG_FILE" || printf '%s[Warning]%s Could not write log to %s\n' "$C_WARN" "$NC" "$LOG_FILE"
  _process_output "$TMPFILE"
  [ -s "$ERRFILE" ] && { printf -- '---\nWarnings:\n' >> "$LOG_FILE"; cat "$ERRFILE" >> "$LOG_FILE" 2>/dev/null; }
  { printf -- '---\n'
    printf 'Summary:  + %d transfer   ~ %d metadata   - %d delete\n' \
      "$PARSE_TRANSFER" "$PARSE_ATTR" "$PARSE_DELETE"
    printf 'Elapsed:  %s\n' "$ELAPSED"
  } >> "$LOG_FILE"
  rm -f "$TMPFILE" "$ERRFILE"
  if [ "$RSYNC_EXIT" -ne 0 ] && [ "$PARTIAL" = false ]; then
    printf '%s[Error]%s Verify failed (rsync exit code %d). Check log at %s\n' \
      "$C_DANGER" "$NC" "$RSYNC_EXIT" "$LOG_FILE"
    exit 1
  fi
  echo
  if [ "$PARSE_TRANSFER" -eq 0 ] && [ "$PARSE_ATTR" -eq 0 ] && [ "$PARSE_DELETE" -eq 0 ]; then
    printf '  Destination matches source byte-for-byte.\n'
    if [ "$PARTIAL" = true ]; then
      printf '%s[Warning]%s Partial verify \xe2\x80\x94 some files were skipped in %s (rsync exit %d).\n' \
        "$C_WARN" "$NC" "$ELAPSED" "$RSYNC_EXIT"
    else
      echo
      printf '%s\xe2\x9c\x93%s Verify completed in %s.\n' "$C_SUCCESS" "$NC" "$ELAPSED"
    fi
  else
    printf '  %s+%s %d transfer   %s~%s %d metadata   %s-%s %d delete\n' \
      "$C_SUCCESS" "$NC" "$PARSE_TRANSFER" "$C_WARN" "$NC" "$PARSE_ATTR" "$C_DANGER" "$NC" "$PARSE_DELETE"
    printf '%s[Warning]%s Differences found in %s \xe2\x80\x94 run Sync to resolve.\n' "$C_WARN" "$NC" "$ELAPSED"
    [ "$PARTIAL" = true ] && printf '%s[Warning]%s Partial verify \xe2\x80\x94 some files were skipped in %s (rsync exit %d).\n' \
      "$C_WARN" "$NC" "$ELAPSED" "$RSYNC_EXIT"
    printf '%sLog written to %s — opening in TextEdit.%s\n' "$C_DIM" "$LOG_FILE" "$NC"
    open -a TextEdit "$LOG_FILE"
  fi
}

run_sync() {
  _run_rsync "Syncing..."
  {
    printf 'mirra sync\n'
    printf 'Started:     %s\n' "$START_TIME"
    printf 'Source:      %s\n' "${SOURCE%/}"
    printf 'Destination: %s\n' "$DESTINATION"
    printf -- '---\n'
  } > "$LOG_FILE" || printf '%s[Warning]%s Could not write log to %s\n' "$C_WARN" "$NC" "$LOG_FILE"
  _process_output "$TMPFILE"
  [ -s "$ERRFILE" ] && { printf -- '---\nWarnings:\n' >> "$LOG_FILE"; cat "$ERRFILE" >> "$LOG_FILE" 2>/dev/null; }
  { printf -- '---\n'
    printf 'Summary:  + %d transferred   ~ %d metadata   - %d deleted\n' \
      "$PARSE_TRANSFER" "$PARSE_ATTR" "$PARSE_DELETE"
    printf 'Elapsed:  %s\n' "$ELAPSED"
  } >> "$LOG_FILE"
  rm -f "$TMPFILE" "$ERRFILE"
  if [ "$RSYNC_EXIT" -ne 0 ] && [ "$PARTIAL" = false ]; then
    printf '%s\xe2\x9c\x97%s Sync failed in %s (rsync exit code %d). Check log at %s\n' \
      "$C_DANGER" "$NC" "$ELAPSED" "$RSYNC_EXIT" "$LOG_FILE"
    exit 1
  fi
  echo
  printf '  %s+%s %d transferred   %s~%s %d metadata   %s-%s %d deleted\n' \
    "$C_SUCCESS" "$NC" "$PARSE_TRANSFER" "$C_WARN" "$NC" "$PARSE_ATTR" "$C_DANGER" "$NC" "$PARSE_DELETE"
  if [ "$PARTIAL" = true ]; then
    printf '%s[Warning]%s Partial sync \xe2\x80\x94 some files were skipped in %s (rsync exit %d).\n' \
      "$C_WARN" "$NC" "$ELAPSED" "$RSYNC_EXIT"
  else
    echo
    printf '%s\xe2\x9c\x93%s Sync completed in %s.\n' "$C_SUCCESS" "$NC" "$ELAPSED"
  fi
  if (( PARSE_TRANSFER + PARSE_ATTR + PARSE_DELETE > 0 )); then
    printf '%sLog written to %s — opening in TextEdit.%s\n' "$C_DIM" "$LOG_FILE" "$NC"
    open -a TextEdit "$LOG_FILE"
  fi
}

# ─── Branding ─────────────────────────────────────────────────────────────────
printf '%s%smirra%s v%s\n' "$C_ACCENT" "$BOLD" "$NC" "$MIRRA_VERSION"
printf '%sby using mirra, you accept all responsibility for any data loss or\n' "$C_DIM"
printf 'damage. this software is provided without warranty of any kind.%s\n' "$NC"
echo

# ─── Parse flags ──────────────────────────────────────────────────────────────
DRY_RUN=false
VERIFY=false
NO_CONFIRM=false
if [ "$1" == "--dry-run" ]; then
  DRY_RUN=true
  shift
elif [ "$1" == "--verify" ]; then
  VERIFY=true
  shift
elif [ "$1" == "--no-confirm" ] || [ "$1" == "-y" ]; then
  NO_CONFIRM=true
  shift
fi
if [[ "$1" == -* ]]; then
  printf '%s[Error]%s Unknown flag: %s\n' "$C_DANGER" "$NC" "$1" >&2
  printf '%s[Error]%s Run '"'"'mirra --help'"'"' for usage.\n' "$C_DANGER" "$NC" >&2
  exit 1
fi

# ─── Source and destination ───────────────────────────────────────────────────
if [ $# -ge 2 ]; then
  if [[ -z "$1" || -z "$2" ]]; then
    printf '%s[Error]%s Source and destination cannot be empty.\n' "$C_DANGER" "$NC"
    exit 1
  fi
  SOURCE="$1"
  DESTINATION="$2"
elif [ $# -eq 1 ]; then
  printf '%s[Error]%s Usage: %s [--dry-run|--verify|--no-confirm] [<source> <destination>]\n' "$C_DANGER" "$NC" "$0"
  exit 1
else
  if [[ ! -t 0 ]]; then
    printf '%s[Error]%s Interactive mode requires a terminal. Usage: %s [--dry-run|--verify] <source> <destination>\n' \
      "$C_DANGER" "$NC" "$0"
    exit 1
  fi
  _SRC_PROMPT=$(printf '\001%s\002Source path:     \001%s\002 ' "$BOLD" "$NC")
  _DST_PROMPT=$(printf '\001%s\002Destination path:\001%s\002 ' "$BOLD" "$NC")
  while true; do
    read -e -p "$_SRC_PROMPT" SOURCE
    SOURCE="${SOURCE#"${SOURCE%%[![:space:]]*}"}"
    SOURCE="${SOURCE%"${SOURCE##*[![:space:]]}"}"
    if [[ "${SOURCE:0:1}" == "'" && "${SOURCE:$((${#SOURCE}-1)):1}" == "'" && ${#SOURCE} -ge 2 ]]; then
      SOURCE="${SOURCE:1:${#SOURCE}-2}"
    elif [[ "${SOURCE:0:1}" == '"' && "${SOURCE:$((${#SOURCE}-1)):1}" == '"' && ${#SOURCE} -ge 2 ]]; then
      SOURCE="${SOURCE:1:${#SOURCE}-2}"
    fi
    if [[ -z "$SOURCE" ]]; then
      printf '%s[Error]%s Source cannot be empty.\n' "$C_DANGER" "$NC"
      continue
    fi
    if [[ ! -d "$SOURCE" ]]; then
      printf '%s[Error]%s Source not found: %s\n' "$C_DANGER" "$NC" "$SOURCE"
      continue
    fi
    break
  done
  echo
  while true; do
    read -e -p "$_DST_PROMPT" DESTINATION
    DESTINATION="${DESTINATION#"${DESTINATION%%[![:space:]]*}"}"
    DESTINATION="${DESTINATION%"${DESTINATION##*[![:space:]]}"}"
    if [[ "${DESTINATION:0:1}" == "'" && "${DESTINATION:$((${#DESTINATION}-1)):1}" == "'" && ${#DESTINATION} -ge 2 ]]; then
      DESTINATION="${DESTINATION:1:${#DESTINATION}-2}"
    elif [[ "${DESTINATION:0:1}" == '"' && "${DESTINATION:$((${#DESTINATION}-1)):1}" == '"' && ${#DESTINATION} -ge 2 ]]; then
      DESTINATION="${DESTINATION:1:${#DESTINATION}-2}"
    fi
    if [[ -z "$DESTINATION" ]]; then
      printf '%s[Error]%s Destination cannot be empty.\n' "$C_DANGER" "$NC"
      continue
    fi
    if [[ ! -d "$DESTINATION" ]]; then
      printf '%s[Error]%s Destination not found: %s\n' "$C_DANGER" "$NC" "$DESTINATION"
      continue
    fi
    break
  done
  echo
fi

# ─── Mode selection ───────────────────────────────────────────────────────────
# Skipped when a mode flag (--dry-run, --verify) or --no-confirm is given.
if [ "$DRY_RUN" = false ] && [ "$VERIFY" = false ] && [ "$NO_CONFIRM" = false ]; then
  printf '%sMode:%s %s[1]%s Dry run  %s[2]%s Sync  %s[3]%s Verify: ' \
    "$BOLD" "$NC" "$C_ACCENT" "$NC" "$C_ACCENT" "$NC" "$C_ACCENT" "$NC"
  read -r _mode_choice
  case "$_mode_choice" in
    1|'') DRY_RUN=true ;;
    3) VERIFY=true ;;
    2) ;;
    *) printf '%s[Error]%s Invalid selection. Choose 1, 2, or 3.\n' "$C_DANGER" "$NC"; exit 1 ;;
  esac
  echo
fi

# Ensure trailing slash for source
[[ ! "$SOURCE" =~ /$ ]] && SOURCE="${SOURCE}/"

# Remove trailing slash from destination
DESTINATION="${DESTINATION%/}"

# Validate source and destination
if [[ ! -d "$SOURCE" ]]; then
  printf '%s[Error]%s Source not found: %s\n' "$C_DANGER" "$NC" "$SOURCE"
  exit 1
fi
if [[ ! -d "$DESTINATION" ]]; then
  printf '%s[Error]%s Destination not found: %s\n' "$C_DANGER" "$NC" "$DESTINATION"
  exit 1
fi
if [[ "${SOURCE%/}" -ef "$DESTINATION" ]]; then
  printf '%s[Error]%s Source and destination are the same path.\n' "$C_DANGER" "$NC"
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

# Check rsync installation
if ! command -v rsync &>/dev/null; then
  printf '%s[Error]%s rsync is not installed.\n' "$C_DANGER" "$NC"
  exit 1
fi

# Log file
LOG_FILE="$SCRIPT_DIR/rsync.log"

# ─── Build command ────────────────────────────────────────────────────────────
RSYNC_OPTS=(-aAXHN --delete --numeric-ids)
[ -n "$EXCLUSIONS_FILE" ] && RSYNC_OPTS+=(--exclude-from="$EXCLUSIONS_FILE")
if [ "$VERIFY" = true ]; then
  RSYNC_OPTS+=(--checksum --dry-run --out-format="%i %n")
elif [ "$DRY_RUN" = true ]; then
  RSYNC_OPTS+=(--dry-run --out-format="%i %n")
else
  RSYNC_OPTS+=(--out-format="%i %n")
fi

# ─── Preview ──────────────────────────────────────────────────────────────────
printf '  %s%s%s  \xe2\x86\x92  %s%s%s\n' \
  "$BOLD" "${SOURCE%/}" "$NC" "$BOLD" "$DESTINATION" "$NC"
if [ "$VERIFY" = true ]; then
  printf '  Neither source nor destination will be modified.\n'
elif [ "$DRY_RUN" = true ]; then
  printf '  Preview only \xe2\x80\x94 no files will be modified.\n'
else
  printf '  Source will not be modified. Destination will be made an exact replica.\n'
fi
printf '  sudo may prompt for your password to preserve file permissions and ACLs.\n'
echo
printf '  %ssudo%s %srsync%s \\\n' "$BOLD" "$NC" "$BOLD" "$NC"
for _opt in "${RSYNC_OPTS[@]}"; do
  [[ "$_opt" == *" "* ]] && printf '      "%s" \\\n' "$_opt" || printf '      %s \\\n' "$_opt"
done
printf '      "%s" \\\n' "$SOURCE"
printf '      "%s"\n' "$DESTINATION"
unset _opt
echo

# ─── Confirm (sync only) ──────────────────────────────────────────────────────
if [ "$DRY_RUN" = false ] && [ "$VERIFY" = false ] && [ "$NO_CONFIRM" = false ]; then
  printf 'Proceed? [y/N]: '
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    printf 'Aborted.\n'
    exit 0
  fi
fi
sudo -v || { printf '%s[Error]%s sudo authentication failed.\n' "$C_DANGER" "$NC"; exit 1; }
echo

# ─── Dispatch ─────────────────────────────────────────────────────────────────
if [ "$VERIFY" = true ]; then
  run_verify
elif [ "$DRY_RUN" = true ]; then
  run_dry_run
else
  run_sync
fi

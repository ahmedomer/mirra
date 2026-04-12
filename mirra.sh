#!/bin/bash

# ANSI color codes
YELLOW='\033[1;33m'
RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

format_time() {
  local s=$1
  if (( s < 60 )); then FTIME="${s}s"
  elif (( s < 3600 )); then FTIME="$(( s / 60 ))m $(( s % 60 ))s"
  else FTIME="$(( s / 3600 ))h $(( (s % 3600) / 60 ))m $(( s % 60 ))s"
  fi
}

get_volumes() {
  VOLUMES=()
  local vol
  for vol in /Volumes/*/; do
    vol="${vol%/}"
    [[ -L "$vol" ]] && continue  # skip boot volume symlink
    VOLUMES+=("$vol")
  done
}

prompt_menu() {
  local title="$1"; shift
  local options=("$@")
  local n=${#options[@]} current=0 key k2 k3 i

  echo -e "$title"
  tput civis 2>/dev/null
  trap 'tput cnorm 2>/dev/null; exit 130' INT

  for (( i=0; i<n; i++ )); do
    (( i == current )) \
      && echo -e "  ${CYAN}❯${NC} ${options[$i]}" \
      || echo -e "    ${options[$i]}"
  done

  while true; do
    IFS= read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn1 -t 1 k2 || k2=""
      IFS= read -rsn1 -t 1 k3 || k3=""
      key="${key}${k2}${k3}"
    fi
    case "$key" in
      $'\x1b[A') (( current > 0 )) && (( current-- )) ;;
      $'\x1b[B') (( current < n-1 )) && (( current++ )) ;;
      ''|$'\n'|$'\r') break ;;
    esac
    tput cuu "$n" 2>/dev/null
    for (( i=0; i<n; i++ )); do
      (( i == current )) \
        && echo -e "  ${CYAN}❯${NC} ${options[$i]}" \
        || echo -e "    ${options[$i]}"
    done
  done

  tput cnorm 2>/dev/null
  trap - INT
  MENU_INDEX=$current
}

spin() {
  local pid=$1 label=$2 tmpfile=${3:-}
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0 ticks=0 elapsed=0 scanned
  format_time "$elapsed"
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -n "$tmpfile" ]]; then
      scanned=$(wc -l < "$tmpfile" 2>/dev/null | tr -d ' ')
      printf "\r\033[K${CYAN}${frames[$i]}${NC} %s  ${DIM}%'d files  %s${NC}" "$label" "$scanned" "$FTIME"
    else
      printf "\r\033[K${CYAN}${frames[$i]}${NC} %s %s" "$label" "$FTIME"
    fi
    i=$(( (i + 1) % ${#frames[@]} ))
    ticks=$(( ticks + 1 ))
    (( ticks % 10 == 0 )) && elapsed=$(( elapsed + 1 )) && format_time "$elapsed"
    sleep 0.1
  done
  printf "\r\033[K"
}

# Branding
echo
echo -e "${CYAN} ▐▛▀▀▜▌ ${NC}  ${BOLD}mirra${NC}"
echo -e "${CYAN}▗▟▌  ▐▙▖${NC}  macOS rsync mirror"
echo

# Parse flags
DRY_RUN=false
VERIFY=false
if [ "$1" == "--dry-run" ]; then
  DRY_RUN=true
  shift
elif [ "$1" == "--verify" ]; then
  VERIFY=true
  shift
fi
if [[ "$1" == --* ]]; then
  echo -e "${RED}[Error]${NC} Unknown flag: $1"
  echo -e "${RED}[Error]${NC} Usage: $0 [--dry-run|--verify] [<source> <destination>]"
  exit 1
fi

# Source and destination
if [ $# -ge 2 ]; then
  if [[ -z "$1" || -z "$2" ]]; then
    echo -e "${RED}[Error]${NC} Source and destination cannot be empty."
    exit 1
  fi
  SOURCE="$1"
  DESTINATION="$2"
elif [ $# -eq 1 ]; then
  echo -e "${RED}[Error]${NC} Usage: $0 [--dry-run|--verify] [<source> <destination>]"
  exit 1
else
  # Interactive drive selection
  get_volumes
  if [ ${#VOLUMES[@]} -lt 2 ]; then
    echo -e "${RED}[Error]${NC} At least two volumes are required. Found: ${#VOLUMES[@]}."
    exit 1
  fi

  vol_names=()
  for vol in "${VOLUMES[@]}"; do
    vol_names+=("${vol##*/}")
  done

  prompt_menu "Select source:" "${vol_names[@]}"
  SOURCE="${VOLUMES[$MENU_INDEX]}"
  echo

  dest_volumes=(); dest_names=()
  for vol in "${VOLUMES[@]}"; do
    if [[ "$vol" != "$SOURCE" ]]; then
      dest_volumes+=("$vol")
      dest_names+=("${vol##*/}")
    fi
  done

  prompt_menu "Select destination:" "${dest_names[@]}"
  DESTINATION="${dest_volumes[$MENU_INDEX]}"
  echo
fi

# Mode selection (skip if --dry-run or --verify was passed)
if [ "$DRY_RUN" = false ] && [ "$VERIFY" = false ]; then
  prompt_menu "Select mode:" \
    "Dry run  preview changes without syncing" \
    "Sync     mirror source to destination" \
    "Verify   check destination matches source byte-for-byte"
  [ "$MENU_INDEX" -eq 0 ] && DRY_RUN=true
  [ "$MENU_INDEX" -eq 2 ] && VERIFY=true
  echo
fi

# Confirm mode
if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}[Info]${NC} Running in dry-run mode."
elif [ "$VERIFY" = true ]; then
  echo -e "${YELLOW}[Info]${NC} Running in verify mode."
else
  echo -e "${YELLOW}[Info]${NC} Running in sync mode."
fi

# Ensure trailing slash for source
[[ ! "$SOURCE" =~ /$ ]] && SOURCE="${SOURCE}/"

# Remove trailing slash from destination
DESTINATION="${DESTINATION%/}"

# Validate source and destination
if [[ ! -d "$SOURCE" ]]; then
  echo -e "${RED}[Error]${NC} Source not found: $SOURCE"
  exit 1
fi
if [[ ! -d "$DESTINATION" ]]; then
  echo -e "${RED}[Error]${NC} Destination not found: $DESTINATION"
  exit 1
fi
if [[ "${SOURCE%/}" -ef "$DESTINATION" ]]; then
  echo -e "${RED}[Error]${NC} Source and destination are the same path."
  exit 1
fi

# Exclusions file (relative to this script)
EXCLUSIONS_FILE="$SCRIPT_DIR/exclusions.txt"
if [ ! -f "$EXCLUSIONS_FILE" ]; then
  echo -e "${YELLOW}[Info]${NC} No exclusions file found at $EXCLUSIONS_FILE. Continuing without exclusions."
  EXCLUSIONS_FILE=""
fi

# Check rsync installation
if ! command -v rsync &>/dev/null; then
  echo -e "${RED}[Error]${NC} rsync is not installed."
  exit 1
fi

# Log file
LOG_FILE="$SCRIPT_DIR/rsync.log"

# rsync options
RSYNC_OPTS=(-aAXHN --delete --numeric-ids --fileflags --force-change)
if [ -n "$EXCLUSIONS_FILE" ]; then
  RSYNC_OPTS+=(--exclude-from="$EXCLUSIONS_FILE")
fi

# Add mode-specific options
if [ "$VERIFY" = true ]; then
  RSYNC_OPTS+=(--checksum --dry-run --out-format="%i %n")
elif [ "$DRY_RUN" = true ]; then
  RSYNC_OPTS+=(--dry-run --out-format="%i %n")
else
  RSYNC_OPTS+=(--out-format="%i %n")
fi

# Run rsync
echo -e "${YELLOW}[Info]${NC} $SOURCE  →  $DESTINATION"
if [ "$VERIFY" = true ]; then
  echo -e "${YELLOW}[Info]${NC} Neither source nor destination will be modified."
else
  echo -e "${YELLOW}[Info]${NC} Source will not be modified. Destination will be made an exact replica."
fi
if [ "$DRY_RUN" = true ]; then
  SPIN_LABEL="Dry run..."
elif [ "$VERIFY" = true ]; then
  SPIN_LABEL="Verifying..."
else
  SPIN_LABEL="Syncing..."
fi
echo -e "${YELLOW}[Info]${NC} sudo is required to preserve ACLs, permissions, and file flags across volumes."
sudo -v || { echo -e "${RED}[Error]${NC} sudo authentication failed."; exit 1; }
echo
_cmd="sudo rsync"
for _opt in "${RSYNC_OPTS[@]}"; do
  [[ "$_opt" == *" "* ]] && _cmd+=" \"$_opt\"" || _cmd+=" $_opt"
done
echo -e "${DIM}${_cmd} \"$SOURCE\" \"$DESTINATION\"${NC}"
unset _cmd _opt
if [ "$DRY_RUN" = false ] && [ "$VERIFY" = false ]; then
  printf "Proceed? [y/N]: "
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[Info]${NC} Aborted."
    exit 0
  fi
fi
START=$SECONDS
TMPFILE=$(mktemp) || { echo -e "${RED}[Error]${NC} Failed to create temp file."; exit 1; }
ERRFILE=$(mktemp) || { echo -e "${RED}[Error]${NC} Failed to create temp file."; rm -f "$TMPFILE"; exit 1; }
sudo rsync "${RSYNC_OPTS[@]}" "$SOURCE" "$DESTINATION" > "$TMPFILE" 2>"$ERRFILE" &
RSYNC_PID=$!
trap 'kill "$RSYNC_PID" 2>/dev/null; rm -f "$TMPFILE" "$ERRFILE"; exit 1' INT TERM HUP
spin "$RSYNC_PID" "$SPIN_LABEL" "$TMPFILE"
wait "$RSYNC_PID"
RSYNC_EXIT=$?
trap - INT TERM HUP
format_time $(( SECONDS - START ))
ELAPSED=$FTIME
PARTIAL=false
if [ "$RSYNC_EXIT" -eq 23 ] || [ "$RSYNC_EXIT" -eq 24 ]; then
  PARTIAL=true
fi
if [ -s "$ERRFILE" ]; then
  while IFS= read -r errline; do
    echo -e "${YELLOW}[Warning]${NC} $errline"
  done < "$ERRFILE"
fi

# If dry-run, parse and summarize output
if [ "$DRY_RUN" = true ]; then
  if [ "$RSYNC_EXIT" -ne 0 ] && [ "$PARTIAL" = false ]; then
    rm -f "$TMPFILE" "$ERRFILE"
    echo -e "${RED}[Error]${NC} Dry run failed (rsync exit code $RSYNC_EXIT)."
    exit 1
  fi
  WILL_COPY=0
  ATTR_CHANGED=0
  DELETED=0

  while IFS= read -r line; do
    line_trimmed="${line#"${line%%[! ]*}"}"
    line_trimmed="${line_trimmed%"${line_trimmed##*[! ]}"}"

    # Skip up-to-date files (lines starting with '.')
    [[ "$line_trimmed" =~ ^\. ]] && continue

    # Handle deletions
    if [[ "$line_trimmed" =~ ^\*deleting[[:space:]]+(.*) ]]; then
      file="${BASH_REMATCH[1]}"
      echo -e "${RED}[Will delete]${NC} $file"
      ((DELETED++))
      continue
    fi

    code="${line_trimmed:0:1}"
    file="${line_trimmed:12}"

    [[ -z "$file" ]] && continue

    case "$code" in
      ">") echo -e "${GREEN}[Will copy]${NC} $file"; ((WILL_COPY++)) ;;
      "c") echo -e "${YELLOW}[Will update]${NC} $file"; ((ATTR_CHANGED++)) ;;
      "d") ;; # skip directory entries
      "x") echo -e "${RED}[Will delete]${NC} $file"; ((DELETED++)) ;;
    esac
  done < "$TMPFILE"
  rm -f "$TMPFILE" "$ERRFILE"

  echo -e "${GREEN}[Summary]${NC} $WILL_COPY files will copy, $ATTR_CHANGED with attribute changes, $DELETED files would be deleted. ($ELAPSED)"
  if [ "$PARTIAL" = true ]; then
    echo -e "${YELLOW}[Warning]${NC} Partial dry run — some files were skipped (rsync exit $RSYNC_EXIT)."
  else
    echo -e "${GREEN}[Success]${NC} Dry run completed successfully."
  fi
elif [ "$VERIFY" = true ]; then
  if [ "$RSYNC_EXIT" -ne 0 ] && [ "$PARTIAL" = false ]; then
    rm -f "$TMPFILE" "$ERRFILE"
    echo -e "${RED}[Error]${NC} Verify failed (rsync exit code $RSYNC_EXIT)."
    exit 1
  fi
  DIFFERS=0
  EXTRA=0

  while IFS= read -r line; do
    line_trimmed="${line#"${line%%[! ]*}"}"
    line_trimmed="${line_trimmed%"${line_trimmed##*[! ]}"}"
    [[ "$line_trimmed" =~ ^\. ]] && continue
    if [[ "$line_trimmed" =~ ^\*deleting[[:space:]]+(.*) ]]; then
      file="${BASH_REMATCH[1]}"
      echo -e "${YELLOW}[Extra]${NC} $file"
      ((EXTRA++))
      continue
    fi
    code="${line_trimmed:0:1}"
    file="${line_trimmed:12}"
    [[ -z "$file" ]] && continue
    case "$code" in
      ">"|"c") echo -e "${RED}[Differs]${NC} $file"; ((DIFFERS++)) ;;
      "d") ;;
    esac
  done < "$TMPFILE"
  rm -f "$TMPFILE" "$ERRFILE"

  if [ "$DIFFERS" -eq 0 ] && [ "$EXTRA" -eq 0 ]; then
    echo -e "${GREEN}[Summary]${NC} Verification passed — destination matches source byte-for-byte. ($ELAPSED)"
    if [ "$PARTIAL" = true ]; then
      echo -e "${YELLOW}[Warning]${NC} Partial verify — some files were skipped (rsync exit $RSYNC_EXIT)."
    else
      echo -e "${GREEN}[Success]${NC} Verify completed successfully."
    fi
  else
    echo -e "${YELLOW}[Summary]${NC} $DIFFERS files differ or missing, $EXTRA extra on destination. ($ELAPSED)"
    echo -e "${YELLOW}[Warning]${NC} Differences found — run Sync to resolve."
    [ "$PARTIAL" = true ] && echo -e "${YELLOW}[Warning]${NC} Partial verify — some files were skipped (rsync exit $RSYNC_EXIT)."
  fi
else
  # Sync mode: write output to log
  if ! cat "$TMPFILE" > "$LOG_FILE"; then
    echo -e "${YELLOW}[Warning]${NC} Could not write log to $LOG_FILE"
  fi
  cat "$ERRFILE" >> "$LOG_FILE" 2>/dev/null
  if [ "$RSYNC_EXIT" -ne 0 ] && [ "$PARTIAL" = false ]; then
    rm -f "$TMPFILE" "$ERRFILE"
    echo -e "${RED}[Error]${NC} Sync failed (rsync exit code $RSYNC_EXIT). Check log at $LOG_FILE"
    exit 1
  fi
  COPIED=0; ATTR_CHANGED=0; DELETED=0
  while IFS= read -r line; do
    line_trimmed="${line#"${line%%[! ]*}"}"
    line_trimmed="${line_trimmed%"${line_trimmed##*[! ]}"}"
    [[ "$line_trimmed" =~ ^\. ]] && continue
    if [[ "$line_trimmed" =~ ^\*deleting[[:space:]] ]]; then
      ((DELETED++)); continue
    fi
    code="${line_trimmed:0:1}"; file="${line_trimmed:12}"
    [[ -z "$file" ]] && continue
    case "$code" in
      ">") ((COPIED++)) ;;
      "c") ((ATTR_CHANGED++)) ;;
      "d") ;; # skip directory entries
      "x") ((DELETED++)) ;;
    esac
  done < "$TMPFILE"
  rm -f "$TMPFILE" "$ERRFILE"
  echo -e "${GREEN}[Summary]${NC} $COPIED files copied, $ATTR_CHANGED with attribute changes, $DELETED deleted. ($ELAPSED)"
  echo -e "${YELLOW}[Info]${NC} Full output logged to $LOG_FILE"
  if [ "$PARTIAL" = true ]; then
    echo -e "${YELLOW}[Warning]${NC} Partial sync — some files were skipped (rsync exit $RSYNC_EXIT)."
  else
    echo -e "${GREEN}[Success]${NC} Sync completed successfully."
  fi
fi
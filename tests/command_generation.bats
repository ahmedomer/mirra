#!/usr/bin/env bats
# Validates that each mirra.sh flow generates the correct rsync command.
#
# Prerequisites:  macOS:  brew install bats-core
#                 Linux:  apt-get install bats  OR  https://github.com/bats-core/bats-core
# Run:            bats tests/command_generation.bats

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  # Isolated workspace — SCRIPT_DIR inside mirra.sh resolves here
  TEST_WORKSPACE=$(mktemp -d)
  cp "$BATS_TEST_DIRNAME/../mirra.sh" "$TEST_WORKSPACE/mirra.sh"
  chmod +x "$TEST_WORKSPACE/mirra.sh"

  # Fresh source and destination directories
  SRC=$(mktemp -d)
  DST=$(mktemp -d)

  # The mock rsync writes each argument (one per line) to this file
  export RSYNC_ARGS_FILE="$TEST_WORKSPACE/rsync_args.txt"

  # Mock binaries — prepended to PATH so they shadow the real sudo/rsync
  mkdir -p "$TEST_WORKSPACE/bin"

  # sudo mock: bypass "sudo -v" (pre-auth); otherwise exec the next command
  # directly so the mock rsync is found via the same PATH
  cat > "$TEST_WORKSPACE/bin/sudo" << 'SUDO_EOF'
#!/bin/sh
[ "$1" = "-v" ] && exit 0
exec "$@"
SUDO_EOF

  # rsync mock: record every argument on its own line. stdout is redirected
  # to TMPFILE by the script, so write to RSYNC_ARGS_FILE via the inherited
  # env var instead. Optional: MOCK_RSYNC_STDERR (one stderr line) and
  # MOCK_RSYNC_EXIT (exit code, default 0).
  cat > "$TEST_WORKSPACE/bin/rsync" << 'RSYNC_EOF'
#!/bin/sh
printf '%s\n' "$@" > "$RSYNC_ARGS_FILE"
[ -n "$MOCK_RSYNC_STDERR" ] && echo "$MOCK_RSYNC_STDERR" >&2
exit "${MOCK_RSYNC_EXIT:-0}"
RSYNC_EOF

  chmod +x "$TEST_WORKSPACE/bin/sudo" "$TEST_WORKSPACE/bin/rsync"

  export PATH="$TEST_WORKSPACE/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_WORKSPACE" "$SRC" "$DST"
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

# Fail if the argument is absent in RSYNC_ARGS_FILE
assert_arg() {
  if ! grep -qF -- "$1" "$RSYNC_ARGS_FILE"; then
    echo "Expected rsync arg not found: $1"
    echo "--- recorded args ---"
    cat "$RSYNC_ARGS_FILE"
    return 1
  fi
}

# Fail if the argument is present in RSYNC_ARGS_FILE
refute_arg() {
  if grep -qF -- "$1" "$RSYNC_ARGS_FILE"; then
    echo "Unexpected rsync arg found: $1"
    echo "--- recorded args ---"
    cat "$RSYNC_ARGS_FILE"
    return 1
  fi
}

# Check that all base flags (present in every mode) are recorded
assert_base_flags() {
  assert_arg "-aAXHN"
  assert_arg "--delete"
  assert_arg "--numeric-ids"
  assert_arg "--out-format=%i %n"
  refute_arg "--fileflags"
  refute_arg "--force-change"
}

# Fail if rsync was invoked at all
refute_rsync_ran() {
  if [ -e "$RSYNC_ARGS_FILE" ]; then
    echo "rsync should not have run; recorded args:"
    cat "$RSYNC_ARGS_FILE"
    return 1
  fi
}

# The run stopped at a prompt: exit 0, "Aborted.", and rsync never ran
assert_aborted() {
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted."* ]]
  refute_rsync_ran
}

# The last two rsync args must be exactly "$SRC/" then "$DST". This covers
# the trailing-slash rules (source gains one, destination never has one),
# exact path values, and ordering in one comparison.
assert_paths() {
  local expected actual
  expected=$(printf '%s\n%s' "$SRC/" "$DST")
  actual=$(tail -n 2 "$RSYNC_ARGS_FILE")
  if [ "$actual" != "$expected" ]; then
    echo "Expected the last two rsync args to be:"
    echo "$expected"
    echo "--- recorded args ---"
    cat "$RSYNC_ARGS_FILE"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------

@test "dry-run with exclusions: base flags + --dry-run + --exclude-from, no --checksum" {
  echo ".DS_Store" > "$TEST_WORKSPACE/exclusions.txt"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  assert_base_flags
  assert_arg  "--dry-run"
  refute_arg  "--checksum"
  assert_arg  "--exclude-from=$TEST_WORKSPACE/exclusions.txt"
  assert_paths
}

@test "dry-run without exclusions: base flags + --dry-run, no --checksum, no --exclude-from" {
  # No exclusions.txt in TEST_WORKSPACE

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  assert_base_flags
  assert_arg  "--dry-run"
  refute_arg  "--checksum"
  refute_arg  "--exclude-from="
  assert_paths
}

# ---------------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------------
# Sync has no CLI flag; the interactive mode menu prompts for a number.
# Stdin sequence:
#   2\n — select option 2 (Sync)
#   y\n — proceed past the confirmation prompt

@test "sync with exclusions: base flags + --exclude-from, no --dry-run, no --checksum" {
  echo ".DS_Store" > "$TEST_WORKSPACE/exclusions.txt"

  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\ny\n')

  [ "$status" -eq 0 ]
  assert_base_flags
  refute_arg  "--dry-run"
  refute_arg  "--checksum"
  assert_arg  "--exclude-from=$TEST_WORKSPACE/exclusions.txt"
  assert_paths
}

@test "sync without exclusions: base flags only, no --dry-run, no --checksum, no --exclude-from" {
  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\ny\n')

  [ "$status" -eq 0 ]
  assert_base_flags
  refute_arg  "--dry-run"
  refute_arg  "--checksum"
  refute_arg  "--exclude-from="
  assert_paths
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

@test "verify with exclusions: base flags + --checksum + --dry-run + --exclude-from" {
  echo ".DS_Store" > "$TEST_WORKSPACE/exclusions.txt"

  run bash "$TEST_WORKSPACE/mirra.sh" --verify "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  assert_base_flags
  assert_arg  "--checksum"
  assert_arg  "--dry-run"
  assert_arg  "--exclude-from=$TEST_WORKSPACE/exclusions.txt"
  assert_paths
}

@test "verify without exclusions: base flags + --checksum + --dry-run, no --exclude-from" {
  run bash "$TEST_WORKSPACE/mirra.sh" --verify "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  assert_base_flags
  assert_arg  "--checksum"
  assert_arg  "--dry-run"
  refute_arg  "--exclude-from="
  assert_paths
}

# ---------------------------------------------------------------------------
# Confirmation is mandatory
# ---------------------------------------------------------------------------
# Sync always requires an explicit "y". There is no flag to skip it.

@test "--no-confirm is rejected as an unknown flag and rsync is never run" {
  run bash "$TEST_WORKSPACE/mirra.sh" --no-confirm "$SRC" "$DST"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag: --no-confirm"* ]]
  refute_rsync_ran
}

@test "-y is rejected as an unknown flag and rsync is never run" {
  run bash "$TEST_WORKSPACE/mirra.sh" -y "$SRC" "$DST"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag: -y"* ]]
  refute_rsync_ran
}

@test "sync answered n at Proceed aborts without running rsync" {
  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\nn\n')

  assert_aborted
}

@test "sync with no answer at Proceed aborts without running rsync" {
  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\n')

  assert_aborted
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
# The real temp directories live on the APFS boot volume, so the volume
# checks pass by default. mock_volume makes $DST look like it sits on a
# different volume by shadowing df and mount:
#   mock_volume <mount point> <mount options, e.g. "apfs, local, noowners">

mock_volume() {
  export MOCK_DST="$DST" MOCK_MNT="$1" MOCK_OPTS="$2"
  cat > "$TEST_WORKSPACE/bin/df" << 'DF_EOF'
#!/bin/sh
for arg in "$@"; do last="$arg"; done
if [ "$last" = "$MOCK_DST" ]; then
  echo "Filesystem 512-blocks Used Available Capacity Mounted on"
  echo "/dev/disk9s1 1000 500 500 50% $MOCK_MNT"
else
  exec /bin/df "$@"
fi
DF_EOF
  cat > "$TEST_WORKSPACE/bin/mount" << 'MOUNT_EOF'
#!/bin/sh
/sbin/mount
echo "/dev/disk9s1 on $MOCK_MNT ($MOCK_OPTS)"
MOUNT_EOF
  chmod +x "$TEST_WORKSPACE/bin/df" "$TEST_WORKSPACE/bin/mount"
}

@test "preflight: non-APFS destination is refused in every mode" {
  mock_volume "/Volumes/Backup" "exfat, local, nodev, nosuid, noowners"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Destination volume /Volumes/Backup is exfat; mirra supports APFS volumes only."* ]]

  run bash "$TEST_WORKSPACE/mirra.sh" --verify "$SRC" "$DST"
  [ "$status" -ne 0 ]

  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\ny\ny\n')
  [ "$status" -ne 0 ]

  refute_rsync_ran
}

@test "preflight: ignored ownership on destination, sync answered n aborts before rsync" {
  mock_volume "/Volumes/Backup" "apfs, local, nodev, nosuid, journaled, noowners"

  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\nn\n')

  [ "$status" -eq 0 ]
  [[ "$output" == *"Ownership is ignored on /Volumes/Backup"* ]]
  [[ "$output" == *"Aborted."* ]]
  refute_rsync_ran
}

@test "preflight: ignored ownership on destination, sync answered y continues" {
  mock_volume "/Volumes/Backup" "apfs, local, nodev, nosuid, journaled, noowners"

  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\ny\ny\n')

  [ "$status" -eq 0 ]
  assert_base_flags
  assert_paths
}

@test "preflight: ignored ownership in dry-run warns without prompting and runs" {
  mock_volume "/Volumes/Backup" "apfs, local, noowners"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *"[Warning] Ownership is ignored"* ]]
  [[ "$output" != *"Continue anyway?"* ]]
  assert_arg "--dry-run"
}

@test "preflight: mount point with spaces is parsed correctly" {
  mock_volume "/Volumes/T Test" "apfs, local, noowners"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *'sudo diskutil enableOwnership "/Volumes/T Test"'* ]]
}

@test "preflight: APFS destination with ownership enabled passes silently" {
  mock_volume "/Volumes/T Test" "apfs, local, journaled"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"[Warning]"* ]]
  [[ "$output" != *"[Error]"* ]]
}

@test "preflight: empty source with non-empty destination, sync answered n aborts before rsync" {
  touch "$DST/keep.txt"

  run bash "$TEST_WORKSPACE/mirra.sh" "$SRC" "$DST" < <(printf '2\nn\n')

  [ "$status" -eq 0 ]
  [[ "$output" == *"Source is empty"* ]]
  [[ "$output" == *"Aborted."* ]]
  refute_rsync_ran
}

@test "preflight: empty source in dry-run warns and still runs rsync" {
  touch "$DST/keep.txt"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *"[Warning] Source is empty"* ]]
  assert_arg "--dry-run"
}

@test "preflight: source with only excluded entries counts as empty" {
  cp "$BATS_TEST_DIRNAME/../exclusions.txt" "$TEST_WORKSPACE/exclusions.txt"
  touch "$SRC/.DS_Store" "$DST/keep.txt"
  mkdir "$SRC/.fseventsd" "$SRC/.Spotlight-V100"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *"Source is empty"* ]]
}

@test "preflight: non-empty source does not trigger the empty-source warning" {
  touch "$SRC/file.txt" "$DST/keep.txt"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"Source is empty"* ]]
}

# ---------------------------------------------------------------------------
# Full Disk Access hint
# ---------------------------------------------------------------------------

@test "permission errors from rsync add a Full Disk Access hint" {
  export MOCK_RSYNC_STDERR='rsync: [sender] opendir "/x/Library/Mail" failed: Operation not permitted (1)'
  export MOCK_RSYNC_EXIT=23

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *"[Hint]"*"Full Disk Access"* ]]
}

@test "no Full Disk Access hint without permission errors" {
  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"Full Disk Access"* ]]
}

@test "preflight: without exclusions.txt, a .DS_Store-only source is not empty" {
  touch "$SRC/.DS_Store" "$DST/keep.txt"

  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"Source is empty"* ]]
}

@test "preview shows the absolute rsync path that sudo will run" {
  run bash "$TEST_WORKSPACE/mirra.sh" --dry-run "$SRC" "$DST" < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *"sudo $TEST_WORKSPACE/bin/rsync"* ]]
}

# mirra

macOS rsync wrapper that keeps a destination as an exact one-way mirror of its source — including permissions, ACLs, extended attributes, and metadata.

## Key files

- `mirra.sh` — entire tool; all logic lives here
- `exclusions.txt` — rsync `--exclude-from` list (macOS volume metadata defaults); absent = no exclusions
- `tests/command_generation.bats` — test suite

## Setup

- macOS required
- Homebrew rsync required: `brew install rsync` — Apple's built-in rsync is missing flags mirra needs
- bats-core required for tests: `brew install bats-core`

## CLI

```bash
./mirra.sh                              # interactive mode
./mirra.sh --dry-run <src> <dst>        # preview changes, write nothing
./mirra.sh --verify  <src> <dst>        # byte-for-byte comparison, write nothing
./mirra.sh --no-confirm <src> <dst>     # sync without confirmation prompt
./mirra.sh -y <src> <dst>               # same as --no-confirm
```

## Tests

```bash
bats tests/command_generation.bats                          # full suite
bats --filter "test name" tests/command_generation.bats     # single test
```

If you change command construction, update the corresponding `assert_arg` / `refute_arg` calls in the affected tests.

## Do not add these rsync flags

- **`-i`** — equivalent to `--out-format='%i %n%L'`; `--out-format` takes precedence, making `-i` a no-op
- **`-h` / `--human-readable`** — changes rsync's stats output format and would break itemize parsing
- **`-W` (whole-file)** — rsync defaults to whole-file for local paths; a no-op
- **`-z` (compress)** — no benefit for local disk transfers; adds CPU overhead
- **`--checksum`** — verify-only; do not add to sync or dry-run (mtime+size is sufficient; checksum reads every byte)
- **`--copy-links` / `--copy-unsafe-links`** — dereferencing symlinks breaks the clone; `-l` (included in `-a`) preserves them as-is
- **`--fileflags`** — macOS-patched rsync extension; not supported by Homebrew rsync 3.4.2+; causes "unknown option" error
- **`--force-change`** — same origin as `--fileflags`; not supported by Homebrew rsync 3.4.2+; causes "unknown option" error

## Architecture

Two-engine model — execution and parsing are separate functions:

- **`_run_rsync`** (execution engine) — runs rsync in background, shows spinner, waits for exit. Sets globals: `RSYNC_EXIT`, `ELAPSED`, `PARTIAL`, `TMPFILE`, `ERRFILE`, `START_TIME`. Does zero output parsing.
- **`_process_output`** (output processor) — reads `$TMPFILE`, parses line by line, appends plain-text `+`/`~`/`-` entries to `$LOG_FILE`, sets globals: `PARSE_TRANSFER`, `PARSE_ATTR`, `PARSE_DELETE`. No terminal output.
- **`run_dry_run` / `run_verify` / `run_sync`** — orchestrators that call both engines, write the log (header → `_process_output` → warnings → summary footer), print the summary line to terminal, and open TextEdit when there are log entries.

## Design decisions

- **`--out-format="%i %n"` must stay in all modes** — the entire output parsing pipeline depends on this format. Removing or changing it will silently break per-file output (`+`, `~`, `-` symbols).
- **Source always gets a trailing slash** — rsync: "sync contents into destination" not "create Source/ subdirectory". Set in the path normalization block; removing this breaks mirror semantics.
- **`sudo -v` is called before backgrounding rsync** — pre-authenticates so a password prompt cannot interrupt the spinner. Do not move it after the background launch.
- **`format_time()` sets global `$FTIME` instead of echoing** — avoids a subshell. Works with bash 3.2 (macOS system bash, which lacks `local -n`). Do not refactor to `echo`/`$(...)`.
- **`_process_output` globals (`PARSE_TRANSFER`, `PARSE_ATTR`, `PARSE_DELETE`) are set inside a `while ... done < file` loop** — this does NOT create a subshell in bash, so globals propagate to callers. Do not refactor to use a pipe (`| while`) which would create a subshell and break the global writes.
- **`--no-confirm` / `-y` imply sync mode** — the mode selection prompt is skipped when this flag is set. Dry-run and verify have no confirmation prompt so the flag is sync-only.
- **Spinner runs at 0.1 s/frame for animation smoothness** — 10 braille frames at 0.1 s/frame = 1 full rotation/second. `spin()` takes no `tmpfile` argument and does no I/O: no file count is shown (the count was inflated by unfiltered rsync lines, and `wc -l` re-reading a growing TMPFILE on every tick was the primary source of unnecessary I/O over long runs). `ticks` and elapsed tracking are not used in `spin()`; final elapsed is computed once in `_run_rsync` via `$SECONDS` (a bash builtin, no subshell) after `wait` returns. A start timestamp is printed by `_run_rsync` on its own line before the spinner begins.
- **Per-file output is logged, not printed to terminal** — `_process_output` appends plain-text `+`/`~`/`-` lines to `$LOG_FILE` (no ANSI codes; TextEdit renders them as garbage). Terminal output is limited to the summary counts and completion message. TextEdit opens automatically when there are entries. The log is written before the exit-code check so partial and failed runs still produce a usable log; hard-failure error messages reference `$LOG_FILE`. For verify with zero differences, TextEdit is not opened.
- **Info block is indented 2 spaces; prompts and actions are flush-left** — the block between mode selection and the Proceed?/sudo-v step (arrow line, mode note, sudo note, command) is indented 2 spaces to visually separate it from interactive prompts. Flags inside the command are at 6 spaces (2 base + 4 continuation). Proceed?, Aborted., and sudo -v are at column 0. Keep all three modes consistent if changing this.

## Rsync correctness spec

Base (all modes): `sudo rsync -aAXHN --delete --numeric-ids [--exclude-from=...] --out-format="%i %n"`
dry-run adds: `--dry-run` / verify adds: `--checksum --dry-run`

## Output parsing invariants

All parsing lives in `_process_output()`. Non-obvious constraints:

1. `*deleting ` must be matched BEFORE extracting the first-char code — `*` is also a valid itemize first char.
2. `*deleting` → `-` (red) in **all three modes**. In verify, this means "extra file in destination that sync would delete."
3. Fail-fast: `if exit≠0 && !partial → exit 1`; partial = rsync exit 23 or 24. Checked in each `run_*` handler before calling `_process_output`.
4. **Directory lines are silently filtered** — after the `*deleting` check, `filetype="${line_trimmed:1:1}"` is extracted (char 1 of the itemize string = file-type field). Any line where `filetype == "d"` is skipped with `continue`. This prevents directory-creation entries (`cd+++++++++`) from being misreported. Do not remove this check.
5. `>` → `+` (transfer needed / transferred), `x` → counted as delete. These are consistent across all three modes.
6. **`c` at position 0 covers two distinct cases** — rsync uses `c` ("local change") for both new non-directory items (symlinks, special files — which have no file data to transfer) and attribute-only updates on existing items. Distinguish them by position 2 of the itemize string: `+` means new item (all fields are `+` for new items) → report as `+` (transfer, counted in `PARSE_TRANSFER`); any other char means attribute-only update on an existing item → report as `~` (metadata, counted in `PARSE_ATTR`). Do not map all `c` entries to `~`; that incorrectly categorizes newly created symlinks as metadata updates.

## Output symbols

| Symbol | Color | Meaning |
|--------|-------|---------|
| `+` | green | File will be / was transferred (new or content-changed); also new symlinks and special files |
| `~` | yellow | Metadata will be / was updated only on an existing item (permissions, timestamps, ACLs — no data transfer) |
| `-` | red | File will be / was deleted (or is extra in destination) |

Summary line format (printed after per-file output): `  + N transfer   ~ N metadata   - N delete` — present tense for dry-run/verify; past tense for sync (`transferred` / `deleted`). Verify prints this only when differences exist; a clean match shows `Destination matches source byte-for-byte.` instead.

## Known issues (do not silently fix)

- **11-character itemize assumption** — `${line_trimmed:12}` assumes exactly 11 rsync itemize chars + 1 space before the filename. A non-standard rsync build would silently mis-parse filenames. Do not work around without understanding the full output format implications.

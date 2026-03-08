# mirra — AI working instructions

Single-file bash tool (`mirra.sh`). This file contains all invariants needed to avoid breaking the tool — do not rely on README.md being read.

## Do not add these rsync flags

- **`-i`** — equivalent to `--out-format='%i %n%L'`; `--out-format` takes precedence, making `-i` a no-op
- **`-h` / `--human-readable`** — changes rsync's stats output format and would break itemize parsing
- **`-W` (whole-file)** — rsync defaults to whole-file for local paths; a no-op
- **`-z` (compress)** — no benefit for local disk transfers; adds CPU overhead
- **`--checksum`** — verify-only; do not add to sync or dry-run (mtime+size is sufficient; checksum reads every byte)
- **`--copy-links` / `--copy-unsafe-links`** — dereferencing symlinks breaks the clone; `-l` (included in `-a`) preserves them as-is

## Design decisions

- **`--out-format="%i %n"` must stay in all modes** — the entire output parsing pipeline depends on this format. Removing or changing it will silently break `[Will copy]` / `[Differs]` / `[Summary]` output.
- **Source always gets a trailing slash** — rsync: "sync contents into destination" not "create Source/ subdirectory". Set at line ~172; removing this breaks mirror semantics.
- **`sudo -v` is called before backgrounding rsync** — pre-authenticates so a password prompt cannot interrupt the spinner. Do not move it after the background launch.
- **`format_time()` sets global `$FTIME` instead of echoing** — avoids a subshell. Works with bash 3.2 (macOS system bash, which lacks `local -n`). Do not refactor to `echo`/`$(...)`.

## Rsync correctness spec

Base (all modes): `sudo rsync -aAXHN --delete --numeric-ids --fileflags --force-change [--exclude-from=...] --out-format="%i %n"`
dry-run adds: `--dry-run` / verify adds: `--checksum --dry-run`

## Output parsing invariants

The parser runs after rsync exits and reads the captured tmpfile. All three modes share the same structure:

1. Lines starting with `.` → up-to-date, skip
2. Lines starting with `*deleting ` → deletion; check BEFORE first-char code (`*` is also a valid first char)
3. Filename starts at index 12 (11-char itemize code + 1 space) — fixed assumption
4. First char: `>` = copy/receive, `c` = attribute change, `d` = directory (skip), `x` = fileflags-extended delete
5. In **verify mode**, `*deleting` → `[Extra]` (destination-only file), not `[Will delete]`
6. Fail-fast: `if exit≠0 && !partial → exit 1`; partial = rsync exit 23 or 24

## Known issues (do not silently fix)

- **11-character itemize assumption** — `${line:12}` assumes exactly 11 rsync itemize chars + 1 space before the filename. A non-standard rsync build would silently mis-parse filenames. Do not work around without understanding the full output format implications.

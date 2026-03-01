# mirra — AI working instructions

Single-file bash tool (`mirra.sh`). Read the code and `README.md` for full context. This file exists solely to give Claude the non-obvious design rationale and invariants needed to avoid breaking things.

## Design decisions

- **`--out-format="%i %n"` must stay in all modes** — the entire output parsing pipeline depends on this format. Removing or changing it will silently break `[Will copy]` / `[Differs]` / `[Summary]` output.
- **`-i` is intentionally absent** — it is equivalent to `--out-format='%i %n%L'`; when `--out-format` is also specified it takes precedence, making `-i` a no-op.
- **`-h` is intentionally absent** — adding `--human-readable` changes rsync's stats output format and would break itemize parsing.
- **`-W` (whole-file) is intentionally absent** — rsync already defaults to whole-file transfers for local-to-local paths; adding it would be a no-op.
- **`-z` (compress) is intentionally absent** — no benefit for local disk transfers; adds CPU overhead.
- **`--checksum` is intentionally absent from sync and dry-run** — modification time + size comparison is correct and fast for a mirror; `--checksum` reads every byte on both sides and is only used in verify mode for byte-for-byte validation.
- **`--copy-links` and `--copy-unsafe-links` are intentionally absent** — `-l` (included in `-a`) preserves symlinks as-is, which is correct for a true clone. Dereferencing symlinks changes the filesystem structure: symlinks become file copies, multiple symlinks to the same file get duplicated, and symlinks pointing outside the source volume pull in external content.
- **Source always gets a trailing slash** (`/Volumes/Source/`) — rsync convention meaning "sync the contents of source into destination", not "create a Source/ subdirectory inside destination". Set at line ~172; removing this breaks the mirror semantics.
- **`sudo -v` is called before backgrounding rsync** — pre-authenticates so a password prompt cannot interrupt the spinner. Do not move it after the background launch.
- **`format_time()` sets global `$FTIME` instead of echoing** — avoids a subshell. Works with bash 3.2 (macOS system bash, which lacks `local -n` namereferences). Do not refactor to `echo`/`$(...)`.

## Output parsing invariants

The parser runs after rsync exits and reads the captured tmpfile. All three modes share the same structure; maintain consistency across them:

1. Lines starting with `.` → up-to-date file, skip
2. Lines starting with `*deleting ` → deletion event; check this BEFORE checking the first character code (the `*` character is also a valid first char)
3. First character of itemize code is the update type; filename starts at index 12 (11-char code + 1 space); this is a known fixed assumption
4. Update type characters: `>` = copy/receive, `c` = attribute change, `d` = directory (skip), `x` = fileflags-extended delete
5. In **verify mode**, `*deleting` means the file exists on the destination but not the source → label as `[Extra]`, not `[Will delete]`
6. All three modes use the **fail-fast pattern**: `if exit≠0 && !partial → exit 1`; partial = rsync exit codes 23 or 24 (partial transfer); do not invert this to a success-first check

## Rsync commands (correctness spec)

Use these as a reference when verifying that changes produce the correct rsync invocation. The exact command is always shown in the confirmation prompt before execution.

**Dry run** — previews changes, writes nothing
```
sudo rsync -aAXHN --delete --numeric-ids --fileflags --force-change \
  [--exclude-from="exclusions.txt"] \
  --dry-run --out-format="%i %n" \
  "/Volumes/Source/" "/Volumes/Destination"
```

**Sync** — performs the actual mirror
```
sudo rsync -aAXHN --delete --numeric-ids --fileflags --force-change \
  [--exclude-from="exclusions.txt"] \
  --out-format="%i %n" \
  "/Volumes/Source/" "/Volumes/Destination"
```

**Verify** — byte-for-byte checksum comparison, writes nothing
```
sudo rsync -aAXHN --delete --numeric-ids --fileflags --force-change \
  [--exclude-from="exclusions.txt"] \
  --checksum --dry-run --out-format="%i %n" \
  "/Volumes/Source/" "/Volumes/Destination"
```

## Known issues (do not silently fix)

- **ANSI codes in `rsync.log`** — the itemize output captured to the log contains raw color codes because the same output stream is used for both terminal display and log writing. Fixing this properly requires two separate output paths (one stripped, one colored); do not strip colors from the main pipeline without that separation.
- **11-character itemize assumption** — `${line:12}` assumes exactly 11 rsync itemize characters + 1 space before the filename. A non-standard rsync build or unexpected output format would silently mis-parse filenames. This is a documented limitation; do not work around it without understanding the full output format implications.

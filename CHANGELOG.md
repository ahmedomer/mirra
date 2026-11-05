# Changelog

All notable changes to mirra are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and mirra uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/); entries before 0.4.0 were reconstructed from the git history.

## Unreleased

### Fixes

- Run rsync under sudo by the absolute path that was checked at startup, so sudo's restricted `PATH` can no longer swap in Apple's `/usr/bin/rsync`. The command preview now shows the full path.
- **preflight:** an empty volume root (only `.fseventsd`, `.Spotlight-V100`, etc.) now counts as an empty source; entries listed in `exclusions.txt` are ignored instead of only `.DS_Store`.
- **verify:** count metadata-only differences (`.f...p.....`, extended attributes) and hard links (`hf...`) instead of silently dropping them; verify previously reported a byte-for-byte match when only these differed. Sync and dry-run counts are fixed the same way.
- **verify:** a partial verify (rsync exit 23/24) no longer prints "Destination matches source byte-for-byte", and now shows the log path.
- Refuse source and destination paths that overlap (one inside the other); syncing a folder into its own parent deleted the source.
- Interactive path prompts expand a leading `~`.
- The spinner is not drawn when output is redirected to a file or pipe.
- README: the verify example with differences no longer shows a success line the script never prints.
- Interrupting a run (Ctrl+C, TERM, HUP) now writes the log of what rsync had done so far instead of discarding it.
- **preflight:** detect an unmounted `/Volumes/<name>` folder by comparing against the volume `/Volumes` lives on, instead of a hardcoded list of boot-volume mount points.

### Performance

- Open the run log once per run instead of once per logged file, and drop the per-line regex in output parsing.
- Look up each volume's mount info once instead of up to three times, and stop the empty check at the first entry instead of listing and sorting the whole directory.

### Refactoring

- Replace the `DRY_RUN`/`VERIFY` booleans with a single `MODE`, and the three per-mode run functions with one `run_mode`.
- Extract `_err`, `_warn`, `_confirm_or_abort` and `_prompt_dir`; simplify test helpers.

## 0.4.0 - 2026-11-03

### ⚠ Breaking changes

- Removed `--no-confirm` and `-y`. Sync always shows the command preview and requires an explicit `y`; both flags are now rejected as unknown.

### Features

- **preflight:** refuse source or destination volumes that are not APFS.
- **preflight:** warn before syncing when a `/Volumes/<name>` path is a leftover folder on the internal disk (drive not connected), when the source is empty but the destination is not, or when a volume has *Ignore ownership* enabled. Sync asks to continue; dry-run and verify only warn.
- Print a Full Disk Access hint when rsync reports "Operation not permitted".

### Fixes

- Filenames starting with `-` no longer corrupt deletion entries in the log ([#12](https://github.com/ahmedomer/mirra/pull/12)).

### Docs

- Document APFS-only scope, the safety checks, and what mirra doesn't do.
- Adopt Conventional Commits and add this changelog.

## [0.3.0] - 2026-05-19

### Features

- Retry mode selection on invalid input and clarify partial-run warnings ([#8](https://github.com/ahmedomer/mirra/pull/8)).
- Detect Apple's bundled rsync at startup and open the log with the system default viewer ([#9](https://github.com/ahmedomer/mirra/pull/9)).
- Show accurate elapsed time in the spinner and prevent idle and disk sleep with `caffeinate` during a run ([#10](https://github.com/ahmedomer/mirra/pull/10)).

### Changes

- Write the log to the user-private `$TMPDIR` with `600` permissions, one file per run ([#6](https://github.com/ahmedomer/mirra/pull/6)).

### Fixes

- Remove the sudo keep-alive loop, a Ctrl+Z handler that killed instead of suspending, and dead whitespace trimming ([#7](https://github.com/ahmedomer/mirra/pull/7)).

## [0.2.0] - 2026-05-19

### Features

- Log every mode to a structured run log and open it when there are entries ([#4](https://github.com/ahmedomer/mirra/pull/4)).

### Fixes

- Report new symlinks and special files as transfers instead of metadata updates ([#2](https://github.com/ahmedomer/mirra/pull/2)).

### Performance

- Simplify the spinner: drop the file count that re-read the output file on every tick, and fix elapsed time ([#3](https://github.com/ahmedomer/mirra/pull/3)).

### Docs

- Add CONTRIBUTING.md ([#1](https://github.com/ahmedomer/mirra/pull/1)).

## [0.1.0] - 2026-05-15

- Initial release: dry-run, sync, and verify modes over `rsync -aAXHN --delete --numeric-ids`.

[0.3.0]: https://github.com/ahmedomer/mirra/compare/5c86b9d...d4dfd67
[0.2.0]: https://github.com/ahmedomer/mirra/compare/30ad77d...5c86b9d
[0.1.0]: https://github.com/ahmedomer/mirra/commit/30ad77d

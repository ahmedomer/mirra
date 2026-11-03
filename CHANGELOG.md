# Changelog

All notable changes to mirra are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and mirra uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/); entries before 0.4.0 were reconstructed from the git history.

## [Unreleased]

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

[Unreleased]: https://github.com/ahmedomer/mirra/compare/d4dfd67...HEAD
[0.3.0]: https://github.com/ahmedomer/mirra/compare/5c86b9d...d4dfd67
[0.2.0]: https://github.com/ahmedomer/mirra/compare/30ad77d...5c86b9d
[0.1.0]: https://github.com/ahmedomer/mirra/commit/30ad77d

# mirra

Mirra is a macOS command-line tool powered by rsync that keeps a destination folder as an exact one-way replica of its source — including every file, permission, and metadata. It is built for APFS volumes.

## Features

- **Exact mirror** — destination is always a perfect replica; files removed from source are removed from destination on the next sync
- **Dry run before you sync** — preview every change (`+` copy, `~` metadata, `-` delete) without writing anything
- **Full metadata preservation** — ownership, permissions, ACLs, extended attributes, hard links, and creation times all preserved
- **Safety checks before every run** — refuses non-APFS volumes and warns before syncing to a disconnected drive, from an empty source, or onto a volume that ignores ownership
- **Always confirms** — sync shows the exact command and never runs without an explicit `y`
- **Symlink-accurate** — symlinks are preserved as symlinks, maintaining exact filesystem structure
- **Smart exclusions** — macOS volume metadata (`.Spotlight-V100`, `.Trashes`, `.DS_Store`, etc.) excluded automatically via `exclusions.txt`
- **Verify mode** — byte-for-byte checksum comparison against source without writing anything; reports mismatched, missing, and extra files
- **Animated progress** — braille spinner with accurate elapsed time; zero I/O overhead during the transfer
- **Run log** — every run writes a structured log (`mirra-<mode>-<timestamp>.log`) to your private temp directory, opened automatically when there are changes; plain text, no ANSI codes
- **Consistent output** — the same `+` / `~` / `-` symbols and summary format across dry-run, sync, and verify

## Requirements & macOS Gotchas

- **macOS**
- **Modern rsync:** Apple's built-in rsync is missing flags mirra depends on. Install a modern version via [Homebrew](https://brew.sh): `brew install rsync`.
- **APFS only:** Both source and destination must be on **APFS** volumes. Other filesystems (exFAT, FAT, network shares) cannot hold the full set of macOS metadata, so mirra refuses them.
- **Full Disk Access:** Since macOS Mojave, Apple restricts file access even for root. Grant "Full Disk Access" to your Terminal (or iTerm2) via *System Settings > Privacy & Security > Full Disk Access*, or rsync will throw "Operation not permitted" errors on protected directories. mirra prints a hint when this happens.
- **Ownership on external drives:** macOS enables *Ignore ownership on this volume* by default on external drives, which silently drops owners and permissions. mirra warns about it; turn it off with `sudo diskutil enableOwnership "/Volumes/<name>"` or in the drive's Get Info window.
- **Data Drives Only:** Mirra cannot create a bootable macOS backup due to Apple's cryptographically sealed Signed System Volume (SSV).

### A note on `sudo` and Homebrew rsync

Mirra uses `sudo` to preserve exact permissions, ownership, and ACLs. macOS configures `sudo` with a restricted `PATH` that may not include Homebrew, so mirra resolves rsync from your own `PATH` and runs it by absolute path (for example `sudo /opt/homebrew/bin/rsync`). The command preview shows exactly which binary will run. If your `PATH` resolves to Apple's `/usr/bin/rsync`, mirra stops and asks you to install Homebrew rsync and put Homebrew ahead of `/usr/bin`.

## Installation

```bash
git clone https://github.com/ahmedomer/mirra.git
cd mirra
chmod +x mirra.sh
```

## Usage

```bash
./mirra.sh [--dry-run|--verify] [<source> <destination>]
./mirra.sh --version
./mirra.sh --help
```

Run without arguments for fully interactive mode.

### Interactive session

Mirra prompts for source and destination paths (with readline editing and tab completion), then a mode selection:

```
Source path:      /Volumes/Extreme SSD

Destination path: /Volumes/Backup

Mode:
  [1] Dry run  (default)
  [2] Sync
  [3] Verify
Select: 
```

After selecting a mode, mirra shows a focused summary of what will happen before proceeding:

```
  /Volumes/Extreme SSD  →  /Volumes/Backup
  Preview only — no files will be modified.
  sudo may prompt for your password to preserve file permissions and ACLs.

  sudo /opt/homebrew/bin/rsync \
      -aAXHN \
      --delete \
      --numeric-ids \
      --exclude-from=/path/to/mirra/exclusions.txt \
      --dry-run \
      "--out-format=%i %n" \
      "/Volumes/Extreme SSD/" \
      "/Volumes/Backup"
```

### Dry run

Preview what would change without writing anything. The terminal shows the summary; the full per-file list goes to the log:

```
Started: Mon 19 May 2026 08:33:43
⠋ Dry run...  0s

  + 3 transfer   ~ 1 metadata   - 1 delete
Log: /var/folders/.../T/mirra-dry-run-20260519-083343.log
✓ Dry run completed in 2s.
```

| Symbol | Meaning |
|--------|---------|
| `+` | File will be / was transferred (new or content-changed; includes new symlinks and special files) |
| `~` | Metadata only will be / was updated on an existing item (permissions, timestamps, ACLs — no data transfer) |
| `-` | File will be / was deleted from destination (or is extra in destination during verify) |

### Sync

Mirror source to destination (requires sudo for full metadata preservation). Asks for confirmation before proceeding:

```
Proceed? [y/N]: y

Started: Mon 19 May 2026 08:33:43
⠋ Syncing...  8s

  + 3 transferred   ~ 1 metadata   - 1 deleted
Log: /var/folders/.../T/mirra-sync-20260519-083343.log
✓ Sync completed in 9s.
```

The full per-file change list, any rsync warnings, and a summary are written to a structured log in your private temp directory (`$TMPDIR`). The log opens automatically when there are entries. Each run creates a new timestamped file — no previous log is overwritten.

### Verify

Compare every file byte-for-byte against the source using checksums. Nothing is written. Reports files that differ, are missing, or exist only on destination:

```
Started: Mon 19 May 2026 08:33:43
⠋ Verifying...  42s

  + 1 transfer   ~ 0 metadata   - 1 delete
[Warning] Differences found in 43s — run Sync to resolve.
Log: /var/folders/.../T/mirra-verify-20260519-083343.log
✓ Verify completed in 43s.
```

When destination matches source exactly, no log is opened:

```
  Destination matches source byte-for-byte.
✓ Verify completed in 43s.
```

Verify reads every byte on both sides, so it is slower than a dry run on large volumes.

### Non-interactive

Pass paths directly to skip the path prompts. Pass `--dry-run` or `--verify` to skip the mode menu:

```bash
./mirra.sh /Volumes/Source /Volumes/Destination
./mirra.sh --dry-run /Volumes/Source /Volumes/Destination
./mirra.sh --verify /Volumes/Source /Volumes/Destination
```

Sync has no flag and always asks `Proceed? [y/N]` after showing the exact command. There is deliberately no way to skip this confirmation.

Paths can include a trailing slash — mirra normalises them automatically (source always gets a trailing slash, destination never does).

### Safety checks

Before anything runs, mirra checks the source and destination volumes:

| Check | Result |
|---|---|
| Source or destination is not on APFS | **Error** — mirra stops |
| A `/Volumes/<name>` path is a leftover folder on the internal disk (the drive isn't connected) | Warning |
| Source is empty but destination is not (sync would delete everything); names in `exclusions.txt` such as `.DS_Store` and `.fseventsd` don't count | Warning |
| A volume has *Ignore ownership* enabled (owners and permissions would be lost) | Warning, with the fix |

In dry-run and verify, warnings are printed and the run continues — nothing is written. In sync, each warning asks `Continue anyway? [y/N]`, and anything but `y` aborts before rsync starts.

## What mirra doesn't do

mirra does one thing: an on-demand, one-way mirror between APFS volumes. It deliberately does not:

- **Keep file history.** The destination is an exact mirror; a file deleted or damaged in the source is deleted or damaged in the destination on the next sync. Use a versioned backup alongside mirra if you need history.
- **Schedule runs.** Every sync is started and confirmed by you.
- **Preserve BSD file flags** (such as `hidden` or `uchg`/locked). Homebrew rsync has no support for them.
- **Make bootable copies.** Apple's Signed System Volume cannot be copied with rsync.
- **Copy from a point-in-time snapshot.** Files that change while a sync is running may be copied mid-change; quit apps that write to the source before syncing, and run Verify afterwards.

## rsync flags

| Flag | Purpose |
|---|---|
| `-a` | Archive mode: recursive, preserves modification times, permissions, owner, group, and device files |
| `-A` | Preserve ACLs (Access Control Lists) |
| `-X` | Preserve extended attributes (xattrs) |
| `-H` | Preserve hard links |
| `-N` | Preserve file creation times (birth times) |
| `--delete` | Remove files from destination that no longer exist in source |
| `--numeric-ids` | Preserve exact numeric UID/GID values without name mapping |
| `--out-format="%i %n"` | Structured itemize output used for parsing — present in all modes |
| `--dry-run` | Added in dry-run and verify modes; rsync scans but writes nothing |
| `--checksum` | Added in verify mode; forces byte-for-byte comparison instead of mtime+size |

### Why mirra manages its own log instead of using `--log-file`

rsync has a built-in `--log-file` option. mirra does not use it because it is unreliable in dry-run and verify modes.

`--log-file` only records completed operations. In dry-run and verify, file transfers are simulated and never actually complete, so rsync silently drops them from the log. Empirically: a run with four events (new file, metadata-only update, new symlink, deletion) produced all four lines via `--out-format` but only one line via `--log-file`. A dry-run log built on `--log-file` would be misleadingly sparse.

`--out-format` fires during file-list iteration — before any write decision — so it captures every affected item consistently across all three modes. The custom log pipeline (`_process_output`) then maps rsync's 11-character itemize codes to the readable `+` / `~` / `-` symbols; that conditional logic cannot be expressed in rsync's format strings.

## Exclusions

`exclusions.txt` (in the same directory as the script) lists paths excluded from the sync. It uses rsync's `--exclude-from` format:

- Paths starting with `/` are anchored to the **source root** (e.g. `/.Trashes`)
- Paths without a leading `/` match at **any depth** (e.g. `.DS_Store`)

The default `exclusions.txt` covers macOS volume metadata. Edit it freely to add your own exclusions. If the file is absent, mirra continues without exclusions and prints a notice.

## Testing

The test suite validates rsync command construction in each mode. Tests require [bats-core](https://github.com/bats-core/bats-core):

```bash
brew install bats-core
bats tests/command_generation.bats
```

The tests cover all three modes (dry-run, sync, verify) with and without `exclusions.txt`, the mandatory sync confirmation (`--no-confirm` / `-y` are rejected, and declining aborts before rsync runs), the safety checks (using mocked `df` and `mount`), and the Full Disk Access hint. Command tests verify flag composition, exact source and destination path values, trailing-slash rules, and argument ordering.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE)

# mirra

Mirra is a macOS command-line tool powered by rsync that keeps a destination folder as an exact one-way replica of its source — including every file, permission, and metadata.

## Features

- **Exact mirror** — destination is always a perfect replica; files removed from source are removed from destination on the next sync
- **Dry run before you sync** — preview every change (`+` copy, `~` metadata, `-` delete) without writing anything
- **Full metadata preservation** — ACLs, extended attributes, hard links, and APFS/HFS+ creation times all preserved
- **Symlink-accurate** — symlinks are preserved as symlinks, maintaining exact filesystem structure
- **Smart exclusions** — macOS volume metadata (`.Spotlight-V100`, `.Trashes`, `.DS_Store`, etc.) excluded automatically via `exclusions.txt`
- **Verify mode** — byte-for-byte checksum comparison against source without writing anything; reports mismatched, missing, and extra files
- **Animated progress** — braille spinner with live file count and elapsed time
- **Consistent output** — the same `+` / `~` / `-` symbols and summary format across dry-run, sync, and verify

## Requirements & macOS Gotchas

- **macOS**
- **Modern rsync:** Apple's built-in rsync is missing flags mirra depends on. Install a modern version via [Homebrew](https://brew.sh): `brew install rsync`.
- **Full Disk Access:** Since macOS Mojave, Apple restricts file access even for root. Grant "Full Disk Access" to your Terminal (or iTerm2) via *System Settings > Privacy & Security > Full Disk Access*, or rsync will throw "Operation not permitted" errors on protected directories.
- **Target File System:** The destination must be formatted as **APFS** or **Mac OS Extended (Journaled)**. ExFAT does not support macOS extended attributes or BSD file flags — a true 1:1 clone is not possible.
- **Data Drives Only:** Mirra cannot create a bootable macOS backup due to Apple's cryptographically sealed Signed System Volume (SSV).

### A note on `sudo` and Homebrew rsync

Mirra uses `sudo` to preserve exact permissions, ownership, and ACLs. macOS configures `sudo` with a restricted `PATH` that may not include Homebrew, causing `sudo` to fall back to Apple's built-in rsync.

If mirra fails with `rsync: illegal option -- N`, verify which rsync `sudo` actually uses:

```bash
sudo which rsync
```

This should output the Homebrew path (`/opt/homebrew/bin/rsync` on Apple Silicon, `/usr/local/bin/rsync` on Intel). If it outputs `/usr/bin/rsync`, add the Homebrew bin directory to `/etc/paths`, or update `secure_path` in `/etc/sudoers` via `sudo visudo`.

## Installation

```bash
git clone https://github.com/ahmedomer/mirra.git
cd mirra
chmod +x mirra.sh
```

## Usage

```bash
./mirra.sh [--dry-run|--verify|--no-confirm|-y] [<source> <destination>]
./mirra.sh --version
./mirra.sh --help
```

Run without arguments for fully interactive mode.

### Interactive session

Mirra prompts for source and destination paths (with readline editing and tab completion), then a mode selection:

```
Source path:      /Volumes/Extreme SSD

Destination path: /Volumes/Backup

Mode: [1] Dry run  [2] Sync  [3] Verify: 
```

After selecting a mode, mirra shows a focused summary of what will happen before proceeding:

```
  /Volumes/Extreme SSD  →  /Volumes/Backup
  Preview only — no files will be modified.
  sudo may prompt for your password to preserve file permissions and ACLs.

  sudo rsync \
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

Preview what would change without writing anything. Each file is labeled with its action:

```
+ Documents/report.pdf
~ Photos/vacation.jpg
- Desktop/old_notes.txt

  + 3 transfer   ~ 1 metadata   - 1 delete
✓ Dry run completed in 2s.
```

| Symbol | Meaning |
|--------|---------|
| `+` | File will be transferred (new or content-changed) |
| `~` | Metadata only will be updated (permissions, timestamps, ACLs — no data transfer) |
| `-` | File will be deleted from destination |

### Sync

Mirror source to destination (requires sudo for full metadata preservation). Asks for confirmation before proceeding:

```
Proceed? [y/N]: y
⠋ Syncing...  1,204 files  8s

+ Documents/report.pdf
~ Photos/vacation.jpg
- Desktop/old_notes.txt

  + 3 transferred   ~ 1 metadata   - 1 deleted
✓ Sync completed in 9s.
```

Full rsync output is also written silently to `rsync.log` (in the same directory as the script) as an archive.

### Verify

Compare every file byte-for-byte against the source using checksums. Nothing is written. Reports files that differ, are missing, or exist only on destination:

```
⠋ Verifying...  1,204 files  42s
+ Documents/report.pdf
- old-folder/archive.zip

  + 1 transfer   ~ 0 metadata   - 1 delete
[Warning] Differences found in 43s — run Sync to resolve.
```

When destination matches source exactly:

```
  Destination matches source byte-for-byte.
✓ Verify completed in 43s.
```

Verify reads every byte on both sides, so it is slower than a dry run on large volumes.

### Non-interactive

Pass paths directly to skip the interactive prompts. Pass `--dry-run` or `--verify` to skip the mode menu:

```bash
./mirra.sh /Volumes/Source /Volumes/Destination
./mirra.sh --dry-run /Volumes/Source /Volumes/Destination
./mirra.sh --verify /Volumes/Source /Volumes/Destination
```

Use `--no-confirm` (or `-y`) to sync without a confirmation prompt — useful for scripted or automated use:

```bash
./mirra.sh --no-confirm /Volumes/Source /Volumes/Destination
./mirra.sh -y /Volumes/Source /Volumes/Destination
```

Paths can include a trailing slash — mirra normalises them automatically (source always gets a trailing slash, destination never does).

## rsync flags

| Flag | Purpose |
|---|---|
| `-a` | Archive mode: recursive, preserves modification times, permissions, owner, group, and device files |
| `-A` | Preserve ACLs (Access Control Lists) |
| `-X` | Preserve extended attributes (xattrs) |
| `-H` | Preserve hard links |
| `-N` | Preserve file creation times (APFS/HFS+ birth times) |
| `--delete` | Remove files from destination that no longer exist in source |
| `--numeric-ids` | Preserve exact numeric UID/GID values without name mapping |
| `--out-format="%i %n"` | Structured itemize output used for parsing — present in all modes |
| `--dry-run` | Added in dry-run and verify modes; rsync scans but writes nothing |
| `--checksum` | Added in verify mode; forces byte-for-byte comparison instead of mtime+size |

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

Eight tests cover all three modes (dry-run, sync, verify) with and without `exclusions.txt`, plus `--no-confirm` and `-y`. Each test verifies flag composition, exact source and destination path values, trailing-slash rules, and argument ordering.

## Contributing

PRs are welcome. Run the test suite before submitting:

```bash
brew install bats-core   # first time only
bats tests/command_generation.bats
```

## License

MIT — see [LICENSE](LICENSE)

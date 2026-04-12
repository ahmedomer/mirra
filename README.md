# mirra

```
 ▐▛▀▀▜▌   mirra
▗▟▌  ▐▙▖  macOS rsync mirror
```

Mirror your drives with precision. Mirra is a macOS command-line tool powered by rsync that keeps a destination as an exact one-way replica of its source — including every file, permission, and metadata.

## Features

- **Exact mirror** — destination is always a perfect replica; files removed from source are removed from destination on the next run
- **Dry run before you sync** — dry-run mode previews every change (copies, deletions, attribute updates) without writing anything
- **Full metadata preservation** — ACLs, extended attributes, hard links, BSD file flags (`chflags`), and APFS/HFS+ creation times all preserved
- **Symlink-accurate** — symlinks on source are preserved as symlinks on destination, maintaining exact filesystem structure
- **Smart exclusions** — macOS volume metadata (`.Spotlight-V100`, `.Trashes`, `.DS_Store`, etc.) excluded automatically via `exclusions.txt`
- **Verify mode** — byte-for-byte checksum comparison against source without writing anything; reports mismatched, missing, and extra files
- **Animated progress** — braille spinner with elapsed time during sync, dry run, and verify
- **Run summary** — files copied, attribute changes, and deletions reported on completion

## Requirements & macOS Gotchas

To achieve a true 1:1 clone on macOS, there are a few strict system requirements and Apple-specific limitations to be aware of:

- **macOS**
- **Modern rsync:** Apple's built-in rsync does not support `--fileflags` or several other flags mirra depends on. Install a modern version via [Homebrew](https://brew.sh): `brew install rsync`.
- **Full Disk Access:** Since macOS Mojave, Apple restricts file access even for the root user. You **must** grant "Full Disk Access" to your Terminal application (or iTerm2) via *System Settings > Privacy & Security > Full Disk Access*, or the script will throw "Operation not permitted" errors on protected directories.
- **Target File System:** The destination drive must be formatted as **APFS** or **Mac OS Extended (Journaled)**. Formats like ExFAT do not support macOS extended attributes (`xattrs`) or BSD file flags — rsync will silently skip preserving them, making a true 1:1 clone impossible.
- **Data Drives Only:** Mirra is designed for data, media, and project drives. It cannot create a bootable backup of a macOS installation due to Apple's cryptographically sealed Signed System Volume (SSV).

### A note on `sudo` and Homebrew rsync

Mirra requires `sudo` to preserve exact user permissions, ownership, and file flags. However, macOS configures `sudo` with its own restricted `PATH` (via `/etc/sudoers`), which may not include Homebrew — causing `sudo` to fall back to Apple's built-in rsync regardless of what `which rsync` shows for your user.

If mirra fails with an error like `rsync: illegal option -- N`, check which rsync `sudo` is actually using:

```bash
sudo which rsync
```

This should output the Homebrew path (`/opt/homebrew/bin/rsync` on Apple Silicon, `/usr/local/bin/rsync` on Intel). If it outputs `/usr/bin/rsync`, add the Homebrew bin directory to the front of `/etc/paths` (requires a shell restart), or update `secure_path` in `/etc/sudoers` via `sudo visudo`.

## Installation

```bash
git clone https://github.com/ahmedomer/mirra.git
cd mirra
chmod +x mirra.sh
```

## Usage

```bash
./mirra.sh
```

On launch, mirra detects connected volumes and walks you through three prompts:

```
Select source:
  ❯ Extreme SSD
    Primary

Select destination:
  ❯ Primary

Select mode:
  ❯ Dry run  preview changes without syncing
    Sync     mirror source to destination
    Verify   check destination matches source byte-for-byte
```

### Dry run

Select **Dry run** to preview what would change without writing anything:

```
[Info] Running in dry-run mode.
[Info] /Volumes/Extreme SSD/  →  /Volumes/Primary
[Info] Source will not be modified. Destination will be made an exact replica.
[Info] sudo is required to preserve ACLs, permissions, and file flags across volumes.

sudo rsync --dry-run ... "/Volumes/Extreme SSD/" "/Volumes/Primary"
⠋ Dry run... 1s
[Will copy]   Documents/report.pdf
[Will delete] old-folder/
[Summary] 1 file will copy, 0 with attribute changes, 1 would be deleted. (2s)
[Success] Dry run completed successfully.
```

### Sync

Select **Sync** to run the actual mirror (requires sudo for full metadata preservation):

```
[Info] Running in sync mode.
[Info] /Volumes/Extreme SSD/  →  /Volumes/Primary
[Info] Source will not be modified. Destination will be made an exact replica.
[Info] sudo is required to preserve ACLs, permissions, and file flags across volumes.

sudo rsync ... "/Volumes/Extreme SSD/" "/Volumes/Primary"
Proceed? [y/N]: y
⠋ Syncing... 3s
[Summary] 1 file copied, 0 with attribute changes, 1 deleted. (4s)
[Info] Full output logged to /path/to/rsync.log
[Success] Sync completed successfully.
```

### Verify

Select **Verify** to compare every file byte-for-byte against the source using checksums. Nothing is written. Reports files that differ, are missing, or exist only on the destination:

```
[Info] Running in verify mode.
[Info] /Volumes/Extreme SSD/  →  /Volumes/Primary
[Info] Neither source nor destination will be modified.
[Info] sudo is required to preserve ACLs, permissions, and file flags across volumes.

sudo rsync --checksum --dry-run ... "/Volumes/Extreme SSD/" "/Volumes/Primary"
⠋ Verifying... 12s
[Differs] Documents/report.pdf
[Extra]   old-folder/archive.zip
[Summary] 1 files differ or missing, 1 extra on destination. (13s)
[Warning] Differences found — run Sync to resolve.
```

Verify reads all data on both sides, so it is slower than a dry run on large volumes.

### Non-interactive (scripting)

Pass paths directly to skip the drive menus. Pass `--dry-run` or `--verify` to skip the mode menu:

```bash
./mirra.sh <source> <destination>
./mirra.sh --dry-run <source> <destination>
./mirra.sh --verify <source> <destination>
```

To skip the interactive confirmation, pipe `y`:

```bash
echo y | ./mirra.sh --dry-run /Volumes/Source /Volumes/Destination
```

## rsync flags

Mirra uses a carefully chosen set of rsync flags to produce a complete, exact mirror.

| Flag | Purpose |
|---|---|
| `-a` | Archive mode: recursive, preserves modification times, permissions, owner, group, and device files |
| `-A` | Preserve ACLs (Access Control Lists) |
| `-X` | Preserve extended attributes (xattrs) |
| `-H` | Preserve hard links |
| `-N` | Preserve file creation times (APFS/HFS+ birth times) |
| `--delete` | Remove files from destination that no longer exist in source |
| `--numeric-ids` | Preserve exact numeric UID/GID values without name mapping — correct for an exact replica, especially when the destination was formatted on a different system |
| `--fileflags` | Preserve macOS BSD file flags (e.g. `uchg`, set via `chflags`) |
| `--force-change` | Temporarily clear immutable flags on destination files before writing — required because `--fileflags` copies immutable flags to the destination, which would block future syncs without this |

## Exclusions

`exclusions.txt` (in the same directory as the script) lists paths excluded from the sync. It uses rsync's `--exclude-from` format:

- Paths starting with `/` are anchored to the **source root** — use this for volume-level directories (e.g. `/.Trashes`)
- Paths without a leading `/` match at **any depth** — use this for files that appear everywhere (e.g. `.DS_Store`)

The default `exclusions.txt` covers macOS volume metadata directories. Edit it to add your own exclusions.

## Testing

The test suite validates that mirra constructs the correct rsync command in each mode. Tests require [bats-core](https://github.com/bats-core/bats-core):

```bash
brew install bats-core
bats tests/command_generation.bats
```

The suite covers all three modes (dry-run, sync, verify), with and without an `exclusions.txt`, verifying flag composition, source trailing slash, and destination path handling.

## License

MIT — see [LICENSE](LICENSE)

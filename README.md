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

## Requirements

- macOS
- rsync with `--fileflags` support (the system rsync on macOS does not support this; install via [Homebrew](https://brew.sh): `brew install rsync`)

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
Proceed? [y/N]: y
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
Proceed? [y/N]: y
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

**Intentionally omitted:**

- `-z` (compress) — no benefit for local disk-to-disk transfers; adds CPU overhead
- `-W` (whole-file) — rsync already uses whole-file transfers by default for local paths; specifying it would be a no-op
- `--checksum` — modification time + size comparison is sufficient for a mirror and avoids reading every byte on disk; used in **Verify mode** only for byte-for-byte comparison
- `--copy-links` / `--copy-unsafe-links` — dereferencing symlinks changes the filesystem structure; the destination would receive copies of symlink targets rather than the symlinks themselves, which is not a true clone; `-l` (included in `-a`) preserves symlinks as-is
- `-i` — equivalent to `--out-format='%i %n%L'`; redundant when `--out-format="%i %n"` is already specified, which takes precedence

## Rsync command reference

These are the exact commands mirra assembles and runs for each mode (with `exclusions.txt` present):

**Dry run**
```bash
sudo rsync -aAXHN --delete --numeric-ids --fileflags --force-change \
  --exclude-from="/path/to/exclusions.txt" \
  --dry-run --out-format="%i %n" \
  "/Volumes/Source/" "/Volumes/Destination"
```

**Sync**
```bash
sudo rsync -aAXHN --delete --numeric-ids --fileflags --force-change \
  --exclude-from="/path/to/exclusions.txt" \
  --out-format="%i %n" \
  "/Volumes/Source/" "/Volumes/Destination"
```

**Verify**
```bash
sudo rsync -aAXHN --delete --numeric-ids --fileflags --force-change \
  --exclude-from="/path/to/exclusions.txt" \
  --checksum --dry-run --out-format="%i %n" \
  "/Volumes/Source/" "/Volumes/Destination"
```

The full command (with actual paths) is always shown in the confirmation prompt before anything runs. To skip the interactive confirmation, pipe `y` to the script:

```bash
echo y | ./mirra.sh --dry-run /Volumes/Source /Volumes/Destination
```

## Exclusions

`exclusions.txt` (in the same directory as the script) lists paths excluded from the sync. It uses rsync's `--exclude-from` format:

- Paths starting with `/` are anchored to the **source root** — use this for volume-level directories (e.g. `/.Trashes`)
- Paths without a leading `/` match at **any depth** — use this for files that appear everywhere (e.g. `.DS_Store`)

The default `exclusions.txt` covers macOS volume metadata directories. Edit it to add your own exclusions.

## License

MIT — see [LICENSE](LICENSE)

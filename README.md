# sqfs_tool.sh

A tool for unpacking and repacking flash memory dumps containing squashfs partitions.

Auto-detects squashfs offset, size, and compression settings using `binwalk` and `unsquashfs`.

## Usage

```bash
# Extract the squashfs filesystem
./sqfs_tool.sh unpack <flash_dump.bin>

# Edit files in squashfs_root/, then repack
./sqfs_tool.sh repack <flash_dump.bin>
```

Repack automatically compares your changes against the original and reports any added, removed, or modified files before writing the output.

## Options

| Flag     | Description                                      |
|----------|--------------------------------------------------|
| `-d DIR` | Extraction directory (default: `squashfs_root`)   |
| `-o FILE`| Output filename (default: `modified_<input.bin>`) |

## Dependencies

`binwalk`, `squashfs-tools` (`unsquashfs` / `mksquashfs`), `coreutils` (`dd`, `sha256sum`)

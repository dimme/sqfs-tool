#!/usr/bin/env bash
set -euo pipefail

# Default values, may be overwritten during execution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNPACK_DIR="squashfs_root"
OUTPUT_FILE=""
COMP="xz"
BLOCK_SIZE=262144

# Print a command before running it
run_cmd() {
    echo "  \$ $*"
    "$@"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options] <flash_dump.bin>

A tool for unpacking and repacking flash memory dumps containing squashfs partitions.

Commands:
  unpack    Extract the squashfs partition from the flash memory dump
  repack    Repack squashfs_root/ back into a modified flash memory dump

Options:
  -d DIR    Extraction directory (default: $UNPACK_DIR)
  -o FILE   Output filename for repack (default: modified_<flash_dump.bin>)
  -h        Show this help

The script auto-detects the squashfs offset and size using binwalk.
EOF
    exit 1
}

check_deps() {
    local missing=()
    for cmd in binwalk unsquashfs mksquashfs dd sha256sum; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing required tools: ${missing[*]}" >&2
        echo "Install with: sudo apt install binwalk squashfs-tools coreutils" >&2
        exit 1
    fi
}

# Parse the first squashfs entry from binwalk output.
# Sets SQFS_OFFSET (decimal) and SQFS_SIZE (bytes).
detect_squashfs() {
    local file="$1"
    local line
    line=$(binwalk "$file" 2>/dev/null | grep -i 'squashfs' | head -1 || true)
    if [[ -z "$line" ]]; then
        echo "Error: no squashfs partition found in $file" >&2
        exit 1
    fi

    SQFS_OFFSET=$(echo "$line" | awk '{print $1}')

    # Extract the "size: NNNN bytes" field from the binwalk description
    SQFS_SIZE=$(echo "$line" | grep -oP 'size:\s*\K[0-9]+' | head -1)
    if [[ -z "$SQFS_SIZE" ]]; then
        echo "Error: could not determine squashfs size from binwalk output" >&2
        exit 1
    fi

    echo "[*] Detected squashfs at offset $SQFS_OFFSET, size $SQFS_SIZE bytes"
}

# Read superblock from the original squashfs and build matching mksquashfs flags.
# Sets MKFS_EXTRA_OPTS as an array.
read_sqfs_opts() {
    local file="$1"
    local sqfs_tmp=".sqfs_header_probe.bin"
    dd if="$file" bs=1 skip="$SQFS_OFFSET" count="$SQFS_SIZE" of="$sqfs_tmp" 2>/dev/null

    local info
    info=$(unsquashfs -s "$sqfs_tmp" 2>/dev/null || true)
    rm -f "$sqfs_tmp"

    MKFS_EXTRA_OPTS=()

    # Compression
    local comp
    comp=$(echo "$info" | awk '/^Compression /{print $2}')
    [[ -n "$comp" ]] && COMP="$comp"

    # Block size
    local bs
    bs=$(echo "$info" | awk '/^Block size /{print $3}')
    [[ -n "$bs" ]] && BLOCK_SIZE="$bs"

    # Tail-end packing
    if echo "$info" | grep -q 'Tailends are not packed'; then
        MKFS_EXTRA_OPTS+=(-no-tailends)
    fi

    # Exportable via NFS
    if echo "$info" | grep -q 'not exportable'; then
        MKFS_EXTRA_OPTS+=(-no-exports)
    fi

    # Xattrs
    if echo "$info" | grep -q 'Xattrs are not stored'; then
        MKFS_EXTRA_OPTS+=(-no-xattrs)
    fi

    # Original timestamp (for reproducibility)
    local ts
    ts=$(echo "$info" | grep -oP 'append time \K.*')
    if [[ -n "$ts" ]]; then
        local epoch
        epoch=$(date -d "$ts" +%s 2>/dev/null || true)
        if [[ -n "$epoch" ]]; then
            MKFS_EXTRA_OPTS+=(-mkfs-time "$epoch")
            MKFS_EXTRA_OPTS+=(-all-time "$epoch")
        fi
    fi

    # Single uid → force all-root
    if echo "$info" | grep -q 'Number of ids 1'; then
        MKFS_EXTRA_OPTS+=(-all-root)
    fi

    echo "[*] mksquashfs flags: -comp $COMP -b $BLOCK_SIZE ${MKFS_EXTRA_OPTS[*]}"
}

do_unpack() {
    local file="$1"
    detect_squashfs "$file"

    if [[ -d "$UNPACK_DIR" ]]; then
        echo "[!] $UNPACK_DIR already exists — removing it"
        rm -rf "$UNPACK_DIR"
    fi

    echo "[*] Extracting squashfs from $file into $UNPACK_DIR/ ..."
    run_cmd dd if="$file" bs=1 skip="$SQFS_OFFSET" count="$SQFS_SIZE" of=".sqfs_tmp.bin" 2>/dev/null
    # unsquashfs may exit non-zero when it can't set ownership (non-root)
    run_cmd unsquashfs -d "$UNPACK_DIR" -f ".sqfs_tmp.bin" || true
    run_cmd rm -f ".sqfs_tmp.bin"

    if [[ ! -d "$UNPACK_DIR" ]]; then
        echo "Error: extraction failed" >&2
        exit 1
    fi

    echo "[+] Unpacked to $UNPACK_DIR/"
}

do_repack() {
    local file="$1"
    detect_squashfs "$file"
    read_sqfs_opts "$file"

    if [[ ! -d "$UNPACK_DIR" ]]; then
        echo "Error: $UNPACK_DIR/ does not exist — run 'unpack' first" >&2
        exit 1
    fi

    # --- Verify: compare current unpack dir against original squashfs ---
    echo "[*] Comparing $UNPACK_DIR/ against original squashfs ..."
    local orig_dir=".sqfs_verify_orig"
    local orig_sqfs=".sqfs_orig.bin"
    run_cmd dd if="$file" bs=1 skip="$SQFS_OFFSET" count="$SQFS_SIZE" of="$orig_sqfs" 2>/dev/null
    [[ -d "$orig_dir" ]] && rm -rf "$orig_dir"
    run_cmd unsquashfs -d "$orig_dir" -f "$orig_sqfs" >/dev/null 2>&1 || true

    echo "  \$ diff -rq --no-dereference $orig_dir $UNPACK_DIR"
    local diff_out
    diff_out=$(diff -rq --no-dereference "$orig_dir" "$UNPACK_DIR" 2>&1) || true

    if [[ -z "$diff_out" ]]; then
        echo "[*] No changes detected — filesystem is unmodified"
    else
        local added removed modified
        added=$(echo "$diff_out" | grep -c "^Only in ${UNPACK_DIR}" || true)
        removed=$(echo "$diff_out" | grep -c "^Only in ${orig_dir}" || true)
        modified=$(echo "$diff_out" | grep -c "^Files .* differ$" || true)

        echo "[*] Changes detected:"
        [[ "$added" -gt 0 ]]    && echo "    Added:    $added file(s)"
        [[ "$removed" -gt 0 ]]  && echo "    Removed:  $removed file(s)"
        [[ "$modified" -gt 0 ]] && echo "    Modified: $modified file(s)"
        echo
        echo "$diff_out" | head -30
    fi
    echo

    run_cmd rm -rf "$orig_dir" "$orig_sqfs"

    # --- Repack ---
    local new_sqfs=".sqfs_repacked.bin"
    echo "[*] Repacking $UNPACK_DIR/ ..."
    run_cmd mksquashfs "$UNPACK_DIR" "$new_sqfs" -comp "$COMP" -b "$BLOCK_SIZE" \
        "${MKFS_EXTRA_OPTS[@]}" -noappend -quiet

    local new_size
    new_size=$(stat -c%s "$new_sqfs")

    # Determine the max space available (next partition or EOF)
    local next_offset
    next_offset=$(binwalk "$file" 2>/dev/null \
        | awk -v off="$SQFS_OFFSET" 'NR>3 && $1 > off {print $1; exit}' || true)
    local max_size
    if [[ -n "$next_offset" ]]; then
        max_size=$((next_offset - SQFS_OFFSET))
    else
        max_size=$(stat -c%s "$file")
        max_size=$((max_size - SQFS_OFFSET))
    fi

    if (( new_size > max_size )); then
        echo "Error: repacked squashfs ($new_size bytes) exceeds available space ($max_size bytes)" >&2
        rm -f "$new_sqfs"
        exit 1
    fi

    local output="${OUTPUT_FILE:-modified_$(basename "$file")}"
    run_cmd cp "$file" "$output"
    run_cmd dd if="$new_sqfs" of="$output" bs=1 seek="$SQFS_OFFSET" conv=notrunc 2>/dev/null

    # Zero-fill any leftover gap between new squashfs end and next partition
    local gap=$((max_size - new_size))
    if (( gap > 0 )); then
        run_cmd dd if=/dev/zero of="$output" bs=1 seek=$((SQFS_OFFSET + new_size)) count="$gap" conv=notrunc 2>/dev/null
    fi

    run_cmd rm -f "$new_sqfs"
    echo "[+] Written to $output (squashfs: $new_size bytes, padded $gap bytes)"
}

# --- Main ---
check_deps

[[ $# -lt 1 ]] && usage

CMD="$1"
shift

while getopts "d:o:h" opt; do
    case "$opt" in
        d) UNPACK_DIR="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -lt 1 ]] && usage

FILE="$1"

if [[ ! -f "$FILE" ]]; then
    echo "Error: file not found: $FILE" >&2
    exit 1
fi

cd "$SCRIPT_DIR"

case "$CMD" in
    unpack)  do_unpack  "$FILE" ;;
    repack)  do_repack  "$FILE" ;;
    *)       echo "Unknown command: $CMD" >&2; usage ;;
esac

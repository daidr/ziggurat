#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$project" != /mnt/[d-z]/* ]]; then
    printf '%s\n' 'The project must be on a non-system Windows drive (/mnt/d through /mnt/z).' >&2
    exit 2
fi
if [[ "$(id -u)" != 0 ]]; then
    printf '%s\n' 'Run as root inside WSL to mount the cache image.' >&2
    exit 2
fi
image="$project/.zig-cache/managed/wsl-cache.ext4"
destination=/mnt/wsl/ziggurat-cache
if [[ $# -gt 1 ]]; then
    printf '%s\n' 'Usage: mount-wsl-cache.sh [--create]' >&2
    exit 2
fi
if [[ "${1:-}" == --create ]]; then
    mkdir -p -- "$(dirname -- "$image")"
    python3 - "$image" <<'PY'
import os
import sys
path = sys.argv[1]
# Exclusive creation: an existing image can never be formatted by this script.
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
try:
    os.ftruncate(fd, 16 * 1024**3)
finally:
    os.close(fd)
PY
    mkfs.ext4 -F -q "$image"
elif [[ $# -gt 0 ]]; then
    printf '%s\n' 'Usage: mount-wsl-cache.sh [--create]' >&2
    exit 2
fi
if [[ ! -f "$image" || -L "$image" ]]; then
    printf '%s\n' 'Cache image is missing or linked. Use --create once to create a new 16 GiB image.' >&2
    exit 2
fi
if mountpoint -q "$destination"; then
    source="$(findmnt -no SOURCE --target "$destination")"
    # DrVFS may expose the same backing file through another mount namespace;
    # its reported path/device number then differs. Check the file inode and
    # ext4 UUID instead of interpreting the kernel's mount-relative path.
    backing_inode="$(losetup --noheadings --output BACK-INO --raw "$source")"
    image_uuid="$(blkid -p -s UUID -o value "$image")"
    mounted_uuid="$(blkid -p -s UUID -o value "$source")"
    if [[ "$backing_inode" != "$(stat -c %i "$image")" || -z "$image_uuid" || "$image_uuid" != "$mounted_uuid" ]]; then
        printf '%s\n' 'Mount point belongs to a different image; refusing to replace it.' >&2
        exit 2
    fi
    findmnt -no SOURCE,FSTYPE,TARGET --target "$destination"
    exit 0
fi
mkdir -p -- "$destination"
if [[ -L "$destination" || -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '%s\n' 'Mount point is linked or nonempty; refusing to hide its contents.' >&2
    exit 2
fi
mount -o loop,noatime "$image" "$destination"
# Match the Windows workspace owner as exposed by DrVFS.
chown "$(stat -c %u "$project"):$(stat -c %g "$project")" "$destination"
findmnt -no SOURCE,FSTYPE,TARGET --target "$destination"

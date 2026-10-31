#!/bin/sh
# Print the path of a verified Zig for this Linux or macOS host, fetching it
# into a persistent tool cache only when no matching copy exists. A `zig` on
# PATH or in the cache that reports the pinned version is reused as is.
set -eu
version=0.17.0
os=$(uname -s)
case "$os/$(uname -m)" in
    Linux/x86_64) name=zig-x86_64-linux-$version expected=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
    Darwin/arm64) name=zig-aarch64-macos-$version expected=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
    Darwin/x86_64) name=zig-x86_64-macos-$version expected=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6 ;;
    *) printf 'unsupported host: %s %s\n' "$os" "$(uname -m)" >&2; exit 1 ;;
esac
cache=${ZIGGURAT_TOOLCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ziggurat}
destination=$cache/$name

found=$(command -v zig 2>/dev/null || true)
if [ -n "$found" ] && [ "$("$found" version 2>/dev/null || true)" = "$version" ]; then
    printf '%s\n' "$found"
    exit 0
fi
if [ -x "$destination/zig" ]; then
    if [ "$("$destination/zig" version 2>/dev/null || true)" = "$version" ]; then
        printf '%s\n' "$destination/zig"
        exit 0
    fi
    printf 'cached %s is damaged; fetching it again\n' "$destination" >&2
fi

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

mkdir -p "$cache"
archive=$(mktemp "$cache/zig-download.XXXXXX")
staging=$(mktemp -d "$cache/zig-extract.XXXXXX")
trap 'rm -rf "$archive" "$staging"' EXIT HUP INT TERM
# The official server first, then community mirrors; the checksum decides.
mirrors=${ZIGGURAT_ZIG_MIRRORS:-"https://ziglang.org/download/$version https://pkg.machengine.org/zig https://zig.linus.dev/zig"}
fetched=
for mirror in $mirrors; do
    # A stalled transfer is abandoned rather than holding the job until its
    # timeout: below 50 KiB/s for 30 seconds counts as stalled.
    if curl --fail --location --silent --show-error --retry 2 --connect-timeout 20 \
        --speed-limit 51200 --speed-time 30 --max-time 600 \
        "$mirror/$name.tar.xz" --output "$archive" &&
        [ "$(sha256 "$archive")" = "$expected" ]; then
        fetched=$mirror
        break
    fi
    printf 'download from %s failed or did not verify\n' "$mirror" >&2
done
[ -n "$fetched" ] || { printf 'no mirror produced a verified %s\n' "$name" >&2; exit 1; }
tar -xJf "$archive" -C "$staging"
rm -rf "$destination"
# A concurrent job may have finished first; either verified copy will do.
mv "$staging/$name" "$destination" 2>/dev/null || true
[ "$("$destination/zig" version)" = "$version" ]
printf '%s\n' "$destination/zig"

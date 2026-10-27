#!/bin/sh
# Fetch and verify Zig 0.15.2 for this Mac's architecture into a persistent
# tool cache and print the zig path. A self-hosted runner reuses the verified
# copy across jobs.
set -eu
version=0.15.2
case "$(uname -m)" in
arm64) arch=aarch64 expected=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
x86_64) arch=x86_64 expected=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f ;;
*)
    echo "fetch-zig-macos.sh: no Zig $version for $(uname -m)" >&2
    exit 1
    ;;
esac
cache=${ZIGGURAT_TOOLCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ziggurat}
destination=$cache/zig-$arch-macos-$version
if [ -x "$destination/zig" ]; then
    [ "$("$destination/zig" version)" = "$version" ]
    printf '%s\n' "$destination/zig"
    exit 0
fi
mkdir -p "$cache"
archive=$(mktemp "$cache/zig-download.XXXXXX")
trap 'rm -f "$archive"' EXIT HUP INT TERM
# A stalled download gives up rather than holding the job until it times
# out, and a mirror serves the same archive; the SHA-256 decides either way.
file=zig-$arch-macos-$version.tar.xz
fetched=
for url in "https://ziglang.org/download/$version/$file" "https://pkg.machengine.org/zig/$version/$file"; do
    if curl --fail --location --silent --show-error --connect-timeout 20 --speed-limit 10240 --speed-time 60 --max-time 900 --retry 2 "$url" --output "$archive" &&
        printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c -s; then
        fetched=1
        break
    fi
    echo "fetch-zig-macos.sh: $url failed or did not match the SHA-256" >&2
done
[ -n "$fetched" ] || exit 1
tar -xJf "$archive" -C "$cache"
[ "$("$destination/zig" version)" = "$version" ]
printf '%s\n' "$destination/zig"

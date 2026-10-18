#!/bin/sh
set -eu
version=0.15.2
expected=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
cache=${ZIGGURAT_TOOLCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ziggurat}
destination=$cache/zig-x86_64-linux-$version
if [ -x "$destination/zig" ]; then
    [ "$("$destination/zig" version)" = "$version" ]
    printf '%s\n' "$destination/zig"
    exit 0
fi
mkdir -p "$cache"
archive=$(mktemp "$cache/zig-download.XXXXXX")
trap 'rm -f "$archive"' EXIT HUP INT TERM
curl --fail --location --silent --show-error "https://ziglang.org/download/$version/zig-x86_64-linux-$version.tar.xz" --output "$archive"
printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status
tar -xJf "$archive" -C "$cache"
[ "$("$destination/zig" version)" = "$version" ]
printf '%s\n' "$destination/zig"

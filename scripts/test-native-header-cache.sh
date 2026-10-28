#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
zig_bin="${ZIG_BIN:-zig}"
if [[ "$("$zig_bin" version)" != 0.17.0 ]]; then
    printf 'Header cache regression requires Zig 0.17.0.\n' >&2
    exit 2
fi
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" native-header-check
mkdir -p "$project/.zig-cache/managed"
work="$(mktemp -d "$project/.zig-cache/managed/native-header-check-XXXXXXXX")"
mkdir "$work/fixture"
cp -- "$project/build_support/native.zig" "$work/native.zig"
cp -- "$project/build_support/native_header_fixture.zig" "$work/build.zig"
for name in helper.zig main.zig value.c first.h second.h; do
    cp -- "$project/tests/native_header_cache/$name" "$work/fixture/$name"
done
cd "$work"
for linkage in object archive; do
    archive=false
    if [[ "$linkage" == archive ]]; then archive=true; fi
    for expected in 17 29; do
        printf '#define ZIGGURAT_HEADER_VALUE %s\n' "$expected" > fixture/second.h
        if ! "$zig_bin" build run "-Darchive=$archive" -j1 --cache-dir "$ZIG_LOCAL_CACHE_DIR" --summary all > "$linkage-value-$expected.log" 2>&1; then
            printf 'Native %s header build failed; inspect %s\n' "$linkage" "$work" >&2
            exit 1
        fi
        if ! grep -qx "native_header_value=$expected" "$linkage-value-$expected.log"; then
            printf 'Indirect %s header was stale; expected %s; inspect %s\n' "$linkage" "$expected" "$work" >&2
            exit 1
        fi
    done
done
printf 'Indirect native header rebuild passed for object and archive (17 -> 29), evidence: %s\n' "$work"

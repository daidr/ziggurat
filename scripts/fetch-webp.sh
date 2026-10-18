#!/bin/sh
set -eu
version=1.6.0
expected=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
deps=$root/.deps
archive=$deps/libwebp-$version.tar.gz
mkdir -p "$deps"
if [ ! -f "$archive" ]; then
    curl --fail --location --silent --show-error "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$version.tar.gz" --output "$archive"
fi
printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status
tar -xzf "$archive" -C "$deps"
printf 'Verified libwebp %s source at %s/libwebp-%s\n' "$version" "$deps" "$version"

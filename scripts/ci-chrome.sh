#!/bin/sh
# Prints the path of a headless Chromium for tests/web/smoke.py: chromium on
# PATH when it is a real one, else Chrome for Testing's headless shell at a
# pinned version, downloaded once into the runner's cache. Ubuntu's chromium
# package is only a snap stub, so runners there take the download.
set -eu
version=157.0.8103.38
for name in chromium chromium-browser google-chrome; do
  path=$(command -v "$name" 2>/dev/null || true)
  if [ -n "$path" ] && "$path" --version >/dev/null 2>&1 && ! readlink -f "$path" | grep -q snap; then
    echo "$path"
    exit 0
  fi
done
root=${XDG_CACHE_HOME:-$HOME/.cache}/ziggurat/chrome-headless-shell-$version
binary=$root/chrome-headless-shell-linux64/chrome-headless-shell
if [ ! -x "$binary" ]; then
  mkdir -p "$root"
  curl -fsSL --retry 3 -o "$root/shell.zip" "https://storage.googleapis.com/chrome-for-testing-public/$version/linux64/chrome-headless-shell-linux64.zip" >&2
  python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$root/shell.zip" "$root" >&2
  chmod +x "$binary"
  rm -f "$root/shell.zip"
fi
echo "$binary"

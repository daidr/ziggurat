#!/bin/sh
# Runs a macOS smoke executable and, when it panics through
# tests/macos_panic.zig, prints its frames as source locations.
# Usage: macos-symbolize.sh <executable> [arguments...]
log=$(mktemp)
"$@" >"$log" 2>&1
status=$?
cat "$log"
base=$(sed -n 's/^ziggurat-panic-base: //p' "$log" | head -n 1)
if [ -n "$base" ]; then
  frames=$(sed -n 's/^ziggurat-panic-frame: //p' "$log" | tr '\n' ' ')
  echo "Symbolized panic frames:"
  # shellcheck disable=SC2086
  atos -o "$1" -l "$base" $frames
  status=1
fi
rm -f "$log"
exit "$status"

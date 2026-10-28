#!/bin/sh
# Kept for older callers; scripts/fetch-zig.sh serves Linux and macOS.
exec sh "$(dirname "$0")/fetch-zig.sh" "$@"

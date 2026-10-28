#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
    printf '%s\n' 'Profile filesystem checks require Linux.' >&2
    exit 2
fi
zig_bin="${ZIG_BIN:-$(command -v zig || true)}"
if [[ -z "$zig_bin" ]]; then
    zig_bin="$HOME/.cache/ziggurat/zig-x86_64-linux-0.17.0/zig"
fi
if [[ "$("$zig_bin" version)" != 0.17.0 ]]; then
    printf '%s\n' 'Profile checks require Zig 0.17.0.' >&2
    exit 2
fi
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" profile-storage
export ZIGGURAT_PROFILE_TEST_ROOT="${ZIGGURAT_PROFILE_TEST_ROOT:-$ZIG_LOCAL_CACHE_DIR/profile-storage-evidence}"
if [[ "$ZIGGURAT_PROFILE_TEST_ROOT" != /* ]]; then
    printf '%s\n' 'Profile checks require an absolute evidence directory.' >&2
    exit 2
fi
linux_cache_filesystem "$ZIGGURAT_PROFILE_TEST_ROOT"
mkdir -p -- "$ZIGGURAT_PROFILE_TEST_ROOT"
# The checks refuse to follow symlinks above the profile: give them the
# real path, as where a runner's home or cache is linked onto another disk.
ZIGGURAT_PROFILE_TEST_ROOT="$(cd -- "$ZIGGURAT_PROFILE_TEST_ROOT" && pwd -P)"
export ZIGGURAT_PROFILE_TEST_ROOT
cd "$project"
exec "$zig_bin" build test-profile-storage test-profile-storage-files \
    -j1 --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --prefix .zig-cache/managed/profile-storage-out --summary all "$@"

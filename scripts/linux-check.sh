#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "$0")/.."
zig_bin="${ZIG_BIN:-zig}"
source scripts/linux-cache-env.sh
configure_linux_cache "$PWD" check
cache_dir="${ZIG_CACHE_DIR:-$ZIG_LOCAL_CACHE_DIR}"
prefix="${ZIG_PREFIX:-zig-out/linux}"
pkg-config --exists gtk+-3.0 pangocairo
"$zig_bin" fmt --check src/platform/linux.zig src/ui/linux.zig tests/linux_smoke.zig
"$zig_bin" build test check --cache-dir "$cache_dir" --prefix "$prefix"
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  printf '%s\n' 'Native smoke requires a connected X11 or Wayland display.' >&2
  exit 2
fi
G_DEBUG=fatal-criticals "$zig_bin" build smoke-linux --cache-dir "$cache_dir" --prefix "$prefix"

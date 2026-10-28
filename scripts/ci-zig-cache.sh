#!/bin/sh
# Print ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR lines for $GITHUB_ENV,
# pointing at caches that outlive the job's checkout. The global cache is
# shared by every job of one Zig version on this machine. The local cache
# belongs to one workspace path, so two checkouts never share one, and it is
# emptied once a week so it cannot grow without bound.
set -eu
version=0.17.0
root=${ZIGGURAT_TOOLCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ziggurat}/ci/zig-$version
workspace=${GITHUB_WORKSPACE:-$(pwd)}
if command -v sha256sum >/dev/null 2>&1; then
    key=$(printf '%s' "$workspace" | sha256sum | cut -c1-16)
else
    key=$(printf '%s' "$workspace" | shasum -a 256 | cut -c1-16)
fi
local_cache=$root/local-$key
stamp=$local_cache/.created
if [ -f "$stamp" ] && [ -n "$(find "$stamp" -mtime +7 2>/dev/null)" ]; then
    rm -rf "$local_cache"
fi
if [ ! -f "$stamp" ]; then
    mkdir -p "$local_cache"
    touch "$stamp"
fi
mkdir -p "$root/global"
printf 'ZIG_GLOBAL_CACHE_DIR=%s\n' "$root/global"
printf 'ZIG_LOCAL_CACHE_DIR=%s\n' "$local_cache"

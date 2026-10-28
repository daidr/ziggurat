#!/bin/sh
# Print ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR lines for $GITHUB_ENV,
# pointing at caches that outlive the job's checkout. The global cache is
# shared by every job of one Zig version on this machine. The local cache
# belongs to one workspace path, so two checkouts never share one.
#
# Every build adds to these caches and Zig never removes anything, so each
# run first trims them:
# - caches of other Zig versions are removed;
# - a local cache unused for 2 days, or created more than 7 days ago, is
#   removed;
# - when everything together exceeds ZIGGURAT_CI_CACHE_MAX_MB (default
#   12288), or the disk has less than ZIGGURAT_CI_CACHE_MIN_FREE_MB (default
#   8192) free, the local caches are removed, then the global cache.
set -eu
version=0.17.0
max_mb=${ZIGGURAT_CI_CACHE_MAX_MB:-12288}
min_free_mb=${ZIGGURAT_CI_CACHE_MIN_FREE_MB:-8192}
ci=${ZIGGURAT_TOOLCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ziggurat}/ci
root=$ci/zig-$version
workspace=${GITHUB_WORKSPACE:-$(pwd)}
if command -v sha256sum >/dev/null 2>&1; then
    key=$(printf '%s' "$workspace" | sha256sum | cut -c1-16)
else
    key=$(printf '%s' "$workspace" | shasum -a 256 | cut -c1-16)
fi
local_cache=$root/local-$key
mkdir -p "$root"

for dir in "$ci"/zig-*; do
    [ -d "$dir" ] && [ "$dir" != "$root" ] && rm -rf "$dir"
done
for dir in "$root"/local-*; do
    [ -d "$dir" ] || continue
    if [ ! -f "$dir/.created" ] || [ -n "$(find "$dir/.created" -mtime +7 2>/dev/null)" ]; then
        rm -rf "$dir"
    elif [ "$dir" != "$local_cache" ] && [ -n "$(find "$dir/.used" -mtime +2 2>/dev/null)" ]; then
        rm -rf "$dir"
    fi
done

used_mb() { du -sk "$root" 2>/dev/null | awk '{print int($1 / 1024)}'; }
free_mb() { df -Pk "$root" | awk 'NR == 2 {print int($4 / 1024)}'; }
over() { [ "$(used_mb)" -gt "$max_mb" ] || [ "$(free_mb)" -lt "$min_free_mb" ]; }
if over; then
    for dir in "$root"/local-*; do
        [ -d "$dir" ] && [ "$dir" != "$local_cache" ] && rm -rf "$dir"
    done
fi
if over; then rm -rf "$local_cache"; fi
if over; then rm -rf "$root/global"; fi
printf 'ziggurat CI caches: %s MB in %s, %s MB free\n' "$(used_mb)" "$root" "$(free_mb)" >&2

if [ ! -f "$local_cache/.created" ]; then
    mkdir -p "$local_cache"
    touch "$local_cache/.created"
fi
touch "$local_cache/.used"
mkdir -p "$root/global"
printf 'ZIG_GLOBAL_CACHE_DIR=%s\n' "$root/global"
printf 'ZIG_LOCAL_CACHE_DIR=%s\n' "$local_cache"

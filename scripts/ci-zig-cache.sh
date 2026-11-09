#!/bin/sh
# Print ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR lines for $GITHUB_ENV,
# pointing at caches that outlive the job's checkout. The global cache is
# shared by every job of one Zig version on this machine. The local cache
# belongs to one workspace path, so two checkouts never share one.
# ZIGGURAT_CI_CACHE_TIER names a separate local cache for a kind of job
# (full, webview): pull request core checks, which run without a tier (or
# with "core"), stay warm while the full suite fills and trims its own.
#
# Every build adds to these caches and Zig never removes anything, so each
# run first trims them:
# - caches of other Zig versions are removed;
# - a local cache unused for 2 days, or created more than 7 days ago, is
#   removed;
# - when everything together exceeds ZIGGURAT_CI_CACHE_MAX_MB (default
#   12288), or the disk has less than ZIGGURAT_CI_CACHE_MIN_FREE_MB (default
#   8192) free, local caches are removed until it fits: other tiers'
#   caches, this job's own when it has a tier, other core caches, this job's
#   own, and last the global cache.
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
mkdir -p "$root"
# Tests that refuse symlinked ancestors keep files under the local cache, so
# hand out the physical path even when the cache directory is a link.
root=$(cd "$root" && pwd -P)
ci=$(dirname "$root")
tier=${ZIGGURAT_CI_CACHE_TIER:-core}
case $tier in
    core) local_cache=$root/local-$key ;;
    *[!a-z0-9]*) echo "ZIGGURAT_CI_CACHE_TIER must be lowercase letters and digits" >&2; exit 1 ;;
    *) local_cache=$root/local-$key-$tier ;;
esac

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
# A core cache is named local-<key> with no tier suffix.
is_core() { case ${1##*/local-} in *-*) return 1 ;; *) return 0 ;; esac; }
trim() { # $1 = core or tier: remove other caches of that kind while over
    for dir in "$root"/local-*; do
        over || return 0
        [ -d "$dir" ] && [ "$dir" != "$local_cache" ] || continue
        if is_core "$dir"; then kind=core; else kind=tier; fi
        if [ "$kind" = "$1" ]; then rm -rf "$dir"; fi
    done
    return 0
}
trim tier
if over && ! is_core "$local_cache"; then rm -rf "$local_cache"; fi
trim core
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

#!/usr/bin/env bash
# Source this file, then call configure_linux_cache PROJECT ROLE.
linux_cache_filesystem() {
    local directory="$1" magic
    while [[ ! -e "$directory" ]]; do
        directory="$(dirname -- "$directory")"
    done
    magic="$(stat -f -c %t -- "$directory")" || return 2
    case "$magic" in
        ef53|58465342|9123683e|1021994|794c7630) return 0 ;;
        *)
            printf 'Linux Zig caches require a supported Linux filesystem (got %s at %s).\n' "$magic" "$directory" >&2
            return 2
            ;;
    esac
}

configure_linux_cache() {
    local project="$1" role="$2" cache_root on_wsl=false
    if [[ "$project" == /mnt/* && "$(uname -r)" == *[Mm]icrosoft* ]]; then
        on_wsl=true
        cache_root="${ZIGGURAT_LINUX_CACHE_ROOT:-/mnt/wsl/ziggurat-cache}"
        if [[ ! -d "$cache_root" ]]; then
            printf '%s\n' 'Mount scripts/mount-wsl-cache.sh or set ZIGGURAT_LINUX_CACHE_ROOT to a Linux filesystem directory.' >&2
            return 2
        fi
        if [[ -z "${ZIGGURAT_LINUX_CACHE_ROOT:-}" ]] && ! mountpoint -q "$cache_root"; then
            printf '%s\n' 'The WSL cache image is not mounted; refusing to use a fallback cache.' >&2
            return 2
        fi
        linux_cache_filesystem "$cache_root" || return 2
    else
        cache_root="${ZIGGURAT_LINUX_CACHE_ROOT:-$project/.zig-cache/managed}"
    fi
    export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$cache_root/$role-cache}"
    export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$cache_root/global}"
    if "$on_wsl"; then
        linux_cache_filesystem "$ZIG_LOCAL_CACHE_DIR" || return 2
        linux_cache_filesystem "$ZIG_GLOBAL_CACHE_DIR" || return 2
    fi
    mkdir -p -- "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
}

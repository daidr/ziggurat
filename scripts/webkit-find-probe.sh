#!/usr/bin/env bash
# Run bounded native Find checks using the existing SDK and cache configuration.
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project"
mode="${1:-all}"
if (( $# > 1 )); then printf '%s\n' 'Expected at most one Find fixture mode.' >&2; exit 2; fi
case "$mode" in all|denied|ordered|cancel|timeout|refresh|reload|recover|close|rawclose|quit) ;; *) printf 'Unknown Find mode: %s\n' "$mode" >&2; exit 2 ;; esac
optimize="${P01_OPTIMIZE:-ReleaseSafe}"
case "$optimize" in Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;; *) printf '%s\n' 'Invalid optimize mode.' >&2; exit 2 ;; esac
work="${P01_DEPS:-$HOME/.cache/ziggurat/webkit-p01-deps}"
sdk="$work/root"
gtk="${GTK_DEPS:-$HOME/.cache/ziggurat/window-state-deps/root}"
tls="${P01_TLS_ROOT:-}"
tls_lib=""
if [[ -n "$tls" ]]; then
    if [[ "$tls" != /* || "$tls" == *[:,]* || "$tls" == *$'\n'* ]]; then
        printf '%s\n' 'TLS dependency root must be absolute without overlay separators.' >&2; exit 2
    fi
    tls="$(realpath -e -- "$tls")"
    tls_lib="$tls/usr/lib/x86_64-linux-gnu"
    [[ -f "$tls_lib/gio/modules/libgiognutls.so" ]] || { printf '%s\n' 'Missing GIO TLS module.' >&2; exit 2; }
fi
zig="${ZIG_BIN:-$HOME/.cache/ziggurat/zig-x86_64-linux-0.17.0/zig}"
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" webkit
build_cache="${P01_BUILD_CACHE:-$ZIG_LOCAL_CACHE_DIR}"
global_cache="${P01_GLOBAL_CACHE:-$ZIG_GLOBAL_CACHE_DIR}"
prefix="${P01_BUILD_PREFIX:-$project/.zig-cache/managed/webkit-out}"
runtime="${P01_RUNTIME_CACHE:-$project/.zig-cache/managed/webkit-runtime-cache}"
output="${P01_OUTPUT_DIR:-$project/.zig-cache/managed/webkit-out/probes}"
export ZIG_LOCAL_CACHE_DIR="$build_cache" ZIG_GLOBAL_CACHE_DIR="$global_cache"
export PKG_CONFIG="$project/scripts/pkg-config-prefix.sh"
export PKG_CONFIG_PATH="$sdk/usr/lib/x86_64-linux-gnu/pkgconfig:$gtk/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
mkdir -p -- "$build_cache" "$global_cache" "$prefix" "$runtime/data" "$output"
"$zig" build build-smoke-find -Dwebview=true "-Doptimize=$optimize" -j1 \
    --cache-dir "$build_cache" --global-cache-dir "$global_cache" --prefix "$prefix" --summary all
executable="$prefix/bin/smoke-find"
[[ -x "$executable" ]] || { printf '%s\n' 'Find executable was not installed.' >&2; exit 2; }
export LD_LIBRARY_PATH="${tls_lib:+$tls_lib:}$sdk/usr/lib/x86_64-linux-gnu:$gtk/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_CONFIG_HOME="$gtk/etc/xdg" XDG_DATA_DIRS="$sdk/usr/share:$gtk/usr/share:/usr/share"
export XDG_CACHE_HOME="$runtime" XDG_DATA_HOME="$runtime/data"
export PATH="$HOME/.cache/ziggurat/window-state-deps/bin:$gtk/usr/bin:$PATH"
export G_DEBUG=fatal-criticals GDK_BACKEND=x11
run_mode() {
    local selected="$1"
    printf 'Find Runtime mode=%s optimize=%s\n' "$selected" "$optimize"
    if [[ -x /usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess && -z "$tls" ]]; then
        xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- "$executable" "$selected"
    else
        mkdir -p -- "$output/find-merged-lib"
        unshare --user --map-root-user --mount --net bash -c '
            set -euo pipefail
            mount -t overlay overlay -o "lowerdir=$1" "$2"
            mount --bind "$2" /usr/lib/x86_64-linux-gnu
            ip link set lo up
            shift 2
            exec xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$@"
        ' bash "${tls_lib:+$tls_lib:}$sdk/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu" \
            "$output/find-merged-lib" "$executable" "$selected"
    fi
}
if [[ "$mode" == all ]]; then
    for selected in denied ordered cancel timeout refresh reload recover close rawclose quit; do
        run_mode "$selected"
    done
else
    run_mode "$mode"
fi

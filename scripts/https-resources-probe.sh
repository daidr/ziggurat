#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" https-resources
zig="${ZIG_BIN:-zig}"
build_target=smoke-https-resources
if [[ "${1:-}" == --native ]]; then
    build_target=test-https-resources-native
    shift
fi
prefix="${ZIGGURAT_HTTPS_TEST_PREFIX:-$project/.zig-cache/managed/https-resources-out}"
runtime="${ZIGGURAT_HTTPS_TEST_RUNTIME:-$project/.zig-cache/managed/https-resources-runtime}"
tls_root="${ZIGGURAT_HTTPS_TLS_ROOT:-}"
library_root="${ZIGGURAT_HTTPS_LIBRARY_ROOT:-}"
mkdir -p -- "$prefix" "$runtime/data"
export ZIGGURAT_HTTPS_TEST_ROOT="$project/tests/fixtures/profile-https"
export XDG_CACHE_HOME="$runtime" XDG_DATA_HOME="$runtime/data"
export G_DEBUG=fatal-criticals GDK_BACKEND=x11
command=("$zig" build "$build_target" -Dhttps-resources=true -j1
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
    --prefix "$prefix" --summary all "$@")
cd "$project"
if [[ -z "$tls_root" ]]; then
    exec xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- "${command[@]}"
fi
for dependency in "$tls_root" "$library_root"; do
    if [[ -n "$dependency" && ( "$dependency" != /* || "$dependency" == *[:,]* || "$dependency" == *$'\n'* ) ]]; then
        printf '%s\n' 'Dependency roots must be absolute paths without overlay separators.' >&2
        exit 2
    fi
done
tls_root="$(realpath -e -- "$tls_root")"
tls_lib="$tls_root/usr/lib/x86_64-linux-gnu"
if [[ ! -f "$tls_lib/gio/modules/libgiognutls.so" ]]; then
    printf '%s\n' 'TLS dependency root is missing the GIO GnuTLS module.' >&2
    exit 2
fi
lower_lib="$tls_lib"
if [[ -n "$library_root" ]]; then
    library_root="$(realpath -e -- "$library_root")"
    lower_lib+=":$library_root/usr/lib/x86_64-linux-gnu"
fi
lower_lib+=":/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$tls_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p -- "$prefix/merged-lib"
# This read-only dependency mount exists only in the test's private namespace.
exec unshare --user --map-root-user --mount --net bash -c '
    set -euo pipefail
    mount -t overlay overlay -o "lowerdir=$1" "$2"
    mount --bind "$2" /usr/lib/x86_64-linux-gnu
    ip link set lo up
    shift 2
    exec xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$@"
' bash "$lower_lib" "$prefix/merged-lib" "${command[@]}"

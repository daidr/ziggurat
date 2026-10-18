#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="${P01_DEPS:-$HOME/.cache/ziggurat/webkit-p01-deps}"
root="$work/root"
gtk="${GTK_DEPS:-$HOME/.cache/ziggurat/window-state-deps/root}"
zig_bin="${ZIG_BIN:-$HOME/.cache/ziggurat/zig-x86_64-linux-0.15.2/zig}"
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" webkit-request
export ZIG_GLOBAL_CACHE_DIR="${P01_GLOBAL_CACHE:-$ZIG_GLOBAL_CACHE_DIR}"
runtime_cache="${P01_RUNTIME_CACHE:-$project/.zig-cache/managed/webkit-runtime-cache}"
output="${P01_OUTPUT_DIR:-$project/.zig-cache/managed/webkit-request-out}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$runtime_cache/data"
export PKG_CONFIG_PATH="$root/usr/lib/x86_64-linux-gnu/pkgconfig:$gtk/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG="$project/scripts/pkg-config-prefix.sh"
read -ra extension_flags <<< "$("$PKG_CONFIG" --cflags --libs webkit2gtk-web-extension-4.1)"
read -ra ui_flags <<< "$("$PKG_CONFIG" --cflags --libs webkit2gtk-4.1)"
mkdir -p "$output/request/good" "$output/request/missing"
case "${P01_REQUEST_PROBE:-runtime}" in
    policy|remote-test|runtime|strict) ;;
    *) printf 'Unknown request probe mode\n' >&2; exit 2 ;;
esac
"$zig_bin" cc -std=c11 -Wall -Wextra -Werror -O1 -g "$project/tests/webkit_request_policy_test.c" "${extension_flags[@]}" -o "$output/request/policy-test"
export LD_LIBRARY_PATH="$root/usr/lib/x86_64-linux-gnu:$gtk/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$output/request/policy-test"
if [[ "${P01_REQUEST_PROBE:-runtime}" == policy ]]; then exit 0; fi
if [[ "${P01_REQUEST_PROBE:-runtime}" == remote-test ]]; then
    "$zig_bin" cc -std=c11 -Wall -Wextra -Werror -O1 -g "$project/tests/webkit_remote_test.c" "${extension_flags[@]}" -o "$output/request/remote-test"
    "$output/request/remote-test"
    exit 0
fi
"$zig_bin" cc -std=c11 -Wall -Wextra -Werror -O1 -g -fPIC -shared "$project/src/webview/webkit_request_extension.c" "${extension_flags[@]}" -o "$output/request/good/libziggurat-request-policy.so"
"$zig_bin" cc -std=c11 -Wall -Wextra -Werror -O1 -g "$project/tests/webkit_request_probe.c" "${ui_flags[@]}" -pthread -o "$output/request/request-probe"
export XDG_CONFIG_HOME="$gtk/etc/xdg"
export XDG_DATA_DIRS="$root/usr/share:$gtk/usr/share:/usr/share"
export XDG_CACHE_HOME="$runtime_cache"
export XDG_DATA_HOME="$runtime_cache/data"
export PATH="$HOME/.cache/ziggurat/window-state-deps/bin:$gtk/usr/bin:$PATH"
export G_DEBUG=fatal-criticals
export GDK_BACKEND=x11
command=("$output/request/request-probe" "$output/request/good" "$output/request/missing")
if [[ "${P01_REQUEST_PROBE:-runtime}" == strict ]]; then command+=(strict); fi
if [[ -x /usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess ]]; then
    xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- "${command[@]}"
else
    mkdir -p "$output/merged-lib"
    unshare --user --map-root-user --mount --net bash -c '
        set -euo pipefail
        mount -t overlay overlay -o "lowerdir=$1/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu" "$2"
        mount --bind "$2" /usr/lib/x86_64-linux-gnu
        ip link set lo up
        shift 2
        exec xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$@"
    ' bash "$root" "$output/merged-lib" "${command[@]}"
fi

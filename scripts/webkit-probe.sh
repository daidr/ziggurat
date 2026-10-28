#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="${P01_DEPS:-$HOME/.cache/ziggurat/webkit-p01-deps}"
root="$work/root"
gtk="${GTK_DEPS:-$HOME/.cache/ziggurat/window-state-deps/root}"
tls_root="${P01_TLS_ROOT:-}"
tls_lib=""
if [[ -n "$tls_root" ]]; then
    if [[ "$tls_root" != /* || "$tls_root" == *[:,]* || "$tls_root" == *$'\n'* ]]; then
        printf '%s\n' 'TLS dependencies require an absolute root without overlay separators.' >&2
        exit 2
    fi
    tls_root="$(realpath -e -- "$tls_root")"
    tls_lib="$tls_root/usr/lib/x86_64-linux-gnu"
    if [[ ! -f "$tls_lib/gio/modules/libgiognutls.so" ]]; then
        printf '%s\n' 'TLS dependency root is missing the GIO GnuTLS module.' >&2
        exit 2
    fi
fi
zig_bin="${ZIG_BIN:-$HOME/.cache/ziggurat/zig-x86_64-linux-0.17.0/zig}"
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" webkit
build_cache="${P01_BUILD_CACHE:-$ZIG_LOCAL_CACHE_DIR}"
global_cache="${P01_GLOBAL_CACHE:-$ZIG_GLOBAL_CACHE_DIR}"
build_prefix="${P01_BUILD_PREFIX:-$project/.zig-cache/managed/webkit-out}"
runtime_cache="${P01_RUNTIME_CACHE:-$project/.zig-cache/managed/webkit-runtime-cache}"
output="${P01_OUTPUT_DIR:-$project/.zig-cache/managed/webkit-out/probes}"
export ZIG_GLOBAL_CACHE_DIR="$global_cache"
export PKG_CONFIG_PATH="$root/usr/lib/x86_64-linux-gnu/pkgconfig:$gtk/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
read -ra raw_flags <<< "$(pkg-config --cflags --libs webkit2gtk-4.1)"
flags=("-L$root/usr/lib/x86_64-linux-gnu" "-L$gtk/usr/lib/x86_64-linux-gnu")
for flag in "${raw_flags[@]}"; do
    if [[ "$flag" == -I/* || "$flag" == -L/* ]]; then
        path="${flag:2}"
        if [[ -e "$root$path" ]]; then flag="${flag:0:2}$root$path"
        elif [[ -e "$gtk$path" ]]; then flag="${flag:0:2}$gtk$path"; fi
    fi
    flags+=("$flag")
done
mkdir -p "$output" "$build_cache" "$global_cache" "$runtime_cache/data"
probe="${P01_PROBE:-contract}"
case "$probe" in
    contract) sources=("$project/tests/webkit_contract_probe.c") ;;
    backend) sources=("$project/tests/webkit_backend_smoke.c" "$project/src/platform/linux.c" "$project/src/webview/webkit_native.c") ;;
    remote) sources=("$project/tests/webkit_remote_backend_smoke.c" "$project/src/platform/linux.c" "$project/src/webview/webkit_native.c") ;;
    local-test) sources=("$project/tests/webkit_local_test.c") ;;
    local) sources=("$project/tests/webkit_local_smoke.c" "$project/src/platform/linux.c" "$project/src/webview/webkit_native.c") ;;
    history-events) sources=("$project/tests/webkit_history_events.c") ;;
    session-host) sources=("$project/tests/webkit_session_host.c" "$project/src/platform/linux.c") ;;
    zig|zig-test|remote-zig|dynamic-zig|capture-zig|capture-owner|find-owner|initializers-zig|initializers-owner|navigation-zig|regions-zig|session-zig|profile-owner|profile-zig|cookies-zig|cookies-owner|https-zig|https-pages-zig|profile-tls-owner) sources=() ;;
    *) printf 'Unknown probe: %s\n' "$probe" >&2; exit 2 ;;
esac
executable="$output/webkit-$probe-probe"
if [[ "$probe" == zig || "$probe" == zig-test || "$probe" == remote-zig || "$probe" == dynamic-zig || "$probe" == capture-zig || "$probe" == capture-owner || "$probe" == find-owner || "$probe" == initializers-zig || "$probe" == initializers-owner || "$probe" == navigation-zig || "$probe" == regions-zig || "$probe" == session-zig || "$probe" == profile-owner || "$probe" == profile-zig || "$probe" == cookies-zig || "$probe" == cookies-owner || "$probe" == https-zig || "$probe" == https-pages-zig || "$probe" == profile-tls-owner ]]; then
    export PKG_CONFIG="$project/scripts/pkg-config-prefix.sh"
    target=smoke-webview-linux
    if [[ "$probe" == zig-test ]]; then target=test-webview; fi
    if [[ "$probe" == remote-zig ]]; then target=smoke-webview-remote-linux; fi
    if [[ "$probe" == dynamic-zig ]]; then target=smoke-webview-dynamic-linux; fi
    if [[ "$probe" == capture-zig ]]; then target=smoke-webview-capture-linux; fi
    if [[ "$probe" == capture-owner ]]; then target=test-webkit-capture; fi
    if [[ "$probe" == find-owner ]]; then target=test-webkit-find; fi
    if [[ "$probe" == initializers-zig ]]; then target=smoke-webview-initializers-linux; fi
    if [[ "$probe" == initializers-owner ]]; then target=test-webkit-initializers; fi
    if [[ "$probe" == navigation-zig ]]; then target=smoke-webview-navigation-linux; fi
    if [[ "$probe" == regions-zig ]]; then target=smoke-webview-regions-linux; fi
    if [[ "$probe" == session-zig ]]; then target=smoke-webview-session-linux; fi
    if [[ "$probe" == initializers-zig || "$probe" == profile-owner || "$probe" == profile-zig || "$probe" == cookies-zig || "$probe" == cookies-owner || "$probe" == https-zig || "$probe" == https-pages-zig || "$probe" == profile-tls-owner ]]; then
        if [[ "$probe" == initializers-zig ]]; then target=smoke-webview-initializers-linux; elif [[ "$probe" == profile-owner ]]; then target=test-webkit-profile; elif [[ "$probe" == profile-zig ]]; then target=smoke-webview-profile-linux; elif [[ "$probe" == cookies-owner ]]; then target=test-webkit-cookies; elif [[ "$probe" == https-zig ]]; then target=smoke-webview-https-linux; elif [[ "$probe" == https-pages-zig ]]; then target=smoke-https-pages; elif [[ "$probe" == profile-tls-owner ]]; then target=test-webkit-profile-tls; else target=smoke-webview-cookies-linux; fi
        export ZIGGURAT_PROFILE_TEST_ROOT="${ZIGGURAT_PROFILE_TEST_ROOT:-$build_cache/profile-owner-evidence}"
        if [[ "$ZIGGURAT_PROFILE_TEST_ROOT" != /* ]]; then
            printf '%s\n' 'Profile checks require an absolute evidence directory.' >&2
            exit 2
        fi
        linux_cache_filesystem "$ZIGGURAT_PROFILE_TEST_ROOT"
        mkdir -p -- "$ZIGGURAT_PROFILE_TEST_ROOT"
    fi
    optimize="${P01_OPTIMIZE:-ReleaseSafe}"
    case "$optimize" in Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;; *) printf 'Invalid optimize mode\n' >&2; exit 2 ;; esac
    command=("$zig_bin" build "$target" -Dwebview=true "-Doptimize=$optimize" -j1 --cache-dir "$build_cache" --prefix "$build_prefix" --summary all)
    if [[ "$probe" == https-pages-zig ]]; then command+=(-Dhttps-resources=true); fi
    cd "$project"
else
    if [[ "$probe" != local-test && "$probe" != contract && "$probe" != history-events && "$probe" != session-host ]]; then
        sources+=("$project/src/file_stream/linux.c" "$project/src/webview/webkit_profile.c")
    fi
    "$zig_bin" cc -std=c11 -Wall -Wextra -Werror -O1 -g "${sources[@]}" "${flags[@]}" -pthread -lX11 -o "$executable"
    command=("$executable")
    if [[ "$probe" == remote ]]; then
        mkdir -p "$output/request/good" "$output/request/missing" "$output/request/bad"
        export PKG_CONFIG="$project/scripts/pkg-config-prefix.sh"
        read -ra extension_flags <<< "$("$PKG_CONFIG" --cflags --libs webkit2gtk-web-extension-4.1)"
        "$zig_bin" cc -std=c11 -Wall -Wextra -Werror -O1 -g -fPIC -shared "$project/src/webview/webkit_request_extension.c" "${extension_flags[@]}" -o "$output/request/good/libziggurat-request-policy.so"
        "$zig_bin" cc -std=c11 -Wall -Wextra -Werror -O1 -g -fPIC -shared "$project/tests/webkit_bad_request_extension.c" "${extension_flags[@]}" -o "$output/request/bad/libziggurat-test-incompatible.so"
        command+=("$output/request/good" "$output/request/missing" "$output/request/bad")
    fi
fi
export LD_LIBRARY_PATH="${tls_lib:+$tls_lib:}$root/usr/lib/x86_64-linux-gnu:$gtk/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_CONFIG_HOME="$gtk/etc/xdg"
export XDG_DATA_DIRS="$root/usr/share:$gtk/usr/share:/usr/share"
export XDG_CACHE_HOME="$runtime_cache"
export XDG_DATA_HOME="$runtime_cache/data"
export PATH="$HOME/.cache/ziggurat/window-state-deps/bin:$gtk/usr/bin:$PATH"
export G_DEBUG=fatal-criticals
export GDK_BACKEND=x11
if [[ -x /usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess && -z "$tls_root" ]]; then
    xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- "${command[@]}"
else
    # Distribution binaries deliberately use their installed helper path. This
    # read-only mount exists only in a private user/mount/network namespace.
    mkdir -p "$output/merged-lib"
    lower_lib="${tls_lib:+$tls_lib:}$root/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
    unshare --user --map-root-user --mount --net bash -c '
        set -euo pipefail
        mount -t overlay overlay -o "lowerdir=$1" "$2"
        mount --bind "$2" /usr/lib/x86_64-linux-gnu
        ip link set lo up
        shift 2
        exec xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$@"
    ' bash "$lower_lib" "$output/merged-lib" "${command[@]}"
fi

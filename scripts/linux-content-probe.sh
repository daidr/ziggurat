#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
gtk="${GTK_DEPS:-$HOME/.cache/ziggurat/window-state-deps/root}"
zig_bin="${ZIG_BIN:-$HOME/.cache/ziggurat/zig-x86_64-linux-0.15.2/zig}"
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" content
export PKG_CONFIG_PATH="$gtk/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
read -ra raw_flags <<< "$(pkg-config --cflags --libs gtk+-3.0 x11)"
flags=("-L$gtk/usr/lib/x86_64-linux-gnu")
for flag in "${raw_flags[@]}"; do
    if [[ "$flag" == -I/* || "$flag" == -L/* ]]; then
        path="${flag:2}"
        if [[ -e "$gtk$path" ]]; then flag="${flag:0:2}$gtk$path"; fi
    fi
    flags+=("$flag")
done
probe="${P01_CONTENT:-full}"
case "$probe" in
    full) fixture=linux_content_smoke.c; executable=linux-content-smoke ;;
    regions) fixture=linux_regions_smoke.c; executable=linux-regions-smoke ;;
    *) printf 'Unknown content probe: %s\n' "$probe" >&2; exit 2 ;;
esac
output="${P01_OUTPUT_DIR:-$project/.zig-cache/managed/content-out}"
mkdir -p "$output"
compiler=("$zig_bin" cc)
if [[ "${P01_ASAN:-0}" == 1 ]]; then
    compiler=(gcc)
    flags+=(-fsanitize=address -fno-omit-frame-pointer)
fi
"${compiler[@]}" -std=c11 -Wall -Wextra -Werror -O1 -g "$project/tests/$fixture" "${flags[@]}" -o "$output/$executable"
export LD_LIBRARY_PATH="$gtk/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_CONFIG_HOME="$gtk/etc/xdg"
export XDG_DATA_DIRS="$gtk/usr/share:/usr/share"
export PATH="$HOME/.cache/ziggurat/window-state-deps/bin:$gtk/usr/bin:$PATH"
export G_DEBUG=fatal-criticals
export GDK_BACKEND=x11
exec xvfb-run -a -s '-screen 0 1280x800x24' "$output/$executable"

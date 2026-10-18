#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "$0")/.."
source scripts/linux-cache-env.sh
configure_linux_cache "$PWD" window-state

# Always use a separate server; never replace the user's window manager.
if [[ "${1:-}" != --isolated-display ]]; then
    exec xvfb-run -a -s '-screen 0 2560x1600x24' bash scripts/linux-window-state.sh --isolated-display "$@"
fi
shift
command -v openbox >/dev/null
command -v xprop >/dev/null
log_path=$(mktemp)
openbox --sm-disable >"$log_path" 2>&1 &
manager_pid=$!
cleanup() {
    kill "$manager_pid" 2>/dev/null || true
    wait "$manager_pid" 2>/dev/null || true
    rm -f -- "$log_path"
}
trap cleanup EXIT
ready=false
for ((attempt=0; attempt<100; attempt++)); do
    if ! kill -0 "$manager_pid" 2>/dev/null; then
        cat "$log_path" >&2
        exit 1
    fi
    manager_state=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null || true)
    if [[ "$manager_state" == *"window id #"* ]]; then
        ready=true
        break
    fi
    sleep 0.05
done
if [[ "$ready" != true ]]; then
    cat "$log_path" >&2
    printf '%s\n' 'Isolated window manager did not become ready.' >&2
    exit 1
fi
for check in smoke-window-state smoke-window-relationships smoke-window-chrome smoke-window-placement; do
    G_DEBUG=fatal-criticals GDK_BACKEND=x11 "${ZIG_BIN:-zig}" build "$check" "$@" -- --require-wm
done

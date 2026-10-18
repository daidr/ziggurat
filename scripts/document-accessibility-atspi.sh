#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == --session ]]; then
    shift
    prefix="${1:?installed test prefix}"
    evidence="${2:?fresh evidence directory}"
    unset NO_AT_BRIDGE
    # An anonymous pipe works on both Linux filesystems and mounted project
    # drives. The independent client sends acknowledgements to this writer.
    coproc ZDA_SERVER { exec "$prefix/bin/smoke-document-accessibility-linux" --external >"$evidence/server.log" 2>&1; }
    server_pid=$ZDA_SERVER_PID
    exec 3>&${ZDA_SERVER[1]}
    control="/proc/$$/fd/3"
    finish() {
        printf q >&3 || true
        if kill -0 "$server_pid" 2>/dev/null; then kill "$server_pid" 2>/dev/null || true; fi
        wait "$server_pid" 2>/dev/null || true
        exec 3>&-
    }
    trap finish EXIT
    if timeout 20 "$prefix/bin/document-accessibility-atspi-client" "$control"; then
        wait "$server_pid"
    else
        status=$?
        cat "$evidence/server.log"
        exit "$status"
    fi
    cat "$evidence/server.log"
    trap - EXIT
    exec 3>&-
    exit 0
fi

if [[ "$(uname -s)" != Linux ]]; then
    printf '%s\n' 'AT-SPI document checks require Linux.' >&2
    exit 2
fi
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" document-accessibility
prefix="${ZIGGURAT_ATSPI_PREFIX:-$project/.zig-cache/managed/document-accessibility-out}"
evidence="${ZIGGURAT_ATSPI_EVIDENCE_DIR:-$prefix/atspi-evidence-${GDK_SCALE:-1}-$$}"
if [[ "$prefix" != /* || "$evidence" != /* ]]; then
    printf '%s\n' 'AT-SPI output and evidence paths must be absolute.' >&2
    exit 2
fi
cd "$project"
"${ZIG_BIN:-zig}" build build-smoke-document-accessibility-linux build-document-accessibility-atspi-client \
    -j1 --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    --prefix "$prefix" --summary all "$@"
mkdir -p -- "$(dirname -- "$evidence")"
mkdir -- "$evidence"
export GDK_BACKEND=x11 G_DEBUG=fatal-criticals
exec timeout --kill-after=5 35 dbus-run-session -- xvfb-run -a -s '-screen 0 1280x800x24' \
    bash "$project/scripts/document-accessibility-atspi.sh" --session "$prefix" "$evidence"

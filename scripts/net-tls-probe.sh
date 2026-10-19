#!/usr/bin/env bash
# Run the network client's real TLS probe against a loopback Python peer with
# disposable certificates. Needs openssl and python3; makes no external request.
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project/scripts/linux-cache-env.sh"
configure_linux_cache "$project" net-tls
zig="${ZIG_BIN:-zig}"
work="$(mktemp -d)"
peer=""
cleanup() {
    if [[ -n "$peer" ]]; then kill "$peer" 2>/dev/null || true; fi
    rm -rf -- "$work"
}
trap cleanup EXIT
for name in trusted untrusted; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
        -subj /CN=localhost -addext subjectAltName=DNS:localhost \
        -keyout "$work/$name-key.pem" -out "$work/$name-cert.pem" 2>/dev/null
done
cd "$project"
"$zig" build install-net-tls-probe --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" --prefix "$work/out" "$@"
mkfifo "$work/port"
python3 tests/net_tls_peer.py "$work/trusted-cert.pem" "$work/trusted-key.pem" >"$work/port" &
peer=$!
read -r port <"$work/port"
"$work/out/bin/net-tls-probe" "$port" "$work/trusted-cert.pem" "$work/untrusted-cert.pem"
wait "$peer"
peer=""

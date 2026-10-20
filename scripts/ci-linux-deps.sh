#!/bin/sh
# Install missing Debian/Ubuntu packages for Linux CI.
#
# Hosted runners start clean; a self-hosted runner keeps packages between jobs.
# Only packages that are not installed reach apt, so a provisioned runner needs
# neither network nor root. Otherwise apt runs as root or through passwordless
# sudo; an interactive password prompt is never attempted.
set -eu
[ "$#" -gt 0 ] || { echo 'usage: ci-linux-deps.sh PACKAGE...' >&2; exit 2; }
command -v dpkg-query >/dev/null 2>&1 || { echo 'ci-linux-deps: dpkg/apt runner required' >&2; exit 1; }
missing=
for package in "$@"; do
    status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    [ "$status" = installed ] || missing="$missing $package"
done
if [ -z "$missing" ]; then
    printf 'ci-linux-deps: all %s packages already installed\n' "$#"
    exit 0
fi
if [ "$(id -u)" -eq 0 ]; then
    run=
elif sudo -n true 2>/dev/null; then
    run='sudo -n'
else
    printf 'ci-linux-deps: missing packages without root or passwordless sudo:%s\n' "$missing" >&2
    exit 1
fi
printf 'ci-linux-deps: installing%s\n' "$missing"
# shellcheck disable=SC2086
$run env DEBIAN_FRONTEND=noninteractive apt-get update
# shellcheck disable=SC2086
$run env DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y $missing

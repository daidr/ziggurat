#!/bin/sh
# Install, launch, upgrade, refuse downgrade, uninstall and purge a fixture
# through the real setup program in a private HOME. Run after
# `zig build build-setup-smoke`; it touches nothing outside its temp dir.
set -eu
bin=${1:-zig-out/bin}
bin=$(cd "$bin" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
unset XDG_DATA_HOME
mkdir -p "$HOME" "$work/v1" "$work/v2"
id=org.ziggurat.SetupSmoke
cp "$bin/setup-fixture-1.0.0" "$work/v1/fixture"
cp "$bin/setup-fixture-1.1.0" "$work/v2/fixture"
printf 'Test fixture only.\n' > "$work/LICENSE.txt"
"$bin/ziggurat-update" pack "$work/v1.zip" "Setup Smoke" "$id" linux-x86_64 1.0.0.0 fixture "$work/v1/fixture" "$work/LICENSE.txt"
"$bin/ziggurat-update" pack "$work/v2.zip" "Setup Smoke" "$id" linux-x86_64 1.1.0.0 fixture "$work/v2/fixture" "$work/LICENSE.txt"
"$bin/ziggurat" package setup --zip "$work/v1.zip" --stub "$bin/ziggurat-setup" --output "$work/setup1" >/dev/null
"$bin/ziggurat" package setup --zip "$work/v2.zip" --stub "$bin/ziggurat-setup" --output "$work/setup2" >/dev/null
root="$HOME/.local/share/$id/install"

mkdir -p "$work/occupied" && echo keep > "$work/occupied/file"
if "$work/setup1" --silent --dir "$work/occupied" 2>/dev/null; then echo "installed into a non-empty directory" >&2; exit 1; fi
test "$(cat "$work/occupied/file")" = keep && test ! -e "$work/occupied/install.json"

"$work/setup1" --silent
test -x "$root/fixture" && test -x "$root/uninstall" && test -f "$root/releases/linux-x86_64-1.0.0.0/fixture"
grep -q 'Exec=' "$HOME/.local/share/applications/$id.desktop"
ZIGGURAT_SETUP_SMOKE_OUT="$work/out" "$HOME/.local/bin/fixture" hello "two words"
test "$(cat "$work/out")" = "1.0.0 hello two words"

"$work/setup2" --silent
ZIGGURAT_SETUP_SMOKE_OUT="$work/out" "$root/fixture" again
test "$(cat "$work/out")" = "1.1.0 again"
if "$work/setup1" --silent 2>/dev/null; then echo "downgrade was accepted" >&2; exit 1; fi
test -f "$root/archives/linux-x86_64-1.1.0.0.zip"

mkdir -p "$HOME/.local/share/$id/settings"
"$root/uninstall" --silent
test ! -e "$root" && test ! -e "$HOME/.local/bin/fixture" && test ! -e "$HOME/.local/share/applications/$id.desktop"
test -d "$HOME/.local/share/$id/settings"
"$work/setup2" --silent
"$root/uninstall" --silent --purge
test ! -e "$HOME/.local/share/$id"

# Debian package of the same release: inspect it, and install it only when
# passwordless root is available (CI runners); the check removes it again.
"$bin/ziggurat" package deb --zip "$work/v2.zip" --maintainer "Ziggurat tests <tests@example.invalid>" --output "$work/fixture.deb" >/dev/null
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --info "$work/fixture.deb" > "$work/info"
  grep -q 'Package: fixture' "$work/info"
  dpkg-deb --contents "$work/fixture.deb" > "$work/contents"
  grep -q './usr/lib/fixture/fixture' "$work/contents"
  grep -q "./usr/share/applications/$id.desktop" "$work/contents"
  if [ "$(id -u)" = 0 ]; then sudo=""; elif sudo -n true 2>/dev/null; then sudo="sudo -n"; else sudo=none; fi
  if [ "$sudo" != none ] && ! dpkg -s fixture >/dev/null 2>&1; then
    $sudo dpkg -i "$work/fixture.deb" >/dev/null
    ZIGGURAT_SETUP_SMOKE_OUT="$work/out" /usr/bin/fixture deb
    test "$(cat "$work/out")" = "1.1.0 deb"
    $sudo dpkg -r fixture >/dev/null
    test ! -e /usr/lib/fixture
  fi
fi
echo "setup smoke passed"

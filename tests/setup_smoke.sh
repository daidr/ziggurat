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

# The app's hooks: init can stop the install, install runs once the app is
# in place, uninstall before its folder goes.
hooks="$work/hooks"
"$bin/ziggurat" package setup --zip "$work/v2.zip" --stub "$bin/ziggurat-setup" --output "$work/setup-refused" \
  --hook-init 'test ! -e "$(dirname "$ZIGGURAT_INSTALL_DIR")/refuse"' >/dev/null
mkdir -p "$HOME/.local/share/$id" && touch "$HOME/.local/share/$id/refuse"
if "$work/setup-refused" --silent 2>/dev/null; then echo "a failing init hook did not stop the install" >&2; exit 1; fi
test ! -e "$root"
rm "$HOME/.local/share/$id/refuse"
"$bin/ziggurat" package setup --zip "$work/v2.zip" --stub "$bin/ziggurat-setup" --output "$work/setup-hooks" \
  --hook-init "echo init \$ZIGGURAT_SCOPE \$ZIGGURAT_VERSION \$ZIGGURAT_SILENT >> '$hooks'" \
  --hook-install "test -x \"\$ZIGGURAT_APP\" && echo install \$(basename \"\$ZIGGURAT_INSTALL_DIR\") >> '$hooks'" \
  --hook-uninstall "test -x \"\$ZIGGURAT_APP\" && echo uninstall >> '$hooks'" >/dev/null
"$work/setup-hooks" --silent
test "$(cat "$hooks")" = "init user 1.1.0.0 1
install install"
"$root/uninstall" --silent --purge
test "$(tail -n 1 "$hooks")" = uninstall
test ! -e "$root"

# Several commands: each is linked unless another program has the name; a
# later version's names replace an earlier's, and uninstalling removes them.
mkdir -p "$HOME/.local/bin" && printf '#!/bin/sh\n' > "$HOME/.local/bin/taken" && chmod +x "$HOME/.local/bin/taken"
"$bin/ziggurat" package setup --zip "$work/v1.zip" --stub "$bin/ziggurat-setup" --output "$work/setup-commands1" --command "fixture-app,fx,taken" >/dev/null
"$bin/ziggurat" package setup --zip "$work/v2.zip" --stub "$bin/ziggurat-setup" --output "$work/setup-commands2" --command "fixture-app,fy" >/dev/null
"$work/setup-commands1" --silent
ZIGGURAT_SETUP_SMOKE_OUT="$work/out" "$HOME/.local/bin/fx" short
test "$(cat "$work/out")" = "1.0.0 short"
test -L "$HOME/.local/bin/fixture-app" && test ! -L "$HOME/.local/bin/taken" && test ! -e "$HOME/.local/bin/fixture"
"$work/setup-commands2" --silent
test -L "$HOME/.local/bin/fy" && test ! -e "$HOME/.local/bin/fx"
"$root/uninstall" --silent --purge
test ! -e "$HOME/.local/bin/fixture-app" && test ! -e "$HOME/.local/bin/fy" && test -f "$HOME/.local/bin/taken"
rm "$HOME/.local/bin/taken"
if "$bin/ziggurat" package setup --zip "$work/v2.zip" --stub "$bin/ziggurat-setup" --output "$work/setup-bad" --command "a/b" 2>/dev/null; then echo "a command with a slash was accepted" >&2; exit 1; fi

# Arch Linux: the PKGBUILD next to the package, whose package() runs here
# as makepkg runs it over the extracted package.
"$bin/ziggurat" package pkgbuild --zip "$work/v2.zip" --command "fixture,fx" >/dev/null
grep -q "^source=('v2.zip')" "$work/PKGBUILD"
grep -q "^sha256sums=('$(sha256sum "$work/v2.zip" | cut -d' ' -f1)')" "$work/PKGBUILD"
grep -q "^pkgver='1.1.0.0'" "$work/PKGBUILD"
grep -q "^depends=('gtk3' 'pango')" "$work/PKGBUILD"
if command -v bash >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  mkdir -p "$work/arch/src" && (cd "$work/arch/src" && unzip -q "$work/v2.zip")
  bash -c "set -e; srcdir='$work/arch/src'; pkgdir='$work/arch/pkg'; . '$work/PKGBUILD'; package"
  test -x "$work/arch/pkg/usr/lib/fixture/fixture" && test "$(readlink "$work/arch/pkg/usr/bin/fx")" = ../lib/fixture/fixture
  test -f "$work/arch/pkg/usr/share/licenses/fixture/LICENSE"
  grep -q 'Exec="/usr/lib/fixture/fixture" %U' "$work/arch/pkg/usr/share/applications/$id.desktop"
fi

# Debian package of the same release: inspect it, and install it only when
# passwordless root is available (CI runners); the check removes it again.
"$bin/ziggurat" package deb --zip "$work/v2.zip" --maintainer "Ziggurat tests <tests@example.invalid>" --command "fixture,fx" --output "$work/fixture.deb" >/dev/null
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --info "$work/fixture.deb" > "$work/info"
  grep -q 'Package: fixture' "$work/info"
  dpkg-deb --contents "$work/fixture.deb" > "$work/contents"
  grep -q './usr/lib/fixture/fixture' "$work/contents"
  grep -q "./usr/share/applications/$id.desktop" "$work/contents"
  grep -q './usr/bin/fx -> ../lib/fixture/fixture' "$work/contents"
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

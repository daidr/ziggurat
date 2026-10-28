#!/bin/sh
# Build a fixture project as a universal macOS app with the real CLI, then
# check what macOS itself says about it: both architectures, a valid
# Info.plist, an ad-hoc signature that passes strict verification, a disk
# image that verifies and shows the app beside an Applications link with
# its layout and volume icon, and install.sh copying the app out of the
# image and removing it again. Run on a Mac after `zig build cli`; it touches
# nothing outside its temp dir.
set -eu
bin=${1:-zig-out/bin}
bin=$(cd "$bin" && pwd)
framework=$(pwd)
work=$(mktemp -d)
mounted=
cleanup() {
    if [ -n "$mounted" ]; then hdiutil detach -force "$mounted" >/dev/null 2>&1 || true; fi
    rm -rf "${work:?}"
}
trap cleanup EXIT
fail() {
    echo "macos_packaging: $*" >&2
    exit 1
}

project="$work/project"
mkdir -p "$project/src"
cat >"$project/build.zig" <<'ZIG'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.standardTargetOptions(.{}), .optimize = b.standardOptimizeOption(.{}) });
    b.installArtifact(b.addExecutable(.{ .name = "smoke", .root_module = module }));
}
ZIG
cat >"$project/src/main.zig" <<'ZIG'
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "packaging smoke\n");
}
ZIG
cat >"$project/ziggurat.json" <<'JSON'
{"name": "Packaging Smoke", "identity": "org.ziggurat.PackagingSmoke", "executable": "smoke", "template": "native", "version": "1.2.0.0",
 "icon": "icon.png", "urlSchemes": ["packaging-smoke"], "fileAssociations": [{"ext": ["pksmoke"]}],
 "i18n": {"dir": "locales", "source": "en"},
 "macos": {"infoPlist": {"LSApplicationCategoryType": "public.app-category.developer-tools"}}}
JSON
mkdir -p "$project/locales"
printf '{"appName": "Packaging Smoke"}\n' >"$project/locales/en.json"
printf '{"appName": "Paketierungstest"}\n' >"$project/locales/de.json"
cp "$framework/assets/application.png" "$project/icon.png"

cd "$project"
"$bin/ziggurat" build --platform macos/universal --package
app="dist/macos-universal/Packaging Smoke.app"
dmg="dist/macos-universal/smoke-1.2.0.0.dmg"
executable="$app/Contents/MacOS/Packaging Smoke"

archs=$(lipo -archs "$executable")
case "$archs" in *arm64*) ;; *) fail "no arm64 in $archs" ;; esac
case "$archs" in *x86_64*) ;; *) fail "no x86_64 in $archs" ;; esac
test "$("$executable")" = "packaging smoke" || fail "the bundle's executable did not run"
plutil -lint "$app/Contents/Info.plist" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = org.ziggurat.PackagingSmoke
test "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = 1.2.0
test "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw "$app/Contents/Info.plist")" = packaging-smoke
test "$(plutil -extract LSApplicationCategoryType raw "$app/Contents/Info.plist")" = public.app-category.developer-tools
plutil -lint "$app/Contents/Resources/de.lproj/InfoPlist.strings" >/dev/null
test "$(plutil -extract CFBundleName raw "$app/Contents/Resources/de.lproj/InfoPlist.strings")" = Paketierungstest
sips -g pixelWidth "$app/Contents/Resources/AppIcon.icns" >/dev/null || fail "the icon is not an icns macOS reads"
codesign --verify --strict --deep --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -q 'Signature=adhoc' || fail "the bundle is not signed ad hoc"

hdiutil verify "$dmg" >/dev/null
hdiutil imageinfo "$dmg" | grep -q 'Format: ULMO' || fail "the disk image is not LZMA compressed"
mkdir "$work/mnt"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$work/mnt" "$dmg" >/dev/null
mounted="$work/mnt"
test -d "$work/mnt/Packaging Smoke.app" || fail "the disk image holds no app"
test "$(readlink "$work/mnt/Applications")" = /Applications || fail "no Applications link"
test -s "$work/mnt/.DS_Store" || fail "no window layout"
test -s "$work/mnt/.VolumeIcon.icns" || fail "no volume icon"
codesign --verify --strict --deep "$work/mnt/Packaging Smoke.app"
hdiutil detach "$work/mnt" >/dev/null
mounted=

# The same app from the update package, and from install.sh.
"$bin/ziggurat" package app --zip dist/org.ziggurat.PackagingSmoke-macos-universal-1.2.0.0.zip --output "$work/again" >/dev/null
codesign --verify --strict --deep "$work/again/Packaging Smoke.app"
"$bin/ziggurat" package install-script --zip dist/org.ziggurat.PackagingSmoke-macos-universal-1.2.0.0.zip --output dist/macos-universal/install.sh >/dev/null
SMOKE_INSTALL_DIR="$work/Applications" SMOKE_NO_OPEN=1 sh dist/macos-universal/install.sh
codesign --verify --strict --deep "$work/Applications/Packaging Smoke.app"
SMOKE_INSTALL_DIR="$work/Applications" sh dist/macos-universal/install.sh --uninstall
test ! -e "$work/Applications/Packaging Smoke.app" || fail "uninstall left the app"

"$bin/ziggurat" doctor || true
echo "macOS packaging smoke passed"

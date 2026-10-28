//! install.sh: installs the app for the current user, without root or a
//! package manager.
//!
//! On Linux it runs the app's setup installer in user scope
//! (`$XDG_DATA_HOME/<identity>/install`, a desktop entry and a command in
//! ~/.local/bin), where the app can update itself: the installer it is
//! given, else the one of its version next to it, else the one it
//! downloads: from the newest GitHub release whose tag has the prefix (read
//! from the GitHub API), or from a download URL. It warns when a WebView
//! app's WebKitGTK is missing, with the command that installs it, and
//! `--uninstall` runs the installed uninstaller.
//!
//! On macOS it takes the app's disk image the same way: the one for the
//! Mac's architecture (Apple silicon even from a shell under Rosetta), else
//! the universal one. It quits the app if it runs, copies the bundle to
//! /Applications, or ~/Applications when the user cannot write there or it
//! is already there, and opens it. curl sets no quarantine, so the app
//! opens without Gatekeeper's prompt for downloaded apps. `--uninstall`
//! removes the bundle.
//!
//!     curl -fsSL https://github.com/OWNER/REPO/releases/latest/download/install.sh | sh
//!
//! For tests, `<STEM>_INSTALL_DIR` is the folder of the bundle on macOS and
//! `<STEM>_NO_OPEN=1` leaves the app closed.
const std = @import("std");

pub const name = "install.sh";

pub const Options = struct {
    /// Display name.
    app_name: []const u8,
    identity: []const u8,
    /// The executable's name without extension, which names the installer
    /// as `ziggurat package setup` does: `<stem>-<version>-<target>-setup`.
    stem: []const u8,
    version: []const u8,
    /// OWNER/NAME of the GitHub repository whose releases hold the installers.
    github: ?[]const u8 = null,
    /// Only releases whose tags start with it, for repositories that
    /// release other things too.
    tag_prefix: []const u8 = "",
    /// Where the installers are served, ending in `/`, as a bucket's URL.
    url: ?[]const u8 = null,
    /// The app shows pages and needs WebKitGTK.
    webview: bool = false,
    /// The file name of the macOS bundle, `<name>.app`.
    bundle: []const u8 = "",
};

/// Writes the script. Every value is quoted for the shell.
pub fn write(writer: *std.Io.Writer, options: Options) !void {
    const github = options.github orelse "";
    const url = options.url orelse "";
    try writer.writeAll("#!/bin/sh\n# Installs ");
    try writer.writeAll(oneLine(options.app_name));
    try writer.writeAll(
        \\ for the current user, without root. On Linux: the app in
        \\# ${XDG_DATA_HOME:-~/.local/share}/IDENTITY/install, a command in ~/.local/bin and its
        \\# entry in the applications menu, through its setup installer. On macOS: the
        \\# app of its disk image in /Applications, or ~/Applications when you cannot
        \\# write there. Made by `ziggurat package install-script`.
        \\#
        \\
    );
    if (github.len > 0) try writer.print("#   curl -fsSL https://github.com/{s}/releases/latest/download/install.sh | sh\n", .{github});
    if (url.len > 0) try writer.print("#   curl -fsSL {s}install.sh | sh\n", .{oneLine(url)});
    try writer.writeAll(
        \\#   sh install.sh [SETUP]
        \\#   sh install.sh --uninstall
        \\set -eu
        \\
        \\
    );
    try assign(writer, "app_name", options.app_name);
    try assign(writer, "identity", options.identity);
    try assign(writer, "name", options.stem);
    try assign(writer, "version", options.version);
    try writer.writeAll("# Where the installers are: the newest release of the repository tagged\n# with the prefix, or a download URL.\n");
    try assign(writer, "repository", github);
    try assign(writer, "tag_prefix", options.tag_prefix);
    try assign(writer, "base_url", url);
    try assign(writer, "needs_webkit", if (options.webview) "1" else "");
    try assign(writer, "bundle", options.bundle);
    var buffer: [128]u8 = undefined;
    const length = @min(buffer.len, options.stem.len);
    for (options.stem[0..length], buffer[0..length]) |byte, *out| out.* = if (std.ascii.isAlphanumeric(byte)) std.ascii.toUpper(byte) else '_';
    try writer.print(
        \\# For tests only: the folder of the macOS bundle, and leaving the app closed.
        \\install_dir="${{{0s}_INSTALL_DIR:-}}"
        \\no_open="${{{0s}_NO_OPEN:-}}"
        \\
    , .{buffer[0..length]});
    try writer.writeAll(body);
}

fn oneLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len];
}

fn assign(writer: *std.Io.Writer, variable: []const u8, value: []const u8) !void {
    try writer.print("{s}=", .{variable});
    try quote(writer, value);
    try writer.writeByte('\n');
}

/// Quotes `text` for a POSIX shell.
pub fn quote(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| if (byte == '\'') try writer.writeAll("'\\''") else try writer.writeByte(byte);
    try writer.writeByte('\'');
}

const body =
    \\
    \\usage() {
    \\  cat <<EOF
    \\Usage: sh install.sh [SETUP | DMG | --uninstall]
    \\
    \\Installs $app_name for you. On Linux: SETUP, else $name-$version-<target>-setup
    \\next to this script, else the latest version, which it downloads. On macOS:
    \\DMG, else $name-$version-<arch>.dmg or $name-$version.dmg next to this script,
    \\else the latest version, which it downloads. --uninstall removes it and leaves
    \\its settings and data in place.
    \\EOF
    \\}
    \\
    \\fail() {
    \\  echo "install.sh: $*" >&2
    \\  exit 1
    \\}
    \\
    \\fetch() {
    \\  if command -v curl >/dev/null 2>&1; then
    \\    curl -fsSL "$1"
    \\  else
    \\    wget -qO- "$1"
    \\  fi
    \\}
    \\
    \\main() {
    \\  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    \\  root="$data_home/$identity/install"
    \\  if [ $# -gt 1 ]; then
    \\    usage >&2
    \\    exit 2
    \\  fi
    \\  system="$(uname -s)"
    \\  case "${1:-}" in
    \\  -h | --help)
    \\    usage
    \\    return
    \\    ;;
    \\  --uninstall)
    \\    if [ "$system" = Darwin ]; then uninstall_mac; else uninstall; fi
    \\    return
    \\    ;;
    \\  -*)
    \\    usage >&2
    \\    exit 2
    \\    ;;
    \\  esac
    \\
    \\  if [ "$system" = Darwin ]; then
    \\    install_mac "${1:-}"
    \\    return
    \\  fi
    \\  [ "$system" = Linux ] || fail "this installs $app_name on Linux and macOS"
    \\  [ "$(id -u)" != 0 ] || fail "run this as the user to install $app_name for, not as root"
    \\  case "$(uname -m)" in
    \\  x86_64 | amd64) target=linux-x86_64 ;;
    \\  aarch64 | arm64) target=linux-aarch64 ;;
    \\  *) fail "$app_name is not made for $(uname -m)" ;;
    \\  esac
    \\
    \\  work="$(mktemp -d)"
    \\  trap 'rm -rf "${work:?}"' EXIT
    \\  trap 'exit 1' HUP INT TERM
    \\
    \\  setup="${1:-}"
    \\  file="$name-$version-$target-setup"
    \\  if [ -z "$setup" ] && [ -f "$0" ] && [ -f "$(dirname -- "$0")/$file" ]; then
    \\    setup="$(dirname -- "$0")/$file"
    \\  fi
    \\  if [ -z "$setup" ]; then
    \\    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "downloading $app_name needs curl or wget"
    \\    if [ -n "$repository" ]; then
    \\      url="$(latest_asset "-$target-setup" "")" || fail "could not list the releases of $repository"
    \\      [ -n "$url" ] || fail "no release of $repository has an installer of $app_name for $target"
    \\    elif [ -n "$base_url" ]; then
    \\      url="$base_url$file"
    \\    else
    \\      fail "no $file next to this script: pass the installer to run"
    \\    fi
    \\    echo "Downloading $app_name from $url"
    \\    fetch "$url" >"$work/setup" || fail "could not download $url"
    \\    setup="$work/setup"
    \\  fi
    \\  [ -f "$setup" ] || fail "no installer at $setup"
    \\  chmod +x "$setup" 2>/dev/null || true
    \\  # The installer checks its own contents, installs, and says where.
    \\  "$setup" --scope user || fail "the installer failed"
    \\  if [ -n "$needs_webkit" ] && ! has_webkit; then
    \\    echo "$app_name needs WebKitGTK 4.1, which is not installed. Install it with:" >&2
    \\    echo "  $(webkit_install_command)" >&2
    \\  fi
    \\}
    \\
    \\# latest_asset prints the URL of the first asset of the newest release
    \\# tagged $tag_prefix, neither a draft nor a prerelease, whose name starts
    \\# with "$name-" and ends with END; else of one that ends with OTHER (when it
    \\# is not empty) with no architecture before it. The GitHub API lists
    \\# releases newest first, each with tag_name, draft and prerelease before the
    \\# browser_download_url of its assets.
    \\latest_asset() {
    \\  page=1
    \\  while [ "$page" -le 10 ]; do
    \\    fetch "https://api.github.com/repos/$repository/releases?per_page=100&page=$page" >"$work/releases.json" || return 1
    \\    tr -d '\n' <"$work/releases.json" |
    \\      grep -oE '"(tag_name|draft|prerelease|browser_download_url)": *("[^"]*"|true|false)' >"$work/fields" || true
    \\    found="$(awk -v prefix="$tag_prefix" -v start="$name-" -v end="$1" -v other="$2" '
    \\      function ends(text, suffix) { return length(text) > length(suffix) && substr(text, length(text) - length(suffix) + 1) == suffix }
    \\      function settle() { if (fallback != "") { print fallback; printed = 1; exit } }
    \\      /^"tag_name"/ { settle(); sub(/^"tag_name": *"/, ""); sub(/"$/, ""); tag = $0; draft = 0; ok = 0; next }
    \\      /^"draft"/ { draft = /true$/; next }
    \\      /^"prerelease"/ { ok = !draft && /false$/ && index(tag, prefix) == 1; next }
    \\      /^"browser_download_url"/ {
    \\        if (!ok) next
    \\        sub(/^"browser_download_url": *"/, ""); sub(/"$/, "")
    \\        asset = $0; sub(/.*\//, "", asset)
    \\        if (index(asset, start) != 1) next
    \\        if (ends(asset, end)) { print; printed = 1; exit }
    \\        if (other != "" && fallback == "" && ends(asset, other) && asset !~ /-(aarch64|x86_64)\.dmg$/) fallback = $0
    \\      }
    \\      END { if (!printed && fallback != "") print fallback }
    \\    ' "$work/fields")"
    \\    if [ -n "$found" ]; then
    \\      echo "$found"
    \\      return
    \\    fi
    \\    # A full page leads to the next.
    \\    [ "$(grep -c '^"tag_name"' "$work/fields" || true)" -ge 100 ] || return 0
    \\    page=$((page + 1))
    \\  done
    \\}
    \\
    \\# has_webkit fails when the library cache has no WebKitGTK 4.1. It succeeds
    \\# when it cannot tell, as without ldconfig or its cache.
    \\has_webkit() {
    \\  for ldconfig in "$(command -v ldconfig || true)" /sbin/ldconfig /usr/sbin/ldconfig; do
    \\    [ -n "$ldconfig" ] && [ -x "$ldconfig" ] || continue
    \\    "$ldconfig" -p >"$work/libs" 2>/dev/null || return 0
    \\    grep -qF libc.so.6 "$work/libs" || return 0
    \\    grep -qF libwebkit2gtk-4.1.so.0 "$work/libs"
    \\    return
    \\  done
    \\  return 0
    \\}
    \\
    \\webkit_install_command() {
    \\  distro=
    \\  for file in /etc/os-release /usr/lib/os-release; do
    \\    if [ -f "$file" ]; then
    \\      distro="$(. "$file" && echo "${ID:-} ${ID_LIKE:-}")" || true
    \\      break
    \\    fi
    \\  done
    \\  for id in $distro; do
    \\    case "$id" in
    \\    debian | ubuntu) echo "sudo apt install libwebkit2gtk-4.1-0" && return ;;
    \\    fedora) echo "sudo dnf install webkit2gtk4.1" && return ;;
    \\    arch) echo "sudo pacman -S webkit2gtk-4.1" && return ;;
    \\    opensuse* | suse) echo "sudo zypper install libwebkit2gtk-4_1-0" && return ;;
    \\    esac
    \\  done
    \\  echo "the package manager of your system (the library is libwebkit2gtk-4.1.so.0)"
    \\}
    \\
    \\uninstall() {
    \\  [ -x "$root/uninstall" ] || fail "$app_name is not installed in $root"
    \\  "$root/uninstall"
    \\}
    \\
    \\# mac_folder prints the folder of the app: where it is installed, else
    \\# /Applications, else, when the user cannot write there, ~/Applications.
    \\mac_folder() {
    \\  if [ -n "$install_dir" ]; then
    \\    echo "$install_dir"
    \\    return
    \\  fi
    \\  for dir in /Applications "$HOME/Applications"; do
    \\    if [ -d "$dir/$bundle" ]; then
    \\      echo "$dir"
    \\      return
    \\    fi
    \\  done
    \\  if [ -w /Applications ]; then
    \\    echo /Applications
    \\  else
    \\    echo "$HOME/Applications"
    \\  fi
    \\}
    \\
    \\mac_running() {
    \\  [ "$(osascript -e "application id \"$identity\" is running" </dev/null 2>/dev/null)" = true ]
    \\}
    \\
    \\# quit_mac asks the app to quit and, after 10 s, stops what still runs from
    \\# the bundle, as an app in the menu bar keeps running without windows.
    \\quit_mac() {
    \\  mac_running || return 0
    \\  echo "Quitting $app_name"
    \\  osascript -e "tell application id \"$identity\" to quit" </dev/null >/dev/null 2>&1 || true
    \\  waited=0
    \\  while mac_running && [ "$waited" -lt 10 ]; do
    \\    sleep 1
    \\    waited=$((waited + 1))
    \\  done
    \\  if mac_running; then
    \\    pkill -f "$1/$bundle/Contents/MacOS/" 2>/dev/null || true
    \\    sleep 1
    \\    ! mac_running || fail "$app_name is still running: quit it and run this again"
    \\  fi
    \\}
    \\
    \\install_mac() {
    \\  [ -n "$bundle" ] || fail "$app_name is not made for macOS"
    \\  arch="$(uname -m)"
    \\  # A shell under Rosetta says x86_64 on Apple silicon.
    \\  if [ "$arch" = x86_64 ] && [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = 1 ]; then arch=arm64; fi
    \\  case "$arch" in
    \\  arm64) arch=aarch64 ;;
    \\  x86_64) ;;
    \\  *) fail "$app_name is not made for $arch" ;;
    \\  esac
    \\
    \\  work="$(mktemp -d)"
    \\  mount=
    \\  trap 'if [ -n "$mount" ]; then hdiutil detach -force "$mount" >/dev/null 2>&1 || true; fi; rm -rf "${work:?}"' EXIT
    \\  trap 'exit 1' HUP INT TERM
    \\
    \\  dmg="$1"
    \\  if [ -z "$dmg" ] && [ -f "$0" ]; then
    \\    for file in "$name-$version-$arch.dmg" "$name-$version.dmg"; do
    \\      if [ -f "$(dirname -- "$0")/$file" ]; then
    \\        dmg="$(dirname -- "$0")/$file"
    \\        break
    \\      fi
    \\    done
    \\  fi
    \\  if [ -z "$dmg" ]; then
    \\    if [ -n "$repository" ]; then
    \\      url="$(latest_asset "-$arch.dmg" ".dmg")" || fail "could not list the releases of $repository"
    \\      [ -n "$url" ] || fail "no release of $repository has a disk image of $app_name for $arch"
    \\    elif [ -n "$base_url" ]; then
    \\      url="$base_url$name-$version-$arch.dmg"
    \\      curl -fsIL "$url" >/dev/null 2>&1 || url="$base_url$name-$version.dmg"
    \\    else
    \\      fail "no $name-$version-$arch.dmg next to this script: pass the disk image to install"
    \\    fi
    \\    echo "Downloading $app_name from $url"
    \\    fetch "$url" >"$work/app.dmg" || fail "could not download $url"
    \\    dmg="$work/app.dmg"
    \\  fi
    \\  [ -f "$dmg" ] || fail "no disk image at $dmg"
    \\
    \\  mkdir "$work/mnt"
    \\  hdiutil attach -readonly -nobrowse -noautoopen -noverify -mountpoint "$work/mnt" "$dmg" >/dev/null || fail "could not open $dmg"
    \\  mount="$work/mnt"
    \\  [ -d "$mount/$bundle" ] || fail "$dmg holds no $bundle"
    \\
    \\  folder="$(mac_folder)"
    \\  mkdir -p "$folder" || fail "could not create $folder"
    \\  quit_mac "$folder"
    \\  echo "Installing $app_name in $folder"
    \\  # Copied beside the old bundle first, which stays until the copy is whole.
    \\  rm -rf "${folder:?}/.${bundle:?}.new"
    \\  ditto "$mount/$bundle" "$folder/.$bundle.new" || fail "could not copy $bundle to $folder"
    \\  rm -rf "${folder:?}/${bundle:?}"
    \\  mv "$folder/.$bundle.new" "$folder/$bundle" || fail "could not install $bundle in $folder"
    \\  hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
    \\  mount=
    \\  [ -n "$no_open" ] || open "$folder/$bundle"
    \\  echo "Installed $app_name in $folder"
    \\}
    \\
    \\uninstall_mac() {
    \\  [ -n "$bundle" ] || fail "$app_name is not made for macOS"
    \\  folder="$(mac_folder)"
    \\  [ -d "$folder/$bundle" ] || fail "$app_name is not installed in /Applications or ~/Applications"
    \\  quit_mac "$folder"
    \\  rm -rf "${folder:?}/${bundle:?}"
    \\  echo "Removed $app_name from $folder"
    \\}
    \\
    \\main "$@"
    \\
;

const testing = std.testing;

fn script(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try write(&out.writer, options);
    return out.toOwnedSlice();
}

test "values are quoted for the shell" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try quote(&out.writer, "it's $HOME");
    try testing.expectEqualStrings("'it'\\''s $HOME'", out.written());
}

test "the script runs the installer next to it, a downloaded one, and the uninstaller" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    const target = switch (@import("builtin").cpu.arch) {
        .x86_64 => "linux-x86_64",
        .aarch64 => "linux-aarch64",
        else => return error.SkipZigTest,
    };
    try temp.dir.makePath("home");
    try temp.dir.makePath("bin");
    const calls = try std.fs.path.join(allocator, &.{ root, "calls" });
    const installer = try std.fmt.allocPrint(allocator, "#!/bin/sh\necho \"$0 $*\" >> '{s}'\n", .{calls});
    try temp.dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "tool-1.2.0.0-{s}-setup", .{target}), .data = installer, .flags = .{ .mode = 0o755 } });
    // Releases from the API: a draft, another app's tag, then ours.
    const releases = try std.fmt.allocPrint(allocator,
        \\[{{"tag_name": "tool-v2", "draft": true, "prerelease": false, "assets": [{{"browser_download_url": "https://x/tool-2-{0s}-setup"}}]}},
        \\ {{"tag_name": "other-v9", "draft": false, "prerelease": false, "assets": [{{"browser_download_url": "https://x/tool-9-{0s}-setup"}}]}},
        \\ {{"tag_name": "tool-v1.3", "draft": false,
        \\   "prerelease": false, "assets": [{{"browser_download_url": "https://x/tool-1.3.0.0-{0s}.zip"}}, {{"browser_download_url": "https://x/tool-1.3.0.0-{0s}-setup"}}]}}]
    , .{target});
    try temp.dir.writeFile(.{ .sub_path = "releases.json", .data = releases });
    const curl = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\echo "curl $*" >> '{0s}/calls'
        \\case "$2" in
        \\*api.github.com*) cat '{0s}/releases.json' ;;
        \\*) cat '{0s}/tool-1.2.0.0-{1s}-setup' ;;
        \\esac
        \\
    , .{ root, target });
    try temp.dir.writeFile(.{ .sub_path = "bin/curl", .data = curl, .flags = .{ .mode = 0o755 } });
    // As a user, also where tests run as root.
    try temp.dir.writeFile(.{ .sub_path = "bin/id", .data = "#!/bin/sh\necho 1000\n", .flags = .{ .mode = 0o755 } });

    const local = try script(allocator, .{ .app_name = "Tool's", .identity = "com.example.tool", .stem = "tool", .version = "1.2.0.0" });
    try temp.dir.writeFile(.{ .sub_path = name, .data = local });
    const remote = try script(allocator, .{ .app_name = "Tool", .identity = "com.example.tool", .stem = "tool", .version = "1.2.0.0", .github = "owner/apps", .tag_prefix = "tool-" });
    try temp.dir.makePath("remote");
    try temp.dir.writeFile(.{ .sub_path = "remote/install.sh", .data = remote });
    try temp.dir.makePath("home/data/com.example.tool/install");
    try temp.dir.writeFile(.{ .sub_path = "home/data/com.example.tool/install/uninstall", .data = installer, .flags = .{ .mode = 0o755 } });

    var environment = std.process.EnvMap.init(allocator);
    try environment.put("HOME", try std.fs.path.join(allocator, &.{ root, "home" }));
    try environment.put("XDG_DATA_HOME", try std.fs.path.join(allocator, &.{ root, "home", "data" }));
    try environment.put("PATH", try std.fmt.allocPrint(allocator, "{s}/bin:/usr/bin:/bin", .{root}));
    for ([_][]const []const u8{ &.{ "sh", "install.sh" }, &.{ "sh", "remote/install.sh" }, &.{ "sh", "install.sh", "--uninstall" } }) |argv| {
        const result = try std.process.Child.run(.{ .allocator = allocator, .argv = argv, .cwd = root, .env_map = &environment });
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("{s}{s}\n", .{ result.stdout, result.stderr });
            return error.ScriptFailed;
        }
    }
    const log = try temp.dir.readFileAlloc(allocator, "calls", 8192);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, log, "\n"), '\n');
    try testing.expect(std.mem.endsWith(u8, lines.next().?, try std.fmt.allocPrint(allocator, "tool-1.2.0.0-{s}-setup --scope user", .{target})));
    try testing.expectEqualStrings("curl -fsSL https://api.github.com/repos/owner/apps/releases?per_page=100&page=1", lines.next().?);
    try testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "curl -fsSL https://x/tool-1.3.0.0-{s}-setup", .{target}), lines.next().?);
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "/setup --scope user"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "com.example.tool/install/uninstall "));
    try testing.expectEqual(null, lines.next());
}

test "on macOS the script installs the bundle of the newest disk image, quitting the app first" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    try temp.dir.makePath("bin");
    try temp.dir.makePath("home");
    // The tools of macOS: hdiutil "mounts" an image by copying the bundle
    // named in it, and the app runs until it is asked to quit.
    const stubs = [_][2][]const u8{
        .{ "uname", "#!/bin/sh\ncase \"$1\" in -s) echo Darwin ;; -m) echo x86_64 ;; esac\n" },
        .{ "sysctl", "#!/bin/sh\necho 1\n" },
        .{ "hdiutil", "#!/bin/sh\necho \"hdiutil $*\" >> '{0s}/calls'\nif [ \"$1\" = attach ]; then for last; do :; done; mkdir -p \"$7/Tool.app/Contents\"; cp \"$last\" \"$7/Tool.app/Contents/image\"; fi\n" },
        .{ "ditto", "#!/bin/sh\ncp -R \"$1\" \"$2\"\n" },
        .{ "osascript", "#!/bin/sh\necho \"osascript $*\" >> '{0s}/calls'\ncase \"$2\" in *quit*) rm -f '{0s}/running' ;; *) [ -f '{0s}/running' ] && echo true || echo false ;; esac\n" },
        .{ "open", "#!/bin/sh\necho \"open $*\" >> '{0s}/calls'\n" },
        .{ "curl", "#!/bin/sh\necho \"curl $*\" >> '{0s}/calls'\ncase \"$2\" in *api.github.com*) cat '{0s}/releases.json' ;; *) echo \"$2\" ;; esac\n" },
    };
    for (stubs) |stub| try temp.dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "bin/{s}", .{stub[0]}), .data = try std.mem.replaceOwned(u8, allocator, stub[1], "{0s}", root), .flags = .{ .mode = 0o755 } });
    // The newest release has only a universal image and another app's; an
    // older one has one for the architecture.
    try temp.dir.writeFile(.{ .sub_path = "releases.json", .data = 
        \\[{"tag_name": "tool-v1.3", "draft": false, "prerelease": false, "assets": [
        \\   {"browser_download_url": "https://x/other-1.3.0.0-aarch64.dmg"}, {"browser_download_url": "https://x/tool-1.3.0.0-x86_64.dmg"},
        \\   {"browser_download_url": "https://x/tool-1.3.0.0-x86_64-setup"}, {"browser_download_url": "https://x/tool-1.3.0.0.dmg"}]},
        \\ {"tag_name": "tool-v1.2", "draft": false, "prerelease": false, "assets": [{"browser_download_url": "https://x/tool-1.2.0.0-aarch64.dmg"}]}]
    });
    try temp.dir.writeFile(.{ .sub_path = "running", .data = "" });
    try temp.dir.makePath("apps/Tool.app/Contents");
    try temp.dir.writeFile(.{ .sub_path = "apps/Tool.app/Contents/old", .data = "" });
    const remote = try script(allocator, .{ .app_name = "Tool", .identity = "com.example.tool", .stem = "tool", .version = "1.2.0.0", .github = "owner/apps", .tag_prefix = "tool-", .bundle = "Tool.app" });
    try temp.dir.writeFile(.{ .sub_path = "install.sh", .data = remote });

    var environment = std.process.EnvMap.init(allocator);
    try environment.put("HOME", try std.fs.path.join(allocator, &.{ root, "home" }));
    try environment.put("PATH", try std.fmt.allocPrint(allocator, "{s}/bin:/usr/bin:/bin", .{root}));
    try environment.put("TOOL_INSTALL_DIR", try std.fs.path.join(allocator, &.{ root, "apps" }));
    for ([_][]const []const u8{ &.{ "sh", "install.sh" }, &.{ "sh", "install.sh", "--uninstall" } }, 0..) |argv, step| {
        const result = try std.process.Child.run(.{ .allocator = allocator, .argv = argv, .cwd = root, .env_map = &environment });
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("{s}{s}\n", .{ result.stdout, result.stderr });
            return error.ScriptFailed;
        }
        if (step == 0) {
            // Apple silicon under Rosetta: the arm64 image is newest only in
            // the older release, so the universal one wins.
            try testing.expectEqualStrings("https://x/tool-1.3.0.0.dmg\n", try temp.dir.readFileAlloc(allocator, "apps/Tool.app/Contents/image", 1024));
            try testing.expectError(error.FileNotFound, temp.dir.access("apps/Tool.app/Contents/old", .{}));
        }
    }
    try testing.expectError(error.FileNotFound, temp.dir.access("apps/Tool.app", .{}));
    const log = try temp.dir.readFileAlloc(allocator, "calls", 8192);
    for ([_][]const u8{
        "curl -fsSL https://x/tool-1.3.0.0.dmg\n",
        "osascript -e tell application id \"com.example.tool\" to quit\n",
        "hdiutil attach -readonly -nobrowse -noautoopen -noverify -mountpoint ",
        try std.fmt.allocPrint(allocator, "open {s}/apps/Tool.app\n", .{root}),
    }) |expected| if (std.mem.indexOf(u8, log, expected) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ expected, log });
        return error.TestExpectedEqual;
    };
}

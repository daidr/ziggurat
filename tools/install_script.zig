//! install.sh for Linux apps: installs the app for the current user,
//! without root or a package manager, by running its setup installer in
//! user scope (`$XDG_DATA_HOME/<identity>/install`, a desktop entry and a
//! command in ~/.local/bin), where the app can update itself. It runs the
//! installer it is given, else the one of its version next to it, else
//! the one it downloads: from the newest GitHub release whose tag has the
//! prefix (read from the GitHub API), or from a download URL. It warns
//! when a WebView app's WebKitGTK is missing, with the command that
//! installs it, and `--uninstall` runs the installed uninstaller.
//!
//!     curl -fsSL https://github.com/OWNER/REPO/releases/latest/download/install.sh | sh
const std = @import("std");
const zio = @import("ziggurat_io");

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
};

/// Writes the script. Every value is quoted for the shell.
pub fn write(writer: *std.Io.Writer, options: Options) !void {
    const github = options.github orelse "";
    const url = options.url orelse "";
    try writer.writeAll("#!/bin/sh\n# Installs ");
    try writer.writeAll(oneLine(options.app_name));
    try writer.writeAll(
        \\ for the current user, without root: the app in
        \\# ${XDG_DATA_HOME:-~/.local/share}/IDENTITY/install, a command in ~/.local/bin and its
        \\# entry in the applications menu, through its setup installer. Made by
        \\# `ziggurat package install-script`.
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
    \\Usage: sh install.sh [SETUP | --uninstall]
    \\
    \\Installs $app_name for you: SETUP, else $name-$version-<target>-setup next
    \\to this script, else the latest version, which it downloads. --uninstall
    \\removes it and leaves its settings and data in place.
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
    \\  case "${1:-}" in
    \\  -h | --help)
    \\    usage
    \\    return
    \\    ;;
    \\  --uninstall)
    \\    uninstall
    \\    return
    \\    ;;
    \\  -*)
    \\    usage >&2
    \\    exit 2
    \\    ;;
    \\  esac
    \\
    \\  [ "$(uname -s)" = Linux ] || fail "this installs $app_name on Linux"
    \\  [ "$(id -u)" != 0 ] || fail "run this as the user to install $app_name for, not as root"
    \\  case "$(uname -m)" in
    \\  x86_64 | amd64) target=linux-x86_64 ;;
    \\  aarch64 | arm64) target=linux-aarch64 ;;
    \\  *) fail "$app_name is not made for $(uname -m)" ;;
    \\  esac
    \\
    \\  work="$(mktemp -d)"
    \\  trap 'rm -rf "$work"' EXIT
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
    \\      url="$(latest_installer)" || fail "could not list the releases of $repository"
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
    \\# latest_installer prints the URL of the installer for $target in the newest
    \\# release tagged $tag_prefix that is neither a draft nor a prerelease. The
    \\# GitHub API lists releases newest first, each with tag_name, draft and
    \\# prerelease before the browser_download_url of its assets.
    \\latest_installer() {
    \\  page=1
    \\  while [ "$page" -le 10 ]; do
    \\    fetch "https://api.github.com/repos/$repository/releases?per_page=100&page=$page" >"$work/releases.json" || return 1
    \\    tr -d '\n' <"$work/releases.json" |
    \\      grep -oE '"(tag_name|draft|prerelease|browser_download_url)": *("[^"]*"|true|false)' >"$work/fields" || true
    \\    found="$(awk -v prefix="$tag_prefix" -v start="$name-" -v end="-$target-setup" '
    \\      /^"tag_name"/ { sub(/^"tag_name": *"/, ""); sub(/"$/, ""); tag = $0; draft = 0; ok = 0; next }
    \\      /^"draft"/ { draft = /true$/; next }
    \\      /^"prerelease"/ { ok = !draft && /false$/ && index(tag, prefix) == 1; next }
    \\      /^"browser_download_url"/ {
    \\        if (!ok) next
    \\        sub(/^"browser_download_url": *"/, ""); sub(/"$/, "")
    \\        asset = $0; sub(/.*\//, "", asset)
    \\        if (index(asset, start) == 1 && length(asset) > length(end) && substr(asset, length(asset) - length(end) + 1) == end) { print; exit }
    \\      }
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
    const root = try zio.realPathAlloc(temp.dir, ".", allocator);
    const target = switch (@import("builtin").cpu.arch) {
        .x86_64 => "linux-x86_64",
        .aarch64 => "linux-aarch64",
        else => return error.SkipZigTest,
    };
    try temp.dir.createDirPath(zio.io(), "home");
    try temp.dir.createDirPath(zio.io(), "bin");
    const calls = try std.fs.path.join(allocator, &.{ root, "calls" });
    const installer = try std.fmt.allocPrint(allocator, "#!/bin/sh\necho \"$0 $*\" >> '{s}'\n", .{calls});
    try temp.dir.writeFile(zio.io(), .{ .sub_path = try std.fmt.allocPrint(allocator, "tool-1.2.0.0-{s}-setup", .{target}), .data = installer, .flags = .{ .permissions = zio.mode(0o755) } });
    // Releases from the API: a draft, another app's tag, then ours.
    const releases = try std.fmt.allocPrint(allocator,
        \\[{{"tag_name": "tool-v2", "draft": true, "prerelease": false, "assets": [{{"browser_download_url": "https://x/tool-2-{0s}-setup"}}]}},
        \\ {{"tag_name": "other-v9", "draft": false, "prerelease": false, "assets": [{{"browser_download_url": "https://x/tool-9-{0s}-setup"}}]}},
        \\ {{"tag_name": "tool-v1.3", "draft": false,
        \\   "prerelease": false, "assets": [{{"browser_download_url": "https://x/tool-1.3.0.0-{0s}.zip"}}, {{"browser_download_url": "https://x/tool-1.3.0.0-{0s}-setup"}}]}}]
    , .{target});
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "releases.json", .data = releases });
    const curl = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\echo "curl $*" >> '{0s}/calls'
        \\case "$2" in
        \\*api.github.com*) cat '{0s}/releases.json' ;;
        \\*) cat '{0s}/tool-1.2.0.0-{1s}-setup' ;;
        \\esac
        \\
    , .{ root, target });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "bin/curl", .data = curl, .flags = .{ .permissions = zio.mode(0o755) } });
    // As a user, also where tests run as root.
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "bin/id", .data = "#!/bin/sh\necho 1000\n", .flags = .{ .permissions = zio.mode(0o755) } });

    const local = try script(allocator, .{ .app_name = "Tool's", .identity = "com.example.tool", .stem = "tool", .version = "1.2.0.0" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = name, .data = local });
    const remote = try script(allocator, .{ .app_name = "Tool", .identity = "com.example.tool", .stem = "tool", .version = "1.2.0.0", .github = "owner/apps", .tag_prefix = "tool-" });
    try temp.dir.createDirPath(zio.io(), "remote");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "remote/install.sh", .data = remote });
    try temp.dir.createDirPath(zio.io(), "home/data/com.example.tool/install");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "home/data/com.example.tool/install/uninstall", .data = installer, .flags = .{ .permissions = zio.mode(0o755) } });

    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("HOME", try std.fs.path.join(allocator, &.{ root, "home" }));
    try environment.put("XDG_DATA_HOME", try std.fs.path.join(allocator, &.{ root, "home", "data" }));
    try environment.put("PATH", try std.fmt.allocPrint(allocator, "{s}/bin:/usr/bin:/bin", .{root}));
    for ([_][]const []const u8{ &.{ "sh", "install.sh" }, &.{ "sh", "remote/install.sh" }, &.{ "sh", "install.sh", "--uninstall" } }) |argv| {
        const result = try zio.run(allocator, .{ .argv = argv, .cwd = .{ .path = root }, .environ_map = &environment });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("{s}{s}\n", .{ result.stdout, result.stderr });
            return error.ScriptFailed;
        }
    }
    const log = try temp.dir.readFileAlloc(zio.io(), "calls", allocator, .limited(8192));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log, "\n"), '\n');
    try testing.expect(std.mem.endsWith(u8, lines.next().?, try std.fmt.allocPrint(allocator, "tool-1.2.0.0-{s}-setup --scope user", .{target})));
    try testing.expectEqualStrings("curl -fsSL https://api.github.com/repos/owner/apps/releases?per_page=100&page=1", lines.next().?);
    try testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "curl -fsSL https://x/tool-1.3.0.0-{s}-setup", .{target}), lines.next().?);
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "/setup --scope user"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "com.example.tool/install/uninstall "));
    try testing.expectEqual(null, lines.next());
}

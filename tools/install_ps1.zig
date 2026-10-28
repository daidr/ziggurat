//! install.ps1 for Windows apps: installs the app for the current user with
//! its setup installer, the one of the latest version for the PC's
//! architecture, downloaded from the newest GitHub release whose tag has
//! the prefix (read from the GitHub API) or from a download URL. Where the
//! release has a SHA256SUMS, the installer must have the SHA-256 it lists.
//! It quits the app if it runs, stopping it when it keeps running 10 s
//! after its windows were asked to close (as in the tray), runs the
//! installer silently in the folder of the installed version, and opens
//! the app:
//!
//!     irm https://github.com/OWNER/REPO/releases/latest/download/install.ps1 | iex
//!
//! It runs in Windows PowerShell 5.1 and in PowerShell 7. The script is
//! ASCII: PowerShell 5.1 decodes a script irm downloads without a charset,
//! as GitHub serves release files, as Latin-1.
//!
//! For tests, `$env:<STEM>_DOWNLOAD_URL` is where the files are instead and
//! `$env:<STEM>_NO_OPEN=1` leaves the app closed.
const std = @import("std");

pub const name = "install.ps1";

pub const Options = struct {
    /// Display name.
    app_name: []const u8,
    identity: []const u8,
    /// The executable's name without extension, which names the installer
    /// as `ziggurat package setup` does: `<stem>-<version>-<target>-setup.exe`.
    stem: []const u8,
    version: []const u8,
    /// OWNER/NAME of the GitHub repository whose releases hold the installers.
    github: ?[]const u8 = null,
    /// Only releases whose tags start with it.
    tag_prefix: []const u8 = "",
    /// Where the installers are served, ending in `/`.
    url: ?[]const u8 = null,
};

/// Quotes `text` for PowerShell, in ASCII: other characters are [char]
/// codes, as PowerShell 5.1 has no escape for them in a string.
pub fn quote(writer: *std.Io.Writer, text: []const u8) !void {
    var ascii = true;
    for (text) |byte| ascii = ascii and byte >= 0x20 and byte < 0x7f;
    if (ascii) return quoteAscii(writer, text);
    // A string first, so that + joins strings rather than adds numbers.
    try writer.writeAll("(''");
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + length, text.len);
        const codepoint: u21 = std.unicode.utf8Decode(text[index..end]) catch 0xfffd;
        if (codepoint >= 0x20 and codepoint < 0x7f) {
            index = end;
            continue;
        }
        if (start < index) {
            try writer.writeAll(" + ");
            try quoteAscii(writer, text[start..index]);
        }
        if (codepoint >= 0x10000) {
            const value = codepoint - 0x10000;
            try writer.print(" + [char]0x{X:0>4} + [char]0x{X:0>4}", .{ 0xd800 + (value >> 10), 0xdc00 + (value & 0x3ff) });
        } else try writer.print(" + [char]0x{X:0>4}", .{codepoint});
        index = end;
        start = end;
    }
    if (start < text.len) {
        try writer.writeAll(" + ");
        try quoteAscii(writer, text[start..]);
    }
    try writer.writeAll(")");
}

fn quoteAscii(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| if (byte == '\'') try writer.writeAll("''") else try writer.writeByte(byte);
    try writer.writeByte('\'');
}

/// The prefix of the variables tests set: the stem in capitals, with
/// underscores for what is not a letter or digit.
pub fn environmentName(buffer: []u8, stem: []const u8) []const u8 {
    const length = @min(buffer.len, stem.len);
    for (stem[0..length], buffer[0..length]) |byte, *out| out.* = if (std.ascii.isAlphanumeric(byte)) std.ascii.toUpper(byte) else '_';
    return buffer[0..length];
}

fn assign(writer: *std.Io.Writer, variable: []const u8, value: []const u8) !void {
    try writer.print("${s} = ", .{variable});
    try quote(writer, value);
    try writer.writeByte('\n');
}

/// Writes the script.
pub fn write(writer: *std.Io.Writer, options: Options) !void {
    const github = options.github orelse "";
    const url = options.url orelse "";
    var title_buffer: [128]u8 = undefined;
    var title: []const u8 = "the app";
    if (options.app_name.len <= title_buffer.len) {
        var ascii = true;
        for (options.app_name) |byte| ascii = ascii and byte >= 0x20 and byte < 0x7f;
        if (ascii) {
            @memcpy(title_buffer[0..options.app_name.len], options.app_name);
            title = title_buffer[0..options.app_name.len];
        }
    }
    try writer.print(
        \\# Installs {s} for the current user: the installer of the latest version
        \\# for this PC, run silently. Made by `ziggurat package install-ps1`.
        \\#
        \\
    , .{title});
    if (github.len > 0) try writer.print("#   irm https://github.com/{s}/releases/latest/download/install.ps1 | iex\n", .{github});
    if (url.len > 0) try writer.print("#   irm {s}install.ps1 | iex\n", .{url});
    try writer.writeAll(
        \\
        \\& {
        \\$ErrorActionPreference = 'Stop'
        \\$ProgressPreference = 'SilentlyContinue'
        \\
        \\
    );
    try assign(writer, "appName", options.app_name);
    try assign(writer, "identity", options.identity);
    try assign(writer, "stem", options.stem);
    try assign(writer, "version", options.version);
    try writer.writeAll("# Where the installers are: the newest release of the repository tagged\n# with the prefix, or a download URL.\n");
    try assign(writer, "repository", github);
    try assign(writer, "tagPrefix", options.tag_prefix);
    try assign(writer, "baseUrl", url);
    var env_buffer: [128]u8 = undefined;
    const env = environmentName(&env_buffer, options.stem);
    try writer.print(
        \\# For tests only: where the files are instead, and leaving the app closed.
        \\$downloadUrl = $env:{0s}_DOWNLOAD_URL
        \\$noOpen = $env:{0s}_NO_OPEN
        \\
    , .{env});
    try writer.writeAll(body);
}

const body =
    \\if ($downloadUrl) {
    \\    $baseUrl = $downloadUrl.TrimEnd('/') + '/'
    \\    $repository = ''
    \\}
    \\$defaultFolder = Join-Path $env:LOCALAPPDATA ('Programs\' + $identity)
    \\
    \\function Get-Arch {
    \\    $arch = $env:PROCESSOR_ARCHITEW6432
    \\    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    \\    if ($arch -eq 'AMD64') {
    \\        # An x64 PowerShell on an Arm PC.
    \\        try {
    \\            if ((Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Architecture -eq 12) { $arch = 'ARM64' }
    \\        } catch {}
    \\    }
    \\    switch ($arch) {
    \\        'ARM64' { return 'aarch64' }
    \\        'AMD64' { return 'x86_64' }
    \\        default { throw "$appName is not made for $arch" }
    \\    }
    \\}
    \\
    \\function Get-File([string]$url, [string]$path) {
    \\    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $path
    \\}
    \\
    \\# Find-Installer returns the URL of the installer for the target: in the
    \\# newest release tagged $tagPrefix that is neither a draft nor a
    \\# prerelease, or at the download URL.
    \\function Find-Installer([string]$target) {
    \\    $suffix = '-' + $target + '-setup.exe'
    \\    if (-not $repository) {
    \\        if (-not $baseUrl) { throw "no download URL: pass the installer to run" }
    \\        return $baseUrl + $stem + '-' + $version + $suffix
    \\    }
    \\    for ($page = 1; $page -le 10; $page++) {
    \\        # Windows PowerShell 5.1 outputs the JSON array as one object, which
    \\        # ForEach-Object enumerates.
    \\        $list = @(Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repository/releases?per_page=100&page=$page" | ForEach-Object { $_ })
    \\        foreach ($r in $list) {
    \\            if ($r.draft -or $r.prerelease -or -not $r.tag_name.StartsWith($tagPrefix)) { continue }
    \\            foreach ($a in $r.assets) {
    \\                if ($a.name.StartsWith($stem + '-') -and $a.name.EndsWith($suffix)) { return $a.browser_download_url }
    \\            }
    \\        }
    \\        if ($list.Count -lt 100) { break }
    \\    }
    \\    throw "no release of $repository has an installer of $appName for $target"
    \\}
    \\
    \\# Get-AppProcess returns the processes running from the folder. It finds
    \\# them with CIM, which reads every path at once.
    \\function Get-AppProcess([string]$folder) {
    \\    $dir = $folder.TrimEnd('\') + '\'
    \\    Get-CimInstance Win32_Process -Property ProcessId, ExecutablePath -ErrorAction SilentlyContinue | Where-Object {
    \\        $_.ExecutablePath -and $_.ProcessId -ne $PID -and $_.ExecutablePath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)
    \\    } | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    \\}
    \\
    \\# Wait-Exit waits up to the seconds for the processes to exit.
    \\function Wait-Exit($processes, [int]$seconds) {
    \\    $deadline = (Get-Date).AddSeconds($seconds)
    \\    foreach ($p in $processes) {
    \\        $left = [int]($deadline - (Get-Date)).TotalMilliseconds
    \\        if ($left -lt 0) { $left = 0 }
    \\        try { [void]$p.WaitForExit($left) } catch {}
    \\    }
    \\}
    \\
    \\function Install-App {
    \\    try {
    \\        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    \\    } catch {}
    \\    $target = 'windows-' + (Get-Arch)
    \\    $url = Find-Installer $target
    \\    $file = $url.Substring($url.LastIndexOf('/') + 1)
    \\    $work = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    \\    New-Item -ItemType Directory -Path $work | Out-Null
    \\    try {
    \\        Write-Host "Downloading $appName from $url"
    \\        $setup = Join-Path $work $file
    \\        Get-File $url $setup
    \\        # A release with SHA256SUMS must list the installer with its SHA-256.
    \\        $sumsFile = Join-Path $work 'SHA256SUMS'
    \\        $hasSums = $true
    \\        try { Get-File ($url.Substring(0, $url.LastIndexOf('/') + 1) + 'SHA256SUMS') $sumsFile } catch { $hasSums = $false }
    \\        if ($hasSums) {
    \\            $sum = $null
    \\            foreach ($line in [IO.File]::ReadAllLines($sumsFile)) {
    \\                if ($line.TrimEnd() -match ('^([0-9a-fA-F]{64}) [ *]' + [regex]::Escape($file) + '$')) { $sum = $Matches[1]; break }
    \\            }
    \\            if (-not $sum) { throw "SHA256SUMS of the release does not list $file" }
    \\            if ((Get-FileHash -Algorithm SHA256 -Path $setup).Hash -ne $sum.ToUpperInvariant()) {
    \\                throw "$file does not have the SHA-256 of SHA256SUMS: not installing it"
    \\            }
    \\        }
    \\
    \\        # The installed version's folder, which a silent install would
    \\        # otherwise leave for the default one.
    \\        $folder = $defaultFolder
    \\        $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $identity
    \\        $location = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
    \\        if ($location) { $folder = $location.TrimEnd('\') }
    \\
    \\        # Quit the app: ask its windows to close and, after 10 s, stop the
    \\        # processes still running from its folder, as an app in the tray
    \\        # keeps running without windows.
    \\        $running = @(Get-AppProcess $folder)
    \\        if ($running.Count -gt 0) {
    \\            Write-Host "Quitting $appName"
    \\            foreach ($p in $running) { try { [void]$p.CloseMainWindow() } catch {} }
    \\            Wait-Exit $running 10
    \\            $running = @(Get-AppProcess $folder)
    \\            if ($running.Count -gt 0) {
    \\                $running | Stop-Process -Force -ErrorAction SilentlyContinue
    \\                Wait-Exit $running 10
    \\                if (@(Get-AppProcess $folder).Count -gt 0) { throw "$appName is still running: quit it and run this again" }
    \\            }
    \\        }
    \\
    \\        Write-Host "Installing $appName in $folder"
    \\        $process = Start-Process -FilePath $setup -ArgumentList ('--silent --scope user --dir "' + $folder + '"') -Wait -PassThru
    \\        if ($process.ExitCode -ne 0) { throw "the installer of $appName failed with exit code $($process.ExitCode)" }
    \\        $exe = Join-Path $folder ($stem + '.exe')
    \\        if (-not (Test-Path -LiteralPath $exe)) { throw "the installer did not install $exe" }
    \\        if (-not $noOpen) { Start-Process -FilePath $exe }
    \\        Write-Host "Installed $appName in $folder"
    \\    } finally {
    \\        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    \\    }
    \\}
    \\
    \\try {
    \\    Install-App
    \\} catch {
    \\    Write-Host "install.ps1: $_" -ForegroundColor Red
    \\    if ($downloadUrl) { exit 1 }
    \\}
    \\}
    \\
;

const testing = std.testing;

fn script(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try write(&out.writer, options);
    return out.toOwnedSlice();
}

test "values are quoted for PowerShell in ASCII" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try quote(&out.writer, "it's");
    try testing.expectEqualStrings("'it''s'", out.written());
    out.clearRetainingCapacity();
    try quote(&out.writer, "Caf\u{e9} \u{1f600}!");
    try testing.expectEqualStrings("('' + 'Caf' + [char]0x00E9 + ' ' + [char]0xD83D + [char]0xDE00 + '!')", out.written());
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("MY_TOOL", environmentName(&buffer, "my-tool"));
}

test "the script is ASCII and names the installer, the release and the app" {
    const text = try script(testing.allocator, .{ .app_name = "T\u{f6}ol", .identity = "com.example.tool", .stem = "tool", .version = "1.2.0.0", .github = "owner/apps", .tag_prefix = "tool-" });
    defer testing.allocator.free(text);
    for (text) |byte| try testing.expect(byte < 0x80);
    for ([_][]const u8{
        "# Installs the app for the current user",
        "#   irm https://github.com/owner/apps/releases/latest/download/install.ps1 | iex\n",
        "$appName = ('' + 'T' + [char]0x00F6 + 'ol')\n",
        "$repository = 'owner/apps'\n",
        "$tagPrefix = 'tool-'\n",
        "$downloadUrl = $env:TOOL_DOWNLOAD_URL\n",
        "--silent --scope user --dir",
    }) |expected| try testing.expect(std.mem.indexOf(u8, text, expected) != null);
}

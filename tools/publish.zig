//! Uploads a release directory written by `ziggurat-update release` (or
//! `ziggurat build --package` plus installers) to a GitHub release with the
//! GitHub CLI, or to an S3 bucket. Archives, patches and installers go first, signed manifests
//! next and feed.json last, so a client that reads any uploaded index never
//! finds it pointing at a file that is not there yet. A new release is
//! created as a draft: installed apps see it once it is published.
const std = @import("std");
const zio = @import("ziggurat_io");
const s3 = @import("s3.zig");
const console_mod = @import("console.zig");

pub const Options = struct {
    directory: []const u8,
    /// OWNER/NAME.
    repository: []const u8,
    tag: []const u8,
    /// Release notes for a newly created release.
    notes_file: ?[]const u8 = null,
    /// Keeps the repository's "latest" release where it is, for apps whose
    /// releases share a repository with others.
    latest: bool = true,
    /// The GitHub CLI executable.
    gh: []const u8 = "gh",
};

/// Asset paths relative to the release directory, each group sorted.
pub const Plan = struct {
    files: []const []const u8,
    manifests: []const []const u8,
    feed: ?[]const u8,

    pub fn count(self: Plan) usize {
        return self.files.len + self.manifests.len + @intFromBool(self.feed != null);
    }
};

pub fn validRepository(repository: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, repository, '/') orelse return false;
    const owner = repository[0..slash];
    const name = repository[slash + 1 ..];
    return validPart(owner) and validPart(name);
}

fn validPart(part: []const u8) bool {
    if (part.len == 0 or part.len > 100 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}

/// Tags stay plain so they cannot be read as options or paths.
pub fn validTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 128 or tag[0] == '-' or std.mem.indexOf(u8, tag, "..") != null) return false;
    for (tag) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != '+') return false;
    return true;
}

/// Where GitHub serves the assets of `tag`; the manifests' URLs must be
/// under it. Caller frees.
pub fn downloadBase(allocator: std.mem.Allocator, repository: []const u8, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}/", .{ repository, tag });
}

const Wire = struct { url: ?[]const u8 = null };

/// Sorts the directory's files into upload groups and checks that every
/// signed manifest names an asset of this release under `base`. Hidden
/// files and subdirectories are skipped. Allocations belong to `allocator`.
pub fn plan(allocator: std.mem.Allocator, dir: std.Io.Dir, base: []const u8) !Plan {
    var files: std.ArrayList([]const u8) = .empty;
    var manifests: std.ArrayList([]const u8) = .empty;
    var feed: ?[]const u8 = null;
    var iterator = dir.iterate();
    while (try iterator.next(zio.io())) |entry| {
        if (entry.kind != .file or entry.name.len == 0 or entry.name[0] == '.') continue;
        const name = try allocator.dupe(u8, entry.name);
        if (std.mem.eql(u8, name, "feed.json")) {
            feed = name;
        } else if (std.mem.endsWith(u8, name, ".json")) {
            try manifests.append(allocator, name);
        } else try files.append(allocator, name);
    }
    if (files.items.len + manifests.items.len == 0 and feed == null) return error.NothingToUpload;
    std.mem.sort([]const u8, files.items, {}, lessThan);
    std.mem.sort([]const u8, manifests.items, {}, lessThan);
    for (manifests.items) |name| {
        const bytes = try dir.readFileAlloc(zio.io(), name, allocator, .limited(16384));
        const parsed = std.json.parseFromSliceLeaky(Wire, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidManifest;
        const url = parsed.url orelse return error.InvalidManifest;
        if (!std.mem.startsWith(u8, url, base)) {
            std.debug.print("publish: {s} points at {s}, outside {s}\n", .{ name, url, base });
            return error.ManifestOutsideRelease;
        }
        const asset = url[base.len..];
        for (files.items) |file| {
            if (std.mem.eql(u8, file, asset)) break;
        } else {
            std.debug.print("publish: {s} names {s}, which the directory does not have\n", .{ name, asset });
            return error.MissingAsset;
        }
    }
    return .{ .files = files.items, .manifests = manifests.items, .feed = feed };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn viewArgs(allocator: std.mem.Allocator, options: Options) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ options.gh, "release", "view", options.tag, "--repo", options.repository, "--json", "isDraft" });
}

pub fn createArgs(allocator: std.mem.Allocator, options: Options) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(allocator, &.{ options.gh, "release", "create", options.tag, "--repo", options.repository, "--draft", "--title", options.tag });
    if (options.notes_file) |path| try args.appendSlice(allocator, &.{ "--notes-file", path }) else try args.appendSlice(allocator, &.{ "--notes", "" });
    if (!options.latest) try args.append(allocator, "--latest=false");
    return args.toOwnedSlice(allocator);
}

/// One `gh release upload` per group; `--clobber` makes a rerun replace
/// what an interrupted one left.
pub fn uploadArgs(allocator: std.mem.Allocator, options: Options, names: []const []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(allocator, &.{ options.gh, "release", "upload", options.tag, "--repo", options.repository, "--clobber" });
    for (names) |name| try args.append(allocator, try std.fs.path.join(allocator, &.{ options.directory, name }));
    return args.toOwnedSlice(allocator);
}

const Ran = struct { ok: bool, output: []const u8 };

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !Ran {
    const result = zio.run(allocator, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("publish: {s} was not found; install the GitHub CLI and sign in with `gh auth login` or GH_TOKEN\n", .{argv[0]});
            return error.GitHubCliUnavailable;
        },
        else => return err,
    };
    const ok = result.term == .exited and result.term.exited == 0;
    return .{ .ok = ok, .output = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }) };
}

/// Blocking: runs the GitHub CLI once per step and stops at the first
/// failure, printing its output. Progress goes to `out`.
pub fn github(allocator: std.mem.Allocator, options: Options, out: *std.Io.Writer) !void {
    if (!validRepository(options.repository)) return error.InvalidRepository;
    if (!validTag(options.tag)) return error.InvalidTag;
    var dir = try std.Io.Dir.cwd().openDir(zio.io(), options.directory, .{ .iterate = true });
    defer dir.close(zio.io());
    const base = try downloadBase(allocator, options.repository, options.tag);
    const assets = try plan(allocator, dir, base);
    const viewed = try runCommand(allocator, try viewArgs(allocator, options));
    if (!viewed.ok) {
        try out.print("creating the draft release {s} of {s}\n", .{ options.tag, options.repository });
        const created = try runCommand(allocator, try createArgs(allocator, options));
        if (!created.ok) {
            std.debug.print("publish: gh release create failed:\n{s}\n", .{created.output});
            return error.ReleaseCreationFailed;
        }
    }
    const feed: []const []const u8 = if (assets.feed) |name| &.{name} else &.{};
    for ([_][]const []const u8{ assets.files, assets.manifests, feed }) |group| {
        if (group.len == 0) continue;
        try out.print("uploading {d} file{s}\n", .{ group.len, if (group.len == 1) "" else "s" });
        const uploaded = try runCommand(allocator, try uploadArgs(allocator, options, group));
        if (!uploaded.ok) {
            std.debug.print("publish: gh release upload failed:\n{s}\n", .{uploaded.output});
            return error.UploadFailed;
        }
    }
    try out.print(
        \\uploaded {d} files to {s} of {s}; publish it once every platform is there:
        \\  gh release edit {s} --repo {s} --draft=false{s}
        \\
    , .{ assets.count(), options.tag, options.repository, options.tag, options.repository, if (options.latest) "" else " --latest=false" });
    try out.flush();
}

pub const S3Options = struct {
    directory: []const u8,
    bucket: s3.Bucket,
    /// Where the bucket's prefix is served, ending in `/`; the manifests'
    /// URLs must be under it.
    url: []const u8,
};

/// Blocking: puts every file of the release directory into the bucket, in
/// the order of `plan`, one request each, and stops at the first failure.
/// install.sh and feed.json are served with `Cache-Control: no-cache`.
pub fn toS3(allocator: std.mem.Allocator, options: S3Options, environment: *const std.process.Environ.Map, console: *console_mod.Console) !void {
    if (!std.mem.endsWith(u8, options.url, "/")) return error.InvalidUrl;
    const client = try s3.Client.fromEnvironment(options.bucket, environment);
    var dir = try std.Io.Dir.cwd().openDir(zio.io(), options.directory, .{ .iterate = true });
    defer dir.close(zio.io());
    const assets = try plan(allocator, dir, options.url);
    var http: std.http.Client = .{ .allocator = allocator, .io = zio.io() };
    defer http.deinit();
    try http.initDefaultProxies(allocator, environment);
    const feed: []const []const u8 = if (assets.feed) |name| &.{name} else &.{};
    for ([_][]const []const u8{ assets.files, assets.manifests, feed }) |group| for (group) |name| {
        const bytes = try dir.readFileAlloc(zio.io(), name, allocator, .limited(4 * 1024 * 1024 * 1024));
        var task: console_mod.Task = undefined;
        var title: [256]u8 = undefined;
        console.start(&task, std.fmt.bufPrint(&title, "Uploading {s}", .{name}) catch name);
        const Shown = struct {
            fn sent(context: *anyopaque, done: u64, total: u64) void {
                const t: *console_mod.Task = @ptrCast(@alignCast(context));
                var a: [16]u8 = undefined;
                var b: [16]u8 = undefined;
                t.set("{s} of {s}", .{ console_mod.formatSize(&a, done), console_mod.formatSize(&b, total) });
            }
        };
        const object = try client.key(allocator, name);
        var reason_buffer: [1024]u8 = undefined;
        var reason: std.Io.Writer = .fixed(&reason_buffer);
        s3.put(allocator, &http, &client, object, bytes, .{ .content_type = s3.contentType(name), .cache_control = s3.cacheControl(name) }, .{ .context = &task, .sent = Shown.sent }, &reason) catch |err| {
            task.fail();
            if (err == error.UploadFailed) console.problem("uploading to s3://{s}/{s}: {s}", .{ client.bucket, object, reason.buffered() });
            return err;
        };
        var size: [16]u8 = undefined;
        task.done("Uploaded {s} ({s})", .{ name, console_mod.formatSize(&size, bytes.len) });
    };
    console.log("Uploaded {d} files to s3://{s}/{s}, which {s} serves", .{ assets.count(), client.bucket, client.prefix, options.url });
}

/// What went wrong, for the error that ends a publish.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCredentials => "uploading to S3 needs the credentials in AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY",
        error.MissingBucket => "--s3 needs the name of a bucket",
        error.InvalidEndpoint => "--endpoint is not an http(s) URL without a path: the endpoint is the service's, and --s3 names the bucket",
        error.InvalidUrl => "--url is where the bucket's files are served, ending in /",
        error.ManifestOutsideRelease => "a manifest points outside --url",
        error.MissingAsset => "a manifest names a file the directory does not have",
        error.NothingToUpload => "the directory holds nothing to upload",
        error.UploadFailed => "the upload failed",
        else => @errorName(err),
    };
}

const testing = std.testing;

test "repository and tag names stay plain" {
    try testing.expect(validRepository("owner/app"));
    try testing.expect(validRepository("my-org/app.desktop_2"));
    try testing.expect(!validRepository("owner"));
    try testing.expect(!validRepository("owner/app/extra"));
    try testing.expect(!validRepository("../app"));
    try testing.expect(!validRepository("owner/"));
    try testing.expect(validTag("v1.2.0"));
    try testing.expect(validTag("app-v1.2.0+build.3"));
    try testing.expect(!validTag("--draft"));
    try testing.expect(!validTag("v1..2"));
    try testing.expect(!validTag("v1/2"));
    try testing.expect(!validTag(""));
}

test "plans upload archives first, manifests next and the feed last" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const base = try downloadBase(allocator, "owner/app", "v1.1.0");
    try testing.expectEqualStrings("https://github.com/owner/app/releases/download/v1.1.0/", base);
    try testing.expectError(error.NothingToUpload, plan(allocator, temp.dir, base));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app-linux-1.1.0.0.zip", .data = "zip" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app-linux-1.0.0.0-to-1.1.0.0.patch", .data = "patch" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app-linux-1.1.0.0.json", .data = "{\"format\":1,\"url\":\"https://github.com/owner/app/releases/download/v1.1.0/app-linux-1.1.0.0.zip\"}" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app-linux-1.0.0.0-to-1.1.0.0.patch.json", .data = "{\"url\":\"https://github.com/owner/app/releases/download/v1.1.0/app-linux-1.0.0.0-to-1.1.0.0.patch\"}" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "feed.json", .data = "{}" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = ".DS_Store", .data = "" });
    try temp.dir.createDir(zio.io(), "downloads", .default_dir);
    const result = try plan(allocator, temp.dir, base);
    try testing.expectEqual(2, result.files.len);
    try testing.expectEqualStrings("app-linux-1.0.0.0-to-1.1.0.0.patch", result.files[0]);
    try testing.expectEqualStrings("app-linux-1.1.0.0.zip", result.files[1]);
    try testing.expectEqual(2, result.manifests.len);
    try testing.expectEqualStrings("feed.json", result.feed.?);
    try testing.expectEqual(5, result.count());

    const options: Options = .{ .directory = "dist", .repository = "owner/app", .tag = "v1.1.0", .latest = false };
    const create = try createArgs(allocator, options);
    try testing.expectEqualStrings("--draft", create[6]);
    try testing.expectEqualStrings("--latest=false", create[create.len - 1]);
    const upload = try uploadArgs(allocator, options, result.files);
    try testing.expectEqualStrings("--clobber", upload[6]);
    try testing.expectEqualStrings("dist" ++ std.fs.path.sep_str ++ "app-linux-1.0.0.0-to-1.1.0.0.patch", upload[7]);
}

test "manifests must point at assets of the same release" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const base = try downloadBase(allocator, "owner/app", "v2");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app.zip", .data = "zip" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app.json", .data = "{\"url\":\"https://downloads.example.com/app.zip\"}" });
    try testing.expectError(error.ManifestOutsideRelease, plan(allocator, temp.dir, base));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app.json", .data = "{\"url\":\"https://github.com/owner/app/releases/download/v2/other.zip\"}" });
    try testing.expectError(error.MissingAsset, plan(allocator, temp.dir, base));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app.json", .data = "not json" });
    try testing.expectError(error.InvalidManifest, plan(allocator, temp.dir, base));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "app.json", .data = "{\"url\":\"https://github.com/owner/app/releases/download/v2/app.zip\"}" });
    _ = try plan(allocator, temp.dir, base);
}

test "uploads run in order through the GitHub CLI" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try zio.realPathAlloc(temp.dir, ".", allocator);
    try temp.dir.createDir(zio.io(), "dist", .default_dir);
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "dist/app.zip", .data = "zip" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "dist/app.json", .data = "{\"url\":\"https://github.com/owner/app/releases/download/v3/app.zip\"}" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "dist/feed.json", .data = "{}" });
    // Records each call; `release view` fails as for a release that does not exist yet.
    const log = try std.fs.path.join(allocator, &.{ root, "calls" });
    const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\necho \"$@\" >> '{s}'\n[ \"$2\" = view ] && exit 1\nexit 0\n", .{log});
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "gh", .data = script, .flags = .{ .permissions = zio.mode(0o755) } });
    const options: Options = .{ .directory = try std.fs.path.join(allocator, &.{ root, "dist" }), .repository = "owner/app", .tag = "v3", .gh = try std.fs.path.join(allocator, &.{ root, "gh" }) };
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try github(allocator, options, &discard.writer);
    const calls = try temp.dir.readFileAlloc(zio.io(), "calls", allocator, .limited(4096));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, calls, "\n"), '\n');
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "release view v3 --repo owner/app"));
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "release create v3 --repo owner/app --draft"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "dist/app.zip"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "dist/app.json"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "dist/feed.json"));
    try testing.expectEqual(null, lines.next());
    // A failing upload stops before the manifests.
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "gh", .data = "#!/bin/sh\nexit 1\n", .flags = .{ .permissions = zio.mode(0o755) } });
    try testing.expectError(error.ReleaseCreationFailed, github(allocator, options, &discard.writer));
}

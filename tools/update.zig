const std = @import("std");
const update = @import("ziggurat_update");

const usage =
    \\ziggurat-update keygen PRIVATE_SEED_FILE PUBLIC_KEY_FILE
    \\ziggurat-update sign ZIP MANIFEST PRIVATE_SEED_FILE ID TARGET VERSION HTTPS_URL
    \\ziggurat-update verify MANIFEST PUBLIC_KEY_FILE ID TARGET CURRENT_VERSION
    \\ziggurat-update publish MANIFEST PUBLIC_KEY_FILE ID TARGET CURRENT_VERSION ZIP ROOT
    \\ziggurat-update current ROOT ID TARGET
    \\Versions have four decimal components. Key files contain exactly 32 raw bytes.
    \\Use a protected signing directory; never distribute the private seed.
    \\Publication performs blocking disk I/O and never overwrites a running release.
    \\Downloads, application shutdown, restart and release retention belong to the host.
    \\
;

pub fn main() void {
    run() catch |err| {
        std.debug.print("update: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len == 1 or std.mem.eql(u8, args[1], "--help")) {
        try std.fs.File.stdout().writeAll(usage);
        return;
    }
    const cwd = std.fs.cwd();
    if (std.mem.eql(u8, args[1], "keygen")) {
        if (args.len != 4) return error.InvalidArguments;
        var key = update.Ed25519.KeyPair.generate();
        defer std.crypto.secureZero(u8, &key.secret_key.bytes);
        var seed = key.secret_key.seed();
        defer std.crypto.secureZero(u8, &seed);
        var secret = try cwd.createFile(args[2], .{ .exclusive = true, .mode = 0o600 });
        defer secret.close();
        errdefer cwd.deleteFile(args[2]) catch {};
        try secret.writeAll(&seed);
        try secret.sync();
        var public = try cwd.createFile(args[3], .{ .exclusive = true });
        defer public.close();
        errdefer cwd.deleteFile(args[3]) catch {};
        try public.writeAll(&key.public_key.toBytes());
        try public.sync();
    } else if (std.mem.eql(u8, args[1], "sign")) {
        if (args.len != 9) return error.InvalidArguments;
        var seed = try readKey(args[4]);
        defer std.crypto.secureZero(u8, &seed);
        var key = try update.Ed25519.KeyPair.generateDeterministic(seed);
        defer std.crypto.secureZero(u8, &key.secret_key.bytes);
        var archive = try cwd.openFile(args[2], .{});
        defer archive.close();
        var buffer: [16 * 1024]u8 = undefined;
        var reader = archive.reader(&buffer);
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        var bytes: u64 = 0;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = try reader.interface.readSliceShort(&chunk);
            if (n == 0) break;
            hash.update(chunk[0..n]);
            bytes = try std.math.add(u64, bytes, n);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        const json = try update.sign(allocator, .{
            .identity = args[5],
            .target = args[6],
            .version = try parseVersion(args[7]),
            .url = args[8],
            .bytes = bytes,
            .sha256 = digest,
            .signature = @splat(0),
        }, key);
        // An explicit output path is exclusive: publication cannot silently replace metadata.
        var output = try cwd.createFile(args[3], .{ .exclusive = true });
        defer output.close();
        errdefer cwd.deleteFile(args[3]) catch {};
        try output.writeAll(json);
        try output.sync();
    } else if (std.mem.eql(u8, args[1], "verify") or std.mem.eql(u8, args[1], "publish")) {
        const publish = std.mem.eql(u8, args[1], "publish");
        if (args.len != (if (publish) @as(usize, 9) else 7)) return error.InvalidArguments;
        const bytes = try cwd.readFileAlloc(allocator, args[2], 16384);
        const verified = try update.parseAndVerify(allocator, bytes, .{
            .public_key = try readKey(args[3]),
            .identity = args[4],
            .target = args[5],
            .current_version = try parseVersion(args[6]),
        });
        defer verified.deinit();
        if (publish) {
            var archive = try cwd.openFile(args[7], .{});
            defer archive.close();
            var root = try cwd.makeOpenPath(args[8], .{ .no_follow = true });
            defer root.close();
            const result = try update.publication.publishZip(allocator, root, archive, &verified, .{});
            var path_buffer: [512]u8 = undefined;
            try std.fs.File.stdout().writeAll(try result.relativePath(&path_buffer));
            try std.fs.File.stdout().writeAll("\n");
        } else try std.fs.File.stdout().writeAll("verified\n");
    } else if (std.mem.eql(u8, args[1], "current")) {
        if (args.len != 5) return error.InvalidArguments;
        var root = try cwd.openDir(args[2], .{ .no_follow = true });
        defer root.close();
        const current = try update.publication.readCurrent(allocator, root, args[3], args[4]);
        var path_buffer: [512]u8 = undefined;
        try std.fs.File.stdout().writeAll(try current.relativePath(&path_buffer));
        try std.fs.File.stdout().writeAll("\n");
    } else return error.UnknownCommand;
}

fn readKey(path: []const u8) ![32]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    if ((try file.stat()).size != 32) return error.InvalidKeyLength;
    var bytes: [32]u8 = undefined;
    if (try file.readAll(&bytes) != bytes.len) return error.InvalidKeyLength;
    return bytes;
}

fn parseVersion(text: []const u8) !update.Version {
    var parts = std.mem.splitScalar(u8, text, '.');
    var result: update.Version = undefined;
    inline for (.{ "major", "minor", "patch", "revision" }) |field| {
        const part = parts.next() orelse return error.InvalidVersion;
        if (part.len == 0) return error.InvalidVersion;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidVersion;
        @field(result, field) = std.fmt.parseInt(u16, part, 10) catch return error.InvalidVersion;
    }
    if (parts.next() != null) return error.InvalidVersion;
    return result;
}

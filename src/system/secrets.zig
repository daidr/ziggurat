//! Small secrets, such as access tokens and API keys, in the system's
//! credential store: the Credential Manager on Windows and the Secret Service
//! on Linux (GNOME Keyring, KWallet, KeePassXC and others, through libsecret).
//! The system encrypts them for the user, unlike a file the application writes.
//!
//! A store keeps each secret under a service and a key. The service groups an
//! application's secrets, usually its reverse-DNS identifier; another program
//! of the same user that names the same service and key reads the same secret.
//! Windows keeps a generic credential whose target is "service/key" and whose
//! user name is the key; Linux keeps an item of the generic secret schema
//! whose `service` and `account` attributes are the service and the key.
//!
//! `set`, `get` and `delete` block: the store may ask the user to unlock it.
//! Call them on a caller-created worker thread, never on the App's main thread
//! while it runs. `Request` carries one operation to such a worker and posts
//! its result back to the main thread through `App.post`. The module starts no
//! thread and allocates nothing.
//!
//! Where no store is reachable, every operation fails with
//! CredentialStoreUnavailable instead of pretending to succeed: on Linux
//! without libsecret, without a session bus or without a Secret Service on it.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");

const os = builtin.os.tag;
const native_windows = !builtin.is_test and os == .windows;
const native_linux = !builtin.is_test and os == .linux;

/// Whether this build has a credential store to try. A Linux session may
/// still lack one at run time (CredentialStoreUnavailable).
pub const capabilities = .{
    .credential_store = os == .windows or os == .linux,
};

/// The largest secret `set` stores, in bytes: the most the Windows Credential
/// Manager keeps, so that an application behaves the same everywhere. Keep
/// more in an encrypted file whose key is a secret.
pub const max_secret_bytes = 2560;
/// The longest service and key, in UTF-8 bytes.
pub const max_name_bytes = 256;

pub const Error = error{
    /// No secret is stored under the service and key.
    SecretNotFound,
    /// No credential store is reachable in this session.
    CredentialStoreUnavailable,
    /// The store refused or failed the operation; `lastFailure` names why.
    CredentialStoreFailed,
    /// The stored secret is longer than the destination.
    SecretTooLarge,
    UnsupportedCapability,
};
pub const NameError = error{ EmptyName, NameTooLong, EmbeddedNul, InvalidUtf8 };

/// The native code of the last failure on the calling thread: a Win32 error,
/// or the GError code of a Secret Service failure.
pub const Failure = struct { domain: enum { win32, glib }, code: i32 };
threadlocal var last_failure: ?Failure = null;
pub fn lastFailure() ?Failure {
    return last_failure;
}

/// Checks a service or key: 1 to `max_name_bytes` bytes of UTF-8 without NUL.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > max_name_bytes) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
}

/// Stores `value` under the service and key, replacing what was there.
/// Blocking; see the module notes. An empty value is a valid secret.
pub fn set(service: []const u8, key: []const u8, value: []const u8) !void {
    try validateName(service);
    try validateName(key);
    if (value.len > max_secret_bytes) return error.SecretTooLarge;
    last_failure = null;
    if (native_windows) return windows.set(service, key, value);
    if (native_linux) return linuxCall(zss_secret_set(service.ptr, service.len, key.ptr, key.len, value.ptr, value.len, &linux_code));
    if (builtin.is_test) return memory.set(service, key, value);
    return error.UnsupportedCapability;
}

/// Writes the secret stored under the service and key to `destination` and
/// returns that slice. SecretNotFound when nothing is stored there. Blocking.
pub fn get(service: []const u8, key: []const u8, destination: []u8) ![]u8 {
    try validateName(service);
    try validateName(key);
    last_failure = null;
    if (native_windows) return windows.get(service, key, destination);
    if (native_linux) {
        var length: usize = 0;
        try linuxCall(zss_secret_get(service.ptr, service.len, key.ptr, key.len, destination.ptr, destination.len, &length, &linux_code));
        return destination[0..length];
    }
    if (builtin.is_test) return memory.get(service, key, destination);
    return error.UnsupportedCapability;
}

/// Removes the secret stored under the service and key. Removing a key that
/// has no secret succeeds. Blocking.
pub fn delete(service: []const u8, key: []const u8) !void {
    try validateName(service);
    try validateName(key);
    last_failure = null;
    if (native_windows) return windows.delete(service, key);
    if (native_linux) return linuxCall(zss_secret_delete(service.ptr, service.len, key.ptr, key.len, &linux_code));
    if (builtin.is_test) return memory.delete(service, key);
    return error.UnsupportedCapability;
}

pub const Operation = enum { set, get, delete };

/// One store operation handed to a worker. Fill it on the main thread with
/// `init`, keep it at a stable address, call `run` on a worker, and read the
/// outcome in `on_done`, which runs once on the main thread. Inputs are copied
/// into the request, so the caller's slices may change after `init`. The
/// request holds the secret in plain memory until `wipe` or the next `init`.
pub const Request = struct {
    app: *z.App,
    operation: Operation,
    context: *anyopaque,
    on_done: *const fn (*anyopaque, *Request) void,
    service_bytes: [max_name_bytes]u8 = undefined,
    service_len: usize = 0,
    key_bytes: [max_name_bytes]u8 = undefined,
    key_len: usize = 0,
    /// The value to store, then for `.get` the value read.
    value_bytes: [max_secret_bytes]u8 = undefined,
    value_len: usize = 0,
    outcome: ?anyerror = null,
    failure: ?Failure = null,
    finished: bool = false,

    /// Validates and copies the inputs. `value` is the secret for `.set` and
    /// must be empty otherwise.
    pub fn init(app: *z.App, operation: Operation, service_name: []const u8, key_name: []const u8, secret: []const u8, context: *anyopaque, on_done: *const fn (*anyopaque, *Request) void) !Request {
        try validateName(service_name);
        try validateName(key_name);
        if (secret.len > max_secret_bytes) return error.SecretTooLarge;
        if (operation != .set and secret.len != 0) return error.UnexpectedValue;
        var request: Request = .{ .app = app, .operation = operation, .context = context, .on_done = on_done };
        @memcpy(request.service_bytes[0..service_name.len], service_name);
        request.service_len = service_name.len;
        @memcpy(request.key_bytes[0..key_name.len], key_name);
        request.key_len = key_name.len;
        @memcpy(request.value_bytes[0..secret.len], secret);
        request.value_len = secret.len;
        return request;
    }

    pub fn service(self: *const Request) []const u8 {
        return self.service_bytes[0..self.service_len];
    }
    pub fn key(self: *const Request) []const u8 {
        return self.key_bytes[0..self.key_len];
    }

    /// Worker thread. Performs the blocking operation, then posts `on_done`
    /// to the main thread. When the post fails (Full or Closed) the request
    /// keeps its outcome, `on_done` never runs, and ownership stays with the
    /// caller, who may retry `post` or drop the request.
    pub fn run(self: *Request) !void {
        self.perform();
        try self.post();
    }

    /// Worker thread. The blocking part of `run`.
    pub fn perform(self: *Request) void {
        std.debug.assert(!self.finished);
        const result: anyerror!void = switch (self.operation) {
            .set => set(self.service(), self.key(), self.value_bytes[0..self.value_len]),
            .get => if (get(self.service(), self.key(), &self.value_bytes)) |read| {
                self.value_len = read.len;
            } else |failed| failed,
            .delete => delete(self.service(), self.key()),
        };
        if (result) |_| {
            self.outcome = null;
        } else |failed| {
            self.outcome = failed;
            if (self.operation == .get) self.value_len = 0;
        }
        self.failure = last_failure;
        self.finished = true;
    }

    /// Any thread, after `perform`. Hands `on_done` to the main thread.
    pub fn post(self: *Request) !void {
        std.debug.assert(self.finished);
        try self.app.post(.{ .context = self, .call = done });
    }

    /// Main thread, in `on_done`: the error of the operation, if it failed.
    pub fn err(self: *const Request) ?anyerror {
        return self.outcome;
    }
    /// Main thread, in `on_done`: the secret a successful `.get` read. It
    /// stays valid until `wipe` or the next `init`.
    pub fn value(self: *const Request) []const u8 {
        return self.value_bytes[0..self.value_len];
    }
    /// Overwrites the secret held by the request.
    pub fn wipe(self: *Request) void {
        std.crypto.secureZero(u8, &self.value_bytes);
        self.value_len = 0;
    }

    fn done(ptr: *anyopaque) void {
        const self: *Request = @ptrCast(@alignCast(ptr));
        self.on_done(self.context, self);
    }
};

threadlocal var linux_code: c_int = 0;
extern fn zss_secret_set([*]const u8, usize, [*]const u8, usize, [*]const u8, usize, *c_int) c_int;
extern fn zss_secret_get([*]const u8, usize, [*]const u8, usize, [*]u8, usize, *usize, *c_int) c_int;
extern fn zss_secret_delete([*]const u8, usize, [*]const u8, usize, *c_int) c_int;

fn linuxCall(result: c_int) Error!void {
    return switch (result) {
        0 => {},
        1 => error.SecretNotFound,
        2 => error.CredentialStoreUnavailable,
        4 => error.SecretTooLarge,
        else => {
            last_failure = .{ .domain = .glib, .code = linux_code };
            return error.CredentialStoreFailed;
        },
    };
}

const windows = if (os == .windows) struct {
    const c = @import("ziggurat_c_win32");
    const error_not_found = 1168;
    /// "service/key" and the key as NUL-terminated UTF-16.
    const Names = struct {
        target: [2 * max_name_bytes + 2]u16 = undefined,
        user: [max_name_bytes + 1]u16 = undefined,

        fn init(self: *Names, service: []const u8, key: []const u8) !void {
            var length = std.unicode.utf8ToUtf16Le(&self.target, service) catch return error.InvalidUtf8;
            self.target[length] = '/';
            length += 1;
            length += std.unicode.utf8ToUtf16Le(self.target[length..], key) catch return error.InvalidUtf8;
            self.target[length] = 0;
            const user = std.unicode.utf8ToUtf16Le(&self.user, key) catch return error.InvalidUtf8;
            self.user[user] = 0;
        }
    };

    fn failed(code: c.DWORD) Error {
        if (code == error_not_found) return error.SecretNotFound;
        last_failure = .{ .domain = .win32, .code = @bitCast(code) };
        return error.CredentialStoreFailed;
    }

    fn set(service: []const u8, key: []const u8, value: []const u8) !void {
        var names: Names = .{};
        try names.init(service, key);
        var credential = std.mem.zeroes(c.CREDENTIALW);
        credential.Type = c.CRED_TYPE_GENERIC;
        credential.TargetName = &names.target;
        credential.UserName = &names.user;
        // Roams with the user's profile on a domain, as generic credentials
        // of other programs do.
        credential.Persist = c.CRED_PERSIST_ENTERPRISE;
        credential.CredentialBlobSize = @intCast(value.len);
        credential.CredentialBlob = if (value.len == 0) null else @constCast(value.ptr);
        if (c.CredWriteW(&credential, 0) == 0) return failed(c.GetLastError());
    }

    fn get(service: []const u8, key: []const u8, destination: []u8) ![]u8 {
        var names: Names = .{};
        try names.init(service, key);
        var credential: c.PCREDENTIALW = null;
        if (c.CredReadW(&names.target, c.CRED_TYPE_GENERIC, 0, &credential) == 0) return failed(c.GetLastError());
        defer c.CredFree(credential);
        const size: usize = credential.*.CredentialBlobSize;
        if (size > destination.len) return error.SecretTooLarge;
        // An empty secret has no blob.
        if (size != 0) {
            @memcpy(destination[0..size], credential.*.CredentialBlob[0..size]);
            std.crypto.secureZero(u8, credential.*.CredentialBlob[0..size]);
        }
        return destination[0..size];
    }

    fn delete(service: []const u8, key: []const u8) !void {
        var names: Names = .{};
        try names.init(service, key);
        if (c.CredDeleteW(&names.target, c.CRED_TYPE_GENERIC, 0) == 0) {
            const code = c.GetLastError();
            if (code != error_not_found) return failed(code);
        }
    }
} else struct {};

/// The test build's store: process memory, so `Request` round trips without
/// a credential store on the machine running the tests.
const memory = struct {
    const capacity = 8;
    const Entry = struct { used: bool = false, name: [2 * max_name_bytes + 1]u8 = undefined, name_len: usize = 0, value: [max_secret_bytes]u8 = undefined, value_len: usize = 0 };
    var mutex: zio.Mutex = .{};
    var entries: [capacity]Entry = @splat(.{});

    fn name(storage: []u8, service: []const u8, key: []const u8) []const u8 {
        @memcpy(storage[0..service.len], service);
        storage[service.len] = '/';
        @memcpy(storage[service.len + 1 ..][0..key.len], key);
        return storage[0 .. service.len + 1 + key.len];
    }
    fn find(target: []const u8) ?*Entry {
        for (&entries) |*entry| if (entry.used and std.mem.eql(u8, entry.name[0..entry.name_len], target)) return entry;
        return null;
    }
    fn set(service: []const u8, key: []const u8, value: []const u8) !void {
        var storage: [2 * max_name_bytes + 1]u8 = undefined;
        const target = name(&storage, service, key);
        mutex.lock();
        defer mutex.unlock();
        const entry = find(target) orelse for (&entries) |*entry| {
            if (!entry.used) break entry;
        } else return error.CredentialStoreFailed;
        entry.used = true;
        @memcpy(entry.name[0..target.len], target);
        entry.name_len = target.len;
        @memcpy(entry.value[0..value.len], value);
        entry.value_len = value.len;
    }
    fn get(service: []const u8, key: []const u8, destination: []u8) ![]u8 {
        var storage: [2 * max_name_bytes + 1]u8 = undefined;
        mutex.lock();
        defer mutex.unlock();
        const entry = find(name(&storage, service, key)) orelse return error.SecretNotFound;
        if (entry.value_len > destination.len) return error.SecretTooLarge;
        @memcpy(destination[0..entry.value_len], entry.value[0..entry.value_len]);
        return destination[0..entry.value_len];
    }
    fn delete(service: []const u8, key: []const u8) !void {
        var storage: [2 * max_name_bytes + 1]u8 = undefined;
        mutex.lock();
        defer mutex.unlock();
        if (find(name(&storage, service, key))) |entry| entry.used = false;
    }
};

test "names are bounded UTF-8 without NUL" {
    try validateName("com.example.app");
    try std.testing.expectError(error.EmptyName, validateName(""));
    try std.testing.expectError(error.EmbeddedNul, validateName("a\x00b"));
    try std.testing.expectError(error.InvalidUtf8, validateName("\xff"));
    try validateName(&@as([max_name_bytes]u8, @splat('x')));
    try std.testing.expectError(error.NameTooLong, validateName(&@as([max_name_bytes + 1]u8, @splat('x'))));
    try std.testing.expectError(error.SecretTooLarge, set("service", "key", &(@as([max_secret_bytes + 1]u8, @splat(1)))));
}

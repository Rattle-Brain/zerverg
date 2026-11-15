//! The admin's password and where it comes from, in priority order:
//!
//!   1. `admin_password_hash` in the config file or environment:
//!      authoritative, the console cannot change it.
//!   2. `auth.json` in the data directory, written by the console's
//!      "change password" form.
//!   3. The factory default, `admin`. Every API call except changing
//!      the password is refused until it is changed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Store = @import("../store/Store.zig");
const files = @import("../store/files.zig");
const password = @import("password.zig");

const Credentials = @This();

pub const Source = enum { config, stored, default };

pub const default_password = "admin";
pub const min_password_len = 8;
pub const max_password_len = 256;

const file_name = "auth.json";

const StoredFile = struct {
    password_hash: []const u8,
};

gpa: Allocator,
io: Io,
store: *Store,
user: []const u8,
mutex: Io.Mutex = .init,
hash_buf: [password.max_hash_len]u8 = undefined,
hash_len: usize = 0,
source: Source = .default,

pub fn init(
    gpa: Allocator,
    io: Io,
    store: *Store,
    user: []const u8,
    config_hash: []const u8,
) !Credentials {
    var self: Credentials = .{
        .gpa = gpa,
        .io = io,
        .store = store,
        .user = user,
    };
    var stored_buf: [password.max_hash_len]u8 = undefined;
    if (config_hash.len > 0) {
        try self.setHash(config_hash, .config);
    } else if (try self.readStored(&stored_buf)) |stored| {
        try self.setHash(stored, .stored);
    } else {
        var buf: [password.max_hash_len]u8 = undefined;
        const hash = try password.hash(gpa, io, default_password, &buf);
        try self.setHash(hash, .default);
    }
    return self;
}

pub fn currentSource(self: *Credentials) Source {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.source;
}

pub fn mustChange(self: *Credentials) bool {
    return self.currentSource() == .default;
}

/// Constant-time-ish check of user and password (argon2 always runs).
pub fn verify(self: *Credentials, user: []const u8, pass: []const u8) bool {
    var hash_copy: [password.max_hash_len]u8 = undefined;
    const hash = self.copyHash(&hash_copy);
    const user_ok = password.constantTimeEql(user, self.user);
    const pass_ok = password.verify(self.gpa, self.io, hash, pass);
    return user_ok and pass_ok;
}

/// Replaces the console-managed password.
pub fn change(self: *Credentials, new_password: []const u8) !void {
    if (self.currentSource() == .config) return error.PasswordManagedByConfig;
    try checkStrength(self.user, new_password);
    var buf: [password.max_hash_len]u8 = undefined;
    const hash = try password.hash(self.gpa, self.io, new_password, &buf);
    try self.writeStored(hash);
    try self.setHash(hash, .stored);
}

pub fn checkStrength(user: []const u8, pass: []const u8) !void {
    if (pass.len < min_password_len) return error.WeakPassword;
    if (pass.len > max_password_len) return error.WeakPassword;
    if (std.ascii.eqlIgnoreCase(pass, default_password)) {
        return error.WeakPassword;
    }
    if (std.ascii.eqlIgnoreCase(pass, user)) return error.WeakPassword;
}

fn setHash(self: *Credentials, hash: []const u8, source: Source) !void {
    if (hash.len > self.hash_buf.len) return error.InvalidPasswordHash;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    @memcpy(self.hash_buf[0..hash.len], hash);
    self.hash_len = hash.len;
    self.source = source;
}

fn copyHash(self: *Credentials, out: *[password.max_hash_len]u8) []const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    @memcpy(out[0..self.hash_len], self.hash_buf[0..self.hash_len]);
    return out[0..self.hash_len];
}

/// Copies the stored hash into `out`; null when there is none.
fn readStored(
    self: *Credentials,
    out: *[password.max_hash_len]u8,
) !?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = files.readAll(
        arena,
        self.io,
        self.store.root,
        file_name,
        4096,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const parsed = std.json.parseFromSliceLeaky(StoredFile, arena, data, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidAuthFile;
    const hash = parsed.password_hash;
    if (hash.len > out.len) return error.InvalidAuthFile;
    @memcpy(out[0..hash.len], hash);
    return out[0..hash.len];
}

fn writeStored(self: *Credentials, hash: []const u8) !void {
    var buf: [password.max_hash_len + 64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(StoredFile{ .password_hash = hash }, .{}, &w);
    self.store.lockExclusive();
    defer self.store.unlockExclusive();
    try files.writeAtomicPrivate(
        self.io,
        self.store.root,
        file_name,
        w.buffered(),
    );
}

test "password strength" {
    try std.testing.expectError(error.WeakPassword, checkStrength("a", "x"));
    try std.testing.expectError(
        error.WeakPassword,
        checkStrength("administrator", "ADMINISTRATOR"),
    );
    try checkStrength("admin", "correct horse");
}

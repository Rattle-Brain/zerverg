//! In-memory admin sessions. Tokens are 256-bit random values;
//! only their SHA-256 digests are stored. Restarting the server logs
//! the admin out, which is acceptable for a single-admin site.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Sessions = @This();

pub const token_bytes = 32;
pub const Token = [token_bytes * 2]u8;
const Digest = [Sha256.digest_length]u8;

const max_sessions = 64;
const max_user_len = 128;

const Entry = struct {
    expires_s: i64,
    user_len: u8,
    user: [max_user_len]u8,
};

gpa: Allocator,
io: Io,
ttl_s: i64,
mutex: Io.Mutex = .init,
/// Token digest -> who and until when.
expiries: std.AutoHashMapUnmanaged(Digest, Entry) = .empty,

pub fn init(gpa: Allocator, io: Io, ttl_s: u32) Sessions {
    return .{ .gpa = gpa, .io = io, .ttl_s = ttl_s };
}

pub fn deinit(self: *Sessions) void {
    self.expiries.deinit(self.gpa);
}

/// Creates a session for `user` and returns its hex token.
pub fn create(self: *Sessions, user: []const u8) !Token {
    if (user.len > max_user_len) return error.UserNameTooLong;
    var entry: Entry = .{
        .expires_s = 0,
        .user_len = @intCast(user.len),
        .user = undefined,
    };
    @memcpy(entry.user[0..user.len], user);
    var raw: [token_bytes]u8 = undefined;
    try self.io.randomSecure(&raw);
    const token = std.fmt.bytesToHex(raw, .lower);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const now = self.nowSeconds();
    if (self.expiries.count() >= max_sessions) self.purgeExpired(now);
    if (self.expiries.count() >= max_sessions) return error.TooManySessions;
    entry.expires_s = now + self.ttl_s;
    try self.expiries.put(self.gpa, digestOf(&token), entry);
    return token;
}

/// The session's user, copied into `arena`; null if invalid.
pub fn userOf(
    self: *Sessions,
    arena: Allocator,
    token: []const u8,
) Allocator.Error!?[]const u8 {
    if (token.len != token_bytes * 2) return null;
    const digest = digestOf(token);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.expiries.get(digest) orelse return null;
    if (entry.expires_s <= self.nowSeconds()) {
        _ = self.expiries.remove(digest);
        return null;
    }
    return try arena.dupe(u8, entry.user[0..entry.user_len]);
}

pub fn destroy(self: *Sessions, token: []const u8) void {
    const digest = digestOf(token);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    _ = self.expiries.remove(digest);
}

/// Logs everyone out (e.g. after a password change).
pub fn destroyAll(self: *Sessions) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.expiries.clearRetainingCapacity();
}

fn purgeExpired(self: *Sessions, now: i64) void {
    // Collect first: removing while iterating invalidates the iterator.
    var stale: [256]Digest = undefined;
    var count: usize = 0;
    var it = self.expiries.iterator();
    while (it.next()) |entry| {
        if (count == stale.len) break;
        if (entry.value_ptr.expires_s <= now) {
            stale[count] = entry.key_ptr.*;
            count += 1;
        }
    }
    for (stale[0..count]) |key| _ = self.expiries.remove(key);
}

fn nowSeconds(self: *Sessions) i64 {
    return Io.Timestamp.now(self.io, .real).toSeconds();
}

fn digestOf(token: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(token, &digest, .{});
    return digest;
}

test "create, validate, destroy" {
    var sessions = Sessions.init(std.testing.allocator, std.testing.io, 60);
    defer sessions.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token = try sessions.create("me@x.test");
    const user = try sessions.userOf(arena, &token);
    try std.testing.expectEqualStrings("me@x.test", user.?);
    try std.testing.expect(try sessions.userOf(arena, "nope") == null);
    sessions.destroy(&token);
    try std.testing.expect(try sessions.userOf(arena, &token) == null);
}

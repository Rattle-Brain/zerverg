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

gpa: Allocator,
io: Io,
ttl_s: i64,
mutex: Io.Mutex = .init,
/// Token digest -> expiry (unix seconds).
expiries: std.AutoHashMapUnmanaged(Digest, i64) = .empty,

pub fn init(gpa: Allocator, io: Io, ttl_s: u32) Sessions {
    return .{ .gpa = gpa, .io = io, .ttl_s = ttl_s };
}

pub fn deinit(self: *Sessions) void {
    self.expiries.deinit(self.gpa);
}

/// Creates a session and returns its hex token.
pub fn create(self: *Sessions) !Token {
    var raw: [token_bytes]u8 = undefined;
    try self.io.randomSecure(&raw);
    const token = std.fmt.bytesToHex(raw, .lower);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const now = self.nowSeconds();
    if (self.expiries.count() >= max_sessions) self.purgeExpired(now);
    if (self.expiries.count() >= max_sessions) return error.TooManySessions;
    try self.expiries.put(self.gpa, digestOf(&token), now + self.ttl_s);
    return token;
}

pub fn isValid(self: *Sessions, token: []const u8) bool {
    if (token.len != token_bytes * 2) return false;
    const digest = digestOf(token);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const expiry = self.expiries.get(digest) orelse return false;
    if (expiry > self.nowSeconds()) return true;
    _ = self.expiries.remove(digest);
    return false;
}

pub fn destroy(self: *Sessions, token: []const u8) void {
    const digest = digestOf(token);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    _ = self.expiries.remove(digest);
}

fn purgeExpired(self: *Sessions, now: i64) void {
    // Collect first: removing while iterating invalidates the iterator.
    var stale: [256]Digest = undefined;
    var count: usize = 0;
    var it = self.expiries.iterator();
    while (it.next()) |entry| {
        if (count == stale.len) break;
        if (entry.value_ptr.* <= now) {
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
    const token = try sessions.create();
    try std.testing.expect(sessions.isValid(&token));
    try std.testing.expect(!sessions.isValid("nope"));
    sessions.destroy(&token);
    try std.testing.expect(!sessions.isValid(&token));
}

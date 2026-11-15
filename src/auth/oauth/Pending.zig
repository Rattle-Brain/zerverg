//! Logins in flight: between sending the browser to the provider and
//! the provider sending it back, we remember the secrets of that one
//! attempt. Entries are single-use and expire after ten minutes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64url = std.base64.url_safe_no_pad;

const Pending = @This();

/// 32 random bytes, base64url: 43 characters, 256 bits of entropy.
pub const Secret = [43]u8;

pub const Entry = struct {
    provider: usize,
    /// PKCE code verifier.
    verifier: Secret,
    /// OIDC nonce, echoed inside the ID token.
    nonce: Secret,
    expires_s: i64,
};

const ttl_s = 10 * 60;
const max_entries = 1024;
const Digest = [Sha256.digest_length]u8;

gpa: Allocator,
io: Io,
mutex: Io.Mutex = .init,
entries: std.AutoHashMapUnmanaged(Digest, Entry) = .empty,

pub fn init(gpa: Allocator, io: Io) Pending {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(self: *Pending) void {
    self.entries.deinit(self.gpa);
}

pub fn randomSecret(io: Io) !Secret {
    var raw: [32]u8 = undefined;
    try io.randomSecure(&raw);
    var out: Secret = undefined;
    _ = base64url.Encoder.encode(&out, &raw);
    return out;
}

/// Starts an attempt; returns its `state` value.
pub fn begin(self: *Pending, entry_without_expiry: Entry) !Secret {
    const state = try randomSecret(self.io);
    var entry = entry_without_expiry;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const now = self.nowSeconds();
    entry.expires_s = now + ttl_s;
    if (self.entries.count() >= max_entries) self.evict(now);
    try self.entries.put(self.gpa, digestOf(&state), entry);
    return state;
}

/// Removes and returns the attempt for `state`, if still valid.
pub fn take(self: *Pending, state: []const u8) ?Entry {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const removed = self.entries.fetchRemove(digestOf(state)) orelse
        return null;
    if (removed.value.expires_s < self.nowSeconds()) return null;
    return removed.value;
}

/// Drops expired entries; if none expired, drops the oldest, so a
/// flood of abandoned attempts cannot lock out real ones for long.
fn evict(self: *Pending, now: i64) void {
    var oldest: ?Digest = null;
    var oldest_expiry: i64 = std.math.maxInt(i64);
    var stale: [64]Digest = undefined;
    var count: usize = 0;
    var it = self.entries.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.expires_s < now and count < stale.len) {
            stale[count] = e.key_ptr.*;
            count += 1;
        }
        if (e.value_ptr.expires_s < oldest_expiry) {
            oldest_expiry = e.value_ptr.expires_s;
            oldest = e.key_ptr.*;
        }
    }
    for (stale[0..count]) |key| _ = self.entries.remove(key);
    if (count == 0) if (oldest) |key| {
        _ = self.entries.remove(key);
    };
}

fn nowSeconds(self: *Pending) i64 {
    return Io.Timestamp.now(self.io, .real).toSeconds();
}

fn digestOf(state: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(state, &digest, .{});
    return digest;
}

test "single use" {
    var pending = Pending.init(std.testing.allocator, std.testing.io);
    defer pending.deinit();
    const state = try pending.begin(.{
        .provider = 1,
        .verifier = try randomSecret(std.testing.io),
        .nonce = try randomSecret(std.testing.io),
        .expires_s = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), pending.take(&state).?.provider);
    try std.testing.expectEqual(@as(?Entry, null), pending.take(&state));
    try std.testing.expectEqual(@as(?Entry, null), pending.take("forged"));
}

//! Per-client-IP brute force protection: after `max_failures` failed
//! logins, the IP is locked out for `lockout_s` seconds.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const LoginLimiter = @This();

pub const Key = [16]u8;

const max_tracked = 4096;

const Entry = struct {
    failures: u16,
    locked_until: i64,
};

gpa: Allocator,
io: Io,
max_failures: u16,
lockout_s: i64,
mutex: Io.Mutex = .init,
entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,

pub fn init(
    gpa: Allocator,
    io: Io,
    max_failures: u16,
    lockout_s: u32,
) LoginLimiter {
    return .{
        .gpa = gpa,
        .io = io,
        .max_failures = max_failures,
        .lockout_s = lockout_s,
    };
}

pub fn deinit(self: *LoginLimiter) void {
    self.entries.deinit(self.gpa);
}

/// IPv4 addresses map into the IPv4-mapped IPv6 range; ports ignored.
pub fn keyOf(address: Io.net.IpAddress) Key {
    return switch (address) {
        .ip6 => |a| a.bytes,
        .ip4 => |a| [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff } ++ a.bytes,
    };
}

pub fn isLocked(self: *LoginLimiter, key: Key) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.entries.get(key) orelse return false;
    return entry.locked_until > self.nowSeconds();
}

pub fn recordFailure(self: *LoginLimiter, key: Key) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const now = self.nowSeconds();
    if (self.entries.count() >= max_tracked) self.purgeStale(now);
    const gop = self.entries.getOrPut(self.gpa, key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{
        .failures = 0,
        .locked_until = 0,
    };
    const entry = gop.value_ptr;
    entry.failures +|= 1;
    if (entry.failures >= self.max_failures) {
        entry.locked_until = now + self.lockout_s;
        entry.failures = 0;
    }
}

pub fn recordSuccess(self: *LoginLimiter, key: Key) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    _ = self.entries.remove(key);
}

fn purgeStale(self: *LoginLimiter, now: i64) void {
    // Collect first: removing while iterating invalidates the iterator.
    var stale: [256]Key = undefined;
    var count: usize = 0;
    var it = self.entries.iterator();
    while (it.next()) |entry| {
        if (count == stale.len) break;
        if (entry.value_ptr.locked_until <= now) {
            stale[count] = entry.key_ptr.*;
            count += 1;
        }
    }
    for (stale[0..count]) |key| _ = self.entries.remove(key);
}

fn nowSeconds(self: *LoginLimiter) i64 {
    return Io.Timestamp.now(self.io, .real).toSeconds();
}

test "locks after max failures" {
    var limiter = LoginLimiter.init(
        std.testing.allocator,
        std.testing.io,
        3,
        60,
    );
    defer limiter.deinit();
    const key = keyOf(.{ .ip4 = .loopback(0) });
    limiter.recordFailure(key);
    limiter.recordFailure(key);
    try std.testing.expect(!limiter.isLocked(key));
    limiter.recordFailure(key);
    try std.testing.expect(limiter.isLocked(key));
}

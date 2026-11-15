//! Caps simultaneous connections per client, so a single client
//! cannot occupy the whole global connection budget.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const client_key = @import("client_key.zig");

const ConnectionLimiter = @This();

gpa: Allocator,
io: Io,
per_client: u32,
mutex: Io.Mutex = .init,
counts: std.AutoHashMapUnmanaged(client_key.Key, u32) = .empty,

pub fn init(gpa: Allocator, io: Io, per_client: u32) ConnectionLimiter {
    return .{ .gpa = gpa, .io = io, .per_client = per_client };
}

pub fn deinit(self: *ConnectionLimiter) void {
    self.counts.deinit(self.gpa);
}

/// Reserves a slot; false when the client is at its limit.
pub fn acquire(self: *ConnectionLimiter, key: client_key.Key) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const gop = self.counts.getOrPut(self.gpa, key) catch return false;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    if (gop.value_ptr.* >= self.per_client) return false;
    gop.value_ptr.* += 1;
    return true;
}

pub fn release(self: *ConnectionLimiter, key: client_key.Key) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const count = self.counts.getPtr(key) orelse return;
    count.* -= 1;
    if (count.* == 0) _ = self.counts.remove(key);
}

test "per client cap" {
    var limiter = ConnectionLimiter.init(
        std.testing.allocator,
        std.testing.io,
        2,
    );
    defer limiter.deinit();
    const key = client_key.of(.{ .ip4 = .loopback(0) });
    try std.testing.expect(limiter.acquire(key));
    try std.testing.expect(limiter.acquire(key));
    try std.testing.expect(!limiter.acquire(key));
    limiter.release(key);
    try std.testing.expect(limiter.acquire(key));
}

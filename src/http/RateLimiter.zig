//! Per-client token bucket: each client earns `per_second` tokens
//! per second up to `burst`; every request spends one.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const client_key = @import("client_key.zig");

const RateLimiter = @This();

const max_tracked = 8192;

const Bucket = struct {
    tokens: f64,
    updated_ns: i96,
};

gpa: Allocator,
io: Io,
per_second: f64,
burst: f64,
mutex: Io.Mutex = .init,
buckets: std.AutoHashMapUnmanaged(client_key.Key, Bucket) = .empty,

/// `per_second == 0` disables limiting.
pub fn init(
    gpa: Allocator,
    io: Io,
    per_second: u32,
    burst: u32,
) RateLimiter {
    return .{
        .gpa = gpa,
        .io = io,
        .per_second = @floatFromInt(per_second),
        .burst = @floatFromInt(@max(burst, 1)),
    };
}

pub fn deinit(self: *RateLimiter) void {
    self.buckets.deinit(self.gpa);
}

pub fn allow(self: *RateLimiter, key: client_key.Key) bool {
    if (self.per_second == 0) return true;
    const now = Io.Timestamp.now(self.io, .awake).nanoseconds;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.buckets.count() >= max_tracked) self.purgeIdle(now);
    const gop = self.buckets.getOrPut(self.gpa, key) catch return true;
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .tokens = self.burst, .updated_ns = now };
    }
    const bucket = gop.value_ptr;
    bucket.tokens = self.refilled(bucket.*, now);
    bucket.updated_ns = now;
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
}

fn refilled(self: *const RateLimiter, bucket: Bucket, now: i96) f64 {
    const elapsed_ns: f64 = @floatFromInt(now - bucket.updated_ns);
    const earned = elapsed_ns / std.time.ns_per_s * self.per_second;
    return @min(self.burst, bucket.tokens + earned);
}

/// Drops buckets that have refilled completely: forgetting them
/// changes nothing.
fn purgeIdle(self: *RateLimiter, now: i96) void {
    var idle: [512]client_key.Key = undefined;
    var count: usize = 0;
    var it = self.buckets.iterator();
    while (it.next()) |entry| {
        if (count == idle.len) break;
        if (self.refilled(entry.value_ptr.*, now) >= self.burst) {
            idle[count] = entry.key_ptr.*;
            count += 1;
        }
    }
    for (idle[0..count]) |key| _ = self.buckets.remove(key);
}

test "burst then refuse" {
    var limiter = RateLimiter.init(
        std.testing.allocator,
        std.testing.io,
        1,
        3,
    );
    defer limiter.deinit();
    const key = client_key.of(.{ .ip4 = .loopback(0) });
    try std.testing.expect(limiter.allow(key));
    try std.testing.expect(limiter.allow(key));
    try std.testing.expect(limiter.allow(key));
    try std.testing.expect(!limiter.allow(key));
}

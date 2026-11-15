//! Identifies a client for per-client limits.
//!
//! IPv4 addresses are used whole. IPv6 addresses are truncated to
//! their /64 prefix: one end user typically controls an entire /64,
//! so keying on full addresses would let them dodge every limit.

const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

pub const Key = [16]u8;

pub fn of(address: IpAddress) Key {
    return switch (address) {
        .ip4 => |a| mapped(a.bytes),
        .ip6 => |a| if (isV4Mapped(a.bytes)) a.bytes else prefix64(a.bytes),
    };
}

fn mapped(ip4: [4]u8) Key {
    return [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff } ++ ip4;
}

fn isV4Mapped(bytes: [16]u8) bool {
    const prefix = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff };
    return std.mem.eql(u8, bytes[0..12], &prefix);
}

fn prefix64(bytes: [16]u8) Key {
    var key = bytes;
    @memset(key[8..], 0);
    return key;
}

test "ipv6 clients share their /64" {
    const a = try IpAddress.parse("2001:db8:1:2::1", 0);
    const b = try IpAddress.parse("2001:db8:1:2:ffff::9", 0);
    const c = try IpAddress.parse("2001:db8:1:3::1", 0);
    try std.testing.expectEqual(of(a), of(b));
    try std.testing.expect(!std.mem.eql(u8, &of(a), &of(c)));
}

test "ipv4 and v4-mapped agree" {
    const a = try IpAddress.parse("192.0.2.7", 0);
    const b = try IpAddress.parse("::ffff:192.0.2.7", 0);
    try std.testing.expectEqual(of(a), of(b));
}

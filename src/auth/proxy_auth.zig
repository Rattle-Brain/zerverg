//! Trusted reverse-proxy authentication: an authenticating proxy
//! (Authelia, oauth2-proxy, Pomerium, ...) puts the user name in a
//! header. The header is only believed when the TCP peer is one of
//! the configured trusted proxies; anyone else could forge it.

const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

pub const Error = error{Unauthorized};

/// Parses the configured proxy addresses (validated at startup).
pub fn parseTrusted(
    arena: std.mem.Allocator,
    addresses: []const []const u8,
) ![]const IpAddress {
    const out = try arena.alloc(IpAddress, addresses.len);
    for (addresses, out) |text, *addr| addr.* = try IpAddress.parse(text, 0);
    return out;
}

pub fn isTrusted(trusted: []const IpAddress, peer: IpAddress) bool {
    for (trusted) |t| {
        if (sameHost(t, peer)) return true;
    }
    return false;
}

/// Returns the user name if the request came through a trusted proxy
/// and the user is allowed.
pub fn userFrom(
    trusted: []const IpAddress,
    allowed: []const []const u8,
    peer: IpAddress,
    header_value: ?[]const u8,
) Error![]const u8 {
    if (!isTrusted(trusted, peer)) return error.Unauthorized;
    const user = std.mem.trim(u8, header_value orelse "", " ");
    if (user.len == 0 or user.len > 256) return error.Unauthorized;
    if (allowed.len == 0) return user;
    for (allowed) |a| {
        if (std.mem.eql(u8, a, user)) return user;
    }
    return error.Unauthorized;
}

/// Address equality ignoring ports.
fn sameHost(a: IpAddress, b: IpAddress) bool {
    return switch (a) {
        .ip4 => |x| switch (b) {
            .ip4 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
            .ip6 => false,
        },
        .ip6 => |x| switch (b) {
            .ip6 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
            .ip4 => false,
        },
    };
}

test "only trusted peers may name the user" {
    const trusted = [_]IpAddress{try IpAddress.parse("10.0.0.2", 0)};
    const proxy = try IpAddress.parse("10.0.0.2", 51000);
    const other = try IpAddress.parse("10.0.0.3", 51000);
    try std.testing.expectEqualStrings(
        "alice",
        try userFrom(&trusted, &.{}, proxy, "alice"),
    );
    try std.testing.expectError(
        error.Unauthorized,
        userFrom(&trusted, &.{}, other, "alice"),
    );
    try std.testing.expectError(
        error.Unauthorized,
        userFrom(&trusted, &.{"bob"}, proxy, "alice"),
    );
}

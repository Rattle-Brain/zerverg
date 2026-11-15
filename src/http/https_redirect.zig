//! With native TLS on, the plain-HTTP port only sends visitors to the
//! HTTPS port.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Request = @import("Request.zig");
const Response = @import("Response.zig");

/// 308 to the same host and target on `https_port`; 400 when the Host
/// header is missing or malformed (it ends up in a Location header).
pub fn respond(
    arena: Allocator,
    request: *const Request,
    https_port: u16,
) Allocator.Error!Response {
    const host_header = request.header("host") orelse
        return Response.text(.bad_request, "missing Host header");
    const host = hostName(host_header) orelse
        return Response.text(.bad_request, "invalid Host header");
    const location = try buildLocation(
        arena,
        host,
        https_port,
        request.path,
        request.query,
    );
    return .{ .status = .permanent_redirect, .location = location };
}

fn buildLocation(
    arena: Allocator,
    host: []const u8,
    https_port: u16,
    path: []const u8,
    query: []const u8,
) Allocator.Error![]const u8 {
    var port_buf: [8]u8 = undefined;
    const port = if (https_port == 443)
        ""
    else
        std.fmt.bufPrint(&port_buf, ":{d}", .{https_port}) catch unreachable;
    const separator: []const u8 = if (query.len > 0) "?" else "";
    return std.mem.concat(arena, u8, &.{
        "https://", host, port, path, separator, query,
    });
}

/// The host part of a Host header, port removed. Null if it holds
/// anything but a DNS name, IPv4 or bracketed IPv6 literal.
fn hostName(header: []const u8) ?[]const u8 {
    const host = if (std.mem.startsWith(u8, header, "["))
        header[0 .. (std.mem.indexOfScalar(u8, header, ']') orelse
            return null) + 1]
    else
        header[0 .. std.mem.indexOfScalar(u8, header, ':') orelse
            header.len];
    if (host.len == 0 or host.len > 255) return null;
    for (host) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or
            c == '[' or c == ']' or c == ':';
        if (!ok) return null;
    }
    return host;
}

test "host name strips the port" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings("example.com", hostName("example.com:7080").?);
    try expectEqualStrings("example.com", hostName("example.com").?);
    try expectEqualStrings("[::1]", hostName("[::1]:7080").?);
    try std.testing.expect(hostName("evil.com/x") == null);
    try std.testing.expect(hostName("") == null);
    try std.testing.expect(hostName("[::1") == null);
}

test "location keeps path and query, omits port 443" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "https://a.b:7443/x?y=1",
        try buildLocation(arena, "a.b", 7443, "/x", "y=1"),
    );
    try std.testing.expectEqualStrings(
        "https://a.b/",
        try buildLocation(arena, "a.b", 443, "/", ""),
    );
}

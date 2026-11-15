//! Response headers, including the security headers sent on every
//! response.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const Config = @import("../config.zig").Config;
const Response = @import("Response.zig");
const Surface = @import("../auth/guard.zig").Surface;

/// Console and API: own origin only, never framed.
const admin_csp = "default-src 'self'; img-src 'self' data:; " ++
    "frame-ancestors 'none'; base-uri 'none'; form-action 'self'";

const permissions_policy = "accelerometer=(), camera=(), " ++
    "geolocation=(), gyroscope=(), magnetometer=(), microphone=(), " ++
    "payment=(), usb=(), interest-cohort=()";

const security_headers = [_]http.Header{
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "referrer-policy", .value = "strict-origin-when-cross-origin" },
    .{ .name = "permissions-policy", .value = permissions_policy },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "cross-origin-resource-policy", .value = "same-site" },
};

pub fn build(
    arena: Allocator,
    config: *const Config,
    surface: Surface,
    path: []const u8,
    response: Response,
) Allocator.Error![]const http.Header {
    var list: std.ArrayList(http.Header) = .empty;
    try list.appendSlice(arena, &.{
        .{ .name = "content-type", .value = response.content_type },
        .{ .name = "cache-control", .value = response.cache_control },
    });
    try list.appendSlice(arena, &security_headers);
    const admin = surface == .admin or isApiPath(path);
    try list.append(arena, .{
        .name = "content-security-policy",
        .value = response.csp orelse
            if (admin) admin_csp else config.public_csp,
    });
    if (admin) try list.append(arena, .{
        .name = "x-robots-tag",
        .value = "noindex, nofollow",
    });
    if (config.https) try list.append(arena, .{
        .name = "strict-transport-security",
        .value = "max-age=31536000; includeSubDomains",
    });
    for (response.set_cookies) |v| {
        try list.append(arena, .{ .name = "set-cookie", .value = v });
    }
    if (response.location) |v| {
        try list.append(arena, .{ .name = "location", .value = v });
    }
    return list.items;
}

fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/");
}

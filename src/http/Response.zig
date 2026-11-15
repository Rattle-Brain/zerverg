//! A fully buffered HTTP response plus constructors for common cases.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const Response = @This();

status: http.Status = .ok,
content_type: []const u8 = "text/plain; charset=utf-8",
body: []const u8 = "",
cache_control: []const u8 = "no-store",
/// Each becomes its own Set-Cookie header.
set_cookies: []const []const u8 = &.{},
location: ?[]const u8 = null,
/// Content-Security-Policy override; null uses the route default.
csp: ?[]const u8 = null,
/// When set, the body is streamed from this file instead of `body`.
/// The server closes it after sending.
file: ?std.Io.File = null,
file_size: u64 = 0,

pub fn text(status: http.Status, body: []const u8) Response {
    return .{ .status = status, .body = body };
}

pub fn html(body: []const u8) Response {
    return .{ .content_type = "text/html; charset=utf-8", .body = body };
}

pub fn noContent() Response {
    return .{ .status = .no_content };
}

pub fn redirect(location: []const u8) Response {
    return .{ .status = .see_other, .location = location };
}

/// Serializes `value` as JSON.
pub fn json(
    arena: Allocator,
    status: http.Status,
    value: anytype,
) Allocator.Error!Response {
    const body = try std.json.Stringify.valueAlloc(arena, value, .{});
    return .{
        .status = status,
        .content_type = "application/json",
        .body = body,
    };
}

/// `{"error": message}` with the given status.
pub fn jsonError(status: http.Status, comptime message: []const u8) Response {
    return .{
        .status = status,
        .content_type = "application/json",
        .body = "{\"error\":\"" ++ message ++ "\"}",
    };
}

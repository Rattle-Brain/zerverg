//! A fully buffered HTTP response plus constructors for common cases.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const Response = @This();

status: http.Status = .ok,
content_type: []const u8 = "text/plain; charset=utf-8",
body: []const u8 = "",
cache_control: []const u8 = "no-store",
set_cookie: ?[]const u8 = null,
location: ?[]const u8 = null,
/// Content-Security-Policy; null sends none.
csp: ?[]const u8 = null,

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

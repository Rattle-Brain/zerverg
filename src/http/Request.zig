//! An HTTP request decoupled from the connection: the parts of the
//! head we need are copied into the request arena before the body is
//! read (reading the body invalidates std.http's head strings).

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const Request = @This();

pub const max_params = 4;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

method: http.Method,
path: []const u8,
query: []const u8,
cookie: ?[]const u8 = null,
authorization: ?[]const u8 = null,
content_type: ?[]const u8 = null,
requested_with: ?[]const u8 = null,
peer: std.Io.net.IpAddress,
body: []const u8 = "",
params: [max_params]Param = undefined,
param_count: usize = 0,

pub const ReadError = error{ TooLarge, BadRequest } || Allocator.Error;

/// Copies the head and reads the body (up to `max_body` bytes).
pub fn fromHttp(
    arena: Allocator,
    raw: *http.Server.Request,
    peer: std.Io.net.IpAddress,
    max_body: usize,
) ReadError!Request {
    const target = try arena.dupe(u8, raw.head.target);
    const split = std.mem.indexOfScalar(u8, target, '?');
    var request: Request = .{
        .method = raw.head.method,
        .path = if (split) |i| target[0..i] else target,
        .query = if (split) |i| target[i + 1 ..] else "",
        .peer = peer,
    };
    try request.copyHeaders(arena, raw);
    request.body = try readBody(arena, raw, max_body);
    return request;
}

fn copyHeaders(
    self: *Request,
    arena: Allocator,
    raw: *http.Server.Request,
) Allocator.Error!void {
    if (raw.head.content_type) |v| self.content_type = try arena.dupe(u8, v);
    var it = raw.iterateHeaders();
    while (it.next()) |header| {
        const value = try arena.dupe(u8, header.value);
        if (eqlIgnoreCase(header.name, "cookie")) {
            self.cookie = value;
        } else if (eqlIgnoreCase(header.name, "authorization")) {
            self.authorization = value;
        } else if (eqlIgnoreCase(header.name, "x-requested-with")) {
            self.requested_with = value;
        }
    }
}

fn readBody(
    arena: Allocator,
    raw: *http.Server.Request,
    max_body: usize,
) ReadError![]const u8 {
    if (!raw.head.method.requestHasBody()) return "";
    // RFC 9112 6.3: no Content-Length and no chunked coding means no
    // body. std.http would otherwise read until the client closes, and
    // asserts on such requests when responding, so make it explicit.
    const chunked = raw.head.transfer_encoding == .chunked;
    if (raw.head.content_length) |len| {
        if (len > max_body) return error.TooLarge;
    } else if (!chunked) {
        raw.head.content_length = 0;
        return "";
    }
    var buf: [4096]u8 = undefined;
    const reader = raw.readerExpectContinue(&buf) catch
        return error.BadRequest;
    return reader.allocRemaining(arena, .limited(max_body + 1)) catch |err|
        switch (err) {
            error.StreamTooLong => error.TooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.BadRequest,
        };
}

/// Named route parameter, set by the router. Asserts it exists.
pub fn param(self: *const Request, name: []const u8) []const u8 {
    for (self.params[0..self.param_count]) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    unreachable;
}

/// Raw (undecoded) query parameter value.
pub fn queryParam(self: *const Request, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, self.query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// Value of cookie `name` from the Cookie header.
pub fn cookieValue(self: *const Request, name: []const u8) ?[]const u8 {
    const header = self.cookie orelse return null;
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |part| {
        const pair = std.mem.trim(u8, part, " ");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn isMutating(self: *const Request) bool {
    return switch (self.method) {
        .GET, .HEAD, .OPTIONS => false,
        else => true,
    };
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn testRequest(query: []const u8, cookie: ?[]const u8) Request {
    return .{
        .method = .GET,
        .path = "/",
        .query = query,
        .cookie = cookie,
        .peer = .{ .ip4 = .loopback(0) },
    };
}

test "query and cookie lookup" {
    const r = testRequest("a=1&version=3", "x=1; zv_session=abc");
    try std.testing.expectEqualStrings("3", r.queryParam("version").?);
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("b"));
    try std.testing.expectEqualStrings("abc", r.cookieValue("zv_session").?);
}

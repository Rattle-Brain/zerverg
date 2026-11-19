//! An HTTP request decoupled from the connection.
//!
//! The head is copied and validated up front. The body is NOT read
//! until `readBody` is called, which the dispatcher only does after
//! the route matched and the client is authorised: anonymous
//! clients can never make the server buffer a large upload.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const Request = @This();

pub const max_params = 4;
pub const max_target_len = 2048;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const BodyState = enum {
    /// The request declared no body.
    absent,
    /// A body was declared and has not been consumed.
    pending,
    /// The body was read into `body`.
    read,
};

method: http.Method,
path: []const u8,
query: []const u8,
cookie: ?[]const u8 = null,
authorization: ?[]const u8 = null,
content_type: ?[]const u8 = null,
requested_with: ?[]const u8 = null,
/// Every header, copied; bounded by the 16 KiB head buffer.
headers: []const http.Header = &.{},
peer: std.Io.net.IpAddress,
body: []const u8 = "",
body_state: BodyState = .absent,
raw: ?*http.Server.Request = null,
params: [max_params]Param = undefined,
param_count: usize = 0,

pub const HeadError = error{ BadRequest, UriTooLong } || Allocator.Error;
pub const BodyError = error{ TooLarge, BadRequest } || Allocator.Error;

/// Copies and validates the head. Does not touch the body.
pub fn fromHttp(
    arena: Allocator,
    raw: *http.Server.Request,
    peer: std.Io.net.IpAddress,
) HeadError!Request {
    if (raw.head.target.len > max_target_len) return error.UriTooLong;
    const target = try arena.dupe(u8, raw.head.target);
    const split = std.mem.indexOfScalar(u8, target, '?');
    const path = if (split) |i| target[0..i] else target;
    try validatePath(path);
    var request: Request = .{
        .method = raw.head.method,
        .path = path,
        .query = if (split) |i| target[i + 1 ..] else "",
        .peer = peer,
        .raw = raw,
        .body_state = declaredBody(raw),
    };
    try request.copyHeaders(arena, raw);
    return request;
}

/// Rejects paths that are not plain origin-form: control bytes,
/// backslashes, empty, `.` or `..` segments. One trailing slash is
/// allowed.
fn validatePath(path: []const u8) error{BadRequest}!void {
    if (path.len == 0 or path[0] != '/') return error.BadRequest;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') return error.BadRequest;
    }
    if (path.len == 1) return;
    const end = if (path[path.len - 1] == '/') path.len - 1 else path.len;
    var segments = std.mem.splitScalar(u8, path[1..end], '/');
    while (segments.next()) |segment| {
        const dot = std.mem.eql(u8, segment, ".");
        const dots = std.mem.eql(u8, segment, "..");
        if (segment.len == 0 or dot or dots) return error.BadRequest;
    }
}

/// RFC 9112 6.3: no Content-Length and no chunked coding means no
/// body. std.http would otherwise read until the client closes, and
/// asserts on such requests when responding, so make it explicit.
fn declaredBody(raw: *http.Server.Request) BodyState {
    if (!raw.head.method.requestHasBody()) return .absent;
    if (raw.head.transfer_encoding == .chunked) return .pending;
    const len = raw.head.content_length orelse {
        raw.head.content_length = 0;
        return .absent;
    };
    return if (len == 0) .absent else .pending;
}

fn copyHeaders(
    self: *Request,
    arena: Allocator,
    raw: *http.Server.Request,
) Allocator.Error!void {
    if (raw.head.content_type) |v| self.content_type = try arena.dupe(u8, v);
    var list: std.ArrayList(http.Header) = .empty;
    var it = raw.iterateHeaders();
    while (it.next()) |h| {
        const copy: http.Header = .{
            .name = try arena.dupe(u8, h.name),
            .value = try arena.dupe(u8, h.value),
        };
        try list.append(arena, copy);
        if (eqlIgnoreCase(copy.name, "cookie")) {
            self.cookie = copy.value;
        } else if (eqlIgnoreCase(copy.name, "authorization")) {
            self.authorization = copy.value;
        } else if (eqlIgnoreCase(copy.name, "x-requested-with")) {
            self.requested_with = copy.value;
        }
    }
    self.headers = list.items;
}

/// First header named `name` (case-insensitive).
pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
    for (self.headers) |h| {
        if (eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Reads the body, refusing anything over `limit` bytes.
pub fn readBody(self: *Request, arena: Allocator, limit: usize) BodyError!void {
    if (self.body_state != .pending) return;
    const raw = self.raw orelse return;
    if (raw.head.content_length) |len| {
        if (len > limit) return error.TooLarge;
    }
    var buf: [4096]u8 = undefined;
    const reader = raw.readerExpectContinue(&buf) catch
        return error.BadRequest;
    self.body = reader.allocRemaining(arena, .limited(limit + 1)) catch |err|
        switch (err) {
            error.StreamTooLong => return error.TooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.BadRequest,
        };
    self.body_state = .read;
}

/// An unconsumed body leaves the stream mid-request: the connection
/// must close rather than be reused.
pub fn canKeepAlive(self: *const Request) bool {
    return self.body_state != .pending;
}

/// Named route parameter, set by the router. Asserts it exists.
pub fn param(self: *const Request, name: []const u8) []const u8 {
    return self.optionalParam(name) orelse unreachable;
}

/// Named route parameter, for handlers shared by routes where only
/// some patterns capture it.
pub fn optionalParam(self: *const Request, name: []const u8) ?[]const u8 {
    for (self.params[0..self.param_count]) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
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

/// Query parameter value with `+` and `%XX` decoded.
pub fn decodedQueryParam(
    self: *const Request,
    arena: Allocator,
    name: []const u8,
) error{ BadRequest, OutOfMemory }!?[]u8 {
    const raw = self.queryParam(name) orelse return null;
    const out = try arena.alloc(u8, raw.len);
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (len += 1) {
        switch (raw[i]) {
            '+' => out[len] = ' ',
            '%' => {
                if (i + 2 >= raw.len) return error.BadRequest;
                out[len] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch
                    return error.BadRequest;
                i += 3;
                continue;
            },
            else => |c| out[len] = c,
        }
        i += 1;
    }
    return out[0..len];
}

/// Value of cookie `name` from the Cookie header.
pub fn cookieValue(self: *const Request, name: []const u8) ?[]const u8 {
    const cookies = self.cookie orelse return null;
    var it = std.mem.splitScalar(u8, cookies, ';');
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

test "query decoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = testRequest("q=a+b%2Fc&bad=%4", null);
    const q = try r.decodedQueryParam(arena, "q");
    try std.testing.expectEqualStrings("a b/c", q.?);
    try std.testing.expectError(
        error.BadRequest,
        r.decodedQueryParam(arena, "bad"),
    );
}

test "path validation" {
    try validatePath("/");
    try validatePath("/docs");
    try validatePath("/api/v1/posts/");
    const bad = [_][]const u8{
        "",        "x",    "//",    "/a//b",
        "/a/../b", "/./a", "/a\\b", "/a\x00",
    };
    for (bad) |p| {
        try std.testing.expectError(error.BadRequest, validatePath(p));
    }
}

test "query and cookie lookup" {
    const r = testRequest("a=1&version=3", "x=1; zv_session=abc");
    try std.testing.expectEqualStrings("3", r.queryParam("version").?);
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("b"));
    try std.testing.expectEqualStrings("abc", r.cookieValue("zv_session").?);
}

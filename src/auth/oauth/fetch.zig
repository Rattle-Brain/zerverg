//! Outbound calls to identity providers.
//!
//! HTTPS only (certificates verified by std's TLS client), except for
//! loopback addresses so a local test provider can be used. Responses
//! are capped, so a misbehaving provider cannot exhaust memory.

const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_response_bytes = 256 * 1024;

pub const Error = error{
    InsecureProviderUrl,
    ProviderUnavailable,
    ProviderRejected,
} || Allocator.Error;

pub const Call = struct {
    url: []const u8,
    /// `application/x-www-form-urlencoded` body; makes it a POST.
    form: ?[]const u8 = null,
    bearer_token: ?[]const u8 = null,
};

/// Performs the call and returns the response body (JSON expected).
pub fn json(gpa: Allocator, io: Io, arena: Allocator, call: Call) Error![]u8 {
    if (!isAllowedUrl(call.url)) return error.InsecureProviderUrl;
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const buffer = try arena.alloc(u8, max_response_bytes);
    var body: Io.Writer = .fixed(buffer);
    const authorization: http.Client.Request.Headers.Value =
        if (call.bearer_token) |t|
            .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) }
        else
            .default;
    const result = client.fetch(.{
        .location = .{ .url = call.url },
        .method = if (call.form != null) .POST else .GET,
        .payload = call.form,
        .response_writer = &body,
        .headers = .{
            .user_agent = .{ .override = "zerverg" },
            .authorization = authorization,
            .content_type = if (call.form != null)
                .{ .override = "application/x-www-form-urlencoded" }
            else
                .default,
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    }) catch |err| {
        std.log.warn("oauth: request to provider failed: {t}", .{err});
        return error.ProviderUnavailable;
    };
    if (result.status != .ok) {
        const status = @intFromEnum(result.status);
        std.log.warn("oauth: provider answered {d}", .{status});
        return error.ProviderRejected;
    }
    return body.buffered();
}

/// `https://`, or `http://` to a loopback host (local test setups).
/// Parsed properly: `http://127.0.0.1:80@evil.example/` has host
/// `evil.example` and is refused.
pub fn isAllowedUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.user != null or uri.password != null) return false;
    const host_component = uri.host orelse return false;
    const host = switch (host_component) {
        .raw, .percent_encoded => |h| h,
    };
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return host.len > 0;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const loopbacks = [_][]const u8{ "127.0.0.1", "localhost", "[::1]", "::1" };
    for (loopbacks) |loopback| {
        if (std.ascii.eqlIgnoreCase(host, loopback)) return true;
    }
    return false;
}

/// Builds `a=1&b=2` with RFC 3986 percent-encoding.
pub fn encodeForm(
    arena: Allocator,
    pairs: []const [2][]const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |pair, i| {
        if (i > 0) try out.append(arena, '&');
        try percentEncode(arena, &out, pair[0]);
        try out.append(arena, '=');
        try percentEncode(arena, &out, pair[1]);
    }
    return out.items;
}

fn percentEncode(
    arena: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) Allocator.Error!void {
    for (text) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or
            c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
}

test "form encoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try encodeForm(arena_state.allocator(), &.{
        .{ "redirect_uri", "https://a.b/c?d=e f" },
        .{ "x", "~ok_" },
    });
    try std.testing.expectEqualStrings(
        "redirect_uri=https%3A%2F%2Fa.b%2Fc%3Fd%3De%20f&x=~ok_",
        out,
    );
}

test "provider urls" {
    try std.testing.expect(isAllowedUrl("https://accounts.google.com/x"));
    try std.testing.expect(isAllowedUrl("http://127.0.0.1:9999/token"));
    try std.testing.expect(!isAllowedUrl("http://evil.example/token"));
    try std.testing.expect(!isAllowedUrl("http://127.0.0.1.evil.example/"));
    try std.testing.expect(!isAllowedUrl("http://127.0.0.1:80@evil.example/"));
    try std.testing.expect(!isAllowedUrl("ftp://127.0.0.1/"));
}

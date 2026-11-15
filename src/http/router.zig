//! Method + path pattern routing. Patterns are literal segments and
//! `:name` captures, e.g. `/api/v1/posts/:slug`. First match wins.

const std = @import("std");
const http = std.http;

const Request = @import("Request.zig");

pub const Access = enum { public, admin };

/// How much request body a route accepts. Mapped to byte limits
/// from the config by the dispatcher.
pub const BodyLimit = enum { none, small, text, media };

pub fn Route(comptime Handler: type) type {
    return struct {
        method: http.Method,
        pattern: []const u8,
        access: Access,
        handler: Handler,
        body: BodyLimit = .none,
        /// Reachable while the factory password is still active.
        before_password_change: bool = false,
    };
}

pub const MatchResult = enum { matched, wrong_method, not_found };

/// Finds the route for `request`, filling its params on success.
pub fn find(
    comptime R: type,
    routes: []const R,
    request: *Request,
) struct { ?*const R, MatchResult } {
    var path_matched = false;
    for (routes) |*route| {
        if (!matchPath(route.pattern, request)) continue;
        if (methodMatches(route.method, request.method)) {
            return .{ route, .matched };
        }
        path_matched = true;
    }
    request.param_count = 0;
    return .{ null, if (path_matched) .wrong_method else .not_found };
}

fn methodMatches(route: http.Method, actual: http.Method) bool {
    if (route == actual) return true;
    return route == .GET and actual == .HEAD;
}

fn matchPath(pattern: []const u8, request: *Request) bool {
    request.param_count = 0;
    var pat_it = std.mem.splitScalar(u8, trimSlash(pattern), '/');
    var path_it = std.mem.splitScalar(u8, trimSlash(request.path), '/');
    while (true) {
        const pat = pat_it.next();
        const seg = path_it.next();
        if (pat == null and seg == null) return true;
        if (pat == null or seg == null) return false;
        if (!matchSegment(pat.?, seg.?, request)) return false;
    }
}

fn matchSegment(pat: []const u8, seg: []const u8, request: *Request) bool {
    if (pat.len > 0 and pat[0] == ':') {
        if (seg.len == 0) return false;
        if (request.param_count == Request.max_params) return false;
        request.params[request.param_count] = .{
            .name = pat[1..],
            .value = seg,
        };
        request.param_count += 1;
        return true;
    }
    return std.mem.eql(u8, pat, seg);
}

fn trimSlash(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}

const TestRoute = Route(u8);

fn testRequest(method: http.Method, path: []const u8) Request {
    return .{
        .method = method,
        .path = path,
        .query = "",
        .peer = .{ .ip4 = .loopback(0) },
    };
}

test "match with params" {
    const routes = [_]TestRoute{
        .{ .method = .GET, .pattern = "/", .access = .public, .handler = 0 },
        .{
            .method = .GET,
            .pattern = "/api/v1/posts/:slug",
            .access = .admin,
            .handler = 1,
        },
    };
    var req = testRequest(.GET, "/api/v1/posts/hello");
    const route, const result = find(TestRoute, &routes, &req);
    try std.testing.expectEqual(MatchResult.matched, result);
    try std.testing.expectEqual(@as(u8, 1), route.?.handler);
    try std.testing.expectEqualStrings("hello", req.param("slug"));

    var root = testRequest(.HEAD, "/");
    _, const root_result = find(TestRoute, &routes, &root);
    try std.testing.expectEqual(MatchResult.matched, root_result);

    var wrong = testRequest(.DELETE, "/");
    _, const wrong_result = find(TestRoute, &routes, &wrong);
    try std.testing.expectEqual(MatchResult.wrong_method, wrong_result);
}

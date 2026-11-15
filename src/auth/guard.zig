//! Decides who is making a request, and whether they may.
//!
//! The server listens on two surfaces:
//!   - public (site, port 7080): the API accepts HTTP Basic only, and
//!     only with the password method. Session cookies are ignored
//!     here, because browsers send cookies to every port of a host
//!     and site snippets run on this origin.
//!   - admin (console, port 9080): session cookies (from a password
//!     or "sign in with ..." login), Basic, or a trusted proxy
//!     header, depending on `auth_method`.
//!
//! With `oauth` or `proxy`, password login is disabled entirely, so
//! the factory `admin:admin` cannot become a back door.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const Request = @import("../http/Request.zig");
const client_key = @import("../http/client_key.zig");
const proxy_auth = @import("proxy_auth.zig");

pub const session_cookie = "zv_session";

/// Mutating cookie-authenticated requests must carry this header.
/// Browsers cannot add it cross-site without a CORS preflight, which
/// we never grant, so it blocks CSRF.
pub const csrf_header_value = "zerverg";

pub const Surface = enum { public, admin };

pub const Via = enum { dev, session, basic, proxy };

pub const Principal = struct {
    name: []const u8,
    via: Via,
    /// Factory password still active: only changing it is allowed.
    must_change: bool = false,
};

pub const Error = error{
    Unauthorized,
    Forbidden,
    TooManyAttempts,
} || Allocator.Error;

pub fn authorize(
    app: *App,
    arena: Allocator,
    request: *const Request,
    surface: Surface,
) Error!Principal {
    if (app.config.dev_mode) return .{ .name = "dev", .via = .dev };
    switch (app.config.auth_method) {
        .password => return passwordPrincipal(app, arena, request, surface),
        .oauth => {
            if (surface == .public) return error.Unauthorized;
            const principal = try sessionPrincipal(app, arena, request, false);
            return principal orelse error.Unauthorized;
        },
        .proxy => {
            if (surface == .public) return error.Unauthorized;
            const user = try proxy_auth.userFrom(
                app.trusted_proxies,
                app.config.proxy_allowed_users,
                request.peer,
                request.header(app.config.proxy_user_header),
            );
            return .{ .name = user, .via = .proxy };
        },
    }
}

fn passwordPrincipal(
    app: *App,
    arena: Allocator,
    request: *const Request,
    surface: Surface,
) Error!Principal {
    const must_change = app.credentials.mustChange();
    if (surface == .admin) {
        if (try sessionPrincipal(app, arena, request, must_change)) |p| {
            return p;
        }
    }
    var storage: [512]u8 = undefined;
    const creds = basicCredentials(request, &storage) orelse
        return error.Unauthorized;
    try checkCredentials(app, request.peer, creds.user, creds.pass);
    return .{
        .name = app.config.admin_user,
        .via = .basic,
        .must_change = must_change,
    };
}

fn sessionPrincipal(
    app: *App,
    arena: Allocator,
    request: *const Request,
    must_change: bool,
) Allocator.Error!?Principal {
    const token = request.cookieValue(session_cookie) orelse return null;
    const user = try app.sessions.userOf(arena, token) orelse return null;
    return .{ .name = user, .via = .session, .must_change = must_change };
}

/// Browser-originated state changes need the CSRF header; Basic auth
/// requests are exempt because browsers never send our Basic
/// credentials on their own (we never send WWW-Authenticate).
pub fn checkCsrf(app: *App, request: *const Request) Error!void {
    if (app.config.dev_mode) return;
    if (!request.isMutating()) return;
    if (request.authorization != null) return;
    const value = request.requested_with orelse return error.Forbidden;
    if (!std.mem.eql(u8, value, csrf_header_value)) return error.Forbidden;
}

/// Verifies admin credentials, rate limited per client IP.
pub fn checkCredentials(
    app: *App,
    peer: std.Io.net.IpAddress,
    user: []const u8,
    pass: []const u8,
) Error!void {
    const key = client_key.of(peer);
    if (app.limiter.isLocked(key)) return error.TooManyAttempts;
    if (app.credentials.verify(user, pass)) {
        app.limiter.recordSuccess(key);
        return;
    }
    app.limiter.recordFailure(key);
    return error.Unauthorized;
}

const Credentials = struct {
    user: []const u8,
    pass: []const u8,
};

/// Decodes `Authorization: Basic ...` into `storage`.
fn basicCredentials(
    request: *const Request,
    storage: *[512]u8,
) ?Credentials {
    const header = request.authorization orelse return null;
    const prefix = "Basic ";
    if (!std.ascii.startsWithIgnoreCase(header, prefix)) return null;
    const encoded = std.mem.trim(u8, header[prefix.len..], " ");

    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(encoded) catch return null;
    if (len > storage.len) return null;
    decoder.decode(storage[0..len], encoded) catch return null;

    const decoded = storage[0..len];
    const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return null;
    return .{ .user = decoded[0..colon], .pass = decoded[colon + 1 ..] };
}

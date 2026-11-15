//! Decides whether a request may reach an admin route.
//!
//! Two ways in: a session cookie (web UI) or HTTP Basic credentials
//! (scripts, curl). Dev mode lets everything through.

const std = @import("std");

const App = @import("../App.zig");
const Request = @import("../http/Request.zig");
const client_key = @import("../http/client_key.zig");
const password = @import("password.zig");

pub const session_cookie = "zv_session";

/// Mutating cookie-authenticated requests must carry this header.
/// Browsers cannot add it cross-site without a CORS preflight, which
/// we never grant, so it blocks CSRF.
pub const csrf_header_value = "zerverg";

pub const Error = error{ Unauthorized, Forbidden, TooManyAttempts };

pub fn authorize(app: *App, request: *const Request) Error!void {
    if (app.config.dev_mode) return;
    if (request.cookieValue(session_cookie)) |token| {
        if (app.sessions.isValid(token)) return;
    }
    var storage: [256]u8 = undefined;
    if (basicCredentials(request, &storage)) |creds| {
        return checkCredentials(app, request.peer, creds.user, creds.pass);
    }
    return error.Unauthorized;
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
    const user_ok = password.constantTimeEql(user, app.config.admin_user);
    // Always verify, so timing does not reveal whether the user exists.
    const pass_ok = password.verify(
        app.gpa,
        app.io,
        app.config.admin_password_hash,
        pass,
    );
    if (user_ok and pass_ok) {
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
    storage: *[256]u8,
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

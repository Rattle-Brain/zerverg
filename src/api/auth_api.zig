//! Login / logout for the web UI.
//!
//!   POST /api/v1/auth/login     {"username": "...", "password": "..."}
//!   POST /api/v1/auth/logout
//!   GET  /api/v1/auth/session   {"authenticated": bool, "dev_mode": bool}

const std = @import("std");

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const guard = @import("../auth/guard.zig");
const common = @import("common.zig");

const LoginBody = struct {
    username: []const u8,
    password: []const u8,
};

pub fn login(ctx: *Context) !Response {
    const app = ctx.app;
    const body = try common.parseJsonBody(LoginBody, ctx);
    try guard.checkCredentials(
        app,
        ctx.request.peer,
        body.username,
        body.password,
    );
    const token = try app.sessions.create();
    var response = try Response.json(ctx.arena, .ok, .{ .ok = true });
    response.set_cookie = try std.fmt.allocPrint(
        ctx.arena,
        "{s}={s}; Path=/api; HttpOnly; SameSite=Strict; Max-Age={d}{s}",
        .{
            guard.session_cookie,
            &token,
            app.config.session_ttl_s,
            if (app.config.https) "; Secure" else "",
        },
    );
    return response;
}

pub fn logout(ctx: *Context) !Response {
    if (ctx.request.cookieValue(guard.session_cookie)) |token| {
        ctx.app.sessions.destroy(token);
    }
    var response = Response.noContent();
    response.set_cookie = guard.session_cookie ++
        "=; Path=/api; HttpOnly; SameSite=Strict; Max-Age=0";
    return response;
}

pub fn session(ctx: *Context) !Response {
    const authenticated = if (guard.authorize(ctx.app, ctx.request)) |_|
        true
    else |_|
        false;
    return Response.json(ctx.arena, .ok, .{
        .authenticated = authenticated,
        .dev_mode = ctx.app.config.dev_mode,
    });
}

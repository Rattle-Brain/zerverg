//! "Sign in with ..." endpoints, on the console port only.
//!
//!   GET /api/v1/auth/oauth/:provider/start     -> 303 to the provider
//!   GET /api/v1/auth/oauth/:provider/callback  <- the provider's 303
//!
//! Failures never reveal details to the browser (they are logged);
//! the console just shows "sign-in failed".

const std = @import("std");

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const auth_api = @import("auth_api.zig");
const client_key = @import("../http/client_key.zig");
const OAuth = @import("../auth/oauth/OAuth.zig");

/// Binds a login attempt to the browser that started it. `Lax`, not
/// `Strict`: it must survive the top-level redirect back from the
/// provider, which is a cross-site navigation.
const state_cookie = "zv_oauth_state";
const state_cookie_path = "/api/v1/auth/oauth";

pub fn start(ctx: *Context) !Response {
    const oauth = ctx.app.oauth orelse return error.NotFound;
    const name = ctx.request.param("provider");
    const begun = oauth.start(ctx.arena, name) catch |err| switch (err) {
        error.UnknownProvider => return error.NotFound,
        else => {
            std.log.warn("oauth: cannot start login: {t}", .{err});
            return failed();
        },
    };
    var response = Response.redirect(begun.url);
    response.set_cookies = try auth_api.cookies(ctx, &.{
        try stateCookie(ctx, &begun.state, 600),
    });
    return response;
}

pub fn callback(ctx: *Context) !Response {
    const app = ctx.app;
    const request = ctx.request;
    const key = client_key.of(request.peer);
    if (app.limiter.isLocked(key)) return failed();
    const provider = request.param("provider");
    const identity = complete(ctx, provider) catch |err| {
        std.log.warn("oauth: {s} login refused: {t}", .{ provider, err });
        if (err == error.NotFound) return error.NotFound;
        if (err == error.UserNotAllowed) app.limiter.recordFailure(key);
        return failed();
    };

    const user = identity.displayName();
    std.log.info("audit: {f} {s} signed in via {s}", .{
        request.peer, user, provider,
    });
    var response = Response.redirect("/");
    response.set_cookies = try auth_api.cookies(ctx, &.{
        try auth_api.newSessionCookie(ctx, user),
        try stateCookie(ctx, "", 0),
    });
    return response;
}

/// Checks the provider's answer and returns who signed in.
fn complete(ctx: *Context, provider: []const u8) !OAuth.Identity {
    const oauth = ctx.app.oauth orelse return error.NotFound;
    const request = ctx.request;
    const arena = ctx.arena;
    const code = try request.decodedQueryParam(arena, "code") orelse "";
    const state = try request.decodedQueryParam(arena, "state") orelse "";
    const cookie = request.cookieValue(state_cookie) orelse "";
    return oauth.finish(arena, provider, code, state, cookie);
}

fn failed() Response {
    return Response.redirect("/#/login?error=signin-failed");
}

fn stateCookie(ctx: *Context, value: []const u8, max_age: u32) ![]const u8 {
    return std.fmt.allocPrint(
        ctx.arena,
        "{s}={s}; Path={s}; HttpOnly; SameSite=Lax; Max-Age={d}{s}",
        .{
            state_cookie,
            value,
            state_cookie_path,
            max_age,
            if (ctx.app.config.https) "; Secure" else "",
        },
    );
}

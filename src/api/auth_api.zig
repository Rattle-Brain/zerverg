//! Console login, logout, session status and password change.
//! Served on the admin surface only.
//!
//!   POST /api/v1/auth/login     {"username", "password"}
//!   POST /api/v1/auth/logout
//!   GET  /api/v1/auth/session   who am I, and what may I do
//!   POST /api/v1/auth/password  {"current_password", "new_password"}

const std = @import("std");

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const guard = @import("../auth/guard.zig");
const common = @import("common.zig");
const config = @import("../config.zig");

const LoginBody = struct {
    username: []const u8,
    password: []const u8,
};

const PasswordBody = struct {
    current_password: []const u8,
    new_password: []const u8,
};

pub fn login(ctx: *Context) !Response {
    const app = ctx.app;
    if (app.config.auth_method != .password) {
        return error.PasswordLoginDisabled;
    }
    const body = try common.parseJsonBody(LoginBody, ctx);
    try guard.checkCredentials(
        app,
        ctx.request.peer,
        body.username,
        body.password,
    );
    var response = try Response.json(ctx.arena, .ok, .{
        .ok = true,
        .must_change_password = app.credentials.mustChange(),
    });
    response.set_cookies = try cookies(ctx, &.{
        try newSessionCookie(ctx, app.config.admin_user),
    });
    return response;
}

pub fn logout(ctx: *Context) !Response {
    if (ctx.request.cookieValue(guard.session_cookie)) |token| {
        ctx.app.sessions.destroy(token);
    }
    var response = Response.noContent();
    response.set_cookies = &.{guard.session_cookie ++
        "=; Path=/api; HttpOnly; SameSite=Strict; Max-Age=0"};
    return response;
}

pub fn session(ctx: *Context) !Response {
    const app = ctx.app;
    const principal = guard.authorize(
        app,
        ctx.arena,
        ctx.request,
        ctx.surface,
    ) catch null;
    const source = app.credentials.currentSource();
    return Response.json(ctx.arena, .ok, .{
        .authenticated = principal != null,
        .user = if (principal) |p| p.name else "",
        .must_change_password = if (principal) |p| p.must_change else false,
        .auth_method = @tagName(app.config.auth_method),
        .password_source = @tagName(source),
        .dev_mode = app.config.dev_mode,
        .public_port = if (app.config.tls)
            app.config.https_port
        else
            app.config.http_port,
        .providers = try providerList(ctx),
    });
}

const ProviderButton = struct { name: []const u8, label: []const u8 };

/// The "sign in with ..." buttons for the console login page.
fn providerList(ctx: *Context) ![]const ProviderButton {
    const app = ctx.app;
    if (app.config.auth_method != .oauth) return &.{};
    const list = try ctx.arena.alloc(
        ProviderButton,
        app.config.oauth_providers.len,
    );
    for (app.config.oauth_providers, list) |p, *button| {
        button.* = .{
            .name = p.name,
            .label = if (p.label.len > 0) p.label else defaultLabel(p),
        };
    }
    return list;
}

fn defaultLabel(p: config.OAuthProvider) []const u8 {
    return switch (p.kind) {
        .google => "Google",
        .github => "GitHub",
        .oidc => p.name,
    };
}

/// Changes the console-managed password. Everyone else is logged out;
/// the caller gets a fresh session.
pub fn changePassword(ctx: *Context) !Response {
    const app = ctx.app;
    if (app.config.auth_method != .password) {
        return error.PasswordLoginDisabled;
    }
    const body = try common.parseJsonBody(PasswordBody, ctx);
    try guard.checkCredentials(
        app,
        ctx.request.peer,
        app.config.admin_user,
        body.current_password,
    );
    try app.credentials.change(body.new_password);
    app.sessions.destroyAll();
    std.log.info("admin password changed", .{});

    var response = try Response.json(ctx.arena, .ok, .{ .ok = true });
    const via = if (ctx.principal) |p| p.via else .basic;
    if (via == .session) response.set_cookies = try cookies(ctx, &.{
        try newSessionCookie(ctx, app.config.admin_user),
    });
    return response;
}

pub fn cookies(
    ctx: *Context,
    values: []const []const u8,
) ![]const []const u8 {
    return ctx.arena.dupe([]const u8, values);
}

/// Starts a console session for `user`; returns its Set-Cookie value.
pub fn newSessionCookie(ctx: *Context, user: []const u8) ![]const u8 {
    const app = ctx.app;
    const token = try app.sessions.create(user);
    return std.fmt.allocPrint(
        ctx.arena,
        "{s}={s}; Path=/api; HttpOnly; SameSite=Strict; Max-Age={d}{s}",
        .{
            guard.session_cookie,
            &token,
            app.config.session_ttl_s,
            if (app.config.https) "; Secure" else "",
        },
    );
}

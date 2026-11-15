//! The route tables and request dispatch: routing, access control,
//! CSRF checks and error mapping all happen here, nowhere else.
//!
//! Two tables, one per listener: the public site (with a Basic-auth
//! API for scripts) and the admin console (with the full API).

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Context = @import("Context.zig");
const Request = @import("http/Request.zig");
const Response = @import("http/Response.zig");
const router = @import("http/router.zig");
const errors = @import("http/errors.zig");
const Config = @import("config.zig").Config;
const guard = @import("auth/guard.zig");
const library = @import("store/library.zig");

const auth_api = @import("api/auth_api.zig");
const oauth_api = @import("api/oauth_api.zig");
const posts_api = @import("api/posts_api.zig");
const themes_api = @import("api/themes_api.zig");
const media_api = @import("api/media_api.zig");
const site_api = @import("api/site_api.zig");
const library_api = @import("api/library_api.zig");
const site = @import("site/handlers.zig");
const console = @import("console/handlers.zig");

const Route = router.Route(Context.Handler);
const BodyLimit = router.BodyLimit;

/// JSON bodies (login, site settings).
const small_body_bytes = 16 * 1024;

const shared_api_routes = api_routes ++
    libraryRoutes(.layouts) ++
    libraryRoutes(.styles) ++
    libraryRoutes(.snippets);

const public_table = shared_api_routes ++ public_routes;
const admin_table = auth_routes ++ shared_api_routes ++ console_routes;

/// Admin surface only. Reachable before the factory password is
/// changed, so the console can force that change.
const auth_routes = [_]Route{
    early(route(.public, .POST, "/api/v1/auth/login", auth_api.login, .small)),
    early(admin(.POST, "/api/v1/auth/logout", auth_api.logout)),
    early(public(.GET, "/api/v1/auth/session", auth_api.session)),
    early(route(
        .admin,
        .POST,
        "/api/v1/auth/password",
        auth_api.changePassword,
        .small,
    )),
    early(public(.GET, "/api/v1/auth/oauth/:provider/start", oauth_api.start)),
    early(public(
        .GET,
        "/api/v1/auth/oauth/:provider/callback",
        oauth_api.callback,
    )),
};

const api_routes = [_]Route{
    admin(.GET, "/api/v1/posts", posts_api.list),
    route(.admin, .POST, "/api/v1/posts", posts_api.create, .text),
    admin(.GET, "/api/v1/posts/:slug", posts_api.get),
    route(.admin, .PUT, "/api/v1/posts/:slug", posts_api.put, .text),
    admin(.DELETE, "/api/v1/posts/:slug", posts_api.remove),
    quiet(route(.admin, .POST, "/api/v1/preview", posts_api.preview, .text)),
    admin(.GET, "/api/v1/themes/:name/preview", themes_api.preview),

    admin(.GET, "/api/v1/media", media_api.list),
    route(.admin, .PUT, "/api/v1/media/:name", media_api.put, .media),
    admin(.DELETE, "/api/v1/media/:name", media_api.remove),

    admin(.GET, "/api/v1/site", site_api.get),
    route(.admin, .PUT, "/api/v1/site", site_api.put, .small),
};

/// The console shell is static and holds no data; everything it shows
/// comes from the authenticated API.
/// The active stylesheet and media are served here too, so previews
/// look like the site.
const console_routes = [_]Route{
    public(.GET, "/", console.index),
    public(.GET, "/console/:file", console.asset),
    public(.GET, "/assets/style.css", site.style),
    public(.GET, "/media/:name", site.mediaFile),
};

/// Order matters: `/:slug` must stay last.
const public_routes = [_]Route{
    public(.GET, "/", site.index),
    public(.GET, "/assets/style.css", site.style),
    public(.GET, "/assets/snippets/:file", site.snippet),
    public(.GET, "/media/:name", site.mediaFile),
    public(.GET, "/search", site.search),
    public(.GET, "/:slug", site.entry),
};

fn libraryRoutes(comptime kind: library.Kind) [6]Route {
    const H = library_api.Handlers(kind);
    const base = "/api/v1/" ++ @tagName(kind);
    return .{
        admin(.GET, base, H.list),
        admin(.GET, base ++ "/:name", H.get),
        route(.admin, .PUT, base ++ "/:name", H.put, .text),
        admin(.DELETE, base ++ "/:name", H.remove),
        admin(.GET, base ++ "/:name/versions", H.versions),
        admin(.POST, base ++ "/:name/rollback", H.rollback),
    };
}

fn route(
    access: router.Access,
    method: std.http.Method,
    pattern: []const u8,
    handler: Context.Handler,
    body: BodyLimit,
) Route {
    return .{
        .method = method,
        .pattern = pattern,
        .access = access,
        .handler = handler,
        .body = body,
    };
}

fn quiet(r: Route) Route {
    var copy = r;
    copy.audit = false;
    return copy;
}

fn early(r: Route) Route {
    var copy = r;
    copy.before_password_change = true;
    return copy;
}

fn public(
    method: std.http.Method,
    pattern: []const u8,
    handler: Context.Handler,
) Route {
    return route(.public, method, pattern, handler, .none);
}

fn admin(
    method: std.http.Method,
    pattern: []const u8,
    handler: Context.Handler,
) Route {
    return route(.admin, method, pattern, handler, .none);
}

pub fn dispatch(
    app: *App,
    arena: Allocator,
    request: *Request,
    surface: guard.Surface,
) Response {
    const table: []const Route = switch (surface) {
        .public => &public_table,
        .admin => &admin_table,
    };
    const found, const result = router.find(Route, table, request);
    var ctx: Context = .{
        .app = app,
        .request = request,
        .arena = arena,
        .surface = surface,
    };
    const response = switch (result) {
        .not_found => errors.toResponse(arena, error.NotFound),
        .wrong_method => errors.toResponse(arena, error.MethodNotAllowed),
        .matched => invoke(&ctx, found.?) catch |err|
            errors.toResponse(arena, err),
    };
    if (result == .matched and found.?.access == .admin and
        found.?.audit and request.isMutating())
    {
        audit(&ctx, response);
    }
    return response;
}

/// Order matters: authorise first, only then read the body.
fn invoke(ctx: *Context, found: *const Route) !Response {
    const app = ctx.app;
    try guard.checkCsrf(app, ctx.request);
    if (found.access == .admin) {
        const principal = try guard.authorize(
            app,
            ctx.arena,
            ctx.request,
            ctx.surface,
        );
        if (principal.must_change and !found.before_password_change) {
            return error.PasswordChangeRequired;
        }
        ctx.principal = principal;
    }
    if (found.body != .none) {
        const limit = bodyLimit(&app.config, found.body);
        try ctx.request.readBody(ctx.arena, limit);
    }
    return found.handler(ctx);
}

fn bodyLimit(config: *const Config, limit: BodyLimit) usize {
    const bytes: usize = switch (limit) {
        .none => 0,
        .small => small_body_bytes,
        .text => config.max_text_upload_bytes,
        .media => @max(config.max_image_bytes, config.max_video_bytes),
    };
    return @min(bytes, config.max_body_bytes);
}

/// One line per admin change, for the operator's records.
fn audit(ctx: *const Context, response: Response) void {
    const user = if (ctx.principal) |p| p.name else "-";
    std.log.info("audit: {f} {s} {t} {s} -> {d}", .{
        ctx.request.peer,
        user,
        ctx.request.method,
        ctx.request.path,
        @intFromEnum(response.status),
    });
}

//! The route table and request dispatch: routing, access control,
//! CSRF checks and error mapping all happen here, nowhere else.

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
const posts_api = @import("api/posts_api.zig");
const media_api = @import("api/media_api.zig");
const site_api = @import("api/site_api.zig");
const library_api = @import("api/library_api.zig");
const site = @import("site/handlers.zig");

const Route = router.Route(Context.Handler);
const BodyLimit = router.BodyLimit;

/// JSON bodies (login, site settings).
const small_body_bytes = 16 * 1024;

const routes = api_routes ++
    libraryRoutes(.layouts) ++
    libraryRoutes(.styles) ++
    libraryRoutes(.snippets) ++
    public_routes;

const api_routes = [_]Route{
    route(.public, .POST, "/api/v1/auth/login", auth_api.login, .small),
    admin(.POST, "/api/v1/auth/logout", auth_api.logout),
    public(.GET, "/api/v1/auth/session", auth_api.session),

    admin(.GET, "/api/v1/posts", posts_api.list),
    route(.admin, .POST, "/api/v1/posts", posts_api.create, .text),
    admin(.GET, "/api/v1/posts/:slug", posts_api.get),
    route(.admin, .PUT, "/api/v1/posts/:slug", posts_api.put, .text),
    admin(.DELETE, "/api/v1/posts/:slug", posts_api.remove),

    admin(.GET, "/api/v1/media", media_api.list),
    route(.admin, .PUT, "/api/v1/media/:name", media_api.put, .media),
    admin(.DELETE, "/api/v1/media/:name", media_api.remove),

    admin(.GET, "/api/v1/site", site_api.get),
    route(.admin, .PUT, "/api/v1/site", site_api.put, .small),
};

/// Order matters: `/:slug` must stay last.
const public_routes = [_]Route{
    public(.GET, "/", site.index),
    public(.GET, "/admin", site.adminPlaceholder),
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

pub fn dispatch(app: *App, arena: Allocator, request: *Request) Response {
    const found, const result = router.find(Route, &routes, request);
    const response = switch (result) {
        .not_found => errors.toResponse(arena, error.NotFound),
        .wrong_method => errors.toResponse(arena, error.MethodNotAllowed),
        .matched => invoke(app, arena, request, found.?) catch |err|
            errors.toResponse(arena, err),
    };
    if (result == .matched and found.?.access == .admin and
        request.isMutating())
    {
        audit(request, response);
    }
    return response;
}

/// Order matters: authorise first, only then read the body.
fn invoke(
    app: *App,
    arena: Allocator,
    request: *Request,
    found: *const Route,
) !Response {
    try guard.checkCsrf(app, request);
    if (found.access == .admin) try guard.authorize(app, request);
    if (found.body != .none) {
        try request.readBody(arena, bodyLimit(&app.config, found.body));
    }
    var ctx: Context = .{ .app = app, .request = request, .arena = arena };
    return found.handler(&ctx);
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
fn audit(request: *const Request, response: Response) void {
    std.log.info("audit: {f} {t} {s} -> {d}", .{
        request.peer,
        request.method,
        request.path,
        @intFromEnum(response.status),
    });
}

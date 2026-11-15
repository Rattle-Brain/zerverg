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
const guard = @import("auth/guard.zig");
const library = @import("store/library.zig");

const auth_api = @import("api/auth_api.zig");
const posts_api = @import("api/posts_api.zig");
const media_api = @import("api/media_api.zig");
const site_api = @import("api/site_api.zig");
const library_api = @import("api/library_api.zig");
const site = @import("site/handlers.zig");

const Route = router.Route(Context.Handler);

/// Applied to every /api and /admin response.
const admin_csp = "default-src 'self'; frame-ancestors 'none'";

const routes = api_routes ++
    libraryRoutes(.layouts) ++
    libraryRoutes(.styles) ++
    libraryRoutes(.snippets) ++
    public_routes;

const api_routes = [_]Route{
    public(.POST, "/api/v1/auth/login", auth_api.login),
    admin(.POST, "/api/v1/auth/logout", auth_api.logout),
    public(.GET, "/api/v1/auth/session", auth_api.session),

    admin(.GET, "/api/v1/posts", posts_api.list),
    admin(.POST, "/api/v1/posts", posts_api.create),
    admin(.GET, "/api/v1/posts/:slug", posts_api.get),
    admin(.PUT, "/api/v1/posts/:slug", posts_api.put),
    admin(.DELETE, "/api/v1/posts/:slug", posts_api.remove),

    admin(.GET, "/api/v1/media", media_api.list),
    admin(.PUT, "/api/v1/media/:name", media_api.put),
    admin(.DELETE, "/api/v1/media/:name", media_api.remove),

    admin(.GET, "/api/v1/site", site_api.get),
    admin(.PUT, "/api/v1/site", site_api.put),
};

/// Order matters: `/:slug` must stay last.
const public_routes = [_]Route{
    public(.GET, "/", site.index),
    public(.GET, "/admin", site.adminPlaceholder),
    public(.GET, "/assets/style.css", site.style),
    public(.GET, "/assets/snippets/:file", site.snippet),
    public(.GET, "/media/:name", site.mediaFile),
    public(.GET, "/:slug", site.entry),
};

fn libraryRoutes(comptime kind: library.Kind) [6]Route {
    const H = library_api.Handlers(kind);
    const base = "/api/v1/" ++ @tagName(kind);
    return .{
        admin(.GET, base, H.list),
        admin(.GET, base ++ "/:name", H.get),
        admin(.PUT, base ++ "/:name", H.put),
        admin(.DELETE, base ++ "/:name", H.remove),
        admin(.GET, base ++ "/:name/versions", H.versions),
        admin(.POST, base ++ "/:name/rollback", H.rollback),
    };
}

fn public(
    method: std.http.Method,
    pattern: []const u8,
    handler: Context.Handler,
) Route {
    return .{
        .method = method,
        .pattern = pattern,
        .access = .public,
        .handler = handler,
    };
}

fn admin(
    method: std.http.Method,
    pattern: []const u8,
    handler: Context.Handler,
) Route {
    return .{
        .method = method,
        .pattern = pattern,
        .access = .admin,
        .handler = handler,
    };
}

pub fn dispatch(app: *App, arena: Allocator, request: *Request) Response {
    var response = route(app, arena, request) catch |err|
        errors.toResponse(arena, err);
    if (isAdminPath(request.path) and response.csp == null) {
        response.csp = admin_csp;
    }
    return response;
}

fn route(app: *App, arena: Allocator, request: *Request) !Response {
    const found, const result = router.find(Route, &routes, request);
    switch (result) {
        .not_found => return error.NotFound,
        .wrong_method => return error.MethodNotAllowed,
        .matched => {},
    }
    try guard.checkCsrf(app, request);
    if (found.?.access == .admin) try guard.authorize(app, request);
    var ctx: Context = .{ .app = app, .request = request, .arena = arena };
    return found.?.handler(&ctx);
}

fn isAdminPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/") or
        std.mem.eql(u8, path, "/admin") or
        std.mem.startsWith(u8, path, "/admin/");
}

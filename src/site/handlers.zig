//! Public, unauthenticated routes: the rendered site and its assets.

const std = @import("std");

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const posts = @import("../store/posts.zig");
const media = @import("../store/media.zig");
const library = @import("../store/library.zig");
const site_state = @import("../store/site_state.zig");
const meta = @import("../content/meta.zig");
const render = @import("render.zig");

const media_cache = "public, max-age=3600";

pub fn index(ctx: *Context) !Response {
    const state = try site_state.read(ctx.app.store, ctx.arena);
    const entries = try posts.list(ctx.app.store, ctx.arena);
    const body = try render.shell(ctx.arena, .{
        .site = state,
        .title = "",
        .main_html = try render.entryList(ctx.arena, entries),
    });
    return Response.html(body);
}

pub fn entry(ctx: *Context) !Response {
    const store = ctx.app.store;
    const html = try posts.read(store, ctx.arena, ctx.request.param("slug"));
    const entry_meta = try meta.extract(html);
    const body = try render.shell(ctx.arena, .{
        .site = try site_state.read(store, ctx.arena),
        .title = entry_meta.title,
        .main_html = meta.bodyOf(html),
    });
    return Response.html(body);
}

pub fn style(ctx: *Context) !Response {
    const state = try site_state.read(ctx.app.store, ctx.arena);
    const name = state.active_style orelse return error.NotFound;
    const css = try library.read(ctx.app.store, ctx.arena, .styles, name, null);
    return .{
        .content_type = library.Kind.styles.contentType(),
        .body = css,
        .cache_control = "no-cache",
    };
}

/// Serves `/assets/snippets/<name>.js`, only for enabled snippets.
pub fn snippet(ctx: *Context) !Response {
    const file = ctx.request.param("file");
    if (!std.mem.endsWith(u8, file, ".js")) return error.NotFound;
    const name = file[0 .. file.len - ".js".len];

    const state = try site_state.read(ctx.app.store, ctx.arena);
    if (!contains(state.enabled_snippets, name)) return error.NotFound;
    const store = ctx.app.store;
    const js = try library.read(store, ctx.arena, .snippets, name, null);
    return .{
        .content_type = library.Kind.snippets.contentType(),
        .body = js,
        .cache_control = "no-cache",
    };
}

pub fn mediaFile(ctx: *Context) !Response {
    const name = ctx.request.param("name");
    const file = try media.read(ctx.app.store, ctx.arena, name);
    return .{
        .content_type = file.content_type,
        .body = file.data,
        .cache_control = media_cache,
        // Neutralises scripts embedded in SVGs opened directly.
        .csp = "sandbox; default-src 'none'; style-src 'unsafe-inline'",
    };
}

/// Placeholder until the admin UI milestone lands.
pub fn adminPlaceholder(_: *Context) !Response {
    var response = Response.html(
        \\<!doctype html><html><head><title>zerverg admin</title></head>
        \\<body><h1>zerverg admin</h1>
        \\<p>The web UI arrives in the next milestone. The REST API is
        \\live under <code>/api/v1</code>.</p></body></html>
    );
    response.csp = "default-src 'none'; frame-ancestors 'none'";
    return response;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

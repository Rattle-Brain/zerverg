//! Public, unauthenticated routes: the rendered site and its assets.

const std = @import("std");

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const media = @import("../store/media.zig");
const library = @import("../store/library.zig");
const site_state = @import("../store/site_state.zig");
const pages = @import("pages.zig");

const media_cache = "public, max-age=3600";

pub fn index(ctx: *Context) !Response {
    return pages.home(ctx);
}

pub fn entry(ctx: *Context) !Response {
    return pages.entry(ctx, ctx.request.param("slug")) catch |err|
        switch (err) {
            // Not a valid slug, so certainly not a page.
            error.InvalidName => error.NotFound,
            else => err,
        };
}

/// `/search?q=...`; the query is capped at 100 bytes.
pub fn search(ctx: *Context) !Response {
    const raw = try ctx.request.decodedQueryParam(ctx.arena, "q") orelse "";
    const query = std.mem.trim(u8, raw, " ");
    if (query.len > 100) return error.BadRequest;
    return pages.search(ctx, query);
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

/// Streams a media file; never loaded into memory whole.
pub fn mediaFile(ctx: *Context) !Response {
    const opened = try media.open(ctx.app.store, ctx.request.param("name"));
    return .{
        .content_type = opened.content_type,
        .file = opened.file,
        .file_size = opened.size,
        .cache_control = media_cache,
        // Neutralises scripts embedded in SVGs opened directly.
        .csp = "sandbox; default-src 'none'; style-src 'unsafe-inline'",
    };
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

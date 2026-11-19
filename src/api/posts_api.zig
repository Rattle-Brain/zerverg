//! REST handlers for posts, pages and their drafts. Entries are HTML
//! or Markdown; uploads pick the format with `?format=html|md`, a
//! `text/markdown` Content-Type, or a leading `---` front matter
//! block. One generic set of handlers, instantiated per shelf.
//!
//!   GET    /api/v1/<shelf>          list with metadata
//!   GET    /api/v1/<shelf>/:slug    raw source
//!   PUT    /api/v1/<shelf>/:slug    create or replace
//!   DELETE /api/v1/<shelf>/:slug
//!   POST   /api/v1/posts            create; slug from the entry itself
//!   POST   /api/v1/drafts/:slug/publish   replace the live entry
//!   POST   /api/v1/entries/:slug/rename?to=<slug>
//!   POST   /api/v1/preview          render a draft with the site layout
//!
//! `<shelf>` is `posts` (published) or `drafts` (never served). A
//! rename moves the whole entry: both shelves and its media.

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const posts = @import("../store/posts.zig");
const entries = @import("../store/entries.zig");
const entry = @import("../content/entry.zig");
const validate = @import("../content/validate.zig");
const pages = @import("../site/pages.zig");

pub fn Handlers(comptime shelf: posts.Shelf) type {
    return struct {
        pub fn list(ctx: *Context) !Response {
            const store = ctx.app.store;
            const summaries = try posts.list(store, ctx.arena, shelf);
            return Response.json(ctx.arena, .ok, summaries);
        }

        pub fn get(ctx: *Context) !Response {
            const slug = ctx.request.param("slug");
            const store = ctx.app.store;
            const source = try posts.read(store, ctx.arena, shelf, slug);
            return .{
                .content_type = source.format.contentType(),
                .body = source.text,
            };
        }

        pub fn put(ctx: *Context) !Response {
            const slug = ctx.request.param("slug");
            const source = try uploadedSource(ctx);
            const summary = try posts.put(ctx.app.store, shelf, slug, source);
            return Response.json(ctx.arena, .ok, summary);
        }

        pub fn remove(ctx: *Context) !Response {
            const slug = ctx.request.param("slug");
            try posts.remove(ctx.app.store, shelf, slug);
            return Response.noContent();
        }
    };
}

pub fn create(ctx: *Context) !Response {
    const source = try uploadedSource(ctx);
    const summary = try posts.put(ctx.app.store, .posts, null, source);
    return Response.json(ctx.arena, .created, summary);
}

/// Moves the stored draft over the live entry.
pub fn publish(ctx: *Context) !Response {
    const slug = ctx.request.param("slug");
    const format = try posts.publish(ctx.app.store, slug);
    const result = .{ .slug = slug, .format = format };
    return Response.json(ctx.arena, .ok, result);
}

/// Moves the entry to a new address, with its draft, its media and
/// every reference to that media. Answers once all of it is done.
pub fn rename(ctx: *Context) !Response {
    const from = ctx.request.param("slug");
    // Slugs never need decoding; anything encoded fails validation.
    const to = ctx.request.queryParam("to") orelse return error.BadRequest;
    try entries.rename(ctx.app.store, ctx.arena, from, to);
    const result = .{ .slug = to, .from = from };
    return Response.json(ctx.arena, .ok, result);
}

/// The full page `pages` would serve for this source; nothing is
/// stored. The console shows it in a sandboxed frame.
pub fn preview(ctx: *Context) !Response {
    const source = try uploadedSource(ctx);
    var response = try pages.preview(ctx, source);
    response.cache_control = "no-store";
    return response;
}

fn uploadedSource(ctx: *Context) !entry.Source {
    const request = ctx.request;
    try validate.text(request.body);
    const format = try entry.detect(
        request.queryParam("format"),
        request.content_type,
        request.body,
    );
    return .{ .text = request.body, .format = format };
}

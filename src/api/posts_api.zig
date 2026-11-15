//! REST handlers for posts and pages. Entries are HTML or Markdown;
//! uploads pick the format with `?format=html|md`, a `text/markdown`
//! Content-Type, or a leading `---` front matter block.
//!
//!   GET    /api/v1/posts          list with metadata
//!   POST   /api/v1/posts          create; slug from the entry itself
//!   GET    /api/v1/posts/:slug    raw source
//!   PUT    /api/v1/posts/:slug    create or replace
//!   DELETE /api/v1/posts/:slug
//!   POST   /api/v1/preview        render a draft with the site layout

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const posts = @import("../store/posts.zig");
const entry = @import("../content/entry.zig");
const validate = @import("../content/validate.zig");
const pages = @import("../site/pages.zig");

pub fn list(ctx: *Context) !Response {
    const summaries = try posts.list(ctx.app.store, ctx.arena);
    return Response.json(ctx.arena, .ok, summaries);
}

pub fn get(ctx: *Context) !Response {
    const slug = ctx.request.param("slug");
    const source = try posts.read(ctx.app.store, ctx.arena, slug);
    return .{
        .content_type = source.format.contentType(),
        .body = source.text,
    };
}

pub fn create(ctx: *Context) !Response {
    const source = try uploadedSource(ctx);
    const summary = try posts.put(ctx.app.store, null, source);
    return Response.json(ctx.arena, .created, summary);
}

pub fn put(ctx: *Context) !Response {
    const slug = ctx.request.param("slug");
    const source = try uploadedSource(ctx);
    const summary = try posts.put(ctx.app.store, slug, source);
    return Response.json(ctx.arena, .ok, summary);
}

pub fn remove(ctx: *Context) !Response {
    try posts.remove(ctx.app.store, ctx.request.param("slug"));
    return Response.noContent();
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

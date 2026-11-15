//! REST handlers for posts and pages.
//!
//!   GET    /api/v1/posts          list with metadata
//!   POST   /api/v1/posts          create; slug from zerverg:slug meta
//!   GET    /api/v1/posts/:slug    raw HTML
//!   PUT    /api/v1/posts/:slug    create or replace
//!   DELETE /api/v1/posts/:slug

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const posts = @import("../store/posts.zig");

pub fn list(ctx: *Context) !Response {
    const summaries = try posts.list(ctx.app.store, ctx.arena);
    return Response.json(ctx.arena, .ok, summaries);
}

pub fn get(ctx: *Context) !Response {
    const slug = ctx.request.param("slug");
    const html = try posts.read(ctx.app.store, ctx.arena, slug);
    return .{ .content_type = "text/html; charset=utf-8", .body = html };
}

pub fn create(ctx: *Context) !Response {
    const summary = try posts.put(ctx.app.store, null, ctx.request.body);
    return Response.json(ctx.arena, .created, summary);
}

pub fn put(ctx: *Context) !Response {
    const slug = ctx.request.param("slug");
    const summary = try posts.put(ctx.app.store, slug, ctx.request.body);
    return Response.json(ctx.arena, .ok, summary);
}

pub fn remove(ctx: *Context) !Response {
    try posts.remove(ctx.app.store, ctx.request.param("slug"));
    return Response.noContent();
}

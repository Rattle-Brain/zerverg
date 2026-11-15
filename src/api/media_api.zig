//! REST handlers for media. Public reads go through `/media/:name`
//! (see site/handlers.zig); these are the admin operations.
//!
//!   GET    /api/v1/media          list with sizes
//!   PUT    /api/v1/media/:name    upload (size limits + quota)
//!   DELETE /api/v1/media/:name

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const media = @import("../store/media.zig");

pub fn list(ctx: *Context) !Response {
    const items = try media.list(ctx.app.store, ctx.arena);
    return Response.json(ctx.arena, .ok, items);
}

pub fn put(ctx: *Context) !Response {
    const name = ctx.request.param("name");
    try media.put(ctx.app.store, ctx.arena, name, ctx.request.body);
    return Response.json(ctx.arena, .created, .{
        .name = name,
        .size = ctx.request.body.len,
    });
}

pub fn remove(ctx: *Context) !Response {
    try media.remove(ctx.app.store, ctx.request.param("name"));
    return Response.noContent();
}

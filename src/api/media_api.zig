//! REST handlers for media. Public reads go through `/media/...`
//! (see site/handlers.zig); these are the admin operations.
//!
//!   GET    /api/v1/media                         list with sizes
//!   PUT    /api/v1/media/:name                   site-wide upload
//!   PUT    /api/v1/media/:folder/:slug/:name     an entry's own
//!   DELETE /api/v1/media/:name
//!   DELETE /api/v1/media/:folder/:slug/:name
//!   DELETE /api/v1/media/:folder/:slug           the whole folder
//!
//! `:folder` is `posts` or `pages`. Uploads check size limits and
//! the quota; an entry's folder is created on its first upload.

const Context = @import("../Context.zig");
const Request = @import("../http/Request.zig");
const Response = @import("../http/Response.zig");
const media = @import("../store/media.zig");
const validate = @import("../content/validate.zig");

pub fn list(ctx: *Context) !Response {
    const items = try media.list(ctx.app.store, ctx.arena);
    return Response.json(ctx.arena, .ok, items);
}

pub fn put(ctx: *Context) !Response {
    const place = try placeOf(ctx.request);
    const media_type = media.mediaTypeOf(place.name) orelse
        return error.UnsupportedMediaType;
    try validate.media(media_type, ctx.request.body);
    try media.put(ctx.app.store, ctx.arena, place, ctx.request.body);
    return Response.json(ctx.arena, .created, .{
        .path = try media.pathOf(ctx.arena, place),
        .name = place.name,
        .size = ctx.request.body.len,
    });
}

pub fn remove(ctx: *Context) !Response {
    try media.remove(ctx.app.store, try placeOf(ctx.request));
    return Response.noContent();
}

pub fn removeFolder(ctx: *Context) !Response {
    const request = ctx.request;
    const folder = try media.folderOf(
        request.param("folder"),
        request.param("slug"),
    );
    try media.removeFolder(ctx.app.store, folder);
    return Response.noContent();
}

fn placeOf(request: *const Request) !media.Place {
    return media.placeOf(
        request.optionalParam("folder"),
        request.optionalParam("slug"),
        request.param("name"),
    );
}

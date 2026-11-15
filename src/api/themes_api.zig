//! Theme previews. A theme is a layout and a stylesheet with the same
//! name (the starter themes ship that way). Switching themes is just
//! `PUT /api/v1/site` with both names.
//!
//!   GET /api/v1/themes/:name/preview[?page=<slug>]
//!     the home page (or <slug>) rendered with that layout and style,
//!     without changing the live site

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const library = @import("../store/library.zig");
const pages = @import("../site/pages.zig");

pub fn preview(ctx: *Context) !Response {
    const name = ctx.request.param("name");
    const store = ctx.app.store;
    // The layout must exist; a missing stylesheet previews unstyled.
    _ = try library.read(store, ctx.arena, .layouts, name, null);
    const css = library.read(store, ctx.arena, .styles, name, null) catch |err|
        switch (err) {
            error.NotFound => "",
            else => return err,
        };
    const page = ctx.request.queryParam("page");
    var response = try pages.themePreview(ctx, page, .{
        .layout = name,
        .css = css,
    });
    response.cache_control = "no-store";
    return response;
}

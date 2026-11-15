//! REST handlers for site-wide settings.
//!
//!   GET /api/v1/site    current settings
//!   PUT /api/v1/site    replace settings (JSON body)

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const site_state = @import("../store/site_state.zig");
const common = @import("common.zig");

pub fn get(ctx: *Context) !Response {
    const state = try site_state.read(ctx.app.store, ctx.arena);
    return Response.json(ctx.arena, .ok, state);
}

pub fn put(ctx: *Context) !Response {
    const state = try common.parseJsonBody(site_state.SiteState, ctx);
    try site_state.write(ctx.app.store, ctx.arena, state);
    return Response.json(ctx.arena, .ok, state);
}

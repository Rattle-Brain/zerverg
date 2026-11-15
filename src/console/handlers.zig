//! Serves the admin console: static files compiled into the binary.
//! The console is a plain client of the REST API; it has no
//! server-side logic of its own.

const std = @import("std");

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");

const index_html = @embedFile("index.html");

const Asset = struct {
    name: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const css = "text/css; charset=utf-8";
const js = "text/javascript; charset=utf-8";

const assets = [_]Asset{
    embed("console.css", css),
    embed("theme.js", js),
    embed("core.js", js),
    embed("views.js", js),
    embed("editor.js", js),
    embed("write.js", js),
    embed("themes.js", js),
};

fn embed(comptime name: []const u8, content_type: []const u8) Asset {
    return .{
        .name = name,
        .content_type = content_type,
        .body = @embedFile(name),
    };
}

/// The console's own policy. Previews render in a `srcdoc` frame that
/// inherits it, so it admits what site pages use (the theme's inline
/// styles, https images and fonts) but still no foreign scripts.
const console_csp = "default-src 'self'; script-src 'self'; " ++
    "style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; " ++
    "media-src 'self' https:; font-src 'self' data: https:; " ++
    "object-src 'none'; base-uri 'none'; form-action 'self'; " ++
    "frame-ancestors 'none'";

pub fn index(_: *Context) !Response {
    return .{
        .content_type = "text/html; charset=utf-8",
        .body = index_html,
        .cache_control = "no-cache",
        .csp = console_csp,
    };
}

/// `/console/<file>`
pub fn asset(ctx: *Context) !Response {
    const name = ctx.request.param("file");
    for (assets) |a| {
        if (!std.mem.eql(u8, a.name, name)) continue;
        return .{
            .content_type = a.content_type,
            .body = a.body,
            .cache_control = "no-cache",
        };
    }
    return error.NotFound;
}

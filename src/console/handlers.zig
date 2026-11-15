//! Serves the admin console: three static files compiled into the
//! binary. The console is a plain client of the REST API; it has no
//! server-side logic of its own.

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");

const index_html = @embedFile("index.html");
const console_css = @embedFile("console.css");
const console_js = @embedFile("console.js");

pub fn index(_: *Context) !Response {
    return .{
        .content_type = "text/html; charset=utf-8",
        .body = index_html,
        .cache_control = "no-cache",
    };
}

pub fn stylesheet(_: *Context) !Response {
    return .{
        .content_type = "text/css; charset=utf-8",
        .body = console_css,
        .cache_control = "no-cache",
    };
}

pub fn script(_: *Context) !Response {
    return .{
        .content_type = "text/javascript; charset=utf-8",
        .body = console_js,
        .cache_control = "no-cache",
    };
}

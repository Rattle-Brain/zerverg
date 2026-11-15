//! Per-request handler context. `arena` lives until the response has
//! been sent, so handlers may return slices allocated from it.

const std = @import("std");

const App = @import("App.zig");
const Request = @import("http/Request.zig");
const Response = @import("http/Response.zig");

pub const Handler = *const fn (ctx: *Context) anyerror!Response;

const Context = @This();

app: *App,
request: *Request,
arena: std.mem.Allocator,

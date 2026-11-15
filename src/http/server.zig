//! TCP listener and per-connection HTTP/1.1 loop.
//!
//! Each connection runs as its own concurrent task. A watchdog task
//! shuts the socket down after `connection_timeout_s`, which bounds
//! slow-client (slowloris) attacks and stuck keep-alive connections.

const std = @import("std");
const Io = std.Io;
const http = std.http;

const App = @import("../App.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const dispatch = @import("../routes.zig").dispatch;
const errors = @import("errors.zig");

const recv_buffer_len = 16 * 1024;
const send_buffer_len = 16 * 1024;

const Counter = std.atomic.Value(u32);

pub fn run(app: *App) !void {
    const io = app.io;
    const address = try Io.net.IpAddress.parse(
        app.config.listen_address,
        app.config.http_port,
    );
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("listening on http://{f}", .{address});

    var group: Io.Group = .init;
    defer group.cancel(io);
    var active: Counter = .init(0);
    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (err == error.Canceled) return;
            std.log.warn("accept: {t}", .{err});
            continue;
        };
        spawnConnection(app, &group, &active, stream);
    }
}

fn spawnConnection(
    app: *App,
    group: *Io.Group,
    active: *Counter,
    stream: Io.net.Stream,
) void {
    const io = app.io;
    if (active.load(.monotonic) >= app.config.max_connections) {
        stream.close(io);
        return;
    }
    _ = active.fetchAdd(1, .monotonic);
    group.concurrent(io, serveConnection, .{ app, stream, active }) catch {
        _ = active.fetchSub(1, .monotonic);
        stream.close(io);
    };
}

fn serveConnection(
    app: *App,
    stream: Io.net.Stream,
    active: *Counter,
) Io.Cancelable!void {
    const io = app.io;
    defer _ = active.fetchSub(1, .monotonic);
    defer stream.close(io);

    const timeout = app.config.connection_timeout_s;
    const watchdog_args = .{ io, stream, timeout };
    var watchdog = io.concurrent(shutdownAfter, watchdog_args) catch null;
    defer if (watchdog) |*w| w.cancel(io) catch {};

    var recv_buffer: [recv_buffer_len]u8 = undefined;
    var send_buffer: [send_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var raw = server.receiveHead() catch return;
        const keep_alive = handleRequest(app, &raw, stream.socket.address);
        if (!keep_alive) return;
    }
}

fn shutdownAfter(
    io: Io,
    stream: Io.net.Stream,
    seconds: u32,
) Io.Cancelable!void {
    try io.sleep(.fromSeconds(seconds), .awake);
    stream.shutdown(io, .both) catch {};
}

/// Handles one request; returns whether the connection may be reused.
fn handleRequest(
    app: *App,
    raw: *http.Server.Request,
    peer: Io.net.IpAddress,
) bool {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var keep_alive = raw.head.keep_alive;
    const max_body = app.config.maxRequestBytes();
    const parsed = Request.fromHttp(arena, raw, peer, max_body);
    const response = if (parsed) |req| r: {
        var request = req;
        break :r dispatch(app, arena, &request);
    } else |err| r: {
        // The body was not fully consumed; the stream is out of sync.
        keep_alive = false;
        break :r errors.toResponse(arena, err);
    };
    send(arena, raw, response, keep_alive) catch return false;
    return keep_alive;
}

fn send(
    arena: std.mem.Allocator,
    raw: *http.Server.Request,
    response: Response,
    keep_alive: bool,
) !void {
    var headers: std.ArrayList(http.Header) = .empty;
    try headers.appendSlice(arena, &.{
        .{ .name = "content-type", .value = response.content_type },
        .{ .name = "cache-control", .value = response.cache_control },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "same-origin" },
    });
    if (response.set_cookie) |v| {
        try headers.append(arena, .{ .name = "set-cookie", .value = v });
    }
    if (response.location) |v| {
        try headers.append(arena, .{ .name = "location", .value = v });
    }
    if (response.csp) |v| {
        try headers.append(arena, .{
            .name = "content-security-policy",
            .value = v,
        });
    }
    try raw.respond(response.body, .{
        .status = response.status,
        .keep_alive = keep_alive,
        .extra_headers = headers.items,
    });
}

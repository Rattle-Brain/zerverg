//! TCP listener and per-connection HTTP/1.1 loop.
//!
//! Defences applied here, before any routing:
//!   - global and per-client connection caps
//!   - a per-connection lifetime watchdog (slowloris, idle keep-alive)
//!   - a cap on requests per connection
//!   - per-client request rate limiting

const std = @import("std");
const Io = std.Io;
const http = std.http;

const App = @import("../App.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const client_key = @import("client_key.zig");
const headers = @import("headers.zig");
const errors = @import("errors.zig");
const dispatch = @import("../routes.zig").dispatch;

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
    const key = client_key.of(stream.socket.address);
    if (active.load(.monotonic) >= app.config.max_connections or
        !app.connections.acquire(key))
    {
        stream.close(io);
        return;
    }
    _ = active.fetchAdd(1, .monotonic);
    group.concurrent(io, serveConnection, .{ app, stream, active }) catch {
        _ = active.fetchSub(1, .monotonic);
        app.connections.release(key);
        stream.close(io);
    };
}

fn serveConnection(
    app: *App,
    stream: Io.net.Stream,
    active: *Counter,
) Io.Cancelable!void {
    const io = app.io;
    const peer = stream.socket.address;
    defer _ = active.fetchSub(1, .monotonic);
    defer app.connections.release(client_key.of(peer));
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

    const max_requests = app.config.max_requests_per_connection;
    var served: u32 = 0;
    while (served < max_requests) : (served += 1) {
        var raw = server.receiveHead() catch return;
        const last = served + 1 == max_requests;
        if (!handleRequest(app, &raw, peer, last)) return;
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
    last: bool,
) bool {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = raw.head.target;

    if (!app.rate_limiter.allow(client_key.of(peer))) {
        const response = errors.toResponse(arena, error.RateLimited);
        send(app, arena, raw, path, response, false) catch {};
        return false;
    }
    var request = Request.fromHttp(arena, raw, peer) catch |err| {
        const response = errors.toResponse(arena, err);
        send(app, arena, raw, "/", response, false) catch {};
        return false;
    };
    const response = dispatch(app, arena, &request);
    const keep_alive = !last and raw.head.keep_alive and
        request.canKeepAlive();
    send(app, arena, raw, request.path, response, keep_alive) catch
        return false;
    return keep_alive;
}

fn send(
    app: *App,
    arena: std.mem.Allocator,
    raw: *http.Server.Request,
    path: []const u8,
    response: Response,
    keep_alive: bool,
) !void {
    const extra = try headers.build(arena, &app.config, path, response);
    const options: http.Server.Request.RespondOptions = .{
        .status = response.status,
        .keep_alive = keep_alive,
        .extra_headers = extra,
    };
    if (response.file) |file| {
        defer file.close(app.io);
        return streamFile(app.io, raw, file, response.file_size, options);
    }
    try raw.respond(response.body, options);
}

/// Streams a file body without loading it into memory.
fn streamFile(
    io: Io,
    raw: *http.Server.Request,
    file: Io.File,
    size: u64,
    options: http.Server.Request.RespondOptions,
) !void {
    var body_buffer: [8192]u8 = undefined;
    var body = try raw.respondStreaming(&body_buffer, .{
        .content_length = size,
        .respond_options = options,
    });
    var file_buffer: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    _ = try file_reader.interface.streamRemaining(&body.writer);
    try body.end();
    try raw.server.out.flush();
}

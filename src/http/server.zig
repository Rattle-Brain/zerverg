//! TCP listener and per-connection HTTP/1.1 loop.
//!
//! Two listeners: the public site and the admin console (see
//! auth/guard.zig for why they are separate origins).
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
const guard = @import("../auth/guard.zig");
const dispatch = @import("../routes.zig").dispatch;

const recv_buffer_len = 16 * 1024;
const send_buffer_len = 16 * 1024;

const Counter = std.atomic.Value(u32);

const Listener = struct {
    surface: guard.Surface,
    server: Io.net.Server,
    active: Counter = .init(0),
};

/// Serves the public site and the admin console until cancelled.
pub fn run(app: *App) !void {
    const io = app.io;
    const config = &app.config;
    var public: Listener = .{
        .surface = .public,
        .server = try listen(io, config.listen_address, config.http_port),
    };
    defer public.server.deinit(io);
    var admin: Listener = .{
        .surface = .admin,
        .server = try listen(
            io,
            config.adminListenAddress(),
            config.admin_port,
        ),
    };
    defer admin.server.deinit(io);

    var admin_loop = try io.concurrent(acceptLoop, .{ app, &admin });
    defer admin_loop.cancel(io) catch {};
    try acceptLoop(app, &public);
}

fn listen(io: Io, host: []const u8, port: u16) !Io.net.Server {
    const address = try Io.net.IpAddress.parse(host, port);
    const server = try address.listen(io, .{ .reuse_address = true });
    std.log.info("listening on http://{f}", .{address});
    return server;
}

fn acceptLoop(app: *App, listener: *Listener) Io.Cancelable!void {
    const io = app.io;
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.server.accept(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("accept: {t}", .{err});
            continue;
        };
        spawnConnection(app, &group, listener, stream);
    }
}

fn spawnConnection(
    app: *App,
    group: *Io.Group,
    listener: *Listener,
    stream: Io.net.Stream,
) void {
    const io = app.io;
    const key = client_key.of(stream.socket.address);
    if (listener.active.load(.monotonic) >= app.config.max_connections or
        !app.connections.acquire(key))
    {
        stream.close(io);
        return;
    }
    _ = listener.active.fetchAdd(1, .monotonic);
    group.concurrent(io, serveConnection, .{ app, stream, listener }) catch {
        _ = listener.active.fetchSub(1, .monotonic);
        app.connections.release(key);
        stream.close(io);
    };
}

fn serveConnection(
    app: *App,
    stream: Io.net.Stream,
    listener: *Listener,
) Io.Cancelable!void {
    const io = app.io;
    const peer = stream.socket.address;
    defer _ = listener.active.fetchSub(1, .monotonic);
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
        const exchange: Exchange = .{
            .app = app,
            .raw = &raw,
            .peer = peer,
            .surface = listener.surface,
            .last = served + 1 == max_requests,
        };
        if (!exchange.handle()) return;
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

/// One request/response on a connection.
const Exchange = struct {
    app: *App,
    raw: *http.Server.Request,
    peer: Io.net.IpAddress,
    surface: guard.Surface,
    /// Last request allowed on this connection.
    last: bool,

    /// Handles the request; returns whether the connection may be
    /// reused.
    fn handle(self: Exchange) bool {
        const app = self.app;
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (!app.rate_limiter.allow(client_key.of(self.peer))) {
            const response = errors.toResponse(arena, error.RateLimited);
            self.send(arena, "/", response, false) catch {};
            return false;
        }
        var request = Request.fromHttp(arena, self.raw, self.peer) catch |err| {
            const response = errors.toResponse(arena, err);
            self.send(arena, "/", response, false) catch {};
            return false;
        };
        const response = dispatch(app, arena, &request, self.surface);
        const keep_alive = !self.last and self.raw.head.keep_alive and
            request.canKeepAlive();
        self.send(arena, request.path, response, keep_alive) catch
            return false;
        return keep_alive;
    }

    fn send(
        self: Exchange,
        arena: std.mem.Allocator,
        path: []const u8,
        response: Response,
        keep_alive: bool,
    ) !void {
        const extra = try headers.build(
            arena,
            &self.app.config,
            self.surface,
            path,
            response,
        );
        const options: http.Server.Request.RespondOptions = .{
            .status = response.status,
            .keep_alive = keep_alive,
            .extra_headers = extra,
        };
        if (response.file) |file| {
            defer file.close(self.app.io);
            return streamFile(self.app.io, self.raw, file, response, options);
        }
        try self.raw.respond(response.body, options);
    }
};

/// Streams a file body without loading it into memory.
fn streamFile(
    io: Io,
    raw: *http.Server.Request,
    file: Io.File,
    response: Response,
    options: http.Server.Request.RespondOptions,
) !void {
    var body_buffer: [8192]u8 = undefined;
    var body = try raw.respondStreaming(&body_buffer, .{
        .content_length = response.file_size,
        .respond_options = options,
    });
    var file_buffer: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    _ = try file_reader.interface.streamRemaining(&body.writer);
    try body.end();
    try raw.server.out.flush();
}

//! Entry point: parses the command line and wires the application.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const App = @import("App.zig");
const Store = @import("store/Store.zig");
const Sessions = @import("auth/Sessions.zig");
const LoginLimiter = @import("auth/LoginLimiter.zig");
const password = @import("auth/password.zig");
const server = @import("http/server.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const command = cli.parse(args[1..]) catch |err| {
        std.log.err("{t}", .{err});
        try printToStdout(init.io, cli.usage);
        std.process.exit(2);
    };
    switch (command) {
        .help => try printToStdout(init.io, cli.usage),
        .hash_password => try runHashPassword(init),
        .serve => |options| try runServe(init, options),
    }
}

fn runServe(init: std.process.Init, options: cli.ServeOptions) !void {
    const io = init.io;
    const config = try loadConfig(init, options);
    if (config.dev_mode) warnDevMode();

    var store = try Store.open(io, config.data_dir, .{
        .text_bytes = config.max_text_upload_bytes,
        .image_bytes = config.max_image_bytes,
        .video_bytes = config.max_video_bytes,
        .media_total_bytes = config.max_media_total_bytes,
        .history_keep = config.history_keep,
    });
    defer store.close();
    var sessions = Sessions.init(init.gpa, io, config.session_ttl_s);
    defer sessions.deinit();
    var limiter = LoginLimiter.init(
        init.gpa,
        io,
        config.login_max_failures,
        config.login_lockout_s,
    );
    defer limiter.deinit();

    var app: App = .{
        .gpa = init.gpa,
        .io = io,
        .config = config,
        .store = &store,
        .sessions = &sessions,
        .limiter = &limiter,
    };
    std.log.info("data directory: {s}", .{config.data_dir});
    try server.run(&app);
}

/// Defaults < config file < environment < CLI flags.
fn loadConfig(
    init: std.process.Init,
    options: cli.ServeOptions,
) !config_mod.Config {
    const arena = init.arena.allocator();
    var config = try config_mod.load(arena, init.io, options.config_path);
    config_mod.applyEnvironment(&config, init.environ_map);
    if (options.dev) {
        config.dev_mode = true;
        config.listen_address = "127.0.0.1";
    }
    if (options.listen_address) |v| config.listen_address = v;
    if (options.data_dir) |v| config.data_dir = v;
    if (options.port) |v| config.http_port = v;
    try config_mod.validate(config);
    return config;
}

fn warnDevMode() void {
    std.log.warn(
        \\
        \\  ************************************************************
        \\  * DEVELOPMENT MODE: authentication is DISABLED.            *
        \\  * Anyone who can reach this port can modify the site.      *
        \\  * Never expose this instance to a network you don't own.   *
        \\  ************************************************************
    , .{});
}

/// Reads one line from stdin and prints its argon2id hash.
fn runHashPassword(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [1024]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &buffer);
    const line = try stdin.interface.takeDelimiter('\n') orelse "";
    const pass = std.mem.trimEnd(u8, line, "\r");
    if (pass.len == 0) {
        std.log.err("empty password", .{});
        std.process.exit(1);
    }
    var out: [password.max_hash_len]u8 = undefined;
    const hash = try password.hash(init.gpa, io, pass, &out);
    try printToStdout(io, hash);
    try printToStdout(io, "\n");
}

fn printToStdout(io: Io, text: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("routes.zig");
    _ = @import("http/router.zig");
    _ = @import("http/Request.zig");
    _ = @import("http/errors.zig");
    _ = @import("store/names.zig");
    _ = @import("store/site_state.zig");
    _ = @import("content/meta.zig");
    _ = @import("auth/password.zig");
    _ = @import("auth/Sessions.zig");
    _ = @import("auth/LoginLimiter.zig");
    _ = @import("site/render.zig");
}

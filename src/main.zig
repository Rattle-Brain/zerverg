//! Entry point: parses the command line and wires the application.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const App = @import("App.zig");
const Store = @import("store/Store.zig");
const Sessions = @import("auth/Sessions.zig");
const LoginLimiter = @import("auth/LoginLimiter.zig");
const ConnectionLimiter = @import("http/ConnectionLimiter.zig");
const RateLimiter = @import("http/RateLimiter.zig");
const password = @import("auth/password.zig");
const server = @import("http/server.zig");
const seed = @import("defaults/seed.zig");
const Credentials = @import("auth/Credentials.zig");
const OAuth = @import("auth/oauth/OAuth.zig");
const proxy_auth = @import("auth/proxy_auth.zig");
const tls_identity = @import("tls/identity.zig");

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
    try seed.seedIfFresh(&store, init.arena.allocator());
    std.log.info("data directory: {s}", .{config.data_dir});

    var credentials = try Credentials.init(
        init.gpa,
        io,
        &store,
        config.admin_user,
        config.admin_password_hash,
    );
    if (config.auth_method == .password and credentials.mustChange()) {
        warnDefaultPassword(config);
    }
    var oauth = try OAuth.init(
        init.gpa,
        io,
        config.oauth_providers,
        config.admin_public_url,
    );
    defer oauth.deinit();
    var app: App = .{
        .gpa = init.gpa,
        .io = io,
        .config = config,
        .store = &store,
        .credentials = &credentials,
        .oauth = if (config.auth_method == .oauth) &oauth else null,
        .trusted_proxies = try proxy_auth.parseTrusted(
            init.arena.allocator(),
            config.trusted_proxies,
        ),
        .sessions = undefined,
        .limiter = undefined,
        .connections = undefined,
        .rate_limiter = undefined,
    };
    try serveWithTls(&app, init.arena.allocator());
}

/// Loads the certificate when native TLS is on, then serves.
fn serveWithTls(app: *App, arena: std.mem.Allocator) !void {
    if (!app.config.tls) return serveWithLimits(app);
    var identity = try tls_identity.load(app.gpa, arena, app.io, app.config);
    defer identity.deinit(app.gpa);
    app.tls_identity = &identity;
    try serveWithLimits(app);
}

/// Creates the per-client limiters and session store, then serves.
fn serveWithLimits(app: *App) !void {
    const gpa = app.gpa;
    const io = app.io;
    const config = &app.config;
    var sessions = Sessions.init(gpa, io, config.session_ttl_s);
    defer sessions.deinit();
    var limiter = LoginLimiter.init(
        gpa,
        io,
        config.login_max_failures,
        config.login_lockout_s,
    );
    defer limiter.deinit();
    var connections = ConnectionLimiter.init(
        gpa,
        io,
        config.max_connections_per_ip,
    );
    defer connections.deinit();
    var rate_limiter = RateLimiter.init(
        gpa,
        io,
        config.rate_limit_per_s,
        config.rate_limit_burst,
    );
    defer rate_limiter.deinit();

    app.sessions = &sessions;
    app.limiter = &limiter;
    app.connections = &connections;
    app.rate_limiter = &rate_limiter;
    try server.run(app);
}

fn warnDefaultPassword(config: config_mod.Config) void {
    std.log.warn(
        \\
        \\  ************************************************************
        \\  * DEFAULT CREDENTIALS ACTIVE: admin / admin                *
        \\  * Log in to the console on port {d:<5} and change them.     *
        \\  * Until then, the API refuses everything else.             *
        \\  ************************************************************
    , .{config.admin_port});
}

/// Defaults < config file < environment < CLI flags.
fn loadConfig(
    init: std.process.Init,
    options: cli.ServeOptions,
) !config_mod.Config {
    const arena = init.arena.allocator();
    var config = try config_mod.load(arena, init.io, options.config_path);
    config_mod.applyEnvironment(&config, init.environ_map);
    try config_mod.resolveOAuthSecrets(arena, &config, init.environ_map);
    if (options.dev) {
        config.dev_mode = true;
        config.listen_address = "127.0.0.1";
        config.admin_listen_address = "127.0.0.1";
    }
    if (options.listen_address) |v| config.listen_address = v;
    if (options.data_dir) |v| config.data_dir = v;
    if (options.port) |v| config.http_port = v;
    if (options.admin_port) |v| config.admin_port = v;
    if (options.tls) config.tls = true;
    if (config.tls) config.https = true;
    try config_mod.validate(config);
    return config;
}

fn warnDevMode() void {
    std.log.warn(
        \\
        \\  ************************************************************
        \\  * DEVELOPMENT MODE: authentication is DISABLED.            *
        \\  * Anyone who can reach these ports can modify the site.    *
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
    _ = @import("site/fragments.zig");
    _ = @import("site/entries_tag.zig");
    _ = @import("layout/xml.zig");
    _ = @import("layout/schema.zig");
    _ = @import("layout/render.zig");
    _ = @import("content/validate.zig");
    _ = @import("http/client_key.zig");
    _ = @import("http/ConnectionLimiter.zig");
    _ = @import("http/RateLimiter.zig");
    _ = @import("auth/Credentials.zig");
    _ = @import("auth/oauth/jwt.zig");
    _ = @import("auth/oauth/fetch.zig");
    _ = @import("auth/oauth/Pending.zig");
    _ = @import("auth/oauth/oidc.zig");
    _ = @import("auth/oauth/identity.zig");
    _ = @import("auth/oauth/OAuth.zig");
    _ = @import("auth/proxy_auth.zig");
    _ = @import("defaults/seed.zig");
    _ = @import("http/https_redirect.zig");
    _ = @import("tls/der.zig");
    _ = @import("tls/pem.zig");
    _ = @import("tls/x509.zig");
    _ = @import("tls/local_ca.zig");
    _ = @import("tls/identity.zig");
    _ = @import("content/markdown.zig");
    _ = @import("content/front_matter.zig");
    _ = @import("content/entry.zig");
}

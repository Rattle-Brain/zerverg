//! Runtime configuration: built-in defaults, overridden by a ZON file,
//! overridden by environment variables, overridden by CLI flags.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_path = "/etc/zerverg/zerverg.zon";

pub const Config = struct {
    listen_address: []const u8 = "0.0.0.0",
    http_port: u16 = 7080,
    https_port: u16 = 7443,
    data_dir: []const u8 = "/var/lib/zerverg",

    admin_user: []const u8 = "admin",
    /// Argon2id PHC string, produced by `zerverg hash-password`.
    admin_password_hash: []const u8 = "",
    session_ttl_s: u32 = 8 * 60 * 60,
    login_max_failures: u16 = 5,
    login_lockout_s: u32 = 15 * 60,

    max_connections: u32 = 256,
    connection_timeout_s: u32 = 60,
    max_text_upload_bytes: usize = 2 * 1024 * 1024,
    max_image_bytes: usize = 10 * 1024 * 1024,
    max_video_bytes: usize = 64 * 1024 * 1024,
    max_media_total_bytes: u64 = 2 * 1024 * 1024 * 1024,
    history_keep: u16 = 10,

    /// Only settable through the `--dev` CLI flag, never from a file.
    dev_mode: bool = false,

    /// Largest request body the server will ever accept.
    pub fn maxRequestBytes(self: Config) usize {
        return @max(
            self.max_text_upload_bytes,
            @max(self.max_image_bytes, self.max_video_bytes),
        );
    }
};

pub const LoadError = error{
    ConfigNotFound,
    InvalidConfig,
    MissingAdminPasswordHash,
} || Allocator.Error;

/// Loads the config file. A missing file is only an error when the
/// path was given explicitly; otherwise defaults are used.
pub fn load(
    arena: Allocator,
    io: Io,
    explicit_path: ?[]const u8,
) LoadError!Config {
    const path = explicit_path orelse default_path;
    const source = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(64 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            if (explicit_path != null) return error.ConfigNotFound;
            return .{};
        },
        else => return error.InvalidConfig,
    };
    return parse(arena, source);
}

fn parse(arena: Allocator, source: [:0]const u8) LoadError!Config {
    var diag: std.zon.parse.Diagnostics = .{};
    var config = std.zon.parse.fromSliceAlloc(
        Config,
        arena,
        source,
        &diag,
        .{ .free_on_error = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            std.log.err("config: {f}", .{diag});
            return error.InvalidConfig;
        },
    };
    config.dev_mode = false;
    return config;
}

/// Environment variables win over the file, which suits containers
/// where secrets arrive through the environment.
pub fn applyEnvironment(
    config: *Config,
    env: *const std.process.Environ.Map,
) void {
    if (env.get("ZERVERG_ADMIN_USER")) |v| config.admin_user = v;
    if (env.get("ZERVERG_ADMIN_PASSWORD_HASH")) |v| {
        config.admin_password_hash = v;
    }
    if (env.get("ZERVERG_DATA_DIR")) |v| config.data_dir = v;
    if (env.get("ZERVERG_LISTEN")) |v| config.listen_address = v;
}

pub fn validate(config: Config) LoadError!void {
    if (config.dev_mode) return;
    if (config.admin_password_hash.len == 0) {
        return error.MissingAdminPasswordHash;
    }
}

test "parse overrides only given fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const config = try parse(
        arena_state.allocator(),
        ".{ .http_port = 9000, .dev_mode = true }",
    );
    try std.testing.expectEqual(@as(u16, 9000), config.http_port);
    try std.testing.expectEqual(@as(u16, 10), config.history_keep);
    try std.testing.expect(!config.dev_mode);
}

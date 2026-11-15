//! Runtime configuration: built-in defaults, overridden by a ZON file,
//! overridden by environment variables, overridden by CLI flags.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const names = @import("store/names.zig");
const fetch = @import("auth/oauth/fetch.zig");

pub const default_path = "/etc/zerverg/zerverg.zon";

pub const AuthMethod = enum {
    /// Username + password (console login or HTTP Basic).
    password,
    /// "Sign in with Google / GitHub / any OpenID Connect provider".
    oauth,
    /// A trusted reverse proxy (Authelia, oauth2-proxy, ...) passes
    /// the authenticated user in a header.
    proxy,
};

pub const OAuthKind = enum {
    /// OpenID Connect with Google's issuer preset.
    google,
    /// GitHub OAuth apps (GitHub does not do OpenID Connect).
    github,
    /// Any OpenID Connect provider: set `issuer`.
    oidc,
};

pub const OAuthProvider = struct {
    /// Slug used in URLs: /api/v1/auth/oauth/<name>/callback.
    name: []const u8,
    kind: OAuthKind,
    /// Button text in the console; defaults to the name.
    label: []const u8 = "",
    /// `oidc` only, e.g. "https://gitlab.com".
    issuer: []const u8 = "",
    client_id: []const u8,
    client_secret: []const u8 = "",
    /// Read the secret from this environment variable instead.
    client_secret_env: []const u8 = "",
    /// Required. Who may log in:
    ///   google/oidc: verified e-mail addresses, or "sub:<subject>"
    ///   github: "id:<numeric id>" (recommended), or a login name
    allowed_users: []const []const u8 = &.{},

    pub fn issuerUrl(self: OAuthProvider) []const u8 {
        return switch (self.kind) {
            .google => "https://accounts.google.com",
            .github => "",
            .oidc => self.issuer,
        };
    }
};

pub const Config = struct {
    listen_address: []const u8 = "0.0.0.0",
    http_port: u16 = 7080,
    https_port: u16 = 7443,
    data_dir: []const u8 = "/var/lib/zerverg",

    /// The admin console's own listener. A separate port is a
    /// separate browser origin, which keeps site snippets away from
    /// the console session. Null address: same as `listen_address`.
    admin_listen_address: ?[]const u8 = null,
    admin_port: u16 = 9080,

    auth_method: AuthMethod = .password,
    admin_user: []const u8 = "admin",
    /// Argon2id PHC string, produced by `zerverg hash-password`. When
    /// set, it is authoritative and the console cannot change it.
    /// When empty, the console-managed password is used, and on a
    /// fresh install that is `admin` (a change is forced on login).
    admin_password_hash: []const u8 = "",
    /// `oauth`: the providers offered on the console login page.
    oauth_providers: []const OAuthProvider = &.{},
    /// `oauth`: the console's public base URL, e.g.
    /// "https://admin.example.com" or "http://localhost:9080". The
    /// callback URL registered with each provider is
    /// <admin_public_url>/api/v1/auth/oauth/<name>/callback.
    admin_public_url: []const u8 = "",
    /// `proxy`: header carrying the authenticated user name.
    proxy_user_header: []const u8 = "x-forwarded-user",
    /// `proxy`: IPs allowed to set that header. Required.
    trusted_proxies: []const []const u8 = &.{},
    /// `proxy`: optional allowlist of user names.
    proxy_allowed_users: []const []const u8 = &.{},
    session_ttl_s: u32 = 8 * 60 * 60,
    login_max_failures: u16 = 5,
    login_lockout_s: u32 = 15 * 60,

    /// Hard ceiling for any request body; per-type limits below must
    /// not exceed it.
    max_body_bytes: usize = 128 * 1024 * 1024,
    max_text_upload_bytes: usize = 4 * 1024 * 1024,
    max_image_bytes: usize = 20 * 1024 * 1024,
    max_video_bytes: usize = 128 * 1024 * 1024,
    max_media_total_bytes: u64 = 2 * 1024 * 1024 * 1024,
    history_keep: u16 = 10,

    max_connections: u32 = 256,
    max_connections_per_ip: u32 = 16,
    max_requests_per_connection: u32 = 1000,
    connection_timeout_s: u32 = 60,
    /// Requests per second per client; 0 disables rate limiting.
    rate_limit_per_s: u32 = 20,
    rate_limit_burst: u32 = 120,

    /// Content-Security-Policy for public pages. Scripts only from
    /// this origin (snippets), so inline <script> in posts is inert.
    public_csp: []const u8 = "default-src 'self'; " ++
        "img-src 'self' data: https:; media-src 'self' https:; " ++
        "style-src 'self' 'unsafe-inline'; script-src 'self'; " ++
        "object-src 'none'; base-uri 'self'; form-action 'self'; " ++
        "frame-ancestors 'none'",
    /// Set when the site is served over HTTPS (e.g. behind a TLS
    /// proxy): adds HSTS and marks the session cookie Secure. Implied
    /// by `tls`.
    https: bool = false,

    /// Native TLS: the site is served on `https_port`, the console on
    /// `admin_port` with TLS, and `http_port` only redirects to HTTPS.
    tls: bool = false,
    /// PEM certificate chain (leaf first) and private key. Both empty:
    /// a local certificate authority in <data_dir>/tls/ signs one.
    tls_cert_file: []const u8 = "",
    tls_key_file: []const u8 = "",
    /// Without cert files: extra DNS names or IPs the generated server
    /// certificate is valid for (localhost, 127.0.0.1, ::1 and this
    /// machine's host name are always included).
    tls_hosts: []const []const u8 = &.{},

    /// Only settable through the `--dev` CLI flag, never from a file.
    dev_mode: bool = false,

    pub fn adminListenAddress(config: Config) []const u8 {
        return config.admin_listen_address orelse config.listen_address;
    }
};

pub const LoadError = error{
    ConfigNotFound,
    InvalidConfig,
    LimitAboveMaxBody,
    MissingOAuthProviders,
    InvalidAdminPublicUrl,
    InvalidOAuthProvider,
    MissingOAuthSecret,
    MissingOAuthAllowlist,
    MissingTrustedProxies,
    InvalidTrustedProxy,
    IncompleteTlsFiles,
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
    @setEvalBranchQuota(10_000); // ZON parsing unrolls per field
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
    if (env.get("ZERVERG_ADMIN_LISTEN")) |v| config.admin_listen_address = v;
    if (env.get("ZERVERG_TLS_CERT")) |v| config.tls_cert_file = v;
    if (env.get("ZERVERG_TLS_KEY")) |v| config.tls_key_file = v;
}

pub fn validate(config: Config) LoadError!void {
    const limits = [_]usize{
        config.max_text_upload_bytes,
        config.max_image_bytes,
        config.max_video_bytes,
    };
    for (limits) |limit| {
        if (limit > config.max_body_bytes) return error.LimitAboveMaxBody;
    }
    const has_cert = config.tls_cert_file.len > 0;
    if (has_cert != (config.tls_key_file.len > 0)) {
        return error.IncompleteTlsFiles;
    }
    switch (config.auth_method) {
        .password => {},
        .oauth => try validateOAuth(config),
        .proxy => {
            if (config.trusted_proxies.len == 0) {
                return error.MissingTrustedProxies;
            }
            for (config.trusted_proxies) |ip| {
                _ = Io.net.IpAddress.parse(ip, 0) catch
                    return error.InvalidTrustedProxy;
            }
        },
    }
}

fn validateOAuth(config: Config) LoadError!void {
    if (config.oauth_providers.len == 0) return error.MissingOAuthProviders;
    if (!isPublicUrl(config.admin_public_url)) {
        return error.InvalidAdminPublicUrl;
    }
    for (config.oauth_providers, 0..) |p, i| {
        names.validateSlug(p.name) catch return error.InvalidOAuthProvider;
        for (config.oauth_providers[0..i]) |other| {
            if (std.mem.eql(u8, other.name, p.name)) {
                return error.InvalidOAuthProvider;
            }
        }
        if (p.client_id.len == 0) return error.InvalidOAuthProvider;
        if (p.kind == .oidc and !isPublicUrl(p.issuer)) {
            return error.InvalidOAuthProvider;
        }
        if (p.client_secret.len == 0) return error.MissingOAuthSecret;
        // Without an allowlist, any account at the provider could log
        // in. Never allowed.
        if (p.allowed_users.len == 0) return error.MissingOAuthAllowlist;
    }
}

/// https, or http on loopback for local setups; no trailing slash.
fn isPublicUrl(url: []const u8) bool {
    if (url.len == 0 or url[url.len - 1] == '/') return false;
    return fetch.isAllowedUrl(url);
}

/// Fills `client_secret` from `client_secret_env` where requested.
pub fn resolveOAuthSecrets(
    arena: Allocator,
    config: *Config,
    env: *const std.process.Environ.Map,
) Allocator.Error!void {
    const providers = try arena.dupe(OAuthProvider, config.oauth_providers);
    for (providers) |*p| {
        if (p.client_secret_env.len == 0) continue;
        p.client_secret = env.get(p.client_secret_env) orelse "";
    }
    config.oauth_providers = providers;
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

test "tls needs both or neither PEM file" {
    try validate(.{ .tls = true });
    try validate(.{ .tls_cert_file = "c.pem", .tls_key_file = "k.pem" });
    try std.testing.expectError(
        error.IncompleteTlsFiles,
        validate(.{ .tls_cert_file = "c.pem" }),
    );
}

test "oauth validation refuses open allowlists" {
    var config: Config = .{
        .auth_method = .oauth,
        .admin_public_url = "https://admin.example.com",
        .oauth_providers = &.{.{
            .name = "google",
            .kind = .google,
            .client_id = "id",
            .client_secret = "secret",
        }},
    };
    try std.testing.expectError(error.MissingOAuthAllowlist, validate(config));
    config.admin_public_url = "http://admin.example.com";
    try std.testing.expectError(error.InvalidAdminPublicUrl, validate(config));
}

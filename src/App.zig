//! Process-wide state shared by every request handler.

const std = @import("std");

const Config = @import("config.zig").Config;
const Store = @import("store/Store.zig");
const Sessions = @import("auth/Sessions.zig");
const LoginLimiter = @import("auth/LoginLimiter.zig");
const ConnectionLimiter = @import("http/ConnectionLimiter.zig");
const RateLimiter = @import("http/RateLimiter.zig");
const Credentials = @import("auth/Credentials.zig");
const OAuth = @import("auth/oauth/OAuth.zig");

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
store: *Store,
sessions: *Sessions,
limiter: *LoginLimiter,
connections: *ConnectionLimiter,
rate_limiter: *RateLimiter,
credentials: *Credentials,
/// Set when `auth_method == .oauth`.
oauth: ?*OAuth = null,
/// Parsed `trusted_proxies`, for `auth_method == .proxy`.
trusted_proxies: []const std.Io.net.IpAddress = &.{},

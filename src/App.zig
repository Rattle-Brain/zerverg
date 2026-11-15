//! Process-wide state shared by every request handler.

const std = @import("std");

const Config = @import("config.zig").Config;
const Store = @import("store/Store.zig");
const Sessions = @import("auth/Sessions.zig");
const LoginLimiter = @import("auth/LoginLimiter.zig");
const ConnectionLimiter = @import("http/ConnectionLimiter.zig");
const RateLimiter = @import("http/RateLimiter.zig");

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
store: *Store,
sessions: *Sessions,
limiter: *LoginLimiter,
connections: *ConnectionLimiter,
rate_limiter: *RateLimiter,

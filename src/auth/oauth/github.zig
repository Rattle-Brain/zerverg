//! GitHub OAuth apps. GitHub has no ID tokens, so after the code
//! exchange we ask its API who the token belongs to, then drop the
//! token: we only ever request `read:user`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const fetch = @import("fetch.zig");
const Identity = @import("identity.zig").Identity;

pub const authorize_endpoint = "https://github.com/login/oauth/authorize";
pub const token_endpoint = "https://github.com/login/oauth/access_token";
const user_endpoint = "https://api.github.com/user";
pub const scope = "read:user";

pub const Error = error{InvalidGitHubReply} || fetch.Error;

pub fn identify(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    form: []const u8,
) Error!Identity {
    const token = try exchangeCode(gpa, io, arena, form);
    const body = try fetch.json(gpa, io, arena, .{
        .url = user_endpoint,
        .bearer_token = token,
    });
    const User = struct { login: []const u8, id: u64 };
    const user = std.json.parseFromSliceLeaky(User, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidGitHubReply;
    return .{
        .subject = try std.fmt.allocPrint(arena, "{d}", .{user.id}),
        .login = user.login,
    };
}

/// GitHub answers 200 even on failure, with an `error` field.
fn exchangeCode(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    form: []const u8,
) Error![]const u8 {
    const body = try fetch.json(gpa, io, arena, .{
        .url = token_endpoint,
        .form = form,
    });
    const Reply = struct {
        access_token: []const u8 = "",
        @"error": []const u8 = "",
    };
    const reply = std.json.parseFromSliceLeaky(Reply, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidGitHubReply;
    if (reply.@"error".len > 0) {
        std.log.warn("oauth: github refused the code: {s}", .{reply.@"error"});
        return error.ProviderRejected;
    }
    if (reply.access_token.len == 0) return error.InvalidGitHubReply;
    return reply.access_token;
}

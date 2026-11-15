//! Helpers shared by the REST handlers.

const std = @import("std");

const Context = @import("../Context.zig");

/// Parses an optional `?version=N` query parameter.
pub fn optionalVersion(ctx: *Context) !?u32 {
    const raw = ctx.request.queryParam("version") orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch error.InvalidVersion;
}

pub fn requiredVersion(ctx: *Context) !u32 {
    return try optionalVersion(ctx) orelse error.InvalidVersion;
}

/// Parses the request body as JSON into `T`, allocating in the arena.
pub fn parseJsonBody(comptime T: type, ctx: *Context) !T {
    return std.json.parseFromSliceLeaky(T, ctx.arena, ctx.request.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

//! REST handlers for the versioned libraries (layouts, styles,
//! snippets). One generic set of handlers, instantiated per kind.
//!
//!   GET    /api/v1/<kind>                      list
//!   GET    /api/v1/<kind>/:name[?version=N]    raw content
//!   PUT    /api/v1/<kind>/:name                upload new version
//!   DELETE /api/v1/<kind>/:name                delete with history
//!   GET    /api/v1/<kind>/:name/versions       version numbers
//!   POST   /api/v1/<kind>/:name/rollback?version=N

const std = @import("std");

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const library = @import("../store/library.zig");
const common = @import("common.zig");

pub fn Handlers(comptime kind: library.Kind) type {
    return struct {
        pub fn list(ctx: *Context) !Response {
            const items = try library.list(ctx.app.store, ctx.arena, kind);
            return Response.json(ctx.arena, .ok, items);
        }

        pub fn get(ctx: *Context) !Response {
            const data = try library.read(
                ctx.app.store,
                ctx.arena,
                kind,
                ctx.request.param("name"),
                try common.optionalVersion(ctx),
            );
            return .{ .content_type = kind.contentType(), .body = data };
        }

        pub fn put(ctx: *Context) !Response {
            const name = ctx.request.param("name");
            const version = try library.upload(
                ctx.app.store,
                ctx.arena,
                kind,
                name,
                ctx.request.body,
            );
            return Response.json(ctx.arena, .created, .{
                .name = name,
                .version = version,
            });
        }

        pub fn remove(ctx: *Context) !Response {
            const name = ctx.request.param("name");
            try library.remove(ctx.app.store, kind, name);
            return Response.noContent();
        }

        pub fn versions(ctx: *Context) !Response {
            const found = try library.versions(
                ctx.app.store,
                ctx.arena,
                kind,
                ctx.request.param("name"),
            );
            return Response.json(ctx.arena, .ok, found);
        }

        pub fn rollback(ctx: *Context) !Response {
            const name = ctx.request.param("name");
            const version = try common.requiredVersion(ctx);
            try library.rollback(ctx.app.store, kind, name, version);
            return Response.json(ctx.arena, .ok, .{
                .name = name,
                .version = version,
            });
        }
    };
}

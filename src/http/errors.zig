//! Maps handler errors to HTTP responses in one place.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const Response = @import("Response.zig");

pub fn toResponse(arena: Allocator, err: anyerror) Response {
    const status = statusOf(err);
    if (status == .internal_server_error) {
        std.log.err("request failed: {t}", .{err});
        return Response.jsonError(status, "InternalError");
    }
    return Response.json(arena, status, .{ .@"error" = @errorName(err) }) catch
        Response.jsonError(.internal_server_error, "OutOfMemory");
}

fn statusOf(err: anyerror) http.Status {
    return switch (err) {
        error.NotFound,
        error.FileNotFound,
        => .not_found,
        error.BadRequest,
        error.InvalidName,
        error.InvalidDate,
        error.InvalidKind,
        error.InvalidVersion,
        error.InvalidJson,
        error.InvalidTitle,
        error.MissingSlug,
        error.TooManySnippets,
        error.InvalidContent,
        error.InvalidXml,
        error.XmlUnsupportedFeature,
        error.XmlTooDeep,
        error.XmlTooLarge,
        error.UnknownLayoutElement,
        error.UnknownLayoutAttribute,
        error.MissingLayoutAttribute,
        error.InvalidLayoutContent,
        error.InvalidLayoutValue,
        error.LayoutNeedsOneMain,
        => .bad_request,
        error.UriTooLong => .uri_too_long,
        error.Unauthorized => .unauthorized,
        error.Forbidden => .forbidden,
        error.MethodNotAllowed => .method_not_allowed,
        error.TooLarge, error.StreamTooLong => .payload_too_large,
        error.UnsupportedMediaType,
        error.ContentMismatch,
        => .unsupported_media_type,
        error.TooManyAttempts, error.RateLimited => .too_many_requests,
        error.QuotaExceeded, error.NoSpaceLeft => .insufficient_storage,
        error.TooManySessions => .service_unavailable,
        else => .internal_server_error,
    };
}

test "known errors map to client statuses" {
    try std.testing.expectEqual(
        http.Status.not_found,
        statusOf(error.NotFound),
    );
    try std.testing.expectEqual(
        http.Status.payload_too_large,
        statusOf(error.TooLarge),
    );
    try std.testing.expectEqual(
        http.Status.internal_server_error,
        statusOf(error.Whatever),
    );
}

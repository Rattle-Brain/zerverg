//! PEM armour: base64 in 64-column lines between BEGIN/END markers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const line_len = 64;

/// `label` is e.g. "CERTIFICATE" or "EC PRIVATE KEY".
pub fn encode(
    arena: Allocator,
    comptime label: []const u8,
    der: []const u8,
) Allocator.Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, encoder.calcSize(der.len));
    _ = encoder.encode(b64, der);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "-----BEGIN " ++ label ++ "-----\n");
    var i: usize = 0;
    while (i < b64.len) : (i += line_len) {
        const end = @min(i + line_len, b64.len);
        try out.appendSlice(arena, b64[i..end]);
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, "-----END " ++ label ++ "-----\n");
    return out.items;
}

test "wraps at 64 columns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try encode(arena_state.allocator(), "X", &([_]u8{0} ** 60));
    var lines = std.mem.splitScalar(u8, text, '\n');
    try std.testing.expectEqualStrings("-----BEGIN X-----", lines.next().?);
    try std.testing.expectEqual(@as(usize, 64), lines.next().?.len);
    try std.testing.expectEqual(@as(usize, 16), lines.next().?.len);
    try std.testing.expectEqualStrings("-----END X-----", lines.next().?);
}

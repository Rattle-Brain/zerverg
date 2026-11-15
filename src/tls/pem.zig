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

/// The DER bytes of the first `label` block in `text`.
pub fn decode(
    arena: Allocator,
    comptime label: []const u8,
    text: []const u8,
) ![]u8 {
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    const start = (std.mem.indexOf(u8, text, begin) orelse
        return error.MissingPemBlock) + begin.len;
    const stop = std.mem.indexOfPos(u8, text, start, end) orelse
        return error.MissingPemBlock;
    const b64 = text[start..stop];
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const out = try arena.alloc(u8, decoder.calcSizeUpperBound(b64.len));
    const len = try decoder.decode(out, b64);
    return out[0..len];
}

test "decode reverses encode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = "any bytes \x00\x01\xff";
    const text = try encode(arena, "THING", data);
    const back = try decode(arena, "THING", text);
    try std.testing.expectEqualSlices(u8, data, back);
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

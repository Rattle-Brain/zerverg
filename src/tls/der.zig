//! Minimal DER encoder: just enough to build one self-signed X.509
//! certificate and its EC private key. Every value is allocated from
//! an arena; nothing here is freed piecemeal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const epoch = std.time.epoch;

pub const Tag = struct {
    pub const integer = 0x02;
    pub const bit_string = 0x03;
    pub const octet_string = 0x04;
    pub const oid = 0x06;
    pub const utf8_string = 0x0c;
    pub const utc_time = 0x17;
    pub const generalized_time = 0x18;
    pub const sequence = 0x30;
    pub const set = 0x31;

    /// `[n]` context-specific, constructed (EXPLICIT wrappers).
    pub fn explicit(n: u5) u8 {
        return 0xa0 | @as(u8, n);
    }

    /// `[n]` context-specific, primitive (IMPLICIT, e.g. SAN entries).
    pub fn implicit(n: u5) u8 {
        return 0x80 | @as(u8, n);
    }
};

/// Encoded OID contents (without tag and length).
pub const Oid = struct {
    pub const ec_public_key = "\x2a\x86\x48\xce\x3d\x02\x01";
    pub const prime256v1 = "\x2a\x86\x48\xce\x3d\x03\x01\x07";
    pub const ecdsa_with_sha256 = "\x2a\x86\x48\xce\x3d\x04\x03\x02";
    pub const common_name = "\x55\x04\x03";
    pub const subject_alt_name = "\x55\x1d\x11";
    pub const ext_key_usage = "\x55\x1d\x25";
    pub const server_auth = "\x2b\x06\x01\x05\x05\x07\x03\x01";
};

/// Tag, definite length, then `content`.
pub fn element(arena: Allocator, tag: u8, content: []const u8) ![]u8 {
    var header: [6]u8 = undefined;
    header[0] = tag;
    var header_len: usize = 2;
    if (content.len < 0x80) {
        header[1] = @intCast(content.len);
    } else {
        const len: u32 = @intCast(content.len);
        const bytes = (32 - @clz(len) + 7) / 8;
        header[1] = 0x80 | @as(u8, @intCast(bytes));
        for (0..bytes) |i| {
            const shift: u5 = @intCast(8 * (bytes - 1 - i));
            header[2 + i] = @truncate(len >> shift);
        }
        header_len += bytes;
    }
    return std.mem.concat(arena, u8, &.{ header[0..header_len], content });
}

/// Wraps the concatenation of `parts` in one element.
pub fn wrap(arena: Allocator, tag: u8, parts: []const []const u8) ![]u8 {
    return element(arena, tag, try std.mem.concat(arena, u8, parts));
}

pub fn sequence(arena: Allocator, parts: []const []const u8) ![]u8 {
    return wrap(arena, Tag.sequence, parts);
}

pub fn oid(arena: Allocator, encoded: []const u8) ![]u8 {
    return element(arena, Tag.oid, encoded);
}

/// Non-negative INTEGER from big-endian magnitude bytes.
pub fn unsigned(arena: Allocator, magnitude: []const u8) ![]u8 {
    var start: usize = 0;
    while (start + 1 < magnitude.len and magnitude[start] == 0) start += 1;
    const trimmed = magnitude[start..];
    const pad: []const u8 = if (trimmed[0] & 0x80 != 0) "\x00" else "";
    return wrap(arena, Tag.integer, &.{ pad, trimmed });
}

/// BIT STRING with no unused bits.
pub fn bitString(arena: Allocator, bytes: []const u8) ![]u8 {
    return wrap(arena, Tag.bit_string, &.{ "\x00", bytes });
}

/// UTCTime before 2050, GeneralizedTime from then on (RFC 5280).
pub fn time(arena: Allocator, unix_seconds: u64) ![]u8 {
    const seconds: epoch.EpochSeconds = .{ .secs = unix_seconds };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    const year: u32 = year_day.year;
    const rest = .{
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    };
    const fmt = "{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z";
    if (year < 2050) {
        const text = try std.fmt.allocPrint(arena, "{d:0>2}" ++ fmt, .{
            year % 100,
        } ++ rest);
        return element(arena, Tag.utc_time, text);
    }
    const text = try std.fmt.allocPrint(arena, "{d:0>4}" ++ fmt, .{
        year,
    } ++ rest);
    return element(arena, Tag.generalized_time, text);
}

test "short and long lengths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const short = try element(arena, Tag.octet_string, "ab");
    try std.testing.expectEqualSlices(u8, "\x04\x02ab", short);
    const long = try element(arena, Tag.octet_string, &([_]u8{0} ** 300));
    try std.testing.expectEqualSlices(u8, "\x04\x82\x01\x2c", long[0..4]);
}

test "integer padding and time formats" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const int = try unsigned(arena, "\x00\x00\x80\x01");
    try std.testing.expectEqualSlices(u8, "\x02\x03\x00\x80\x01", int);
    const utc = try time(arena, 0);
    try std.testing.expectEqualStrings("700101000000Z", utc[2..]);
    const gen = try time(arena, 2_556_143_999); // 2050-12-31 23:59:59
    try std.testing.expectEqual(Tag.generalized_time, gen[0]);
    try std.testing.expectEqualStrings("20501231235959Z", gen[2..]);
}

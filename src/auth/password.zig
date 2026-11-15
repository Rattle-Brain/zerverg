//! Password hashing and verification (argon2id, PHC string format).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const argon2 = std.crypto.pwhash.argon2;

/// OWASP-recommended parameters: 19 MiB, 2 passes. Kept modest so
/// concurrent login attempts cannot exhaust memory.
const params = argon2.Params.owasp_2id;

pub const max_hash_len = 128;

pub fn hash(
    gpa: Allocator,
    io: Io,
    password: []const u8,
    out: *[max_hash_len]u8,
) ![]const u8 {
    return argon2.strHash(password, .{
        .allocator = gpa,
        .params = params,
    }, out, io);
}

pub fn verify(
    gpa: Allocator,
    io: Io,
    phc_hash: []const u8,
    password: []const u8,
) bool {
    argon2.strVerify(phc_hash, password, .{ .allocator = gpa }, io) catch
        return false;
    return true;
}

/// Constant-time comparison for strings of any length.
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var ha: [Sha256.digest_length]u8 = undefined;
    var hb: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(a, &ha, .{});
    Sha256.hash(b, &hb, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, ha, hb);
}

test "hash then verify" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var buf: [max_hash_len]u8 = undefined;
    const h = try hash(gpa, io, "hunter2", &buf);
    try std.testing.expect(verify(gpa, io, h, "hunter2"));
    try std.testing.expect(!verify(gpa, io, h, "hunter3"));
}

test "constant time eql" {
    try std.testing.expect(constantTimeEql("abc", "abc"));
    try std.testing.expect(!constantTimeEql("abc", "abcd"));
}

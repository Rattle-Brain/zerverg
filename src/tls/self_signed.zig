//! Generates a self-signed ECDSA P-256 certificate, so `tls = true`
//! works out of the box. Browsers will warn about it; it exists for
//! first runs, LANs and testing. Real deployments provide a cert.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const der = @import("der.zig");
const pem = @import("pem.zig");
const Tag = der.Tag;
const Oid = der.Oid;

pub const common_name = "zerverg self-signed";
const validity_s: u64 = 10 * 365 * 24 * 60 * 60;
const backdate_s: u64 = 24 * 60 * 60;

/// PEM-encoded certificate and matching private key.
pub const Pair = struct {
    cert_pem: []const u8,
    key_pem: []const u8,
};

/// Valid for localhost, 127.0.0.1 and ::1, for ten years.
pub fn generate(arena: Allocator, io: Io, now_s: u64) !Pair {
    const key_pair = Ecdsa.KeyPair.generate(io);
    const public_key = key_pair.public_key.toUncompressedSec1();
    var serial: [16]u8 = undefined;
    io.random(&serial);
    serial[0] &= 0x7f;
    serial[0] |= 0x01; // positive and never all zero

    const tbs = try toBeSigned(arena, &serial, &public_key, now_s);
    const signature = try key_pair.sign(tbs, null);
    var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const cert = try der.sequence(arena, &.{
        tbs,
        try signatureAlgorithm(arena),
        try der.bitString(arena, signature.toDer(&sig_buf)),
    });
    const secret = key_pair.secret_key.toBytes();
    return .{
        .cert_pem = try pem.encode(arena, "CERTIFICATE", cert),
        .key_pem = try pem.encode(
            arena,
            "EC PRIVATE KEY",
            try ecPrivateKey(arena, &secret, &public_key),
        ),
    };
}

fn toBeSigned(
    arena: Allocator,
    serial: []const u8,
    public_key: []const u8,
    now_s: u64,
) ![]u8 {
    const name = try distinguishedName(arena);
    const not_before = now_s -| backdate_s;
    return der.sequence(arena, &.{
        try der.element(arena, Tag.explicit(0), "\x02\x01\x02"), // v3
        try der.unsigned(arena, serial),
        try signatureAlgorithm(arena),
        name, // issuer
        try der.sequence(arena, &.{
            try der.time(arena, not_before),
            try der.time(arena, not_before + validity_s),
        }),
        name, // subject
        try subjectPublicKeyInfo(arena, public_key),
        try der.wrap(arena, Tag.explicit(3), &.{try extensions(arena)}),
    });
}

fn signatureAlgorithm(arena: Allocator) ![]u8 {
    return der.sequence(arena, &.{try der.oid(arena, Oid.ecdsa_with_sha256)});
}

fn distinguishedName(arena: Allocator) ![]u8 {
    const attribute = try der.sequence(arena, &.{
        try der.oid(arena, Oid.common_name),
        try der.element(arena, Tag.utf8_string, common_name),
    });
    const rdn = try der.wrap(arena, Tag.set, &.{attribute});
    return der.sequence(arena, &.{rdn});
}

fn curveAlgorithm(arena: Allocator) ![]u8 {
    return der.sequence(arena, &.{
        try der.oid(arena, Oid.ec_public_key),
        try der.oid(arena, Oid.prime256v1),
    });
}

fn subjectPublicKeyInfo(arena: Allocator, public_key: []const u8) ![]u8 {
    return der.sequence(arena, &.{
        try curveAlgorithm(arena),
        try der.bitString(arena, public_key),
    });
}

/// subjectAltName (localhost, 127.0.0.1, ::1) and serverAuth usage.
fn extensions(arena: Allocator) ![]u8 {
    const ipv6_loopback = "\x00" ** 15 ++ "\x01";
    const names = try der.sequence(arena, &.{
        try der.element(arena, Tag.implicit(2), "localhost"),
        try der.element(arena, Tag.implicit(7), "\x7f\x00\x00\x01"),
        try der.element(arena, Tag.implicit(7), ipv6_loopback),
    });
    const usages = try der.sequence(arena, &.{
        try der.oid(arena, Oid.server_auth),
    });
    return der.sequence(arena, &.{
        try extension(arena, Oid.subject_alt_name, names),
        try extension(arena, Oid.ext_key_usage, usages),
    });
}

fn extension(arena: Allocator, id: []const u8, value: []const u8) ![]u8 {
    return der.sequence(arena, &.{
        try der.oid(arena, id),
        try der.element(arena, Tag.octet_string, value),
    });
}

/// SEC1 ECPrivateKey (RFC 5915).
fn ecPrivateKey(
    arena: Allocator,
    secret: []const u8,
    public_key: []const u8,
) ![]u8 {
    return der.sequence(arena, &.{
        "\x02\x01\x01", // version 1
        try der.element(arena, Tag.octet_string, secret),
        try der.wrap(arena, Tag.explicit(0), &.{
            try der.oid(arena, Oid.prime256v1),
        }),
        try der.wrap(arena, Tag.explicit(1), &.{
            try der.bitString(arena, public_key),
        }),
    });
}

test "generated certificate parses and verifies itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const now: u64 = 1_800_000_000;
    const pair = try generate(arena, io, now);

    const begin = "-----BEGIN CERTIFICATE-----\n";
    const end = std.mem.indexOf(u8, pair.cert_pem, "-----END").?;
    const b64 = pair.cert_pem[begin.len..end];
    const decoder = std.base64.standard.decoderWithIgnore("\n");
    const bytes = try arena.alloc(u8, b64.len);
    const len = try decoder.decode(bytes, b64);

    const Certificate = std.crypto.Certificate;
    const cert: Certificate = .{ .buffer = bytes[0..len], .index = 0 };
    const parsed = try cert.parse();
    try std.testing.expectEqualStrings(common_name, parsed.commonName());
    try parsed.verify(parsed, now);
    try parsed.verifyHostName("localhost");
}
